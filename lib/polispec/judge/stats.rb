#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "json"
require "time"

module Polispec
  module Judge
    class Stats
      DEFAULT_SINCE = "1h"
      UNITS = { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.freeze
      DURATION = /\A([1-9]\d{0,6})([smhd])\z/.freeze
      TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/.freeze
      TIME_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
      PERCENTILES = { "p50" => 50, "p90" => 90, "p99" => 99 }.freeze
      BLOCK_BYTES = 65_536
      MAX_SECONDS = 31_536_000
      READ_CAP_BYTES = 67_108_864
      SKEW_SECONDS = 60
      JUDGE_LOG = "judge.log"
      JUDGE_LOG_ROTATED = "judge.log.1"
      LAUNCHER_LOG = "launcher.jsonl"
      JUDGE_STATE = "judge.json"
      SUPERVISED = "judge.supervised"
      DENY = "deny"

      attr_reader :since

      def self.seconds(text)
        match = DURATION.match(text.to_s)
        raise ArgumentError, "bad duration #{text.to_s.inspect}: use Ns, Nm, Nh or Nd" unless match

        total = match[1].to_i * UNITS.fetch(match[2])
        raise ArgumentError, "duration #{text} exceeds 365d" if total > MAX_SECONDS

        total
      end

      def initialize(home:, since: DEFAULT_SINCE, now: Time.now)
        @home = home
        @since = since
        @seconds = self.class.seconds(since)
        @now = now.utc
        @cutoff = (@now - @seconds).strftime(TIME_FORMAT)
        @malformed = 0
        @unreadable = []
        @truncated = []
      end

      def report
        requests = judge_records
        launcher = launcher_records
        durations = requests.filter_map { |record| number(record["duration_ms"]) }
        judged = requests.filter_map { |record| number(record["judge_ms"]) }
        causes = tally(launcher.map { |record| record["cause"] })
        denies = tally(launcher.select { |record| record["decision"] == DENY }.map { |record| record["cause"] })
        {
          "since" => @since,
          "from" => @cutoff,
          "until" => @now.strftime(TIME_FORMAT),
          "requests" => requests.length,
          "duration_ms" => summarize(durations),
          "judge_ms" => summarize(judged),
          "launcher" => { "events" => launcher.length, "causes" => causes, "denies" => denies },
          "judge" => judge_info,
          "supervised" => File.exist?(File.join(@home, SUPERVISED)),
          "malformed" => @malformed,
          "unreadable" => @unreadable,
          "truncated" => @truncated
        }
      end

      def render(report)
        lines = ["polispec judge stats: last #{report['since']} (#{report['from']} to #{report['until']})"]
        lines << "requests: #{report['requests']}"
        lines << distribution_line("duration_ms", report["duration_ms"])
        lines << distribution_line("judge_ms", report["judge_ms"])
        launcher = report["launcher"]
        lines << "launcher events: #{launcher['events']}"
        lines << "  causes: #{pairs(launcher['causes'])}"
        lines << "  denies: #{pairs(launcher['denies'])}"
        judge = report["judge"]
        lines << "judge: pid #{judge['pid'] || '-'} #{judge['running'] ? 'running' : 'not running'}, workers #{judge['workers'] || '-'}"
        lines << "supervised: #{report['supervised'] ? 'yes' : 'no'}"
        lines << "malformed lines: #{report['malformed']}" if report["malformed"].positive?
        lines << "unreadable: #{report['unreadable'].join(', ')}" unless report["unreadable"].empty?
        lines << "truncated at #{READ_CAP_BYTES} bytes: #{report['truncated'].join(', ')}" unless report["truncated"].empty?
        lines
      end

      private

      def distribution_line(name, summary)
        return "#{name}: no records" if summary["count"].zero?

        "#{name}: p50 #{summary['p50']}  p90 #{summary['p90']}  p99 #{summary['p99']}  max #{summary['max']}  (n=#{summary['count']})"
      end

      def pairs(counts)
        counts.empty? ? "none" : counts.map { |name, count| "#{name}=#{count}" }.join(" ")
      end

      def number(value)
        value.is_a?(Numeric) ? value : nil
      end

      def tally(values)
        counts = Hash.new(0)
        values.each { |value| counts[value.to_s] += 1 }
        counts.sort_by { |name, count| [-count, name] }.to_h
      end

      def summarize(values)
        sorted = values.sort
        count = sorted.length
        return { "count" => 0, "p50" => nil, "p90" => nil, "p99" => nil, "max" => nil } if count.zero?

        summary = { "count" => count }
        PERCENTILES.each { |name, percent| summary[name] = sorted[((percent * count + 99) / 100) - 1] }
        summary["max"] = sorted.last
        summary
      end

      def judge_records
        lines, reached_start = lines_since(File.join(@home, JUDGE_LOG))
        lines += lines_since(File.join(@home, JUDGE_LOG_ROTATED)).first if reached_start
        parse(lines)
      end

      def launcher_records
        parse(lines_since(File.join(@home, LAUNCHER_LOG)).first)
      end

      def parse(lines)
        lines.each_with_object([]) do |line, records|
          next if line.strip.empty?

          record = JSON.parse(line)
          if record.is_a?(Hash) && record["ts"].is_a?(String) && TIMESTAMP.match?(record["ts"])
            records << record if record["ts"] >= @cutoff
          else
            @malformed += 1
          end
        rescue JSON::ParserError
          @malformed += 1
        end
      end

      def lines_since(path)
        File.open(path, "rb") { |file| read_tail(file, path) }
      rescue Errno::ENOENT
        [[], true]
      rescue SystemCallError, IOError => error
        @unreadable << "#{File.basename(path)} (#{error.class})"
        [[], false]
      end

      def read_tail(file, path)
        size = file.size
        floor = [size - READ_CAP_BYTES, 0].max
        position = size
        carry = +""
        batches = []
        reached_start = false
        loop do
          if position <= floor
            reached_start = floor.zero?
            @truncated << File.basename(path) unless reached_start
            batches << [carry] if reached_start && !carry.empty?
            break
          end
          step = [BLOCK_BYTES, position - floor].min
          position -= step
          file.seek(position)
          parts = (file.read(step) + carry).split("\n", -1)
          carry = parts.shift
          batches << parts
          break if older_than_window?(parts)
        end
        [batches.reverse.flatten, reached_start]
      end

      def older_than_window?(lines)
        stop = (@now - @seconds - SKEW_SECONDS).strftime(TIME_FORMAT)
        lines.each do |line|
          stamp = line[/"ts":"([^"]*)"/, 1]
          return stamp < stop if stamp && TIMESTAMP.match?(stamp)
        end
        false
      end

      def judge_info
        data = JSON.parse(File.read(File.join(@home, JUDGE_STATE)))
        return empty_judge unless data.is_a?(Hash)

        pid = data["pid"].is_a?(Integer) && data["pid"].positive? ? data["pid"] : nil
        workers = data["workers"].is_a?(Integer) ? data["workers"] : nil
        { "pid" => pid, "running" => alive?(pid), "workers" => workers }
      rescue JSON::ParserError, SystemCallError
        empty_judge
      end

      def empty_judge
        { "pid" => nil, "running" => false, "workers" => nil }
      end

      def alive?(pid)
        return false unless pid

        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end
    end
  end
end
