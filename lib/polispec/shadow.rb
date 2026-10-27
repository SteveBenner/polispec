#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "json"
require "fileutils"
require "rbconfig"
require "time"
require_relative "state"

module Polispec
  module Shadow
    SCHEMA = "polispec.shadow/v1"
    FILE = "shadow.json"
    LOG = "shadow.jsonl"
    ROTATED = "shadow.1.jsonl"
    LOCK = "shadow.lock"
    PAYLOADS = "shadow"
    CAP_BYTES = 1_048_576
    ERROR_GAP = 60
    TIMEOUT = 5
    PAYLOAD_LIMIT = 262_144
    PAYLOAD_TTL = 600
    PRIORITY = 10
    OFF = "off"
    SOFT = [SystemCallError, IOError, JSON::JSONError, NotImplementedError, TypeError, ArgumentError, Polispec::Error].freeze

    module_function

    def config_path
      File.join(State.home, FILE)
    end

    def log_path
      File.join(State.home, LOG)
    end

    def lock_path
      File.join(State.home, LOCK)
    end

    def payload_dir
      File.join(State.home, PAYLOADS)
    end

    def config
      data = JSON.parse(File.read(config_path))
      data.is_a?(Hash) && data["runtime"].is_a?(String) ? data : nil
    rescue SystemCallError, JSON::ParserError
      nil
    end

    def tree?(tree)
      File.file?(File.join(tree, "bin", "polispec")) && File.file?(File.join(tree, "VERSION"))
    end

    def start(runtime)
      tree = File.realpath(File.expand_path(runtime.to_s))
      raise Polispec::Error, "#{runtime} is not a polispec tree (no bin/polispec and VERSION)" unless tree?(tree)

      State.ensure_dirs
      record = { "schema" => SCHEMA, "runtime" => tree, "version" => File.read(File.join(tree, "VERSION")).strip, "live_version" => Polispec.version, "started_at" => Time.now.utc.iso8601 }
      temporary = "#{config_path}.tmp-#{Process.pid}"
      File.write(temporary, "#{JSON.pretty_generate(record)}\n", perm: 0o600)
      File.rename(temporary, config_path)
      record
    rescue Errno::ENOENT
      raise Polispec::Error, "#{runtime} does not exist"
    end

    def stop
      current = config
      File.delete(config_path) if File.exist?(config_path)
      current
    end

    def handoff(harness:, raw:, entry:, verdict:)
      return nil if ENV["POLISPEC_SHADOW"] == OFF || !File.file?(config_path)
      return nil unless entry.is_a?(Hash) && raw.is_a?(String) && raw.bytesize <= PAYLOAD_LIMIT

      current = config
      return nil unless current && tree?(current["runtime"])

      FileUtils.mkdir_p(payload_dir, mode: 0o700)
      file = File.join(payload_dir, "p-#{Process.pid}-#{(Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i}.json")
      action = entry["action"].is_a?(Hash) ? entry["action"] : {}
      body = { "harness" => harness, "raw" => raw, "call_digest" => action["call_digest"], "tool" => action["tool"], "judgment" => entry["id"],
               "live" => { "verdict" => verdict ? verdict.level.to_s : "allow", "rule_id" => verdict && verdict.rule_id } }
      File.write(file, JSON.generate(body), perm: 0o600)
      pid = Process.spawn(RbConfig.ruby, File.join(ROOT, "bin", "polispec"), "shadow", "work", file, pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL)
      Process.detach(pid)
      pid
    rescue *SOFT
      nil
    end

    def work(file)
      Process.setpriority(Process::PRIO_PROCESS, 0, PRIORITY)
      payload = JSON.parse(File.read(file))
      File.delete(file)
      sweep
      current = config
      return nil unless current && tree?(current["runtime"])

      outcome = candidate(current["runtime"], payload["harness"].to_s, payload["raw"].to_s)
      row = base_row(payload, current)
      if outcome["error"]
        append(row.merge("kind" => "error", "error" => outcome["error"]), throttle: true)
      elsif differs?(payload["live"], outcome)
        append(row.merge("kind" => "disagree", "candidate" => { "verdict" => outcome["verdict"], "rule_id" => outcome["rule_id"] }))
      end
      nil
    rescue *SOFT
      nil
    end

    def sweep
      Dir.glob(File.join(payload_dir, "p-*.json")).each do |file|
        File.delete(file) if Time.now - File.mtime(file) > PAYLOAD_TTL
      rescue SystemCallError
        next
      end
    end

    def base_row(payload, current)
      {
        "ts" => Time.now.utc.iso8601(3), "call_digest" => payload["call_digest"], "tool" => payload["tool"], "harness" => payload["harness"],
        "judgment" => payload["judgment"], "live" => payload["live"], "candidate_version" => current["version"]
      }
    end

    def differs?(live, outcome)
      live["verdict"] != outcome["verdict"] || live["rule_id"] != outcome["rule_id"]
    end

    def candidate(runtime, harness, raw)
      require "open3"
      argv = [RbConfig.ruby, File.join(runtime, "bin", "polispec"), "explain", "--harness", harness, "--json"]
      Open3.popen3({ "POLISPEC_SHADOW" => OFF }, *argv, pgroup: true) do |stdin, stdout, stderr, waiter|
        begin
          stdin.write(raw)
        rescue SystemCallError
          nil
        ensure
          stdin.close
        end
        reading = [Thread.new { stdout.read }, Thread.new { stderr.read }]
        unless waiter.join(TIMEOUT)
          begin
            Process.kill("KILL", -waiter.pid)
          rescue SystemCallError
            nil
          end
          waiter.join
          next { "error" => "timeout after #{TIMEOUT}s" }
        end
        out = reading[0].value
        reading[1].value
        next { "error" => "exit #{waiter.value.exitstatus.inspect}" } unless waiter.value.success?

        parsed = JSON.parse(out)
        next { "error" => "unreadable output" } unless parsed.is_a?(Hash) && parsed["verdict"].is_a?(String)

        { "verdict" => parsed["verdict"], "rule_id" => parsed["rule_id"] }
      end
    rescue JSON::ParserError
      { "error" => "unreadable output" }
    rescue SystemCallError => e
      { "error" => e.class.name }
    end

    def append(row, throttle: false)
      State.ensure_dirs
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        return nil if throttle && recent_error?(Time.parse(row["ts"]))

        File.rename(log_path, File.join(State.home, ROTATED)) if File.file?(log_path) && File.size(log_path) > CAP_BYTES
        File.open(log_path, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |file| file.syswrite("#{JSON.generate(row)}\n") }
      end
      row
    end

    def recent_error?(now)
      return false unless File.file?(log_path)

      File.open(log_path, "rb") do |file|
        file.seek([file.size - 8192, 0].max)
        file.read.to_s.lines.reverse_each do |line|
          parsed = State.parse_line(line)
          next unless parsed && parsed["kind"] == "error"

          return now - Time.parse(parsed["ts"].to_s) < ERROR_GAP
        end
      end
      false
    end

    def rows
      list = []
      [File.join(State.home, ROTATED), log_path].each do |file|
        next unless File.file?(file)

        File.foreach(file) do |line|
          parsed = State.parse_line(line)
          list << parsed if parsed
        end
      end
      list
    end

    def report
      list = rows
      groups = list.select { |row| row["kind"] == "disagree" }.group_by { |row| [row.dig("live", "rule_id"), row.dig("candidate", "rule_id"), row.dig("live", "verdict"), row.dig("candidate", "verdict")] }
      changes = groups.map do |(rule_before, rule_after, verdict_before, verdict_after), items|
        { "rule_before" => rule_before, "rule_after" => rule_after, "verdict_before" => verdict_before, "verdict_after" => verdict_after, "count" => items.length,
          "tools" => items.map { |item| item["tool"] }.compact.uniq, "example_call_digest" => items.last["call_digest"], "last_seen" => items.last["ts"] }
      end
      { "shadow" => config, "disagreements" => list.count { |row| row["kind"] == "disagree" }, "errors" => list.count { |row| row["kind"] == "error" },
        "changes" => changes.sort_by { |item| -item["count"] }, "last_error" => list.reverse.find { |row| row["kind"] == "error" } }
    end
  end
end
