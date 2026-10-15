#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../operator/git"

module Polispec
  class StatusCommand
    USAGE = "usage: polispec status [<project>] [--json]"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      args = args.dup
      json = args.delete("--json")
      return usage unless args.length <= 1

      ledger = Ledger.load
      projects = args.empty? ? ledger.projects : [ledger.project(args.first)].compact
      raise Polispec::Operator::Failure.new("unknown_project", "#{args.first} is not in the ledger") if projects.empty? && !args.empty?

      report = { "ledger" => ledger.path, "enforce" => Engine::Settings.enforce_mode, "projects" => projects.map { |project| describe(ledger, project) } }
      json ? puts(JSON.generate(report)) : print_text(report)
      0
    rescue Polispec::Operator::Failure => e
      e.report(json: json)
      1
    rescue Polispec::Error => e
      Polispec::Operator::Failure.new("error", e.message).report(json: json)
      1
    end

    private

    def describe(ledger, project)
      entry = { "id" => project.id, "status" => project.status, "trust_ref" => project.trust_ref, "repo" => project.repo }
      entry["packages"] = project.packages.map { |item| item.slice("name", "variant", "version", "applied_at") } unless project.packages.empty?
      return entry if project.status == "retired"

      loaded = PolicySource.resolve(project, ledger: ledger)
      pause = Engine::Pauses.active(ledger, project.id)
      windows = %w[promote.to_stable desk.dispatch].flat_map { |scope| Freeze.active(loaded.policy, scope, project: project) }
      entry.merge(
        "policy_source" => loaded.source, "policy_digest" => loaded.digest, "finding" => loaded.finding || semantic_finding(loaded, project, ledger),
        "pause" => pause, "freezes" => windows.map(&:to_h), "pending_allow_once" => pending(ledger, project.id),
        "deployments" => deployments(project.id)
      )
    end

    def semantic_finding(loaded, project, ledger)
      return nil if loaded.source == "defaults" || !loaded.policy.is_a?(Hash)

      problems = Operator::Gates.health_required_errors(loaded.policy) + Operator::Gates.env_names_errors(loaded.policy) + ValidateProfiles.errors(loaded.policy, project, ledger: ledger)
      problems.empty? ? nil : { "kind" => "policy_invalid", "detail" => problems.join("; ") }
    end

    def deployments(project_id)
      data = File.file?(State.state_file) ? Schema::Document.parse(File.read(State.state_file), State.state_file) : {}
      saved = data.is_a?(Hash) ? data["deployments"] : nil
      receipts = saved.is_a?(Hash) ? saved[project_id] : nil
      receipts = {} unless receipts.is_a?(Hash)
      attempts = State.read_jsonl("deploys").select { |row| row["project"] == project_id }.group_by { |row| row["env"] }
      (receipts.keys + attempts.keys).uniq.to_h do |env|
        receipt = receipts[env].is_a?(Hash) ? receipts[env].slice("record_id", "sha", "tag", "health", "pinned_behind", "at") : nil
        latest = attempts[env]&.last&.slice("id", "sha", "tag", "health", "pinned_behind", "at")
        verified = receipt && latest && !receipt["record_id"].to_s.empty? && receipt["record_id"] == latest["id"] &&
          receipt["sha"] == latest["sha"] && receipt["tag"] == latest["tag"] && receipt["health"] == "ok" &&
          latest["health"] == "ok" && receipt["pinned_behind"] == false && latest["pinned_behind"] == false
        [env, { "receipt" => receipt, "latest_attempt" => latest, "verified" => !!verified }]
      end
    rescue Polispec::Error, SystemCallError, TypeError
      {}
    end

    def pending(ledger, project_id)
      Engine::Passes.fold(ledger).values.count { |entry| entry["project"] == project_id && entry["consumed_at"].nil? }
    end

    def print_text(report)
      puts "ledger #{report['ledger']}; guard mode #{report['enforce']}"
      report["projects"].each do |entry|
        puts "#{entry['id']}: #{entry['status']} trust_ref=#{entry['trust_ref']}"
        Array(entry["packages"]).each { |item| puts "  package #{item['name']} #{item['version']}#{item['variant'] ? " (#{item['variant']})" : ''} applied #{item['applied_at']}" }
        next unless entry["policy_source"]

        puts "  policy #{entry['policy_source']} #{entry['policy_digest']}"
        puts "  finding #{entry['finding']['kind']}: #{entry['finding']['detail']}" if entry["finding"]
        puts "  paused until #{entry['pause']['expires_at']} (#{entry['pause']['reason']})" if entry["pause"]
        entry["freezes"].each { |window| puts "  frozen #{window['id']} until #{window['until']}" }
        puts "  allow-once ids outstanding or unconsumed: #{entry['pending_allow_once']}"
      end
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("status", Polispec::StatusCommand, summary: "policy source, pause, freeze and allow-once state per project")
