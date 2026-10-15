#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Journal
    KEY = "polispec.verdicts.journal"
    STREAM = "journal"
    KEEP = 5000
    TRIM_AT = 5500
    TRIM_CHECK_BYTES = 600_000
    WINDOW_SECONDS = 14 * 24 * 3600

    module_function

    def enabled?
      return @enabled unless @enabled.nil?

      @enabled = Engine::Settings.text(KEY, "off") == "on"
    rescue StandardError
      @enabled = false
    end

    def reset!
      @enabled = nil
    end

    def record(outcome, target, ctx, tool)
      return unless enabled?

      Array(outcome.rows).each { |row| State.append_jsonl(STREAM, entry(row, target, ctx, tool)) }
      trim
    rescue StandardError
      nil
    end

    def entry(row, target, ctx, tool)
      action = row.action
      hint = Engine::Envs.hint_of(action)
      {
        "ts" => Time.now.utc.iso8601, "project" => target.project, "env" => row.env, "action_class" => action.action_class, "tool" => tool.to_s,
        "ref" => hint["ref"].is_a?(String) ? hint["ref"] : nil, "path" => home_relative(hint["path"]), "crosses" => crosses(action, target, ctx),
        "destructive" => Engine::Destructive.of?(action, ctx) ? true : false, "shape" => Array(hint["shape"]).map(&:to_s),
        "verdict" => row.verdict.level, "rule_id" => row.verdict.rule_id
      }
    end

    def crosses(action, target, ctx)
      return "data_classes" if action.action_class == "data.copy" && !Engine::Envs.crossing(action, target, ctx).empty?
      return "location" if Engine::Locations.crossing(action, target, ctx)

      nil
    rescue StandardError
      nil
    end

    def home_relative(path)
      return nil unless path.is_a?(String) && !path.empty?

      home = Dir.home
      path == home || path.start_with?("#{home}/") ? path.sub(home, "~") : path
    end

    def expand(path)
      path.is_a?(String) && path.start_with?("~/") ? File.join(Dir.home, path[2..]) : path
    end

    def trim
      path = State.log_path(STREAM)
      return unless File.file?(path) && File.size(path) > TRIM_CHECK_BYTES

      lines = File.readlines(path)
      return unless lines.length > TRIM_AT

      temp = "#{path}.#{Process.pid}.tmp"
      File.write(temp, lines.last(KEEP).join, perm: 0o600)
      File.rename(temp, path)
    rescue SystemCallError
      nil
    end

    def recent(now = Time.now)
      cutoff = now - WINDOW_SECONDS
      State.read_jsonl(STREAM).select do |row|
        stamp = Time.iso8601(row["ts"].to_s) rescue nil
        stamp && stamp >= cutoff
      end
    end

    def action_for(row)
      hint = { "env" => row["env"] }
      hint["ref"] = row["ref"] if row["ref"]
      hint["path"] = expand(row["path"]) if row["path"]
      hint["destructive"] = true if row["destructive"]
      hint["shape"] = row["shape"] if row["shape"].is_a?(Array) && !row["shape"].empty?
      Action.new(class: row["action_class"], env_hint: hint, raw: "journal replay")
    end

    def label(row)
      "#{row['action_class']} #{[row['ref'], row['path']].compact.join(' ')}".strip
    end
  end
end
