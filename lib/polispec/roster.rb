#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Roster
    class Unknown < Polispec::Error; end

    CLAUDE_EFFORTS = %w[low medium high xhigh max].freeze
    CODEX_EFFORTS = %w[low medium high xhigh].freeze
    MODEL = /\A[a-z0-9][a-z0-9.\-]{0,63}\z/
    AGENT = /\A[a-z0-9][a-z0-9_\-]{0,63}\z/
    AGENT_PHASES = %w[intake diagnose spec build].freeze
    CLAUDE_ONLY = %w[intake ship].freeze
    BUDGET = (0.5..100).freeze
    MERGE_RUNS = %w[merge own].freeze
    SHIP_RUNS = %w[script model].freeze
    ON_FAILURE = %w[stop model].freeze
    BASE_KEYS = %w[harness model effort budget_usd].freeze

    module_function

    def efforts(roster, harness)
      configured = (roster["harness_effort"] || {})[harness]
      return configured if configured.is_a?(Array)

      { "claude" => CLAUDE_EFFORTS, "codex" => CODEX_EFFORTS }[harness]
    end

    def harness_names(roster)
      (Array((roster["harness_effort"] || {}).keys) + %w[claude codex]).uniq
    end

    def digest_of(roster)
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(roster)))}"
    end

    def canonical(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, canonical(value[key])] }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def slot_for(roster, role: nil, pipeline: nil, phase: nil)
      if role
        slot = (roster["roles"] || {})[role.to_s]
        raise Unknown, "no role #{role} in the roster" unless slot

        return slot
      end
      raise Unknown, "give --role or --pipeline with --phase" unless pipeline && phase

      phases = ((roster["pipelines"] || {})[pipeline.to_s] || {})["phases"]
      raise Unknown, "no pipeline #{pipeline} in the roster" unless phases

      slot = phases[phase.to_s]
      raise Unknown, "no phase #{phase} in pipeline #{pipeline}" unless slot

      slot
    end

    def env_allowed(roster, env, role: nil, pipeline: nil, phase: nil)
      caps = (roster["environments"] || {})[env.to_s]
      return false unless caps

      if role
        matches?(Array(caps["roles"]), role.to_s)
      else
        matches?(Array(caps["pipelines"]), "#{pipeline}.#{phase}")
      end
    end

    def matches?(patterns, name)
      patterns.any? { |pattern| pattern == "*" || File.fnmatch?(pattern, name) }
    end

    def resolve(roster, role: nil, pipeline: nil, phase: nil, env: "dev", digest: nil)
      slot = slot_for(roster, role: role, pipeline: pipeline, phase: phase)
      {
        "default" => slot["default"],
        "bounds" => slot["bounds"] || {},
        "env_allowed" => env_allowed(roster, env, role: role, pipeline: pipeline, phase: phase),
        "roster_digest" => digest || digest_of(roster)
      }
    end

    def check(roster, pipeline, profile, env: nil)
      phases = ((roster["pipelines"] || {})[pipeline.to_s] || {})["phases"]
      raise Unknown, "no pipeline #{pipeline} in the roster" unless phases

      given = profile.is_a?(Hash) && profile["phases"].is_a?(Hash) ? profile["phases"] : profile
      return [violation(nil, "profile", given.class.name, "an object of phases")] unless given.is_a?(Hash)

      violations = []
      (given.keys - phases.keys).each { |name| violations << violation(name, "phase", name, "one of #{phases.keys.join(', ')}") }
      (phases.keys - given.keys).each { |name| violations << violation(name, "phase", nil, "required") }
      phases.each do |name, slot|
        entry = given[name]
        next if entry.nil?

        unless entry.is_a?(Hash)
          violations << violation(name, "phase", entry, "an object")
          next
        end
        base = baseline(roster, name, entry)
        violations.concat(base)
        violations.concat(bounds(roster, name, entry, slot["bounds"] || {}, base.map { |item| item["field"] }))
        violations.concat(environment(roster, env, pipeline, name)) if env
      end
      violations.concat(budget_ceiling(roster, given))
      violations
    end

    def violation(phase, field, value, bound)
      { "phase" => phase, "field" => field, "value" => value, "bound" => bound }
    end

    def allowed_keys(name)
      case name
      when "diagnose", "spec" then %w[run agent] + BASE_KEYS
      when "ship" then %w[run on_failure] + BASE_KEYS
      else %w[agent] + BASE_KEYS
      end
    end

    def baseline(roster, name, entry)
      out = []
      (entry.keys - allowed_keys(name)).each { |key| out << violation(name, key, entry[key], "key not allowed in #{name}") }
      out.concat(run_rules(name, entry))
      harness = entry["harness"]
      known = harness_names(roster)
      if !harness.is_a?(String) || !known.include?(harness)
        out << violation(name, "harness", harness, "one of #{known.join(', ')}")
      elsif harness != "claude" && CLAUDE_ONLY.include?(name)
        out << violation(name, "harness", harness, "claude only for #{name}")
      end
      out.concat(model_rules(name, entry))
      out.concat(effort_rules(roster, name, entry))
      out.concat(budget_rules(name, entry))
      out.concat(agent_rules(name, entry))
      out
    end

    def run_rules(name, entry)
      case name
      when "diagnose", "spec"
        MERGE_RUNS.include?(entry["run"]) ? [] : [violation(name, "run", entry["run"], "one of #{MERGE_RUNS.join(', ')}")]
      when "ship"
        out = []
        out << violation(name, "run", entry["run"], "one of #{SHIP_RUNS.join(', ')}") unless SHIP_RUNS.include?(entry["run"])
        out << violation(name, "on_failure", entry["on_failure"], "one of #{ON_FAILURE.join(', ')}") unless ON_FAILURE.include?(entry["on_failure"])
        out
      else
        []
      end
    end

    def model_rules(name, entry)
      model = entry["model"]
      model.is_a?(String) && model.match?(MODEL) ? [] : [violation(name, "model", model, "lowercase letters, digits, dots and dashes")]
    end

    def effort_rules(roster, name, entry)
      effort = entry["effort"]
      harness = entry["harness"]
      choices = efforts(roster, harness)
      return [] if choices.nil?
      return [violation(name, "effort", effort, "empty or one of #{choices.join(', ')} for #{harness}")] unless effort.nil? || choices.include?(effort)
      if harness == "claude" && entry["model"].to_s.include?("haiku") && !effort.nil?
        return [violation(name, "effort", effort, "empty for haiku models")]
      end

      []
    end

    def budget_rules(name, entry)
      budget = entry["budget_usd"]
      return [] if budget.is_a?(Numeric) && budget.to_f.finite? && BUDGET.cover?(budget.to_f)

      [violation(name, "budget_usd", budget, "number from #{BUDGET.min} to #{BUDGET.max}")]
    end

    def agent_rules(name, entry)
      agent = entry["agent"]
      return [] if agent.nil? || agent == ""
      return [violation(name, "agent", agent, "not allowed on #{name}")] unless AGENT_PHASES.include?(name)

      agent.is_a?(String) && agent.match?(AGENT) ? [] : [violation(name, "agent", agent, "lowercase letters, digits, dashes and underscores")]
    end

    def bounds(roster, name, entry, bound, flagged)
      out = []
      harness = entry["harness"]
      if bound["harnesses"] && !flagged.include?("harness") && !Array(bound["harnesses"]).include?(harness)
        out << violation(name, "harness", harness, "one of #{Array(bound['harnesses']).join(', ')}")
      end
      if bound["models"] && !flagged.include?("model") && !Array(bound["models"]).include?(entry["model"])
        out << violation(name, "model", entry["model"], "one of #{Array(bound['models']).join(', ')}")
      end
      out.concat(effort_bounds(roster, name, entry, bound["effort"])) if bound["effort"] && !flagged.include?("effort") && !flagged.include?("harness")
      out.concat(budget_bounds(name, entry, bound["budget_usd"])) if bound["budget_usd"] && !flagged.include?("budget_usd")
      out
    end

    def effort_bounds(roster, name, entry, limit)
      effort = entry["effort"]
      return [] if effort.nil?

      order = efforts(roster, entry["harness"])
      return [] if order.nil?

      out = []
      rank = order.index(effort)
      if limit["min"]
        floor = order.index(limit["min"])
        out << violation(name, "effort", effort, "min #{limit['min']}") if floor.nil? || rank < floor
      end
      if limit["max"]
        ceiling = order.index(limit["max"])
        out << violation(name, "effort", effort, "max #{limit['max']}") if ceiling.nil? || rank > ceiling
      end
      out
    end

    def budget_bounds(name, entry, limit)
      budget = entry["budget_usd"].to_f
      out = []
      out << violation(name, "budget_usd", entry["budget_usd"], "min #{limit['min']}") if limit["min"] && budget < limit["min"]
      out << violation(name, "budget_usd", entry["budget_usd"], "max #{limit['max']}") if limit["max"] && budget > limit["max"]
      out
    end

    def environment(roster, env, pipeline, name)
      return [] if env_allowed(roster, env, pipeline: pipeline, phase: name)

      [violation(name, "environment", env, "pipeline #{pipeline}.#{name} not permitted in #{env}")]
    end

    def budget_ceiling(roster, given)
      cap = (roster["budgets"] || {})["per_run_usd_max"]
      return [] unless cap

      given.each_with_object([]) do |(name, entry), out|
        next unless entry.is_a?(Hash) && entry["budget_usd"].is_a?(Numeric)

        out << violation(name, "budget_usd", entry["budget_usd"], "max #{cap} (per_run_usd_max)") if entry["budget_usd"] > cap
      end
    end
  end
end
