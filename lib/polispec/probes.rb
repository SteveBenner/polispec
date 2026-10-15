#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "delegate"
require_relative "journal"
require_relative "packages"

module Polispec
  module Probes
    Side = Struct.new(:id, :project, :ledger, :policy, :source, :digest, :target, :cwd, :global, :chain, keyword_init: true)
    Outcome = Struct.new(:level, :rule_id) do
      def text
        "#{level} #{rule_id}"
      end

      def severity
        LEVELS.index(level.to_s) || 0
      end
    end
    GIT_CLASSES = %w[git.push git.tag git.rewrite git.commit git.merge].freeze
    UNGOVERNED = Outcome.new("allow", "UNGOVERNED").freeze

    class QuietLedger < SimpleDelegator
      def pauses_log
        "/nonexistent/polispec-plan-pauses.jsonl"
      end

      def allow_once_log
        "/nonexistent/polispec-plan-allow-once.jsonl"
      end
    end

    module Quiet
      @silent = false

      class << self
        attr_accessor :silent
      end

      def emit(type, fields = {})
        return nil if Quiet.silent

        super
      end
    end
    Events.singleton_class.prepend(Quiet)

    module_function

    def silently
      previous = Quiet.silent
      Quiet.silent = true
      yield
    ensure
      Quiet.silent = previous
    end

    def side(project:, ledger:, policy:, source:, digest:, raw: nil, raw_digest: nil, local: :auto)
      wrapped = QuietLedger.new(ledger)
      target = Target.new(project: project.id, env: "dev", policy: policy, roster: nil, policy_source: source, digest: digest)
      Side.new(id: project.id, project: project, ledger: wrapped, policy: policy, source: source, digest: digest, target: target,
               cwd: File.expand_path(project.repo), global: Layers.global, chain: chain_of(project, ledger, raw, raw_digest, local))
    end

    def chain_of(project, ledger, raw, raw_digest, local)
      return nil unless raw.is_a?(Hash)

      Layers.load(project, nil, policy: raw, digest: raw_digest, ledger: ledger, local: local)
    rescue StandardError
      nil
    end

    def compose(project, ledger, policy_text, env_text, source:, local:)
      combined = Environments.combine(policy_text, env_text, source)
      unless combined.errors.nil?
        detail = Array(combined.errors).first(3).map { |error| "#{error['pointer']} #{error['message']}".strip }
        raise Operator::Failure.new("policy_invalid", "the proposed policy for #{project.id} does not validate", "problems" => detail)
      end
      if combined.data["project"] != project.id
        raise Operator::Failure.new("policy_invalid", "the proposed policy names project #{combined.data['project']}, not #{project.id}")
      end

      policy, digest = Layers.compose(project, combined.data, combined.digest, ledger: ledger, local: local)
      side(project: project, ledger: ledger, policy: policy, source: source, digest: digest, raw: combined.data, raw_digest: combined.digest, local: local)
    end

    def resolved(project, ledger)
      loaded = PolicySource.resolve(project, ledger: ledger)
      raw = PolicySource.raw(project, ledger: ledger)
      side(project: project, ledger: ledger, policy: loaded.policy, source: loaded.source, digest: loaded.digest,
           raw: raw && raw.policy, raw_digest: raw && raw.digest, local: Layers.local_source(project, loaded.source))
    end

    def generate(policy, repo)
      envs = Engine::Envs.environments(policy)
      list = []
      envs.each do |name, spec|
        next unless spec.is_a?(Hash)

        branch = spec["branch"]
        checkout = spec["checkout"].to_s
        base = checkout.empty? || checkout == "repo" ? repo : File.expand_path(checkout)
        GIT_CLASSES.each { |klass| list << ["#{klass} #{branch} (#{name})", Action.new(class: klass, env_hint: { "ref" => branch, "path" => base }, raw: "plan probe")] } if branch
        list << ["data.write #{base}/probe-data (#{name})", Action.new(class: "data.write", env_hint: { "path" => "#{base}/probe-data" }, raw: "plan probe")]
        unless base == repo
          list << ["fs.write #{base}/probe (#{name})", Action.new(class: "fs.write", env_hint: { "path" => "#{base}/probe" }, raw: "plan probe")]
          list << ["fs.delete #{base}/probe (#{name})", Action.new(class: "fs.delete", env_hint: { "path" => "#{base}/probe" }, raw: "plan probe")]
        end
        Array(spec["secrets"]).each do |glob|
          list << ["secrets.read #{glob} (#{name})", Action.new(class: "secrets.read", env_hint: { "secret" => glob.gsub(/[*?]/, "x") }, raw: "plan probe")]
        end
        Array(spec["services"]).each do |unit|
          list << ["service.control #{unit} (#{name})", Action.new(class: "service.control", env_hint: { "unit" => unit }, raw: "plan probe")]
        end
        tier = Engine::Envs.tier_name(name, policy)
        %w[deploy promote].each { |klass| list << ["#{klass} #{name}", Action.new(class: klass, env_hint: { "env" => tier }, raw: "plan probe")] }
      end
      names = envs.select { |_, spec| spec.is_a?(Hash) }.keys
      names.permutation(2).each do |from, to|
        list << ["data.copy #{from} -> #{to}", Action.new(class: "data.copy", env_hint: { "from" => { "env" => Engine::Envs.tier_name(from, policy) }, "to" => { "env" => Engine::Envs.tier_name(to, policy) } }, raw: "plan probe")]
      end
      list << ["policy.edit #{Packages::Runner::POLICY_FILE}", Action.new(class: "policy.edit", env_hint: { "path" => File.join(repo, Packages::Runner::POLICY_FILE) }, raw: "plan probe")]
      list << ["fs.write #{Runtime.root}/probe (runtime)", Action.new(class: "fs.write", env_hint: { "path" => File.join(Runtime.root, "probe") }, raw: "plan probe")]
      list
    end

    def judge(side, action)
      return UNGOVERNED if side.nil? || side.project.status != "live"

      context = { cwd: side.cwd, ledger: side.ledger, global: side.global, tool: "plan", policies: { side.id => side.policy } }
      verdict = Engine.explain([action], side.target, context).verdict
      Outcome.new(verdict.level, verdict.rule_id)
    rescue StandardError => e
      Outcome.new("error", e.class.name)
    end

    def outcomes(side, actions)
      actions.map { |_label, action| judge(side, action) }
    end

    def compare(actions, old, new)
      actions.each_with_index.map { |(label, _action), index| pair(label, old[index], new[index]) }
    end

    def run(before, after)
      reference = after || before
      return [] unless reference

      actions = generate(reference.policy, reference.cwd)
      compare(actions, outcomes(before, actions), outcomes(after, actions))
    end

    def pair(label, old, new)
      change = new.severity > old.severity ? "tighten" : (new.severity < old.severity ? "loosen" : "same")
      { "probe" => label, "before" => old.text, "after" => new.text, "change" => change }
    end

    def journal_actions(rows)
      grouped = rows.group_by { |row| [row["project"], row["action_class"], row["env"], row["ref"], row["path"], row["destructive"], Array(row["shape"])] }
      grouped.values.map do |entries|
        row = entries.first
        ["journal #{Journal.label(row)} (#{row['env']}) x#{entries.length}", Journal.action_for(row)]
      end
    end
  end
end
