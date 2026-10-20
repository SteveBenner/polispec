#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "open3"
require "securerandom"

module Polispec
  module Author
    class CodexSession
      attr_reader :id, :model, :effort, :usage, :cost, :dir

      def initialize(id: SecureRandom.uuid, roots:, model:, effort:, system_prompt:, resume: false, binary: "codex")
        @id = id
        @roots = roots
        @model = model
        @effort = effort
        @system_prompt = system_prompt
        @binary = binary
        @dir = File.join(Author.dir, id)
        @thread_id = nil
        @usage = {}
        @cost = nil
        @closed = false
        @pid = nil
      end

      def alive?
        !@closed
      end

      def argv(text)
        head = [@binary, "exec"]
        head += ["resume", @thread_id] if @thread_id
        args = head + ["--json", "--sandbox", "read-only", "--skip-git-repo-check"]
        args += ["-m", @model.to_s] if @model && !@model.to_s.empty?
        args += ["-c", "model_reasoning_effort=\"#{@effort}\""] if @effort && !@effort.to_s.empty?
        prompt = @thread_id ? text.to_s : "#{@system_prompt}\n\n#{text}"
        args << prompt
        forbidden = args.find { |arg| arg.to_s.start_with?("--dangerously") || arg.to_s == "--yolo" }
        raise Polispec::Error, "refusing to start codex with #{forbidden}" if forbidden

        args
      end

      def turn(text, timeout: Bounds::TURN_TIMEOUT, &emit)
        raise Unavailable.new("closed", "the author session is closed") if @closed

        attempts = 0
        started = clock
        begin
          run_once(text, started + timeout, started, emit)
        rescue ProcessGone => e
          if attempts < Bounds::RETRIES
            attempts += 1
            sleep(Bounds.jitter(attempts))
            retry
          end
          emit&.call(type: "error", message: "codex exited: #{e.message}")
          raise Unavailable.new("harness_failed", "codex exited before answering: #{e.message}")
        end
      end

      def close
        @closed = true
        kill("TERM")
      end

      private

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def run_once(text, deadline, started, emit)
        FileUtils.mkdir_p(@dir, mode: 0o700)
        File.chmod(0o700, @dir)
        env = { "POLISPEC_ACTOR" => "author:#{@id}" }
        begin
          stdin, stdout, stderr, wait = Open3.popen3(env, *argv(text), chdir: @dir, pgroup: true)
        rescue SystemCallError => e
          raise Unavailable.new("harness_missing", "cannot start #{@binary}: #{e.message}")
        end
        @pid = wait.pid
        stdin.close
        errors = Thread.new { stderr.read.to_s[0, 400] rescue "" }
        parts = +""
        seen = false
        reader = Thread.new do
          stdout.each_line do |line|
            seen = true if consume_line(line, parts, emit)
          end
        end
        unless reader.join([deadline - clock, 0].max)
          kill("TERM")
          wait.join(Bounds::KILL_GRACE) || kill("KILL")
          emit&.call(type: "error", message: "turn timed out")
          raise Unavailable.new("timeout", "the author turn timed out")
        end
        wait.join(5)
        raise ProcessGone, errors.value.to_s.strip unless seen || !parts.empty?

        done = { type: "done", text: parts, session: @id, usage: @usage, cost: @cost, duration_ms: ((clock - started) * 1000).round }
        emit&.call(done)
        done
      ensure
        [stdout, stderr].compact.each { |io| io.close unless io.closed? }
      end

      def consume_line(line, parts, emit)
        frame = JSON.parse(line)
        return false unless frame.is_a?(Hash)

        case frame["type"]
        when "thread.started"
          @thread_id = frame["thread_id"].to_s unless frame["thread_id"].to_s.empty?
        when "item.completed"
          item = frame["item"]
          if item.is_a?(Hash) && item["type"] == "agent_message"
            parts << item["text"].to_s
            emit&.call(type: "delta", text: item["text"].to_s)
          end
        when "item.started"
          item = frame["item"]
          emit&.call(type: "tool", name: item["type"].to_s, decision: "sandboxed") if item.is_a?(Hash) && item["type"] == "command_execution"
        when "turn.completed"
          @usage = frame["usage"].is_a?(Hash) ? frame["usage"] : {}
        end
        true
      rescue JSON::ParserError
        false
      end

      def kill(name)
        return unless @pid

        Process.kill(name, -@pid)
      rescue SystemCallError
        nil
      end
    end
  end
end
