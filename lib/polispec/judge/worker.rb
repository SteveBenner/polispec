#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Judge
    class Worker
      STATM_PATH = "/proc/self/statm"
      ACTIVITY_BYTE = "a"
      WAKE_BYTE = "w"

      def initialize(listener:, token:, master:, life:, activity:)
        @listener = listener
        @token = token
        @master = master
        @life = life
        @activity = activity
        @freshness = Freshness.new(stat_cache: StatCache.new)
        @memo = {}
        @key = nil
        @served = 0
        @stopping = false
        @recycled = false
        @page_bytes = Etc.sysconf(Etc::SC_PAGESIZE)
      end

      def run
        @wake_r, @wake_w = IO.pipe
        %w[TERM INT HUP].each { |name| Signal.trap(name) { wake } }
        Signal.trap("CHLD", "DEFAULT")
        Signal.trap("USR1", "DEFAULT")
        serve
        @recycled ? RECYCLED_STATUS : 0
      end

      private

      def wake
        @wake_w.write_nonblock(WAKE_BYTE)
      rescue IO::WaitWritable, SystemCallError, IOError
        nil
      end

      def serve
        until @stopping
          reap
          ready = IO.select([@listener, @life, @wake_r])
          break if ready[0].include?(@wake_r) || ready[0].include?(@life)

          conn = begin
            @listener.accept_nonblock
          rescue IO::WaitReadable, SystemCallError
            next
          end
          @served += 1
          touch
          handle(conn)
          touch
          @recycled = recycle?
          @stopping = true if @recycled
        end
      end

      def reap
        loop do
          break unless Process.wait(-1, Process::WNOHANG)
        end
      rescue Errno::ECHILD
        nil
      end

      def touch
        @activity.write_nonblock(ACTIVITY_BYTE)
      rescue IO::WaitWritable, SystemCallError, IOError
        nil
      end

      def recycle?
        return true if @served >= WORKER_REQUEST_CAP

        fields = File.read(STATM_PATH).split
        fields[STATM_RESIDENT].to_i * @page_bytes > WORKER_RSS_CAP_MB * BYTES_PER_MB
      rescue SystemCallError
        false
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def millis(from, to)
        ((to - from) * 1000).round(2)
      end

      def handle(conn)
        started = clock
        return unless loopback?(conn)

        line, carry = read_header(conn)
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
          retire_master
          return
        end
        payload = read_payload(conn, bytes, carry)
        return reply(conn, "error", "") unless payload

        outcome = CODE_MODES.include?(mode) ? run_code(mode, harness, payload) : run_judge(mode, harness, payload, caller_pid(caller_text))
        return reply(conn, "error", "") unless outcome

        reply(conn, outcome[:status].to_s, outcome[:body])
        log(mode, harness, payload, outcome[:log_status] || outcome[:status], started, outcome)
      rescue StandardError, ScriptError => error
        reply(conn, "error", "")
        log(mode || "-", harness || "-", nil, "error:#{error.class}", started, { changed: false, fresh_ms: nil, judge_ms: nil }) if started
      ensure
        conn.close unless conn.closed?
      end

      def retire_master
        @stopping = true
        Process.kill("USR1", @master) if Process.ppid == @master
      rescue SystemCallError
        nil
      end

      def run_judge(mode, harness, payload, caller_pid)
        Thread.current[HookMemo::SLOT] = nil
        fresh_started = clock
        key = @freshness.key
        judge_started = clock
        changed = false
        if key != @key
          changed = !@key.nil?
          @key = key
          @memo = {}
          Layers.reset!
          Exceptions.reset!
        end
        begin
          Thread.current[HookMemo::SLOT] = @memo
          Thread.current[Predicates::CALLER] = caller_pid
          status, body = HookCommand.new.judge_request(mode, harness, payload)
        ensure
          Thread.current[HookMemo::SLOT] = nil
          Thread.current[Predicates::CALLER] = nil
          prune
        end
        { status: status, body: body, changed: changed, fresh_ms: millis(fresh_started, judge_started), judge_ms: millis(judge_started, clock) }
      end

      def run_code(mode, harness, payload)
        Thread.current[HookMemo::SLOT] = nil
        cwd = code_cwd(payload)
        return nil unless cwd

        Dir.chdir(cwd) { execute_code(mode, harness, payload) }
      rescue SystemCallError
        nil
      end

      def code_cwd(payload)
        data = JSON.parse(payload)
        cwd = data.is_a?(Hash) ? data["cwd"] : nil
        cwd.is_a?(String) && !cwd.empty? && File.directory?(cwd) ? cwd : nil
      rescue JSON::ParserError
        nil
      end

      def execute_code(mode, harness, payload)
        phase = mode.delete_prefix("code-")
        stdout = StringIO.new
        saved = [$stdin, $stdout, $stderr]
        $stdin = StringIO.new(payload)
        $stdout = stdout
        $stderr = StringIO.new
        judge_started = clock
        log_status = nil
        begin
          status = Polispec::CLI.run(["code-hook", phase, "--harness", harness])
        rescue SystemExit => error
          status = error.status
        rescue StandardError, ScriptError => error
          status = 0
          log_status = "error:#{error.class}"
        ensure
          $stdin, $stdout, $stderr = saved
        end
        reap
        { status: status, body: stdout.string, log_status: log_status, changed: false, fresh_ms: 0.0, judge_ms: millis(judge_started, clock) }
      end

      def prune
        @memo.delete_if { |name, _| name.is_a?(Array) && name[0] == :hook_memo && !KEEP_MEMO.include?(name[1]) }
      end

      def recorded_runtime
        state = Judge.read_state
        state && state["token"] == @token && state["runtime"].is_a?(String) ? File.expand_path(state["runtime"]) : Judge.own_runtime
      end

      def caller_pid(text)
        pid = text.to_i
        return nil unless pid.positive? && File.stat("/proc/#{pid}").uid == Process.uid

        pid
      rescue SystemCallError
        nil
      end

      def loopback?(conn)
        conn.peeraddr[3] == "127.0.0.1"
      rescue SystemCallError, IOError, SocketError
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
            carry = buffer[(index + 1)..] || "".b
            return line.valid_encoding? ? [line, carry] : nil
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

      def read_payload(conn, bytes, carry)
        buffer = (carry || "".b).dup
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

      def reply(conn, status, body)
        conn.write("#{PROTOCOL} #{status} #{body.bytesize}\n#{body}")
      rescue SystemCallError, IOError
        nil
      end

      def log(mode, harness, payload, status, started, outcome)
        tool = payload && payload[/"tool_name"\s*:\s*"([^"]*)"/, 1]&.scrub
        record = {
          "ts" => Time.now.utc.iso8601, "mode" => mode, "harness" => harness, "tool" => tool, "status" => status,
          "duration_ms" => millis(started, clock), "fresh_ms" => outcome[:fresh_ms], "judge_ms" => outcome[:judge_ms],
          "worker" => Process.pid, "key_changed" => outcome[:changed], "via" => "judge"
        }
        Judge.append_log(record)
      rescue JSON::JSONError, EncodingError
        nil
      end
    end
  end
end
