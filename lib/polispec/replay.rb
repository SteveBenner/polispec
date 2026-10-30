#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "json"
require "tmpdir"
require "timeout"
require "open3"
require "rbconfig"
require_relative "judgments"
require_relative "operator/git"

module Polispec
  module Replay
    DEFAULT_DAYS = 14
    CHILD = File.join(LIB, "replay_child.rb")
    CHILD_TIMEOUT = 180
    ITEM_BUDGET = 0.005
    UNOWNED_ID = "global"
    OVERRIDE_PHRASE = "pin with unexplained verdicts"
    ChangeKey = Struct.new(:rule_before, :rule_after, :verdict_before, :verdict_after, keyword_init: true)

    class Unavailable < Polispec::Error; end

    Result = Struct.new(:runtime, :baseline, :version, :days, :rows, :compared, :skipped_policy, :skipped_unjudged, :changes, :explained_by, keyword_init: true) do
      def unexplained
        changes.reject { |change| change["explained"] }
      end

      def explained
        changes.select { |change| change["explained"] }
      end

      def percent(count)
        rows.to_i.zero? ? 0.0 : (count * 100.0 / rows).round(1)
      end

      def to_h
        {
          "runtime" => runtime, "baseline" => baseline, "version" => version, "days" => days, "rows" => rows, "compared" => compared,
          "compared_percent" => percent(compared),
          "skipped_policy_moved" => skipped_policy, "skipped_unjudged" => skipped_unjudged,
          "changed" => changes.sum { |change| change["count"] }, "unexplained" => unexplained.sum { |change| change["count"] },
          "changelog_section" => explained_by, "changes" => changes
        }
      end
    end

    module_function

    def run(runtime:, days: DEFAULT_DAYS, baseline: nil, now: Time.now)
      tree = File.expand_path(runtime.to_s)
      raise Unavailable, "#{runtime} is not a polispec tree (no bin/polispec)" unless tree?(tree)

      base = File.expand_path((baseline || installed_root || ROOT).to_s)
      raise Unavailable, "#{baseline} is not a polispec tree (no bin/polispec)" unless tree?(base)

      items, rows = collect(days, now)
      verdicts, before = judge_both(tree, base, items)
      compare(tree, base, days, rows, items, verdicts, before)
    end

    def judge_both(tree, base, items)
      return [{ "version" => version_of(tree), "projects" => {} }] * 2 if items.empty?
      return [evaluate(tree, items)] * 2 if same_tree?(base, tree)

      baseline = Thread.new { evaluate(base, items) }
      candidate = evaluate(tree, items)
      [candidate, baseline.value]
    end

    def tree?(tree)
      File.file?(File.join(tree, "bin", "polispec")) && File.file?(File.join(tree, "VERSION"))
    end

    def installed_root
      candidates = [ENV.fetch("POLISPEC_BIN", nil)] + ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "polispec") }
      candidates.compact.reject(&:empty?).each do |path|
        next unless File.file?(path) && File.executable?(path)

        root = File.dirname(File.dirname(File.realpath(path)))
        return root if tree?(root)
      rescue SystemCallError
        next
      end
      nil
    end

    def same_tree?(left, right)
      File.realpath(left) == File.realpath(right)
    rescue SystemCallError
      false
    end

    def version_of(tree)
      File.read(File.join(tree, "VERSION")).strip
    end

    def spec_key(project, row, scope = {})
      [project, row["action_class"], row["env"], row["ref"], row["path"], row["destructive"] ? true : false, Array(row["shape"]), scope["cwd"], scope["tool"]]
    end

    def unowned?(target)
      target["project"].to_s == UNOWNED_ID || target["policy_source"].to_s == "path"
    end

    def collect(days, now)
      cutoff = now - (days * 86_400)
      items = {}
      total = 0
      Judgments.each_record do |entry, _|
        stamp = Judgments.stamp_of(entry)
        next unless stamp && stamp >= cutoff

        action = entry["action"].is_a?(Hash) ? entry["action"] : {}
        digest = action["call_digest"]
        Array(entry["targets"]).each do |target|
          project = target["project"].to_s
          scope = unowned?(target) ? { "cwd" => action["cwd"], "tool" => action["tool"] }.compact : {}
          Array(target["rows"]).each do |row|
            next unless row.is_a?(Hash) && row["action_class"]

            total += 1
            item = (items[spec_key(project, row, scope)] ||= { "project" => project, "spec" => row.slice("action_class", "env", "ref", "path", "destructive", "shape").merge(scope), "groups" => {} })
            group = (item["groups"][[target["policy_digest"], row["verdict"].to_s, row["rule_id"]]] ||= { "count" => 0, "example" => digest })
            group["count"] += 1
          end
        end
      end
      [items, total]
    end

    def evaluate(tree, items)
      Dir.mktmpdir("polispec-replay-") do |dir|
        input = File.join(dir, "rows.json")
        projects = items.values.each_with_index.group_by { |item, _| item["project"] }
        payload = { "projects" => projects.transform_values { |list| list.map { |item, index| item["spec"].merge("key" => index) } } }
        File.write(input, JSON.generate(payload))
        out, err, status = capture([RbConfig.ruby, CHILD, tree, input], CHILD_TIMEOUT + (items.size * ITEM_BUDGET).ceil)
        raise Unavailable, "the engine of #{tree} could not replay the corpus (exit #{status&.exitstatus.inspect}): #{err.to_s.strip.lines.last.to_s.strip[0, 200]}" unless status&.success?

        JSON.parse(out)
      end
    rescue JSON::ParserError
      raise Unavailable, "the engine of #{tree} returned output that is not JSON"
    end

    def capture(argv, limit = CHILD_TIMEOUT)
      Timeout.timeout(limit) do
        Open3.capture3({ "POLISPEC_SHADOW" => "off" }, *argv)
      end
    rescue Timeout::Error
      raise Unavailable, "the candidate engine did not finish replaying within #{limit}s"
    rescue SystemCallError => e
      raise Unavailable, "cannot run the candidate engine: #{e.message}"
    end

    def compare(tree, base, days, total, items, verdicts, before)
      version = verdicts["version"] || version_of(tree)
      section = changelog_section(tree, version)
      buckets = {}
      compared = skipped_policy = skipped_unjudged = 0
      items.values.each_with_index do |item, index|
        project = verdicts.dig("projects", item["project"])
        baseline = before.dig("projects", item["project"])
        item["groups"].each do |(digest, _recorded_level, _recorded_rule), group|
          outcome = project && project["outcomes"][index.to_s]
          prior = baseline && baseline["outcomes"][index.to_s]
          unless outcome && prior
            skipped_unjudged += group["count"]
            next
          end
          if baseline["digest"] != digest
            skipped_policy += group["count"]
            next
          end
          compared += group["count"]
          level, rule = prior
          after_level, after_rule = outcome
          next if after_level == level && after_rule == rule

          key = ChangeKey.new(rule_before: rule, rule_after: after_rule, verdict_before: level, verdict_after: after_level)
          bucket = (buckets[key] ||= { "rule_before" => rule, "rule_after" => after_rule, "verdict_before" => level, "verdict_after" => after_level, "count" => 0, "example_call_digest" => group["example"], "projects" => [] })
          bucket["count"] += group["count"]
          bucket["projects"] |= [item["project"]]
        end
      end
      changes = buckets.values.sort_by { |change| [-change["count"], change["rule_before"].to_s, change["rule_after"].to_s] }
      changes.each { |change| change["explained"] = explained?(section, change) }
      Result.new(runtime: tree, baseline: base, version: version, days: days, rows: total, compared: compared, skipped_policy: skipped_policy,
                 skipped_unjudged: skipped_unjudged, changes: changes, explained_by: section ? "## [#{version}]" : nil)
    end

    def changelog_section(tree, version)
      text = File.read(File.join(tree, "CHANGELOG.md"))
      match = text.match(/^## \[?#{Regexp.escape(version)}\]?[^\n]*\n(.*?)(?=^## |\z)/m)
      match && match[1]
    rescue SystemCallError
      nil
    end

    def explained?(section, change)
      return false unless section

      [change["rule_before"], change["rule_after"]].compact.reject(&:empty?).any? { |rule| section.match?(/(?<![A-Za-z0-9_-])#{Regexp.escape(rule)}(?![A-Za-z0-9_-])/) }
    end

    def render(result, out: $stdout)
      out.puts "replay of #{result.runtime} (#{result.version}) over the last #{result.days} days"
      out.puts "rulebook digests from #{result.baseline} (#{version_of(result.baseline)})"
      out.puts "rows: #{result.rows}, compared: #{result.compared} (#{result.percent(result.compared)}%), skipped because the rulebook moved: #{result.skipped_policy} (#{result.percent(result.skipped_policy)}%), skipped because the target is not in the ledger: #{result.skipped_unjudged} (#{result.percent(result.skipped_unjudged)}%)"
      out.puts "changelog section for #{result.version}: #{result.explained_by || 'none'}"
      out.puts "changed: #{result.changes.sum { |change| change['count'] }}, unexplained: #{result.unexplained.sum { |change| change['count'] }}"
      result.changes.each do |change|
        out.puts "  #{change['explained'] ? 'explained  ' : 'unexplained'} rule #{change['rule_before'] || '-'} -> #{change['rule_after'] || '-'}  verdict #{change['verdict_before']} -> #{change['verdict_after']}  x#{change['count']}  e.g. #{change['example_call_digest'].to_s[0, 19]}  (#{change['projects'].join(', ')})"
      end
    end

    def failure(result)
      Operator::Failure.new("pin_unexplained_verdicts", "the candidate #{result.version} changes #{result.unexplained.sum { |change| change['count'] }} recorded verdicts that its CHANGELOG section does not explain",
                            "changes" => result.unexplained.map { |change| change.slice("rule_before", "rule_after", "verdict_before", "verdict_after", "count", "example_call_digest") })
    end
  end
end
