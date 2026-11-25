#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

module Polispec
  module HarnessControls
    class PlaneCache
      TOGGLE_ENV = "POLISPEC_JUDGE_PLANE_CACHE"
      TOGGLE_VALUES = %w[on off].freeze
      DEFAULT_TOGGLE = "on"
      RACY_WINDOW = 2.0
      NANOS = 1_000_000_000
      RACY_WINDOW_NANOS = (RACY_WINDOW * NANOS).to_i
      ENTRY_CAP = 8
      PATH_CAP = 65_536
      CTIME_INDEX = 4
      NO_CTIME = 0
      RECORDER_SLOT = :polispec_plane_recorder
      Entry = Struct.new(:stamps, :payload, keyword_init: true)
      DEFAULT_ACCEPT = lambda do |result|
        result.is_a?(Hash) && result["status"] == "active" && result["development"] == false && result["findings"] == []
      end

      class Recorder
        def initialize
          @paths = {}
          @invalid = false
        end

        def paths
          @paths.keys
        end

        def usable?
          !@invalid
        end

        def read(path)
          value = absolute(path)
          return if value.nil? || @paths.key?(value)

          if @paths.size >= PATH_CAP
            @invalid = true
            return
          end
          @paths[value] = true
          parent = File.dirname(value)
          read(parent) unless parent == value
        end

        private

        def absolute(path)
          text = path.to_s
          unless text.start_with?("/")
            @invalid = true
            return nil
          end
          File.expand_path(text)
        rescue ArgumentError
          @invalid = true
          nil
        end
      end

      attr_reader :hits, :misses

      def self.current
        Thread.current.thread_variable_get(RECORDER_SLOT)
      end

      def self.recording(recorder)
        previous = Thread.current.thread_variable_get(RECORDER_SLOT)
        Thread.current.thread_variable_set(RECORDER_SLOT, recorder)
        yield
      ensure
        Thread.current.thread_variable_set(RECORDER_SLOT, previous)
      end

      def self.enabled?
        value = ENV[TOGGLE_ENV].to_s.strip.downcase
        value = DEFAULT_TOGGLE unless TOGGLE_VALUES.include?(value)
        value == "on"
      end

      def self.stamp(path)
        first = File.lstat(path)
        return [row(first)] unless first.symlink?

        [row(first), follow(path)]
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      rescue SystemCallError => error
        error.class.name
      end

      def self.follow(path)
        row(File.stat(path))
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      rescue SystemCallError => error
        error.class.name
      end

      def self.row(stat)
        [stat.dev, stat.ino, stat.size, nanos(stat.mtime), nanos(stat.ctime), stat.mode, stat.uid]
      end

      def self.nanos(time)
        time.to_i * NANOS + time.nsec
      end

      def initialize(accept: DEFAULT_ACCEPT)
        @accept = accept
        @lock = Mutex.new
        @entries = {}
        @hits = 0
        @misses = 0
      end

      def fetch(identity:)
        return yield if @lock.owned?

        @lock.synchronize do
          key = [identity, process_identity]
          entry = @entries[key]
          if entry && fresh?(entry)
            @hits += 1
            next Marshal.load(entry.payload)
          end
          @entries.delete(key)
          @misses += 1
          taken = clock_nanos
          recorder = Recorder.new
          result = self.class.recording(recorder) { yield }
          remember(key, result, recorder, taken)
          result
        end
      end

      def clear
        @lock.synchronize { @entries.clear }
      end

      private

      def process_identity
        [Process.euid, Process.egid, Process.uid, Process.gid, Process.groups]
      end

      def clock_nanos
        Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
      end

      def fresh?(entry)
        entry.stamps.all? { |path, stamp| self.class.stamp(path) == stamp }
      end

      def remember(key, result, recorder, taken)
        return unless recorder.usable? && @accept.call(result)

        stamps = recorder.paths.map { |path| [path, self.class.stamp(path)] }
        return if racy?(stamps, taken)

        @entries.shift while @entries.size >= ENTRY_CAP
        @entries[key] = Entry.new(stamps: stamps, payload: Marshal.dump(result))
      end

      def racy?(stamps, taken)
        newest = stamps.map { |_path, stamp| ctime_of(stamp) }.max || NO_CTIME
        taken - newest < RACY_WINDOW_NANOS
      end

      def ctime_of(stamp)
        return NO_CTIME unless stamp.is_a?(Array)

        stamp.map { |row| row.is_a?(Array) ? row[CTIME_INDEX] : NO_CTIME }.max || NO_CTIME
      end

      SHARED = new
    end
  end
end
