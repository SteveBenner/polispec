#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "fileutils"
require "json"
require "time"

module Polispec
  module Web
    class Server
      LOG_LIMIT = 4 * 1024 * 1024
      ACCESS_FORMAT = "%t %m %U %s %{X-Request-Id}o".freeze
      WATCH_INTERVAL = 30
      RELEASE_EXIT = 75

      class Refused < Polispec::Error
        attr_reader :code

        def initialize(code, message)
          super(message)
          @code = code
        end
      end

      class LogFile
        def initialize(path, limit = LOG_LIMIT)
          @path = path
          @limit = limit
          @lock = Mutex.new
          @io = open_log
        end

        def <<(text)
          @lock.synchronize do
            rotate if @io.size >= @limit
            @io << text
          end
          self
        end

        def close
          @lock.synchronize { @io.close unless @io.closed? }
        end

        private

        def open_log
          io = File.open(@path, File::WRONLY | File::APPEND | File::CREAT, 0o600)
          io.sync = true
          io
        end

        def rotate
          @io.close
          File.rename(@path, "#{@path}.1")
          @io = open_log
        end
      end

      def self.info_path
        File.join(Web.dir, "server.json")
      end

      def self.read_info
        data = JSON.parse(File.read(info_path))
        data.is_a?(Hash) ? data : nil
      rescue SystemCallError, JSON::ParserError
        nil
      end

      def self.alive?(pid)
        return false unless pid.is_a?(Integer) && pid.positive?

        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def self.running
        info = read_info
        info && alive?(info["pid"]) ? info : nil
      end

      def self.stale(info = running)
        return nil unless info

        recorded = info["version"].to_s
        installed = Polispec.version
        return "the running server (pid #{info['pid']}) recorded no release; the installed release is #{installed}" if recorded.empty?

        older = Gem::Version.new(recorded) < Gem::Version.new(installed)
        older ? "the running server (pid #{info['pid']}) serves #{recorded}; the installed release is #{installed}" : nil
      rescue ArgumentError
        "the running server (pid #{info['pid']}) recorded an unreadable release #{recorded.inspect}; the installed release is #{installed}"
      end

      attr_reader :exit_status

      def initialize(bind:, port:, read_only:, exposed:)
        @exit_status = 0
        @launcher = launcher_path
        @root = real_root(Polispec::ROOT)
        @version = Polispec.version
        @bind = bind
        @port = port
        @read_only = read_only
        @exposed = exposed
        @public_origin = Web.public_origin(Engine::Settings.web_public_origin)
        @stopping = false
      end

      def run(&on_ready)
        Web.ensure_dir
        claim_info_file
        secret = Auth.load_secret
        auth = Auth.new(secret: secret)
        @log = LogFile.new(File.join(Web.dir, "server.log"))
        logger = ::WEBrick::Log.new(@log, ::WEBrick::Log::INFO)
        Web.context = Context.new(bind: @bind, port: @port, read_only: @read_only, exposed: @exposed, auth: auth, logger: logger, public_origin: @public_origin)
        serve(logger, auth, &on_ready)
      rescue Errno::EADDRINUSE
        raise Refused.new("port_in_use", "#{@bind}:#{@port} is already in use")
      rescue Errno::EACCES, Errno::EADDRNOTAVAIL => e
        raise Refused.new("bind_failed", "cannot bind #{@bind}:#{@port}: #{e.message}")
      ensure
        release_info_file
        @log&.close
      end

      private

      def serve(logger, auth, &on_ready)
        options = {
          Host: @bind,
          Port: @port,
          Logger: logger,
          AccessLog: [[@log, ACCESS_FORMAT]],
          DoNotReverseLookup: true,
          ServerSoftware: "polispec-web"
        }
        Rackup::Handler::WEBrick.run(App.app, **options) do |server|
          @server = server
          port = server.listeners.first.addr[1]
          Web.context.port = port
          write_info(port)
          install_traps
          start_watch
          Events.emit("polispec.web", event: "start", bind: @bind, port: port, read_only: @read_only)
          on_ready&.call(Info.new(@bind, port, Process.pid, auth, @public_origin))
        end
        Events.emit("polispec.web", event: "stop", bind: @bind, port: Web.context.port)
      end

      Info = Struct.new(:bind, :port, :pid, :auth, :public_origin) do
        def host
          bind.to_s.include?(":") ? "[#{bind}]" : bind
        end

        def url_host
          ["0.0.0.0", "::"].include?(bind) ? "127.0.0.1" : host
        end

        def url(code = auth.mint)
          "#{public_origin || "http://#{url_host}:#{port}"}/#k=#{code}"
        end
      end

      def launcher_path
        File.expand_path($PROGRAM_NAME)
      rescue ArgumentError
        nil
      end

      def real_root(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end

      def release_version(root)
        File.read(File.join(root, "VERSION")).strip
      end

      def installed_release
        root = Polispec::ROOT
        if @launcher && File.exist?(@launcher)
          candidate = File.dirname(File.dirname(File.realpath(@launcher)))
          root = candidate if File.file?(File.join(candidate, "VERSION"))
        end
        root = File.realpath(root)
        [root, release_version(root)]
      rescue SystemCallError
        nil
      end

      def release_label(root, version)
        "#{version} at #{root}"
      end

      def start_watch
        @watcher = Thread.new do
          loop do
            sleep WATCH_INTERVAL
            root, version = installed_release
            next if root.nil? || (root == @root && version == @version)

            release_changed(release_label(@root, @version), release_label(root, version))
            break
          end
        end
      end

      def release_changed(from, to)
        message = "the installed release changed from #{from} to #{to}; exiting so the supervisor restarts it"
        warn "polispec web: #{message}"
        @log << "#{Time.now.utc.iso8601} release changed #{from} -> #{to}\n"
        Events.emit("polispec.web", event: "release_changed", bind: @bind, port: Web.context.port, from: from, to: to)
        @exit_status = RELEASE_EXIT
        stop
      end

      def install_traps
        %w[TERM INT].each do |name|
          Signal.trap(name) { stop }
        end
      end

      def stop
        return if @stopping

        @stopping = true
        Thread.new do
          Web.stop_hooks.each do |hook|
            begin
              hook.call
            rescue StandardError
              nil
            end
          end
          @server&.shutdown
        end
      end

      def claim_info_file
        path = self.class.info_path
        return unless File.exist?(path)

        info = self.class.read_info
        if info && self.class.alive?(info["pid"])
          raise Refused.new("already_running", "polispec web is already running as pid #{info['pid']} on #{info['bind']}:#{info['port']}")
        end

        File.rename(path, "#{path}.stale-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}")
      end

      def write_info(port)
        path = self.class.info_path
        temp = "#{path}.#{Process.pid}.tmp"
        record = { "pid" => Process.pid, "port" => port, "bind" => @bind, "public_origin" => @public_origin, "started_at" => Time.now.utc.iso8601, "version" => @version, "root" => @root }
        File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(record)) }
        File.rename(temp, path)
      end

      def release_info_file
        info = self.class.read_info
        File.delete(self.class.info_path) if info && info["pid"] == Process.pid
      rescue SystemCallError
        nil
      end
    end
  end
end
