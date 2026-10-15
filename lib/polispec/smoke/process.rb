#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "pty"
require "io/console"
require_relative "../smoke"

module Polispec
  module Smoke
    module Exec
      Result = Struct.new(:exit, :stdout, :stderr, :duration, :timed_out, :error, keyword_init: true)
      CAPTURE_LIMIT = 4 * 1024 * 1024
      TERM_GRACE = 2
      QUIET = 0.4
      OWN = /\A(POLISPEC_|RPLUGIN_POLISPEC_)/

      module_function

      def clean_env(extra)
        base = ENV.keys.grep(OWN).to_h { |key| [key, nil] }
        base.merge(extra.transform_keys(&:to_s))
      end

      def clock
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end

      def terminate(pid)
        signal_group("TERM", pid)
        deadline = clock + TERM_GRACE
        loop do
          return if ::Process.wait(pid, ::Process::WNOHANG)
          break if clock >= deadline

          sleep 0.05
        end
        signal_group("KILL", pid)
        ::Process.wait(pid)
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end

      def signal_group(signal, pid)
        ::Process.kill(signal, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        begin
          ::Process.kill(signal, pid)
        rescue SystemCallError
          nil
        end
      end

      def drain(io)
        buffer = +""
        loop do
          chunk = io.readpartial(65_536)
          buffer << chunk if buffer.bytesize < CAPTURE_LIMIT
        end
      rescue EOFError, IOError, Errno::EIO
        buffer
      end

      def run(argv, env:, chdir:, stdin: nil, timeout: 30)
        started = clock
        out_r, out_w = IO.pipe
        err_r, err_w = IO.pipe
        in_r, in_w = IO.pipe
        begin
          pid = ::Process.spawn(clean_env(env), *argv, chdir: chdir, in: in_r, out: out_w, err: err_w, pgroup: true)
        rescue SystemCallError => e
          [out_r, out_w, err_r, err_w, in_r, in_w].each(&:close)
          return Result.new(exit: nil, stdout: "", stderr: "", duration: clock - started, timed_out: false, error: e.message)
        end
        [out_w, err_w, in_r].each(&:close)
        out_thread = Thread.new { drain(out_r) }
        err_thread = Thread.new { drain(err_r) }
        begin
          in_w.write(stdin) if stdin
        rescue SystemCallError, IOError
          nil
        ensure
          in_w.close unless in_w.closed?
        end
        waiter = ::Process.detach(pid)
        timed_out = waiter.join(timeout).nil?
        terminate(pid) if timed_out
        status = waiter.value
        out = out_thread.value
        err = err_thread.value
        [out_r, err_r].each(&:close)
        Result.new(exit: timed_out ? nil : status.exitstatus, stdout: out.force_encoding("UTF-8").scrub, stderr: err.force_encoding("UTF-8").scrub,
                   duration: clock - started, timed_out: timed_out, error: nil)
      end

      def run_pty(argv, env:, chdir:, lines:, timeout: 30)
        started = clock
        deadline = started + timeout
        output = +""
        reader, writer, pid = PTY.spawn(clean_env(env), *argv, chdir: chdir)
        queue = lines.dup
        last_data = clock
        fresh = false
        timed_out = false
        loop do
          now = clock
          if now >= deadline
            timed_out = true
            break
          end
          ready = IO.select([reader], nil, nil, 0.1)
          if ready
            begin
              chunk = reader.read_nonblock(65_536)
              output << chunk if output.bytesize < CAPTURE_LIMIT
              last_data = clock
              fresh = true
            rescue IO::WaitReadable
              nil
            rescue EOFError, Errno::EIO
              break
            end
          elsif fresh && !queue.empty? && clock - last_data >= QUIET
            writer.write("#{queue.shift}\n")
            writer.flush
            fresh = false
          end
        end
        terminate(pid) if timed_out
        status = timed_out ? nil : ::Process.wait2(pid).last
        reader.close
        writer.close unless writer.closed?
        text = output.force_encoding("UTF-8").scrub.gsub("\r\n", "\n").gsub("\r", "")
        Result.new(exit: status&.exitstatus, stdout: text, stderr: "", duration: clock - started, timed_out: timed_out, error: nil)
      rescue SystemCallError, PTY::ChildExited => e
        Result.new(exit: nil, stdout: output.to_s, stderr: "", duration: clock - started, timed_out: false, error: e.message)
      end
    end
  end
end
