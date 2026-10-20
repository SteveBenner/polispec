#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../views"

module Polispec
  module Web
    module JudgmentStream
      POLL = 0.5
      HEARTBEAT = 15
      MAX_STREAMS = 8
      CHUNK = 1_048_576

      @streams = []
      @lock = Mutex.new
      @stopping = false

      class << self
        def admit(body)
          2.times do
            @lock.synchronize do
              return false if @stopping

              if @streams.length < MAX_STREAMS
                @streams << body
                return true
              end
              @streams.first.cancel!
            end
            sleep(POLL * 2)
          end
          false
        end

        def release(body)
          @lock.synchronize { @streams.delete(body) }
        end

        def stop!
          @stopping = true
        end

        def stopping?
          @stopping
        end

        def count
          @lock.synchronize { @streams.length }
        end
      end

      class Tail
        def initialize(path)
          @path = path
          @io = nil
          @buffer = +""
          open_end
        end

        def lines
          out = []
          drain(out)
          if @io.nil?
            open_start if File.file?(@path)
          elsif rotated?
            drain(out)
            @io.close
            @io = nil
            @buffer = +""
            open_start
            drain(out)
          end
          out
        rescue SystemCallError, IOError
          out
        end

        def close
          @io&.close
        end

        private

        def open_end
          return unless File.file?(@path)

          @io = File.open(@path, "rb")
          @io.seek(0, IO::SEEK_END)
        rescue SystemCallError
          @io = nil
        end

        def open_start
          @io = File.open(@path, "rb")
        rescue SystemCallError
          @io = nil
        end

        def rotated?
          File.stat(@path).ino != @io.stat.ino
        rescue SystemCallError
          false
        end

        def drain(out)
          return unless @io

          while (chunk = @io.read(CHUNK))
            @buffer << chunk
          end
          while (cut = @buffer.index("\n"))
            line = @buffer.slice!(0, cut + 1)
            out << line
          end
        end
      end

      class Body
        def initialize(tail, filters, alive)
          @tail = tail
          @filters = filters
          @alive = alive
          @cancelled = false
        end

        def cancel!
          @cancelled = true
        end

        def call(stream)
          tail = @tail
          alive = @alive
          beat = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          stream.write(": ready\n\n")
          until JudgmentStream.stopping? || @cancelled
            tail.lines.each do |line|
              record = State.parse_line(line)
              next unless record && match?(record)

              stream.write("event: judgment\ndata: #{JSON.generate(Views.stripped(record))}\n\n")
              beat = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if now - beat >= HEARTBEAT
              stream.write(": heartbeat\n\n")
              beat = now
            end
            break unless alive.call

            sleep(POLL)
          end
        rescue SystemCallError, IOError
          nil
        ensure
          tail.close
          JudgmentStream.release(self)
        end

        def match?(record)
          filters = @filters
          return false if filters[:session] && record.dig("action", "session_id") != filters[:session]
          targets = Array(record["targets"])
          return false if filters[:project] && targets.none? { |target| target["project"] == filters[:project] }
          return false if filters[:rule] && targets.none? { |target| target["rule_id"] == filters[:rule] || Array(target["rows"]).any? { |row| row["rule_id"] == filters[:rule] } }

          true
        end
      end
    end

    Web.at_stop { JudgmentStream.stop! }

    Web.route("judgments") do |r|
      r.is do
        r.get do
          view_call { Views.judgments(r.params["since"], r.params["session"], r.params["project"], r.params["rule"], r.params["limit"]) }
        end
        fail!(405, "method_not_allowed", "unsupported method")
      end
      r.is "stream" do
        r.get do
          token = current_session.token
          filters = { session: r.params["session"], project: r.params["project"], rule: r.params["rule"] }.reject { |_, value| value.to_s.empty? }
          tail = JudgmentStream::Tail.new(Judgments.path)
          body = JudgmentStream::Body.new(tail, filters, -> { !auth.lookup(token).nil? })
          unless JudgmentStream.admit(body)
            tail.close
            fail!(429, "rate_limited", "at most #{JudgmentStream::MAX_STREAMS} judgment streams at a time", retry_after: 5)
          end
          headers = { "Content-Security-Policy" => App::CSP, "X-Content-Type-Options" => "nosniff", "Referrer-Policy" => "no-referrer" }.merge("Content-Type" => "text/event-stream", "Cache-Control" => "no-store", "X-Request-Id" => request_id, "X-Accel-Buffering" => "no")
          r.halt([200, headers, body])
        end
        fail!(405, "method_not_allowed", "unsupported method")
      end
      fail!(404, "not_found", "no such route")
    end
  end
end
