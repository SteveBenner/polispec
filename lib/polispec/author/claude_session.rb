#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "open3"
require "securerandom"
require "timeout"

module Polispec
  module Author
    class TimedQueue
      def initialize
        @items = []
        @mutex = Mutex.new
        @cond = ConditionVariable.new
      end

      def push(item)
        @mutex.synchronize do
          @items << item
          @cond.signal
        end
      end

      def pop(timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        @mutex.synchronize do
          while @items.empty?
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return nil if remaining <= 0

            @cond.wait(@mutex, remaining)
          end
          @items.shift
        end
      end
    end

    class ProcessGone < StandardError; end

    class ClaudeSession
      TOOLS = %w[Read Grep Glob].freeze
      PATH_KEYS = %w[file_path path notebook_path].freeze
      DENY_MESSAGE = "polispec author drafts only; it reads the project and the shelf".freeze

      attr_reader :id, :model, :effort, :tools, :usage, :cost, :dir

      def initialize(id: SecureRandom.uuid, roots:, model:, effort:, system_prompt:, resume: false, binary: "claude")
        @id = id
        @roots = roots.map { |root| real(root) }.compact.uniq
        @model = model
        @effort = effort
        @system_prompt = system_prompt
        @resume = resume
        @binary = binary
        @dir = File.join(Author.dir, id)
        @queue = nil
        @closed = false
        @seen_frame = false
        @tools = []
        @usage = {}
        @cost = nil
      end

      def alive?
        !@closed && @wait && @wait.alive?
      end

      def help_flags
        @help_flags ||= begin
          Timeout.timeout(10) do
            out, = Open3.capture2e(@binary, "--help")
            out.to_s
          end
        rescue StandardError
          ""
        end
      end

      def argv
        args = [@binary, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--include-partial-messages", "--replay-user-messages", "--permission-prompts", "host"]
        args += @resume ? ["--resume", @id] : ["--session-id", @id]
        args += ["--model", @model.to_s] if @model && !@model.to_s.empty?
        args += ["--effort", @effort.to_s] if @effort && !@effort.to_s.empty? && help_flags.include?("--effort")
        args += ["--tools", TOOLS.join(","), "--permission-mode", "manual", "--allowedTools", *allow_rules, "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                 "--append-system-prompt", @system_prompt.to_s]
        forbidden = args.find { |arg| arg.to_s.start_with?("--dangerously") }
        raise Polispec::Error, "refusing to start claude with #{forbidden}" if forbidden

        args
      end

      def allow_rules
        @roots.map { |root| "Read(/#{root}/**)" }
      end

      def turn(text, timeout: Bounds::TURN_TIMEOUT, &emit)
        raise Unavailable.new("closed", "the author session is closed") if @closed

        attempts = 0
        started = clock
        begin
          ensure_process
          write_json(type: "user", message: { role: "user", content: text.to_s })
          consume(started + timeout, started, emit)
        rescue ProcessGone => e
          teardown
          if !@seen_frame && attempts < Bounds::RETRIES
            attempts += 1
            sleep(Bounds.jitter(attempts))
            retry
          end
          emit&.call(type: "error", message: "claude exited: #{e.message}")
          raise Unavailable.new("harness_failed", "claude exited before answering: #{e.message}")
        end
      end

      def close
        return if @closed

        @closed = true
        teardown
      end

      def decide(tool_name, input)
        return [false, DENY_MESSAGE] unless TOOLS.include?(tool_name.to_s) && input.is_a?(Hash)

        paths = PATH_KEYS.map { |key| input[key] }.compact
        return [false, DENY_MESSAGE] if tool_name.to_s == "Read" && !input["file_path"].is_a?(String)
        return [false, DENY_MESSAGE] unless paths.all? { |value| value.is_a?(String) && inside?(value) }
        return [false, DENY_MESSAGE] if tool_name.to_s == "Glob" && !glob_ok?(input["pattern"])

        [true, nil]
      end

      private

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def glob_ok?(pattern)
        return true if pattern.nil?
        return false unless pattern.is_a?(String)
        return false if pattern.split("/").include?("..")
        return true unless pattern.start_with?("/", "~")

        cut = pattern.index(/[*?\[{]/)
        prefix = cut ? pattern[0, cut] : pattern
        prefix = File.dirname(prefix) unless prefix.end_with?("/") || File.directory?(prefix)
        inside?(prefix)
      end

      def real(path)
        full = File.expand_path(path.to_s)
        tail = []
        until File.exist?(full) || full == "/"
          tail.unshift(File.basename(full))
          full = File.dirname(full)
        end
        File.join(File.realpath(full), *tail)
      rescue SystemCallError
        nil
      end

      def inside?(path)
        return false if path.to_s.include?("\0")

        resolved = real(File.expand_path(path.to_s, @dir))
        return false unless resolved

        @roots.any? { |root| resolved == root || resolved.start_with?("#{root}/") }
      end

      def ensure_process
        return if @wait && @wait.alive?

        FileUtils.mkdir_p(@dir, mode: 0o700)
        File.chmod(0o700, @dir)
        @queue = TimedQueue.new
        @stderr_tail = +""
        env = ENV.keys.grep(/\APOLISPEC_/).to_h { |key| [key, nil] }
        env["POLISPEC_ACTOR"] = "author:#{@id}"
        begin
          @stdin, stdout, stderr, @wait = Open3.popen3(env, *argv, chdir: @dir, pgroup: true)
        rescue SystemCallError => e
          raise Unavailable.new("harness_missing", "cannot start #{@binary}: #{e.message}")
        end
        queue = @queue
        @reader = Thread.new do
          stdout.each_line { |line| queue.push([:line, line]) }
          queue.push([:eof])
        rescue IOError
          queue.push([:eof])
        end
        @err_reader = Thread.new do
          stderr.each_line do |line|
            @stderr_tail << line
            @stderr_tail = @stderr_tail[-4096..-1] if @stderr_tail.length > 4096
          end
        rescue IOError
          nil
        end
      end

      def write_json(hash)
        @stdin.write("#{JSON.generate(hash)}\n")
        @stdin.flush
      rescue IOError, Errno::EPIPE
        raise ProcessGone, "stdin closed"
      end

      def consume(deadline, started, emit)
        deltas = +""
        assistant = +""
        loop do
          remaining = deadline - clock
          if remaining <= 0
            teardown(hard: true)
            emit&.call(type: "error", message: "turn timed out")
            raise Unavailable.new("timeout", "the author turn timed out")
          end
          item = @queue.pop(remaining)
          next unless item

          if item.first == :eof
            raise ProcessGone, @stderr_tail.to_s.strip[0, 200].to_s
          end

          frame = parse(item.last)
          next unless frame

          @seen_frame = true
          @resume = true
          if Author.kill_switch?
            teardown(hard: true)
            @closed = true
            emit&.call(type: "error", message: "author switched off")
            raise Unavailable.new("kill_switch", "author is switched off")
          end
          done = handle(frame, deltas, assistant, started, emit)
          return done if done
        end
      end

      def parse(line)
        frame = JSON.parse(line)
        frame.is_a?(Hash) ? frame : nil
      rescue JSON::ParserError
        nil
      end

      def handle(frame, deltas, assistant, started, emit)
        case frame["type"]
        when "system"
          init(frame) if frame["subtype"] == "init"
          nil
        when "stream_event"
          event = frame["event"]
          deltas.clear if event.is_a?(Hash) && event["type"] == "message_start"
          delta = event.is_a?(Hash) ? event["delta"] : nil
          if event.is_a?(Hash) && event["type"] == "content_block_delta" && delta.is_a?(Hash) && delta["type"] == "text_delta"
            deltas << delta["text"].to_s
            emit&.call(type: "delta", text: delta["text"].to_s)
          end
          nil
        when "assistant"
          blocks = frame.dig("message", "content")
          assistant.clear if Array(blocks).any? { |block| block.is_a?(Hash) && block["type"] == "text" } && frame["parent_tool_use_id"].nil?
          Array(blocks).each { |block| assistant << block["text"].to_s if block.is_a?(Hash) && block["type"] == "text" }
          nil
        when "control_request"
          control(frame, emit)
          nil
        when "result"
          finish(frame, deltas, assistant, started, emit)
        end
      end

      def init(frame)
        @model = frame["model"] if frame["model"].is_a?(String)
        @tools = Array(frame["tools"]).map(&:to_s)
      end

      def control(frame, emit)
        request = frame["request"]
        request_id = frame["request_id"]
        return unless request.is_a?(Hash)

        if request["subtype"] == "can_use_tool"
          allow, message = decide(request["tool_name"], request["input"])
          payload = allow ? { behavior: "allow", updatedInput: request["input"] } : { behavior: "deny", message: message }
          write_json(type: "control_response", response: { subtype: "success", request_id: request_id, response: payload })
          emit&.call(type: "tool", name: request["tool_name"].to_s, decision: allow ? "allow" : "deny")
        else
          write_json(type: "control_response", response: { subtype: "error", request_id: request_id, error: "unsupported request" })
        end
      end

      def finish(frame, deltas, assistant, started, emit)
        @usage = frame["usage"].is_a?(Hash) ? frame["usage"] : {}
        @cost = frame["total_cost_usd"]
        text = [frame["result"].to_s, deltas, assistant].find { |item| !item.to_s.strip.empty? }.to_s
        if frame["is_error"] == true
          emit&.call(type: "error", message: text.empty? ? "claude reported an error" : text)
          raise Unavailable.new("harness_error", text.empty? ? "claude reported an error" : text)
        end
        done = { type: "done", text: text, session: @id, usage: @usage, cost: @cost, duration_ms: ((clock - started) * 1000).round }
        emit&.call(done)
        done
      end

      def teardown(hard: false)
        stdin = @stdin
        wait = @wait
        @stdin = nil
        @wait = nil
        begin
          stdin&.close
        rescue IOError
          nil
        end
        if wait
          unless !hard && wait.join(2)
            signal("TERM", wait.pid)
            unless wait.join(Bounds::KILL_GRACE)
              signal("KILL", wait.pid)
              wait.join(2)
            end
          end
        end
        [@reader, @err_reader].compact.each { |thread| thread.join(1) || thread.kill }
        @reader = nil
        @err_reader = nil
      end

      def signal(name, pid)
        Process.kill(name, -pid)
      rescue SystemCallError
        begin
          Process.kill(name, pid)
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
