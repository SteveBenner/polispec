#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "digest"

module Polispec
  module Judge
    class StatCache
      RACY_WINDOW = 2.0
      ENTRY_CAP = 16_384
      NANOS = 1_000_000_000
      MISSING = "-"
      CTIME_INDEX = 4
      Entry = Struct.new(:tuple, :digest, :taken_at, keyword_init: true)

      def initialize
        @entries = {}
      end

      def digest(path)
        file_digest(path) || MISSING
      end

      def file_digest(path)
        key = path.to_s
        return nil if key.empty?

        taken = clock
        current = tuple(key)
        if current.nil?
          @entries.delete(key)
          return nil
        end
        entry = @entries[key]
        return entry.digest if entry && entry.tuple == current && !racy?(current, entry.taken_at)

        value = read_digest(key)
        store(key, Entry.new(tuple: current, digest: value, taken_at: taken))
        value
      end

      def tuple(path)
        stat = File.stat(path.to_s)
        stat.file? ? build(stat) : nil
      rescue SystemCallError, ArgumentError
        nil
      end

      def stamp(path)
        build(File.stat(path.to_s))
      rescue SystemCallError, ArgumentError
        nil
      end

      def racy?(tuple, taken_at)
        !tuple.nil? && taken_at - tuple[CTIME_INDEX].to_f / NANOS < RACY_WINDOW
      end

      def racy_any?(tuples, taken_at)
        tuples.any? { |tuple| racy?(tuple, taken_at) }
      end

      def clock
        Process.clock_gettime(Process::CLOCK_REALTIME)
      end

      protected

      def read_digest(path)
        Digest::SHA256.hexdigest(File.binread(path))
      rescue SystemCallError, IOError
        MISSING
      end

      private

      def build(stat)
        [stat.dev, stat.ino, stat.size, nanos(stat.mtime), nanos(stat.ctime)]
      end

      def nanos(time)
        time.to_i * NANOS + time.nsec
      end

      def store(key, entry)
        @entries.delete(key)
        @entries[key] = entry
        @entries.shift while @entries.size > ENTRY_CAP
      end
    end
  end
end
