#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Judge
    class Server
      POLL = 5.0
      STOP_BYTE = "t"
      CHILD_BYTE = "c"
      STOP_SIGNALS = %w[TERM INT HUP USR1].freeze
      DRAIN_BYTES = 4096

      attr_reader :token

      def self.run
        new.run
      end

      def initialize
        @token = SecureRandom.hex(16)
        @idle = Judge.idle_seconds
        @count = Judge.worker_count
        @children = {}
        @due = []
        @early = 0
        @stopping = false
        @published = false
      end

      def run
        state = Judge.read_state
        if state && state["pid"] != Process.pid && Judge.listening?(state)
          warn "polispec: judge already listening on 127.0.0.1:#{state['port']}"
          return 0
        end

        FileUtils.mkdir_p(State.home, mode: 0o700)
        @listener = TCPServer.new("127.0.0.1", 0)
        @listener.listen(LISTEN_BACKLOG)
        @wake_r, @wake_w = IO.pipe
        @activity_r, @activity_w = IO.pipe
        @life_r, @life_w = IO.pipe
        STOP_SIGNALS.each { |name| Signal.trap(name) { wake(STOP_BYTE) } }
        Signal.trap("CHLD") { wake(CHILD_BYTE) }
        Judge.preload
        publish
        @count.times { fork_worker }
        supervise
        0
      ensure
        retire
      end

      private

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def wake(byte)
        @wake_w.write_nonblock(byte)
      rescue IO::WaitWritable, SystemCallError, IOError
        nil
      end

      def publish
        record = { "port" => @listener.addr[1], "token" => @token, "pid" => Process.pid, "runtime" => Judge.own_runtime, "version" => Polispec.version, "started" => Time.now.utc.iso8601, "workers" => @count }
        write_atomic(Judge.state_path, JSON.generate(record))
        write_atomic(Judge.supervised_path, Process.pid.to_s) if Judge.supervised?
        @published = true
      end

      def write_atomic(path, text)
        temp = "#{path}.#{Process.pid}.tmp"
        File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write("#{text}\n") }
        File.chmod(0o600, temp)
        File.rename(temp, path)
      end

      def fork_worker
        pid = fork do
          status = 1
          begin
            (STOP_SIGNALS + %w[CHLD]).each { |name| Signal.trap(name, "DEFAULT") }
            [@wake_r, @wake_w, @activity_r, @life_w].each(&:close)
            status = Worker.new(listener: @listener, token: @token, master: Process.ppid, life: @life_r, activity: @activity_w).run
          ensure
            warn "polispec: judge worker failed: #{$!.class}" if $!
            exit!(status)
          end
        end
        @children[pid] = clock
      rescue SystemCallError => error
        warn "polispec: judge worker fork failed: #{error.class}"
        @due << clock + RESPAWN_BACKOFF
      end

      def supervise
        @last_activity = clock
        until @stopping
          reap_children
          spawn_due
          ready = IO.select([@wake_r, @activity_r], nil, nil, timeout)
          if ready
            @last_activity = clock if ready[0].include?(@activity_r) && !drain(@activity_r).empty?
            @stopping = true if ready[0].include?(@wake_r) && drain(@wake_r).include?(STOP_BYTE)
          end
          @stopping = true if idle_expired?
        end
      end

      def timeout
        waits = [POLL]
        waits << (@due.min - clock) unless @due.empty?
        waits << (@last_activity + @idle - clock) unless @idle == IDLE_NEVER
        [waits.min, 0.0].max
      end

      def idle_expired?
        @idle != IDLE_NEVER && clock - @last_activity >= @idle
      end

      def drain(io)
        io.read_nonblock(DRAIN_BYTES)
      rescue IO::WaitReadable, EOFError, SystemCallError, IOError
        ""
      end

      def reap_children
        loop do
          pid, status = Process.wait2(-1, Process::WNOHANG)
          break unless pid

          started = @children.delete(pid)
          schedule_respawn(started, status) if started && !@stopping
        end
      rescue Errno::ECHILD
        nil
      end

      def schedule_respawn(started, status)
        recycled = status.exitstatus == RECYCLED_STATUS
        if !recycled && clock - started < EARLY_DEATH
          @early += 1
        else
          @early = 0
        end
        delay = if recycled then 0.0
                elsif @early >= EARLY_DEATH_LIMIT then RESPAWN_BACKOFF
                else RESPAWN_DELAY
                end
        @due << clock + delay
      end

      def spawn_due
        return if @stopping

        now = clock
        ready, @due = @due.partition { |at| at <= now }
        ready.each { fork_worker }
      end

      def retire
        @stopping = true
        @children.each_key { |pid| signal(pid, "TERM") }
        @listener.close if @listener && !@listener.closed?
        wait_children
        return unless @published

        state = Judge.read_state
        File.delete(Judge.state_path) if state && state["token"] == @token
        File.delete(Judge.supervised_path) if supervised_own?
      rescue SystemCallError
        nil
      end

      def supervised_own?
        File.file?(Judge.supervised_path) && File.read(Judge.supervised_path).strip == Process.pid.to_s
      rescue SystemCallError
        false
      end

      def signal(pid, name)
        Process.kill(name, pid)
      rescue Errno::ESRCH
        nil
      end

      def wait_children
        stop = clock + HookCommand::HOOK_BUDGET + 1
        until @children.empty?
          begin
            pid = Process.wait(-1, Process::WNOHANG)
          rescue Errno::ECHILD
            break
          end
          if pid
            @children.delete(pid)
          elsif clock >= stop
            @children.each_key { |left| signal(left, "KILL") }
            break
          else
            sleep(0.02)
          end
        end
        reap_after_kill
      end

      def reap_after_kill
        @children.each_key do |pid|
          Process.wait(pid)
        rescue Errno::ECHILD
          next
        end
        @children.clear
      end
    end
  end
end
