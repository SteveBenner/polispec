#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "socket"
require "json"
require "digest"
require "securerandom"
require "fileutils"
require "open3"
require "time"
require_relative "commands/hook"

module Polispec
  module Judge
    PROTOCOL = "POLISPEC/1"
    HEADER_LIMIT = 512
    HEADER_DEADLINE = 1.0
    PAYLOAD_DEADLINE = 3.0
    DEFAULT_IDLE = 1800
    LOG_LIMIT = 1_048_576
    SHELF_FILE_CAP = 2000
    KEEP_MEMO = %i[ledger_load spec_policy prefetch_policies shipped_layer layers_fingerprint catalog_state catalog_modules catalog_delete_protected].freeze
    HEADER = /\A#{Regexp.escape(PROTOCOL)} (\h{32}) (pretool|session) ([a-z]+) (\S.*?)(?: caller=(\d+))? (\d+)\z/.freeze
    REF_SAFE = %r{\A[A-Za-z0-9][A-Za-z0-9._/@+-]*\z}.freeze

    module_function

    def state_path
      File.join(State.home, "judge.json")
    end

    def log_path
      File.join(State.home, "judge.log")
    end

    def own_runtime
      forced = ENV["POLISPEC_JUDGE_RUNTIME"].to_s.strip
      return File.expand_path(forced) unless forced.empty?

      File.join(Polispec::ROOT, "bin")
    end

    def read_state
      data = JSON.parse(File.read(state_path))
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def listening?(state)
      return false unless state && state["port"].is_a?(Integer)

      Socket.tcp("127.0.0.1", state["port"], connect_timeout: 0.5) { true }
    rescue SystemCallError, IOError, SocketError
      false
    end

    def idle_seconds
      value = ENV["POLISPEC_JUDGE_IDLE"].to_s.strip
      value.match?(/\A\d+\z/) && value.to_i.positive? ? value.to_i : DEFAULT_IDLE
    end

    class Freshness
      def initialize
        @ledger_digest = nil
        @repos = []
      end

      def key
        parts = []
        ledger_path = safely { Ledger.default_path }.to_s
        bytes = ledger_path.empty? ? nil : fileread(ledger_path)
        parts << ledger_path << digest(bytes)
        parts << digest(fileread(rplugin_settings))
        parts << digest(fileread(safely { NativeSettings.path }.to_s))
        parts << digest(fileread(resolved_settings))
        parts << digest(fileread(HarnessControls::Plane::ACTIVE_PATH))
        parts << Polispec.version
        parts << shelf
        parts << catalog
        parts << project_refs(bytes, ledger_path)
        Digest::SHA256.hexdigest(parts.join("\0"))
      end

      private

      def safely
        yield
      rescue StandardError, ScriptError
        nil
      end

      def fileread(path)
        return nil if path.to_s.empty?

        File.file?(path) ? File.binread(path) : nil
      rescue SystemCallError
        nil
      end

      def digest(bytes)
        bytes.nil? ? "-" : Digest::SHA256.hexdigest(bytes)
      end

      def rplugin_settings
        base = ENV["XDG_CONFIG_HOME"].to_s
        base = File.join(Dir.home, ".config") if base.empty?
        File.join(base, "rplugin", "polispec", "settings.yml")
      end

      def resolved_settings
        base = ENV["XDG_STATE_HOME"].to_s
        base = File.join(Dir.home, ".local", "state") if base.empty?
        File.join(base, "rplugin", "polispec", "settings.resolved.json")
      end

      def catalog
        dir = Catalog.state_dir
        files = [Catalog.state_path] + Dir.glob(File.join(dir, Catalog::PROVISION_DIR, "**", "*.yml")).sort
        Digest::SHA256.hexdigest(files.map { |file| "#{file}\0#{digest(fileread(file))}" }.join("\n"))
      rescue StandardError, ScriptError => error
        "catalog:#{error.class}"
      end

      def shelf
        source = Layers.source
        return "none" unless source

        if source.kind == :dir
          root = File.expand_path(source.root)
          files = Dir.glob(File.join(root, "**", "*")).sort.select { |file| File.file?(file) }.first(SHELF_FILE_CAP)
          body = files.map { |file| "#{file.delete_prefix(root)}\0#{digest(fileread(file))}" }
          Digest::SHA256.hexdigest(["dir", root, *body].join("\n"))
        else
          Digest::SHA256.hexdigest(["repo", source.repo, source.ref, source.path, commit_of(source.repo, source.ref)].join("\n"))
        end
      rescue StandardError, ScriptError => error
        "shelf:#{error.class}"
      end

      def project_refs(bytes, ledger_path)
        digest = digest(bytes)
        if digest != @ledger_digest
          @ledger_digest = digest
          @repos = begin
            Ledger.load_uncached(ledger_path).projects.select { |project| project.status == "live" && !project.repo.to_s.empty? && !project.trust_ref.to_s.empty? }.map { |project| [project.id, File.expand_path(project.repo), project.trust_ref.to_s] }
          rescue StandardError, ScriptError
            []
          end
        end
        Digest::SHA256.hexdigest(@repos.map { |id, repo, ref| [id, repo, ref, commit_of(repo, ref)].join("\0") }.join("\n"))
      end

      def commit_of(repo, ref)
        ref = ref.to_s
        found = REF_SAFE.match?(ref) && !ref.include?("..") ? file_ref(repo, ref) : nil
        found || rev_parse(repo, ref)
      end

      def git_dirs(repo)
        dotgit = File.join(repo, ".git")
        dir = nil
        if File.directory?(dotgit)
          dir = dotgit
        elsif File.file?(dotgit)
          line = File.read(dotgit, 512).to_s[/\Agitdir:\s*(.+?)\s*$/, 1]
          dir = File.expand_path(line, repo) if line
        elsif File.file?(File.join(repo, "HEAD"))
          dir = repo
        end
        return [] unless dir

        common = File.join(dir, "commondir")
        shared = File.file?(common) ? File.expand_path(File.read(common).strip, dir) : nil
        [dir, shared].compact.uniq
      rescue SystemCallError
        []
      end

      def file_ref(repo, ref)
        dirs = git_dirs(repo)
        return nil if dirs.empty?

        names = [ref, "refs/#{ref}", "refs/heads/#{ref}", "refs/tags/#{ref}", "refs/remotes/#{ref}"]
        names.each do |name|
          dirs.each do |dir|
            value = follow(dirs, dir, name, 0)
            return value if value
          end
        end
        nil
      rescue SystemCallError
        nil
      end

      def follow(dirs, dir, name, depth)
        return nil if depth > 5

        path = File.join(dir, name)
        if File.file?(path)
          text = File.read(path, 256).to_s.strip
          return text if text.match?(/\A\h{40,64}\z/)
          return follow(dirs, dir, text.delete_prefix("ref: ").strip, depth + 1) if text.start_with?("ref: ")

          return nil
        end
        dirs.each do |base|
          packed = File.join(base, "packed-refs")
          next unless File.file?(packed)

          File.foreach(packed) do |line|
            sha, ref = line.chomp.split(" ", 2)
            return sha if ref == name && sha.to_s.match?(/\A\h{40,64}\z/)
          end
        end
        nil
      end

      def rev_parse(repo, ref)
        out, status = Open3.capture2(PolicySource::GIT_ENV, "git", "-C", repo, "rev-parse", "--verify", "-q", "#{ref}^{commit}", err: File::NULL)
        status.success? ? out.strip : "-"
      rescue SystemCallError
        "-"
      end
    end

    class Server
      attr_reader :token

      def self.run
        new.run
      end

      def initialize
        @freshness = Freshness.new
        @memo = {}
        @key = nil
        @token = SecureRandom.hex(16)
        @stopping = false
        @idle = Judge.idle_seconds
      end

      def run
        state = Judge.read_state
        if state && state["pid"] != Process.pid && Judge.listening?(state)
          warn "polispec: judge already listening on 127.0.0.1:#{state['port']}"
          return 0
        end

        FileUtils.mkdir_p(State.home, mode: 0o700)
        @listener = TCPServer.new("127.0.0.1", 0)
        @wake_r, @wake_w = IO.pipe
        %w[TERM INT HUP].each { |name| Signal.trap(name) { @wake_w.write_nonblock("x") rescue nil } }
        publish
        serve
        0
      ensure
        retire
      end

      private

      def publish
        record = { "port" => @listener.addr[1], "token" => @token, "pid" => Process.pid, "runtime" => Judge.own_runtime, "version" => Polispec.version, "started" => Time.now.utc.iso8601 }
        path = Judge.state_path
        temp = "#{path}.#{Process.pid}.tmp"
        File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write("#{JSON.generate(record)}\n") }
        File.chmod(0o600, temp)
        File.rename(temp, path)
        @published = true
      end

      def retire
        @listener.close if @listener && !@listener.closed?
        return unless @published

        state = Judge.read_state
        File.delete(Judge.state_path) if state && state["token"] == @token
      rescue SystemCallError
        nil
      end

      def serve
        deadline = clock + @idle
        until @stopping
          reap
          remaining = deadline - clock
          break if remaining <= 0

          ready = IO.select([@listener, @wake_r], nil, nil, [remaining, 5].min)
          next unless ready
          break if ready[0].include?(@wake_r)

          conn = begin
            @listener.accept_nonblock
          rescue IO::WaitReadable, SystemCallError
            next
          end
          handle(conn)
          deadline = clock + @idle
        end
      end

      def reap
        loop { break unless Process.wait(-1, Process::WNOHANG) }
      rescue SystemCallError
        nil
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def handle(conn)
        started = clock
        return unless loopback?(conn)

        line = read_header(conn)
        return reply(conn, "error", "") unless line

        match = HEADER.match(line)
        return reply(conn, "error", "") unless match

        token, mode, harness, runtime, caller_text, bytes = match.captures
        return reply(conn, "error", "") unless token.bytesize == @token.bytesize && same_token?(token)

        bytes = bytes.to_i
        return reply(conn, "error", "") if bytes <= 0 || bytes > HookCommand::INPUT_LIMIT
        return reply(conn, "error", "") unless HookCommand::HARNESSES.include?(harness)

        if File.expand_path(runtime) != recorded_runtime
          reply(conn, "stale", "")
          @stopping = true
          return
        end
        payload = read_payload(conn, bytes)
        return reply(conn, "error", "") unless payload

        status, body, changed = judge(mode, harness, payload, caller_pid(caller_text))
        reply(conn, status.to_s, body)
        log(mode, harness, payload, status, started, changed, "judge")
      rescue StandardError, ScriptError => error
        reply(conn, "error", "")
        log(mode || "-", harness || "-", nil, "error:#{error.class}", started, false, "judge") if started
      ensure
        conn.close unless conn.closed?
      end

      def recorded_runtime
        state = Judge.read_state
        state && state["token"] == @token && state["runtime"].is_a?(String) ? File.expand_path(state["runtime"]) : Judge.own_runtime
      end

      def loopback?(conn)
        conn.peeraddr[3] == "127.0.0.1"
      rescue StandardError
        false
      end

      def same_token?(given)
        result = 0
        given.bytes.zip(@token.bytes) { |a, b| result |= a ^ b }
        result.zero?
      end

      def read_header(conn)
        buffer = +"".b
        stop = clock + HEADER_DEADLINE
        loop do
          return nil if buffer.bytesize > HEADER_LIMIT + 1

          index = buffer.index("\n")
          if index
            return nil if index > HEADER_LIMIT

            line = buffer[0...index].dup.force_encoding(Encoding::UTF_8)
            @carry = buffer[(index + 1)..] || "".b
            return line.valid_encoding? ? line : nil
          end

          wait = stop - clock
          return nil if wait <= 0
          return nil unless IO.select([conn], nil, nil, wait)

          chunk = conn.read_nonblock(HEADER_LIMIT + 1 - buffer.bytesize, exception: false)
          return nil if chunk.nil?

          buffer << chunk if chunk.is_a?(String)
        end
      rescue SystemCallError, IOError
        nil
      end

      def read_payload(conn, bytes)
        buffer = (@carry || "".b).dup
        @carry = nil
        stop = clock + PAYLOAD_DEADLINE
        return nil if buffer.bytesize > bytes
        while buffer.bytesize < bytes
          wait = stop - clock
          return nil if wait <= 0
          return nil unless IO.select([conn], nil, nil, wait)

          chunk = conn.read_nonblock([bytes - buffer.bytesize, 65_536].min, exception: false)
          return nil if chunk.nil?
          buffer << chunk if chunk.is_a?(String)
        end
        buffer.force_encoding(Encoding::UTF_8)
      rescue SystemCallError, IOError
        nil
      end

      def judge(mode, harness, payload, caller_pid)
        changed = refresh
        Thread.current[HookMemo::SLOT] = @memo
        Thread.current[Predicates::CALLER] = caller_pid
        status, body = HookCommand.new.judge_request(mode, harness, payload)
        [status, body, changed]
      ensure
        prune
        Thread.current[HookMemo::SLOT] = nil
        Thread.current[Predicates::CALLER] = nil
      end

      def caller_pid(text)
        pid = text.to_i
        return nil unless pid.positive? && File.stat("/proc/#{pid}").uid == Process.uid

        pid
      rescue SystemCallError
        nil
      end

      def refresh
        Thread.current[HookMemo::SLOT] = nil
        key = @freshness.key
        return false if key == @key

        first = @key.nil?
        @key = key
        @memo = {}
        Layers.reset!
        Exceptions.reset!
        !first
      end

      def prune
        @memo.delete_if { |name, _| name.is_a?(Array) && name[0] == :hook_memo && !KEEP_MEMO.include?(name[1]) }
      end

      def reply(conn, status, body)
        conn.write("#{PROTOCOL} #{status} #{body.bytesize}\n#{body}")
      rescue SystemCallError, IOError
        nil
      end

      def log(mode, harness, payload, status, started, changed, via)
        tool = payload && payload[/"tool_name"\s*:\s*"([^"]*)"/, 1]
        record = { "ts" => Time.now.utc.iso8601, "mode" => mode, "harness" => harness, "tool" => tool, "status" => status, "duration_ms" => ((clock - started) * 1000).round(2), "key_changed" => changed, "via" => via }
        path = Judge.log_path
        File.rename(path, "#{path}.1") if File.file?(path) && File.size(path) > LOG_LIMIT
        File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |file| file.write("#{JSON.generate(record)}\n") }
      rescue StandardError
        nil
      end
    end
  end
end
