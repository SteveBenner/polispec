#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "open3"
require "shellwords"

module Polispec
  module Trace
    SILENT_VERBS = %w[hook code-hook].freeze
    FLAG = /\A(?:--verbose(?:=(.*))?|-v)\z/m.freeze
    ENV_TEXT = %w[1 true on text].freeze
    ENV_OFF = ["", "0", "false", "off"].freeze
    FLAG_ERROR = "polispec: --verbose takes text or json".freeze
    ENV_ERROR = "polispec: POLISPEC_VERBOSE takes 1, text, json or off".freeze

    @mode = :off
    @mutex = Mutex.new
    @depth = 0
    @io = nil
    @started = nil
    @file = nil
    @op = nil

    module_function

    def on?
      @mode != :off
    end

    def json?
      @mode == :json
    end

    def extract(argv, env)
      return [argv, nil, nil] if silent?(argv)

      stop = argv.index("--") || argv.length
      kept = []
      mode = nil
      argv.each_with_index do |token, index|
        match = index < stop ? FLAG.match(token) : nil
        unless match
          kept << token
          next
        end
        value = match[1]
        return [argv, nil, FLAG_ERROR] unless value.nil? || %w[text json].include?(value)

        mode = value == "json" ? :json : :text
      end
      return [kept, mode, nil] if mode

      from_env(kept, env)
    end

    def silent?(argv)
      words = argv.take_while { |token| token != "--" }.reject { |token| token.start_with?("-") }
      return false unless SILENT_VERBS.include?(words.first)

      !(words.first == "hook" && words[1] == "git" && %w[install uninstall].include?(words[2]))
    end

    def from_env(argv, env)
      raw = env["POLISPEC_VERBOSE"]
      return [argv, nil, nil] if raw.nil?

      value = raw.to_s.strip.downcase
      return [argv, nil, nil] if ENV_OFF.include?(value)
      return [argv, :text, nil] if ENV_TEXT.include?(value)
      return [argv, :json, nil] if value == "json"

      [argv, nil, ENV_ERROR]
    end

    def configure(mode, op:)
      return self if on?

      require_relative "trace/stream"
      require_relative "trace/logfile"
      @mutex.synchronize do
        @io = $stderr
        @started = now
        @depth = 0
        @op = op.to_s
        @mode = mode == :json ? :json : :text
      end
      @file = Logfile.open(@mode, @op)
      failed = @file.nil? && Logfile.failure
      write_line(0, "# trace polispec #{Polispec.version} #{@op} pid #{Process.pid}", "begin", "op" => @op, "pid" => Process.pid, "version" => Polispec.version)
      info("trace file unavailable", error: failed) if failed
      self
    end

    def finish(status)
      return nil unless on?

      elapsed = now - @started
      file_path = @file ? @file.path : nil
      write_line(0, "# done exit #{status} in #{format('%.1f', elapsed)} s", "end", "exit" => status, "ms" => (elapsed * 1000).round, "file" => file_path)
      write_line(0, "# trace file #{path(file_path)}", nil, nil) if file_path && !json?
      reset!
      nil
    end

    def reset!
      @mutex.synchronize do
        @file.close if @file
        @file = nil
        @mode = :off
        @depth = 0
        @io = nil
      end
      nil
    rescue StandardError
      @mode = :off
      nil
    end

    def step(label, **fields)
      return yield unless on?

      started = now
      clean = compact(fields)
      write_line(@depth, "> #{one_line(label)}#{Stream.fields(clean)}", "step", "phase" => "start", "label" => label.to_s, "fields" => clean)
      failure = nil
      begin
        @depth += 1
        yield
      rescue Exception => e
        failure = e
        raise
      ensure
        @depth -= 1
        close_step(label, started, failure)
      end
    end

    def info(message, **fields)
      return nil unless on?

      clean = compact(fields)
      write_line(@depth, "- #{one_line(message)}#{Stream.fields(clean)}", "info", "message" => message.to_s, "fields" => clean)
      nil
    end

    def command(argv, chdir: nil)
      return nil unless on?

      words = argv.is_a?(Array) ? argv.map(&:to_s) : [argv.to_s]
      text = argv.is_a?(Array) ? Shellwords.join(words) : argv.to_s
      shown = chdir && File.expand_path(chdir.to_s) != Dir.pwd ? " (in #{path(chdir.to_s)})" : ""
      write_line(@depth, "$ #{one_line(text)}#{shown}", "command", "argv" => words, "cwd" => chdir.nil? ? nil : chdir.to_s)
      nil
    end

    def exit_line(code, ms, timed_out: false)
      return nil unless on?

      shown = Stream.duration(ms)
      write_line(@depth, "= exit #{code} in #{shown}#{timed_out ? ' (timed out)' : ''}", "exit", "code" => code, "ms" => ms.round, "timed_out" => timed_out ? true : false)
      nil
    end

    def output(text, stream: :out, depth: nil)
      return nil unless on?

      level = depth || @depth + 1
      line = Stream.clean(text.to_s).sub(/\r?\n\z/, "")
      marker = stream == :err ? "2| " : "| "
      write_line(level, "#{marker}#{json? ? line : Stream.control(line)}", "output", "stream" => stream == :err ? "err" : "out", "text" => line)
      nil
    end

    def drain(io, stream: :out)
      drain_at(io, stream, @depth + 1, false)
    end

    def capture3(*args)
      return Open3.capture3(*without_trace(args)) unless on?

      traced(:three, args)
    end

    def capture2(*args)
      return Open3.capture2(*without_trace(args)) unless on?

      traced(:two, args)
    end

    def capture2e(*args)
      return Open3.capture2e(*without_trace(args)) unless on?

      traced(:two_e, args)
    end

    def path(text)
      home = Dir.home
      shown = text.to_s
      return shown if home.nil? || home.empty? || home == "/"

      shown == home || shown.start_with?("#{home}/") ? "~#{shown[home.length..]}" : shown
    rescue StandardError
      text.to_s
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def compact(fields)
      fields.reject { |_, value| value.nil? }
    end

    def one_line(text)
      text.to_s.gsub(/\s*[\r\n]+\s*/, " ")
    end

    def reason(error)
      if defined?(Polispec::Operator::Failure) && error.is_a?(Polispec::Operator::Failure)
        "#{error.code[0, 300]}: #{error.message.to_s[0, 300]}"
      else
        "#{error.class}: #{error.message.to_s[0, 300]}"
      end
    end

    def close_step(label, started, failure)
      ms = ((now - started) * 1000).round
      if failure
        shown = one_line(reason(failure))
        write_line(@depth, "! #{one_line(label)} failed after #{Stream.duration(ms)}: #{shown}", "step", "phase" => "end", "label" => label.to_s, "ok" => false, "ms" => ms, "error" => shown)
      else
        write_line(@depth, "+ #{one_line(label)} (#{Stream.duration(ms)})", "step", "phase" => "end", "label" => label.to_s, "ok" => true, "ms" => ms)
      end
    rescue StandardError
      nil
    end

    def write_line(depth, body, event, data)
      return nil unless on?

      @mutex.synchronize do
        return nil unless on?

        elapsed = now - @started
        line = if @mode == :json
          event ? Stream.json_line(elapsed, depth, event, data) : nil
        else
          Stream.text_line(elapsed, depth, body)
        end
        next unless line

        emit_stream(line)
        @file = Logfile.write(@file, @mode, line, elapsed, depth)
      end
      nil
    end

    def emit_stream(line)
      @io.write("#{line}\n")
    rescue IOError, SystemCallError
      nil
    end

    def drain_at(io, stream, depth, quiet)
      lines = []
      begin
        while (line = io.gets)
          lines << line
          output(line, stream: stream, depth: depth) unless quiet
        end
      rescue IOError, SystemCallError
        nil
      end
      lines.join
    end

    def without_trace(args)
      last = args.last
      return args unless last.is_a?(Hash) && last.key?(:trace)

      rest = last.reject { |key, _| key == :trace }
      rest.empty? ? args[0...-1] : args[0...-1] + [rest]
    end

    def traced(kind, args)
      given = args.last.is_a?(Hash) ? args.last : nil
      base = given ? args[0...-1] : args
      opts = given ? given.dup : {}
      mode = opts.delete(:trace)
      stdin_data = opts.delete(:stdin_data)
      binmode = opts.delete(:binmode)
      cmd = base.first.is_a?(Hash) ? base.drop(1) : base
      display = cmd.map { |item| item.is_a?(Array) ? item.first.to_s : item.to_s }
      popen_args = base + (opts.empty? ? [] : [opts])
      silent = mode == :silent
      quiet = mode == :quiet || silent
      depth = @depth
      command(display.length == 1 ? display.first : display, chdir: opts[:chdir]) unless silent
      started = now
      out = err = status = nil
      case kind
      when :three
        Open3.popen3(*popen_args) do |inp, o, e, wait|
          binmode_all(binmode, inp, o, e)
          out_thread = Thread.new { drain_at(o, :out, depth + 1, quiet) }
          err_thread = Thread.new { drain_at(e, :err, depth + 1, quiet) }
          feed(inp, stdin_data)
          out = out_thread.value
          err = err_thread.value
          status = wait.value
        end
      when :two
        Open3.popen2(*popen_args) do |inp, o, wait|
          binmode_all(binmode, inp, o)
          out_thread = Thread.new { drain_at(o, :out, depth + 1, quiet) }
          feed(inp, stdin_data)
          out = out_thread.value
          status = wait.value
        end
      else
        Open3.popen2e(*popen_args) do |inp, o, wait|
          binmode_all(binmode, inp, o)
          out_thread = Thread.new { drain_at(o, :out, depth + 1, quiet) }
          feed(inp, stdin_data)
          out = out_thread.value
          status = wait.value
        end
      end
      unless silent
        exit_line(status.exitstatus || -1, (now - started) * 1000)
        summarize(out, err) if quiet
      end
      kind == :three ? [out, err, status] : [out, status]
    end

    def binmode_all(binmode, *ios)
      ios.each(&:binmode) if binmode
    end

    def feed(io, data)
      begin
        io.write(data.to_s)
      rescue Errno::EPIPE
        nil
      end
      io.close
    end

    def summarize(out, err)
      total = out.to_s.bytesize + err.to_s.bytesize
      source = out.to_s.strip.empty? ? err.to_s : out.to_s
      first = Stream.clean(source.lines.first.to_s).strip
      first = "#{first[0, 120]} ..." if first.length > 120
      info(first.empty? ? "output #{total} bytes" : "output #{total} bytes: #{first}")
    end

    private_class_method :now, :compact, :one_line, :reason, :close_step, :write_line, :emit_stream, :drain_at, :without_trace, :traced, :binmode_all, :feed, :summarize, :from_env, :silent?
  end
end
