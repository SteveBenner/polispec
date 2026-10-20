#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "canonical"
require_relative "effect"
require_relative "judgments"

module Polispec
  module Sessions
    SCHEMA = "polispec.session/v1"
    STREAM = "sessions"
    ROTATE_BYTES = 16 * 1024 * 1024
    READ_BYTES = 2 * 1024 * 1024

    module_function

    def path
      State.log_path(STREAM)
    end

    def launcher(env = ENV, harness: nil)
      root = env["CLAUDE_PLUGIN_ROOT"].to_s
      return launcher_row("claude-plugin", root) unless root.empty?

      bridge = env["PLUGIN_ROOT"].to_s
      return launcher_row("codex-bridge", bridge) unless bridge.empty?

      guard = env["POLISPEC_GUARD_PATH"].to_s
      return { "kind" => "unknown", "version" => nil, "path" => nil } if guard.empty?

      launcher_row(harness.to_s == "codex" ? "codex-bridge" : "native", guard)
    end

    def launcher_row(kind, path)
      version = path.split("/").reverse.find { |part| part.match?(Effect::SEMVER) }
      { "kind" => kind, "version" => version, "path" => Judgments.home_relative(path) }
    end

    def record(session_id:, harness:, event:, agent_type:, cwd:, project:, epoch:, text:)
      body = {
        "schema" => SCHEMA, "ts" => Time.now.utc.iso8601(3), "session_id" => Judgments.text_or_nil(session_id), "harness" => harness.to_s,
        "event" => Judgments.text_or_nil(event) || "SessionStart", "agent_type" => Judgments.text_or_nil(agent_type), "cwd" => Judgments.home_relative(cwd.to_s),
        "project" => project, "epoch" => epoch, "text_digest" => text.to_s.empty? ? nil : Canonical.sha256(text.to_s), "launcher" => launcher(ENV, harness: harness)
      }
      append(body)
    rescue StandardError, ScriptError
      nil
    end

    def append(body)
      State.ensure_dirs
      file = path
      File.rename(file, File.join(State.home, "sessions.#{Time.now.utc.strftime('%Y%m%dT%H%M%S%LZ')}.jsonl")) if File.file?(file) && File.size(file) > ROTATE_BYTES
      State.append_jsonl(STREAM, body)
    end

    def files
      Dir.glob(File.join(State.home, "sessions.*.jsonl")).sort + (File.file?(path) ? [path] : [])
    end

    def records
      list = []
      files.each do |file|
        File.foreach(file) do |line|
          parsed = State.parse_line(line)
          list << parsed if parsed
        end
      end
      list
    end

    def stamp(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def tail_judgments(cutoff)
      found = []
      Judgments.files.reverse_each do |file|
        size = File.size(file)
        window = READ_BYTES
        older = false
        loop do
          chunk = File.open(file, "rb") do |handle|
            handle.seek([size - window, 0].max)
            handle.read
          end
          lines = chunk.split("\n")
          lines.shift if window < size
          rows = lines.filter_map { |line| State.parse_line(line) }
          first = rows.first && stamp(rows.first["ts"])
          older = !first.nil? && first < cutoff
          if window >= size || older
            found.concat(rows.select { |row| (at = stamp(row["ts"])) && at >= cutoff })
            break
          end
          window *= 2
        end
        break if older
      end
      found
    rescue SystemCallError
      found
    end

    def active(window = 3600, now = Time.now)
      cutoff = now - window
      table = {}
      fresh = lambda do |id|
        table[id] ||= { "session_id" => id, "harness" => nil, "first_seen" => nil, "last_call" => nil, "epoch" => nil, "epochs" => [], "launcher" => nil, "text_digest" => nil, "projects" => {} }
      end
      records.each do |row|
        at = stamp(row["ts"])
        id = row["session_id"]
        next unless id && at && at >= cutoff

        item = fresh.call(id)
        item["harness"] ||= row["harness"]
        item["first_seen"] = row["ts"] if item["first_seen"].nil? || row["ts"] < item["first_seen"]
        item["last_call"] = row["ts"] if item["last_call"].nil? || row["ts"] > item["last_call"]
        item["launcher"] = row["launcher"]
        item["text_digest"] = row["text_digest"]
        item["epochs"] << [row["ts"], row["epoch"]] if row["epoch"]
        item["last_session_event"] = row["ts"]
      end
      tail_judgments(cutoff).each do |row|
        id = row.dig("action", "session_id")
        next unless id

        item = fresh.call(id)
        item["harness"] ||= row.dig("action", "harness")
        item["first_seen"] = row["ts"] if item["first_seen"].nil? || row["ts"] < item["first_seen"]
        item["judged_at"] = row["ts"] if item["judged_at"].nil? || row["ts"] > item["judged_at"]
        item["last_call"] = row["ts"] if item["last_call"].nil? || row["ts"] > item["last_call"]
        item["epochs"] << [row["ts"], row["epoch"]] if row["epoch"]
        Array(row["targets"]).each { |target| item["projects"][target["project"]] = target["policy_digest"] if target["project"] }
      end
      table.values.each do |item|
        item["epoch"] = item["epochs"].max_by(&:first)&.last
        item["calls_judged"] = !item["judged_at"].nil?
      end
      table.values.sort_by { |item| item["first_seen"].to_s }
    end
  end
end
