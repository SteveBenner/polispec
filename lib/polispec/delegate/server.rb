#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "socket"
require "json"
require_relative "../delegate"
require_relative "grants"
require_relative "run"

module Polispec
  module Delegate
    class Server
      MAX_REQUEST = 16_384
      MAX_REPLY = 131_072
      READ_DEADLINE = 5
      RATE_LIMIT = 60
      MAX_ACTIVE = 2
      KEEP_FINISHED = 50
      LOG_MAX_AGE = 30 * 24 * 3600
      STOP_WAIT = 15
      BY = /\A[A-Za-z0-9 ._@:-]{1,64}\z/.freeze
      RUN_ID = /\Adrn_[0-9a-f]{12}\z/.freeze

      def self.run
        new.run
      end

      def initialize
        @runs = {}
        @order = []
        @hits = Hash.new { |hash, key| hash[key] = [] }
        @mutex = Mutex.new
        @stopping = false
      end

      def run
        reason = refusal
        if reason
          warn "polispec: delegate serve refused: #{reason}"
          return 3
        end

        expire_logs
        begin
          bind
        rescue SystemCallError, ArgumentError => e
          warn "polispec: delegate serve cannot bind #{Delegate.socket_path}: #{e.message}"
          return 1
        end
        serve
        shutdown
        0
      end

      def refusal
        return "the sealed plane is active; delegation is not available on a sealed plane" if Delegate.sealed?
        return "delegation is disabled (#{Delegate.kill_marker} exists)" if File.exist?(Delegate.kill_marker)
        return "a listener already answers on #{Delegate.socket_path}" if listening?

        nil
      end

      def listening?
        path = Delegate.socket_path
        return false unless File.exist?(path)

        UNIXSocket.open(path) { true }
      rescue SystemCallError, ArgumentError
        false
      end

      def expire_logs
        cutoff = Time.now - LOG_MAX_AGE
        Dir.glob(File.join(Delegate.runs_dir, "drn_*.log")).each do |file|
          File.delete(file) if File.file?(file) && File.mtime(file) < cutoff
        end
      rescue SystemCallError
        nil
      end

      def bind
        path = Delegate.socket_path
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        FileUtils.mkdir_p(Delegate.dir, mode: 0o700)
        File.rename(path, "#{path}.stale-#{Time.now.to_i}") if File.exist?(path) || File.symlink?(path)
        @listener = UNIXServer.new(path)
        File.chmod(0o600, path)
        @inode = File.stat(path).ino
        @wake_r, @wake_w = IO.pipe
        %w[TERM INT].each { |name| Signal.trap(name) { @wake_w.write_nonblock("x") rescue nil } }
        warn "polispec: delegate listening on #{path}"
      end

      def serve
        until @stopping
          ready = IO.select([@listener, @wake_r])
          if ready[0].include?(@wake_r)
            @stopping = true
            break
          end
          conn = begin
            @listener.accept_nonblock
          rescue IO::WaitReadable, SystemCallError
            next
          end
          handle(conn)
        end
      end

      def handle(conn)
        return conn.close unless peer_ok?(conn)

        request = read_request(conn)
        reply = request.is_a?(Hash) ? dispatch(request, conn) : request
        write_reply(conn, reply)
      rescue StandardError => e
        write_reply(conn, { "ok" => false, "code" => "error", "detail" => e.class.to_s })
      ensure
        conn.close unless conn.closed?
      end

      def peer_ok?(conn)
        creds = conn.getsockopt(:SOCKET, :PEERCRED).data.unpack("iII")
        creds[1] == Process.uid
      rescue StandardError
        true
      end

      def read_request(conn)
        buffer = +""
        deadline = Time.now + READ_DEADLINE
        until buffer.include?("\n")
          left = deadline - Time.now
          return { "ok" => false, "code" => "timeout" } if left <= 0
          return { "ok" => false, "code" => "too_large" } if buffer.bytesize > MAX_REQUEST
          next unless IO.select([conn], nil, nil, left)

          chunk = conn.read_nonblock(4096, exception: false)
          break if chunk.nil?

          buffer << chunk if chunk.is_a?(String)
        end
        line = buffer.lines.first.to_s
        return { "ok" => false, "code" => "too_large" } if line.bytesize > MAX_REQUEST

        parsed = JSON.parse(line)
        parsed.is_a?(Hash) ? parsed : { "ok" => false, "code" => "invalid" }
      rescue JSON::ParserError
        { "ok" => false, "code" => "invalid" }
      end

      def write_reply(conn, reply)
        text = JSON.generate(reply)
        text = JSON.generate("ok" => false, "code" => "too_large") if text.bytesize + 1 > MAX_REPLY
        conn.write("#{text}\n")
      rescue SystemCallError, IOError
        nil
      end

      def dispatch(request, conn)
        return { "ok" => true, "version" => Polispec.version } if request["op"] == "ping"
        return { "ok" => false, "code" => "disabled" } if File.exist?(Delegate.kill_marker) || Delegate.sealed?

        grant = Grants.authenticate(request["app"], request["token"])
        return { "ok" => false, "code" => "unauthorized" } unless grant
        return { "ok" => false, "code" => "rate_limited" } unless within_rate?(grant["app"])

        case request["op"]
        when "request" then start_run(grant, request, conn)
        when "output" then output(grant, request)
        when "phrase" then phrase(grant, request)
        when "cancel" then cancel(grant, request)
        when "status" then status(grant)
        else { "ok" => false, "code" => "invalid" }
        end
      end

      def within_rate?(app)
        now = Time.now.to_f
        hits = @hits[app]
        hits.reject! { |stamp| now - stamp > 60 }
        return false if hits.length >= RATE_LIMIT

        hits << now
        true
      end

      def start_run(grant, request, conn)
        argv = request["argv"]
        by = request["by"]
        return { "ok" => false, "code" => "invalid", "detail" => "by" } unless by.is_a?(String) && BY.match?(by)

        return { "ok" => false, "code" => "disabled", "detail" => "exceptions.delegate_promote" } if Grants.exceptions_argv?(argv) && Grants.exceptions_locked?

        reason = Grants.covers?(grant, argv)
        return { "ok" => false, "code" => "out_of_scope", "detail" => reason } if reason

        @mutex.synchronize do
          active = @runs.values.select(&:active?)
          project = Run.project_of(argv)
          same = active.find { |run| run.project == project }
          return { "ok" => false, "code" => "busy", "run_id" => same.id } if same
          return { "ok" => false, "code" => "busy" } if active.length >= MAX_ACTIVE

          run = Run.new(app: grant["app"], by: by, argv: argv)
          run.start([@listener, conn, @wake_r, @wake_w])
          @runs[run.id] = run
          @order << run.id
          prune
          { "ok" => true, "run_id" => run.id }
        end
      end

      def prune
        finished = @order.reject { |id| @runs[id].active? }
        (finished.length - KEEP_FINISHED).times do
          id = finished.shift
          @runs.delete(id)
          @order.delete(id)
        end
      end

      def find_run(grant, request)
        id = request["run_id"]
        run = id.is_a?(String) && RUN_ID.match?(id) ? @runs[id] : nil
        run && run.app == grant["app"] ? run : nil
      end

      def output(grant, request)
        run = find_run(grant, request)
        return { "ok" => false, "code" => "not_found" } unless run

        offset = request["offset"]
        return { "ok" => false, "code" => "invalid", "detail" => "offset" } unless offset.is_a?(Integer) && offset >= 0

        run.snapshot(offset)
      end

      def phrase(grant, request)
        run = find_run(grant, request)
        return { "ok" => false, "code" => "not_found" } unless run

        text = request["text"]
        return { "ok" => false, "code" => "invalid", "detail" => "text" } unless text.is_a?(String) && text.bytesize <= 200 && !text.include?("\n") && !text.include?("\r")

        run.offer_phrase(text) ? { "ok" => true } : { "ok" => false, "code" => "not_waiting" }
      end

      def cancel(grant, request)
        run = find_run(grant, request)
        return { "ok" => false, "code" => "not_found" } unless run

        run.cancel
        { "ok" => true }
      end

      def status(grant)
        active = @runs.values.select(&:active?).select { |run| run.app == grant["app"] }.map(&:id)
        { "ok" => true, "version" => Polispec.version, "scope" => Grants.public_scope(grant), "active" => active }
      end

      def shutdown
        @listener.close unless @listener.closed?
        @runs.values.select(&:active?).each(&:cancel)
        deadline = Time.now + STOP_WAIT
        @runs.values.each { |run| run.wait([deadline - Time.now, 0].max) }
        path = Delegate.socket_path
        File.delete(path) if File.socket?(path) && File.stat(path).ino == @inode
      rescue SystemCallError
        nil
      end
    end
  end
end
