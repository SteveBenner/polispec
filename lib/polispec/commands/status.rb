#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

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
      raise Polispec::Error, "#{args.first} is not in the ledger" if projects.empty? && !args.empty?

      report = { "ledger" => ledger.path, "enforce" => Engine::Settings.enforce_mode, "projects" => projects.map { |project| describe(ledger, project) } }
      json ? puts(JSON.generate(report)) : print_text(report)
      0
    end

    private

    def describe(ledger, project)
      entry = { "id" => project.id, "status" => project.status, "trust_ref" => project.trust_ref, "repo" => project.repo }
      return entry if project.status == "retired"

      loaded = PolicySource.resolve(project, ledger: ledger)
      pause = Engine::Pauses.active(ledger, project.id)
      windows = %w[promote.to_stable desk.dispatch].flat_map { |scope| Freeze.active(loaded.policy, scope, project: project) }
      entry.merge(
        "policy_source" => loaded.source, "policy_digest" => loaded.digest, "finding" => loaded.finding,
        "pause" => pause, "freezes" => windows.map(&:to_h), "pending_allow_once" => pending(ledger, project.id)
      )
    end

    def pending(ledger, project_id)
      Engine::Passes.fold(ledger).values.count { |entry| entry["project"] == project_id && entry["consumed_at"].nil? }
    end

    def print_text(report)
      puts "ledger #{report['ledger']}; guard mode #{report['enforce']}"
      report["projects"].each do |entry|
        puts "#{entry['id']}: #{entry['status']} trust_ref=#{entry['trust_ref']}"
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
