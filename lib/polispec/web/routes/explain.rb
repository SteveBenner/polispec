#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "../proposals"
require_relative "../../commands/explain"
require_relative "../../explain/rule_locator"
require_relative "../../exceptions"

module Polispec
  module Web
    RuleLocator = Polispec::RuleLocator

    module ExplainRoute
      TIERS = %w[dev test prod].freeze

      module_function

      def judge(tool, input, cwd)
        payload = JSON.generate("hook_event_name" => "PreToolUse", "tool_name" => tool, "tool_input" => input, "cwd" => cwd, "session_id" => "web-explain")
        Proposals.synchronize { ExplainCommand.new.send(:judge, "claude", payload) }
      end

      def env_entry(result, project_id)
        rule = result["rule_id"]
        located = rule ? RuleLocator.locate(rule, project_id) : nil
        layer = located && located["layer"]
        trace = rule ? [{ "layer" => layer, "rule" => rule, "matched" => true, "verdict" => result["verdict"], "winner" => true }] : []
        { "verdict" => result["verdict"], "rule" => rule, "layer" => layer, "overrides" => [], "reason" => result["reason"], "trace" => trace }
      end

      def project_checkouts(project, ledger)
        repo = File.expand_path(project.repo)
        policy = Probes.resolved(project, ledger).policy
        list = {}
        Engine::Envs.environments(policy).each do |name, spec|
          next unless spec.is_a?(Hash)

          checkout = spec["checkout"].to_s
          list[Engine::Envs.tier_name(name, policy)] ||= checkout.empty? || checkout == "repo" ? repo : File.expand_path(checkout)
        end
        list["dev"] ||= repo
        list
      end

      def envs_for(entry, ledger, tool, input, all_envs, cwd)
        if entry.respond_to?(:repo)
          places = project_checkouts(entry, ledger)
          places = { "dev" => cwd.to_s.empty? ? places["dev"] : cwd } unless all_envs
        else
          places = { "dev" => entry.path }
        end
        out = {}
        TIERS.each do |tier|
          next unless places[tier]

          result = judge(tool, input, places[tier])
          raise Operator::Failure.new("explain_failed", "the call could not be judged in #{tier}") unless result

          out[tier] = env_entry(result, entry.id)
        end
        out
      end

      def entries(ledger)
        ledger.projects.reject { |project| project.status == "retired" } + ledger.paths.reject { |path| path.status == "retired" }
      end

      def explain_call(body)
        tool = body["tool"].to_s
        raise Operator::Failure.new("invalid", "tool is required") if tool.empty?

        input = body["input"].is_a?(Hash) ? body["input"] : {}
        all_envs = body["all_envs"] == true
        cwd = body["cwd"].is_a?(String) ? body["cwd"] : nil
        ledger = Ledger.load
        target = body["target"]
        if target.is_a?(Hash)
          entry = ledger.entry(target["id"].to_s)
          raise Operator::Failure.new("unknown_entry", "#{target['id']} is not in the ledger") unless entry && target["kind"].to_s == (entry.respond_to?(:repo) ? "project" : "path")

          return { "envs" => envs_for(entry, ledger, tool, input, true, cwd) }
        end
        scope = entries(ledger)
        unless cwd.to_s.empty?
          located = ledger.locate(cwd, paths: true)
          scope = located ? scope.select { |item| item.id == (located.respond_to?(:project) && located.project ? located.project.id : located.entry&.id) } : []
        end
        list = scope.map { |entry| { "id" => entry.id, "kind" => entry.respond_to?(:repo) ? "project" : "path", "envs" => envs_for(entry, ledger, tool, input, all_envs, cwd) } }
        { "entries" => list }
      end

      def explain_record(id)
        record = Judgments.find(id)
        raise Operator::Failure.new("unknown_entry", "no judgment #{id}") unless record

        targets = Array(record["targets"])
        list = targets.map do |target|
          env = target["env"].to_s.empty? ? "dev" : target["env"].to_s
          tier = TIERS.include?(env) ? env : "prod"
          located = target["rule_id"] ? RuleLocator.locate(target["rule_id"], target["project"]) : nil
          layer = located && located["layer"]
          trace = target["rule_id"] ? [{ "layer" => layer, "rule" => target["rule_id"], "matched" => true, "verdict" => target["verdict"], "winner" => true }] : []
          { "id" => target["project"].to_s, "kind" => "project", "envs" => { tier => { "verdict" => target["verdict"], "rule" => target["rule_id"], "layer" => layer, "overrides" => [], "reason" => located && located["description"], "trace" => trace } } }
        end
        first = targets.find { |target| target["rule_id"] } || targets.first
        summary = first ? { "id" => id, "project" => first["project"], "env" => first["env"], "verdict" => first["verdict"], "rule" => first["rule_id"] } : { "id" => id }
        { "entries" => list, "record" => summary }
      end

      def next_step(located, project_id)
        match = located["match"].is_a?(Hash) ? located["match"] : {}
        klass = Array(match["class"]).first.to_s
        env = match["env"].is_a?(Array) ? match["env"].first : match["env"]
        level = located["verdict"].to_s
        step = klass.empty? ? nil : Engine.next_step(klass, env.to_s, project_id, level)
        step.to_s.empty? ? located["description"].to_s : step
      rescue StandardError
        located["description"].to_s
      end

      def allow_once_id(rule_id, project_id)
        entries = Engine::Passes.fold(Ledger.load)
        found = entries.each_value.find { |entry| entry["rule_id"] == rule_id && (project_id.nil? || entry["project"] == project_id) && !entry["consumed_at"] }
        found && found["id"]
      rescue StandardError
        nil
      end

      def draft_exception(rule_id, located)
        entry = Exceptions.build_entry(kind: "rule", tool: "Bash", command: "<the exact command to except>", rule: rule_id, scope: { "global" => true }, note: "<why this is safe>", now: Time.now)
        { "target" => { "kind" => "global", "id" => "exceptions" }, "yaml" => Exceptions.dump([entry]) }
      end

      def text_tokens(text)
        found = text.scan(/\[POLISPEC ([^\]\s]+)\]/).flatten
        found.empty? ? text.scan(RuleLocator::RULE_TOKEN).uniq.first(8) : found
      end

      def explain_text(body)
        project = nil
        if body["judgment_id"].is_a?(String) && !body["judgment_id"].empty?
          record = Judgments.find(body["judgment_id"])
          raise Operator::Failure.new("unknown_entry", "no judgment #{body['judgment_id']}") unless record

          target = Array(record["targets"]).find { |item| item["rule_id"] } || Array(record["targets"]).first
          tokens = target && target["rule_id"] ? [target["rule_id"]] : []
          project = target && target["project"]
          judgment_id = body["judgment_id"]
        else
          text = body["text"].to_s
          raise Operator::Failure.new("invalid", "text or judgment_id is required") if text.strip.empty?

          tokens = text_tokens(text)
        end
        tokens.each do |token|
          located = RuleLocator.locate(token, project)
          next unless located

          return {
            "match" => true, "judgment_id" => judgment_id, "rule_id" => token, "layer" => located["layer"], "module" => located["module"], "verdict" => located["verdict"],
            "description" => located["description"], "source" => located["source"], "way_forward" => next_step(located, project || located["project"]),
            "draft_exception" => draft_exception(token, located), "allow_once" => { "id" => allow_once_id(token, project || located["project"]) }
          }
        end
        { "match" => false, "tried" => tokens }
      end
    end

    Web.route("explain") do |r|
      r.is do
        r.post do
          body = r.POST
          fail!(400, "bad_json", "tool and input, or judgment_id, are required") unless body.is_a?(Hash)
          begin
            body["judgment_id"].is_a?(String) && !body["judgment_id"].empty? ? ExplainRoute.explain_record(body["judgment_id"]) : ExplainRoute.explain_call(body)
          rescue Polispec::Error => e
            fail!(*Proposals.describe(e))
          end
        end
        fail!(405, "method_not_allowed", "unsupported method")
      end
      fail!(404, "not_found", "no such route")
    end

    Web.route("explain-text") do |r|
      r.is do
        r.post do
          body = r.POST
          fail!(400, "bad_json", "text or judgment_id is required") unless body.is_a?(Hash)
          begin
            ExplainRoute.explain_text(body)
          rescue Polispec::Error => e
            fail!(*Proposals.describe(e))
          end
        end
        fail!(405, "method_not_allowed", "unsupported method")
      end
      fail!(404, "not_found", "no such route")
    end
  end
end
