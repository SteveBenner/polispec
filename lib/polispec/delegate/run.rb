#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "../delegate"

module Polispec
  module Delegate
    class Run
      OUTPUT_CAP = 8 * 1024 * 1024
      CHUNK = 65_536
      REPLY_LIMIT = 131_072
      TIMEOUT = 3600
      KILL_AFTER = 10
      PHRASE_WAIT = 600
      FINISHED = %w[succeeded failed cancelled timed_out].freeze

      class Confirmer
        def initialize(prompt_w, phrase_r, log)
          @prompt_w = prompt_w
          @phrase_r = phrase_r
          @log = log
        end

        def confirm(phrase, prompt)
          @log.puts(prompt) if prompt
          @log.write("Type exactly: #{phrase}\n> ")
          @log.flush
          @prompt_w.write("#{JSON.generate('phrase' => phrase, 'prompt' => prompt.to_s)}\n")
          @prompt_w.flush
          raise NoAnswer, "no phrase was typed within 10 minutes; nothing was done" unless IO.select([@phrase_r], nil, nil, PHRASE_WAIT)

          line = @phrase_r.gets
          raise NoAnswer, "no phrase was typed within 10 minutes; nothing was done" if line.nil?

          typed = line.chomp
          @log.puts("\n(phrase received, #{typed.length} characters)")
          @log.flush
          typed == phrase
        end
      end

      attr_reader :id, :app, :by, :argv, :project, :started_at

      def self.project_of(argv)
        return "global" if argv.first == "exceptions"

        skip = false
        argv.drop(1).each do |item|
          if skip
            skip = false
          elsif %w[--to --tag].include?(item)
            skip = true
          elsif !item.start_with?("--")
            return item
          end
        end
        nil
      end

      def initialize(app:, by:, argv:)
        @id = "drn_#{SecureRandom.hex(6)}"
        @app = app
        @by = by
        @argv = argv
        @project = self.class.project_of(argv)
        @mutex = Mutex.new
        @state = "running"
        @exit_code = nil
        @prompt = nil
        @cancelled = false
        @timed_out = false
        @term_at = nil
        @started_at = Time.now.utc
        @ended_at = nil
      end

      def log_path
        File.join(Delegate.runs_dir, "#{@id}.log")
      end

      def active?
        !FINISHED.include?(state)
      end

      def state
        @mutex.synchronize { @state }
      end

      def start(close_in_child)
        FileUtils.mkdir_p(Delegate.runs_dir, mode: 0o700)
        log = File.open(log_path, File::WRONLY | File::APPEND | File::CREAT, 0o600)
        prompt_r, prompt_w = IO.pipe
        phrase_r, phrase_w = IO.pipe
        State.append_jsonl("delegate_runs", { "run_id" => @id, "app" => @app, "by" => @by, "argv" => @argv, "started_at" => @started_at.iso8601 })
        @pid = fork { child(log, prompt_r, prompt_w, phrase_r, phrase_w, close_in_child) }
        log.close
        prompt_w.close
        phrase_r.close
        @prompt_r = prompt_r
        @phrase_w = phrase_w
        @monitor = Thread.new { monitor }
        self
      end

      def child(log, prompt_r, prompt_w, phrase_r, phrase_w, close_in_child)
        close_in_child.each { |io| io.close unless io.closed? }
        prompt_r.close
        phrase_w.close
        Process.setsid
        Signal.trap("TERM", "DEFAULT")
        Signal.trap("INT", "DEFAULT")
        $stdin.reopen("/dev/null")
        $stdout.reopen(log)
        $stderr.reopen(log)
        $stdout.sync = true
        $stderr.sync = true
        Polispec::Delegate.via = "delegate:#{@app}:#{@by}"
        Polispec::Operator::Tty.delegate = Confirmer.new(prompt_w, phrase_r, $stdout)
        code = Polispec::CLI.run(@argv)
        $stdout.flush
        exit!(code.is_a?(Integer) ? code : 0)
      rescue SignalException => e
        exit!(128 + (e.signo || 15))
      rescue Exception => e
        begin
          $stdout.puts("polispec: #{e.class}: #{e.message}")
          $stdout.flush
        rescue StandardError
          nil
        end
        exit!(1)
      end

      def monitor
        loop do
          drain_prompts
          status = reap
          if status
            finish(status)
            break
          end
          enforce_deadlines
        end
      rescue StandardError => e
        @mutex.synchronize do
          @state = "failed" if active_state?
          @ended_at ||= Time.now.utc
        end
        conclude("polispec: monitor failed: #{e.class}: #{e.message}")
      ensure
        @prompt_r&.close unless @prompt_r&.closed?
        @phrase_w&.close unless @phrase_w&.closed?
      end

      def active_state?
        !FINISHED.include?(@state)
      end

      def drain_prompts
        ready = IO.select([@prompt_r], nil, nil, 0.2)
        return unless ready

        line = @prompt_r.gets
        return if line.nil?

        data = JSON.parse(line)
        @mutex.synchronize do
          @prompt = { "text" => data["prompt"].to_s, "phrase" => data["phrase"].to_s }
          @state = "waiting_phrase" if active_state?
        end
      rescue JSON::ParserError, IOError
        nil
      end

      def reap
        _, status = Process.wait2(@pid, Process::WNOHANG)
        status
      rescue Errno::ECHILD
        :gone
      end

      def enforce_deadlines
        now = Time.now
        if @term_at.nil? && now - @started_at > TIMEOUT
          @mutex.synchronize { @timed_out = true }
          terminate
        elsif @term_at && now - @term_at > KILL_AFTER && !@killed
          @killed = true
          signal("KILL")
        end
      end

      def terminate
        @term_at = Time.now
        signal("TERM")
      end

      def signal(name)
        Process.kill(name, -@pid)
      rescue SystemCallError
        begin
          Process.kill(name, @pid)
        rescue SystemCallError
          nil
        end
      end

      def finish(status)
        code = status == :gone ? nil : (status.exitstatus || (status.termsig ? 128 + status.termsig : nil))
        @mutex.synchronize do
          @exit_code = code
          @ended_at = Time.now.utc
          @prompt = nil
          @state = if @cancelled then "cancelled"
                   elsif @timed_out then "timed_out"
                   elsif code == 0 then "succeeded"
                   else "failed"
                   end
        end
        conclude(nil)
      end

      def conclude(note)
        File.open(log_path, "a") { |file| file.puts(note) } if note
        duration = ((@ended_at - @started_at) * 1000).to_i
        State.append_jsonl("delegate_runs", { "run_id" => @id, "app" => @app, "by" => @by, "argv" => @argv, "state" => @state, "exit_code" => @exit_code,
                                              "ended_at" => @ended_at.iso8601, "duration_ms" => duration })
        Events.emit("polispec.delegate", app: @app, run_id: @id, by: @by, argv: @argv, result: @state, exit_code: @exit_code, duration_ms: duration)
      end

      def cancel
        @mutex.synchronize do
          return false unless active_state?

          @cancelled = true
        end
        terminate unless @term_at
        true
      end

      def offer_phrase(text)
        @mutex.synchronize do
          return false unless @state == "waiting_phrase"

          @phrase_w.write("#{text}\n")
          @phrase_w.flush
          @prompt = nil
          @state = "running"
          true
        end
      rescue IOError, SystemCallError
        false
      end

      def wait(timeout)
        @monitor&.join(timeout)
      end

      def snapshot(offset)
        info = @mutex.synchronize do
          { state: @state, exit_code: @exit_code, prompt: @prompt, ended_at: @ended_at }
        end
        data, next_offset, truncated = read_chunk(offset)
        {
          "ok" => true, "run_id" => @id, "state" => info[:state], "exit_code" => info[:exit_code], "offset" => next_offset, "data" => data,
          "truncated" => truncated, "prompt" => info[:prompt], "started_at" => @started_at.iso8601, "ended_at" => info[:ended_at]&.iso8601
        }
      end

      def read_chunk(offset)
        size = File.exist?(log_path) ? File.size(log_path) : 0
        capped = size > OUTPUT_CAP
        limit = [size, OUTPUT_CAP].min
        return ["", offset, capped] if offset >= limit

        want = [CHUNK, limit - offset].min
        bytes = File.open(log_path, "rb") do |file|
          file.seek(offset)
          file.read(want).to_s
        end
        more = offset + bytes.bytesize < limit
        loop do
          kept = more ? complete_prefix(bytes) : bytes
          shown = kept.dup.force_encoding("UTF-8").scrub
          return [shown, offset + kept.bytesize, capped] if JSON.generate("data" => shown).bytesize + 1024 <= REPLY_LIMIT || bytes.bytesize <= 1

          bytes = bytes.byteslice(0, bytes.bytesize * 3 / 4)
          more = true
        end
      end

      def complete_prefix(bytes)
        tail = [bytes.bytesize, 3].min
        (1..tail).each do |back|
          byte = bytes.getbyte(bytes.bytesize - back)
          next if byte & 0xC0 == 0x80

          need = if byte >= 0xF0 then 4
                 elsif byte >= 0xE0 then 3
                 elsif byte >= 0xC0 then 2
                 else 1
                 end
          return back < need ? bytes.byteslice(0, bytes.bytesize - back) : bytes
        end
        bytes
      end

      def to_summary
        { "run_id" => @id, "app" => @app, "project" => @project, "state" => state }
      end
    end
  end
end
