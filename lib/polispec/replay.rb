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
    OVERRIDE_PHRASE = "pin with unexplained verdicts"
    ChangeKey = Struct.new(:rule_before, :rule_after, :verdict_before, :verdict_after, keyword_init: true)

    class Unavailable < Polispec::Error; end

    Result = Struct.new(:runtime, :version, :days, :rows, :compared, :skipped_policy, :skipped_unjudged, :changes, :explained_by, keyword_init: true) do
      def unexplained
        changes.reject { |change| change["explained"] }
      end

      def explained
        changes.select { |change| change["explained"] }
      end

      def to_h
        {
          "runtime" => runtime, "version" => version, "days" => days, "rows" => rows, "compared" => compared,
          "skipped_policy_moved" => skipped_policy, "skipped_unjudged" => skipped_unjudged,
          "changed" => changes.sum { |change| change["count"] }, "unexplained" => unexplained.sum { |change| change["count"] },
          "changelog_section" => explained_by, "changes" => changes
        }
      end
    end

    module_function

    def run(runtime:, days: DEFAULT_DAYS, now: Time.now)
      tree = File.expand_path(runtime.to_s)
      raise Unavailable, "#{runtime} is not a polispec tree (no bin/polispec)" unless File.file?(File.join(tree, "bin", "polispec")) && File.file?(File.join(tree, "VERSION"))

      items, rows = collect(days, now)
      verdicts = items.empty? ? { "version" => version_of(tree), "projects" => {} } : evaluate(tree, items)
      compare(tree, days, rows, items, verdicts)
    end

    def version_of(tree)
      File.read(File.join(tree, "VERSION")).strip
    end

    def spec_key(project, row)
      [project, row["action_class"], row["env"], row["ref"], row["path"], row["destructive"] ? true : false, Array(row["shape"])]
    end

    def collect(days, now)
      cutoff = now - (days * 86_400)
      items = {}
      total = 0
      Judgments.each_record do |entry, _|
        stamp = Judgments.stamp_of(entry)
        next unless stamp && stamp >= cutoff

        digest = entry["action"].is_a?(Hash) ? entry["action"]["call_digest"] : nil
        Array(entry["targets"]).each do |target|
          project = target["project"].to_s
          Array(target["rows"]).each do |row|
            next unless row.is_a?(Hash) && row["action_class"]

            total += 1
            item = (items[spec_key(project, row)] ||= { "project" => project, "spec" => row.slice("action_class", "env", "ref", "path", "destructive", "shape"), "groups" => {} })
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
        out, err, status = capture([RbConfig.ruby, CHILD, tree, input])
        raise Unavailable, "the candidate engine could not replay the corpus (exit #{status&.exitstatus.inspect}): #{err.to_s.strip.lines.last.to_s.strip[0, 200]}" unless status&.success?

        JSON.parse(out)
      end
    rescue JSON::ParserError
      raise Unavailable, "the candidate engine returned output that is not JSON"
    end

    def capture(argv)
      Timeout.timeout(CHILD_TIMEOUT) do
        Open3.capture3({ "POLISPEC_SHADOW" => "off" }, *argv)
      end
    rescue Timeout::Error
      raise Unavailable, "the candidate engine did not finish replaying within #{CHILD_TIMEOUT}s"
    rescue SystemCallError => e
      raise Unavailable, "cannot run the candidate engine: #{e.message}"
    end

    def compare(tree, days, total, items, verdicts)
      version = verdicts["version"] || version_of(tree)
      section = changelog_section(tree, version)
      buckets = {}
      compared = skipped_policy = skipped_unjudged = 0
      items.values.each_with_index do |item, index|
        project = verdicts.dig("projects", item["project"])
        item["groups"].each do |(digest, level, rule), group|
          outcome = project && project["outcomes"][index.to_s]
          unless outcome
            skipped_unjudged += group["count"]
            next
          end
          if project["digest"] != digest
            skipped_policy += group["count"]
            next
          end
          compared += group["count"]
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
      Result.new(runtime: tree, version: version, days: days, rows: total, compared: compared, skipped_policy: skipped_policy,
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
      out.puts "rows: #{result.rows}, compared: #{result.compared}, skipped because the rulebook moved: #{result.skipped_policy}, skipped because the project is not judged: #{result.skipped_unjudged}"
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
