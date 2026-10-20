#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Author
    module Bounds
      MAX_SESSIONS = 3
      IDLE_SECONDS = 15 * 60
      TURN_TIMEOUT = 180
      KILL_GRACE = 5
      RETRIES = 2
      RETRY_BASE = 1.0
      BUCKET_TURNS = 10
      BUCKET_WINDOW = 60

      class SessionLock
        attr_reader :id

        def initialize(id, file, path)
          @id = id
          @file = file
          @path = path
        end

        def release
          return unless @file

          @file.flock(File::LOCK_UN)
          @file.close
          File.delete(@path) if File.exist?(@path)
        rescue SystemCallError, IOError
          nil
        ensure
          @file = nil
        end
      end

      module_function

      def sessions_dir
        File.join(Author.dir, "sessions")
      end

      def gate(&block)
        FileUtils.mkdir_p(Author.dir, mode: 0o700)
        File.open(File.join(Author.dir, "gate.lock"), File::RDWR | File::CREAT, 0o600) do |file|
          file.flock(File::LOCK_EX)
          block.call
        end
      end

      def live_locks
        Dir.glob(File.join(sessions_dir, "*.lock")).select do |path|
          held?(path)
        end
      end

      def held?(path)
        File.open(path, File::RDWR) do |file|
          if file.flock(File::LOCK_EX | File::LOCK_NB)
            file.flock(File::LOCK_UN)
            File.delete(path) rescue nil
            false
          else
            true
          end
        end
      rescue Errno::ENOENT
        false
      end

      def acquire_session(id)
        FileUtils.mkdir_p(sessions_dir, mode: 0o700)
        gate do
          raise Busy.new if live_locks.length >= MAX_SESSIONS

          path = File.join(sessions_dir, "#{id}.lock")
          file = File.open(path, File::RDWR | File::CREAT, 0o600)
          file.flock(File::LOCK_EX | File::LOCK_NB)
          file.truncate(0)
          file.write("#{Process.pid}\n")
          file.flush
          SessionLock.new(id, file, path)
        end
      end

      def take_turn(now = Time.now.to_f)
        FileUtils.mkdir_p(Author.dir, mode: 0o700)
        path = File.join(Author.dir, "bucket.json")
        File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
          file.flock(File::LOCK_EX)
          turns = read_turns(file).select { |stamp| now - stamp < BUCKET_WINDOW }
          if turns.length >= BUCKET_TURNS
            wait = (BUCKET_WINDOW - (now - turns.min)).ceil
            raise RateLimited.new([wait, 1].max)
          end
          turns << now
          file.rewind
          file.truncate(0)
          file.write(JSON.generate("turns" => turns))
          file.flush
        end
        true
      end

      def read_turns(file)
        text = file.read.to_s
        return [] if text.strip.empty?

        data = JSON.parse(text)
        Array(data["turns"]).select { |value| value.is_a?(Numeric) }.map(&:to_f)
      rescue JSON::ParserError
        []
      end

      def jitter(base)
        base * (0.7 + (rand * 0.6))
      end
    end
  end
end
