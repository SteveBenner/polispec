#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "json"
require "shellwords"
require_relative "rule_locator"

module Polispec
  module RuleTrace
    CATALOG_PREFIX = "catalog:"

    @active = false
    @current = nil
    @traces = {}
    @outcomes = []

    class << self
      attr_reader :traces, :outcomes

      def active?
        @active
      end

      def start
        @active = true
        @current = nil
        @traces = {}
        @outcomes = []
      end

      def stop
        @active = false
        @current = nil
      end

      def begin_row
        @current = []
      end

      def end_row(action, target, row)
        @traces[[target.project, action.object_id]] = { "picks" => @current || [], "row" => row }
        @current = nil
      end

      def pick(target, ctx, matcher, result)
        return unless @current

        @current << matches_for(target, ctx, matcher, result.first)
      end

      def outcome(target, ctx, outcome)
        @outcomes << [target, ctx, outcome]
      end

      def matches_for(target, ctx, matcher, picked)
        chain = Layers.chain_for(target, ctx)
        layers = chain ? chain.layers : [Layers::Layer.new(name: "repo", source: target.policy_source.to_s, digest: nil, rules: Array(target.policy["rules"]), modules: [], extras: {})]
        found = []
        layers.each_with_index do |layer, index|
          chosen = false
          Array(layer.rules).each do |rule|
            next unless rule.is_a?(Hash) && matcher.call(rule)

            replaced = chain && chain.applied.find { |upper, id, over| upper == index && id == rule["id"] && matcher.call(over) }
            entry = { "layer" => layer, "index" => index, "rule" => rule, "overridden_by" => replaced && replaced.last["id"], "in_effect" => false, "winner" => rule.equal?(picked) }
            unless replaced || chosen
              entry["in_effect"] = true
              chosen = true
            end
            found << entry
          end
        end
        { "chained" => !chain.nil?, "matches" => found, "picked" => picked }
      end
    end

    module PickCapture
      def pick(target, ctx, &matcher)
        result = super
        RuleTrace.pick(target, ctx, matcher, result) if RuleTrace.active?
        result
      end
    end

    module JudgeCapture
      private

      def judge(action, target, ctx)
        return super unless RuleTrace.active?

        RuleTrace.begin_row
        row = super
        RuleTrace.end_row(action, target, row)
        row
      end
    end

    module ExplainCapture
      def explain(actions, target, ctx = {})
        outcome = super
        RuleTrace.outcome(target, ctx, outcome) if RuleTrace.active?
        outcome
      end
    end

    Layers.singleton_class.prepend(PickCapture)
    Engine.singleton_class.prepend(JudgeCapture)
    Engine.singleton_class.prepend(ExplainCapture)

    class Report
      LEVEL_ORDER = %w[allow warn deny].freeze

      def initialize(tool:, command:, ledger:)
        @tool = tool
        @command = command
        @ledger = ledger
      end

      def targets
        RuleTrace.outcomes.map { |target, ctx, outcome| target_entry(target, ctx, outcome) }
      end

      private

      def target_entry(target, ctx, outcome)
        project = @ledger && @ledger.project(target.project)
        {
          "project" => target.project, "env" => outcome.env, "policy_source" => target.policy_source.to_s, "policy_digest" => target.digest,
          "verdict" => outcome.verdict.level.to_s, "rule_id" => outcome.verdict.rule_id, "reason" => outcome.verdict.reason,
          "rows" => Array(outcome.rows).map { |row| row_entry(row, target, ctx, project) }
        }
      end

      def row_entry(row, target, ctx, project)
        trace = RuleTrace.traces[[target.project, row.action.object_id]]
        hint = Engine::Envs.hint_of(row.action)
        picks = trace ? trace["picks"] : []
        matched = picks.flat_map { |pick| pick["matches"].map { |entry| match_entry(entry, target, project) } }
        winner = matched.find { |entry| entry["winner"] }
        verdict = row.verdict
        {
          "action" => { "class" => row.action.action_class, "raw" => row.action.raw.to_s, "path" => hint["path"], "env" => row.env },
          "verdict" => verdict.level.to_s, "rule_id" => verdict.rule_id, "reason" => verdict.reason,
          "matched" => matched, "winner" => winner,
          "why" => why(verdict, winner, matched, picks.first),
          "change" => change(verdict, winner, target, project)
        }
      end

      def match_entry(entry, target, project)
        layer = entry["layer"]
        located = RuleLocator.locate_in(layer, entry["rule"], project, @ledger) || {}
        source = located["source"] || {}
        module_name = located["module"]
        {
          "rule_id" => entry["rule"]["id"], "verdict" => entry["rule"]["verdict"].to_s, "layer" => layer.name, "layer_source" => layer.source.to_s,
          "file" => file_of(layer, source["path"], project), "line" => source["line"], "module" => module_name,
          "params" => params_of(module_name, located["label"]), "package" => package_of(layer, module_name, project),
          "overridden_by" => entry["overridden_by"], "in_effect" => entry["in_effect"], "winner" => entry["winner"], "project" => target.project
        }
      end

      def params_of(name, label)
        return nil unless name && label

        rest = label.to_s[name.length..].to_s
        rest.start_with?("{") ? JSON.parse(rest) : {}
      rescue JSON::ParserError
        nil
      end

      def package_of(layer, module_name, project)
        return nil unless layer.name == "repo" && module_name.nil? && project

        list = Array(project.packages).map { |item| item.slice("name", "version", "variant") }
        list.empty? ? nil : list
      end

      def file_of(layer, path, project)
        return nil unless path

        name = layer.name.to_s
        return file_in_catalog(path) if name == "catalog"
        return File.join(File.expand_path(project.repo), path) if name == "repo" && project && path == project.policy
        return path if path.start_with?("/")

        shelf = Layers.store && Layers.store.source
        return path unless shelf

        shelf.kind == :dir ? File.join(shelf.root, path) : File.join(shelf.repo, shelf.path.to_s, path)
      end

      def file_in_catalog(label)
        key = label.to_s.delete_prefix(CATALOG_PREFIX)
        found = Catalog.shipped_files.find { |sub, _| "#{sub.spec}/#{sub.id}" == key }
        found ? File.join(Polispec::ROOT, found.last) : label
      end

      def why(verdict, winner, matched, pick)
        return "no rule matched; with no matching rule the engine allows the call" if matched.empty? && verdict.rule_id == "NO-RULE"
        return "no layer rule decided it; the engine's own #{verdict.rule_id} guard answered (#{verdict.level})" unless winner

        effective = matched.select { |entry| entry["in_effect"] }
        others = effective.reject { |entry| entry["winner"] }
        skipped = matched.reject { |entry| entry["overridden_by"].nil? }.map { |entry| "#{entry['rule_id']} (layer #{entry['layer']}) is overridden by #{entry['overridden_by']}" }
        text = if !pick || !pick["chained"]
          "the policy is not layered; the first matching rule applies"
        elsif others.empty?
          "the only rule in effect among the layers"
        else
          ranking(winner, others)
        end
        ([text] + skipped).join("; ")
      end

      def ranking(winner, others)
        lower = others.select { |entry| LEVEL_ORDER.index(entry["verdict"]).to_i < LEVEL_ORDER.index(winner["verdict"]).to_i }
        equal = others.select { |entry| entry["verdict"] == winner["verdict"] }
        parts = []
        parts << "#{winner['verdict']} outranks #{lower.map { |entry| "#{entry['verdict']} #{entry['rule_id']} (#{entry['layer']})" }.join(', ')} (deny over warn over allow)" unless lower.empty?
        parts << "ties on #{winner['verdict']} with #{equal.map { |entry| "#{entry['rule_id']} (#{entry['layer']})" }.join(', ')}; the deeper layer #{winner['layer']} wins" unless equal.empty?
        parts.join("; ")
      end

      def change(verdict, winner, target, project)
        return nil if verdict.allow? && winner.nil?

        levers = []
        if winner
          levers.concat(levers_for(winner, target, project))
        elsif verdict.rule_id.to_s != "NO-RULE"
          levers << { "lever" => "engine", "command" => nil, "note" => verdict.next_step.to_s.empty? ? "decided by the engine's own #{verdict.rule_id} guard; no rulebook edit changes it" : verdict.next_step }
        end
        levers << exception_lever(winner, verdict) if verdict.warn? && verdict.rule_id.to_s != "NO-RULE"
        levers << { "lever" => "next_step", "command" => nil, "note" => verdict.next_step } unless verdict.next_step.to_s.empty?
        levers
      end

      def levers_for(winner, target, project)
        layer = winner["layer"].to_s
        id = winner["rule_id"]
        if layer == "repo"
          [{ "lever" => "plan", "command" => "polispec plan project:#{target.project}", "note" => "edit #{winner['file'] || 'the project policy'}#{winner['line'] ? ":#{winner['line']}" : ''} on main, then plan and apply; the change takes effect once the operator promotes it to #{project ? project.trust_ref : 'stable'}" }]
        elsif layer.start_with?("child:")
          child = layer.delete_prefix("child:")
          [{ "lever" => "plan", "command" => "polispec plan project:#{child}", "note" => "#{id} lives in the nested project #{child}" }]
        elsif layer == "global" || layer.start_with?("path:")
          [{ "lever" => "plan", "command" => "polispec plan global", "note" => "edit #{winner['file'] || 'the shelf file'}#{winner['line'] ? ":#{winner['line']}" : ''} in a shelf draft, then apply global with --confirm; the operator confirms global shelf changes" }]
        elsif layer == "catalog"
          spec = winner["layer_source"].to_s
          label = catalog_label(winner)
          [{ "lever" => "catalog", "command" => label ? "polispec catalog deactivate #{label}" : "polispec catalog list", "note" => "#{id} ships with polispec#{spec.empty? ? '' : " (#{spec})"}; the operator can deactivate its catalog spec, or a project can override the rule only when it is marked overridable" }]
        else
          []
        end
      end

      def catalog_label(winner)
        name = winner["module"].to_s
        return nil if name.empty?

        found = Catalog.shipped_files.find { |sub, _| Catalog.module_name("#{sub.spec}/#{sub.id}") == name }
        found && "#{found.first.spec}/#{found.first.id}"
      end

      def exception_lever(winner, verdict)
        glob = Shellwords.escape(@command.to_s)
        tool = Shellwords.escape(@tool.to_s)
        { "lever" => "exception", "command" => "polispec exceptions add --kind rule --rule #{verdict.rule_id} --tool #{tool} --command #{glob}", "note" => "an exception lifts a warn for the exact call text; it never lifts a deny" }
      end
    end
  end
end
