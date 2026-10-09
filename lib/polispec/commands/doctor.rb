#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../validate_profiles"

module Polispec
  class DoctorCommand
    USAGE = "usage: polispec doctor [--json]"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      args = args.dup
      json = args.delete("--json")
      return usage unless args.empty?

      findings = []
      ledger = load_ledger(findings)
      check_ledger(ledger, findings) if ledger
      check_runtime(findings)
      json ? puts(JSON.generate("ok" => findings.empty?, "findings" => findings)) : print_text(findings)
      findings.empty? ? 0 : 1
    end

    private

    def load_ledger(findings)
      path = Ledger.default_path
      unless File.file?(path)
        findings << finding(nil, "ledger_missing", "no ledger at #{path}")
        return nil
      end
      result = Schema.validate_file("ledger", path)
      result.errors.each { |error| findings << finding(nil, "ledger_invalid", "#{error.pointer} #{error.message}".strip) }
      Ledger.load(path)
    rescue Polispec::Error => e
      findings << finding(nil, "ledger_unreadable", e.message)
      nil
    end

    def check_ledger(ledger, findings)
      ledger.projects.reject { |project| project.status == "retired" }.each do |project|
        check_project(ledger, project, findings)
      end
    end

    def check_project(ledger, project, findings)
      unless File.directory?(File.expand_path(project.repo))
        findings << finding(project.id, "repo_missing", "#{project.repo} is not a directory")
        return
      end
      loaded = PolicySource.resolve(project, ledger: ledger)
      findings << finding(project.id, loaded.finding["kind"], loaded.finding["detail"]) if loaded.finding
      defaults = loaded.source == "defaults"
      roster = PolicySource.roster_digest(project)
      Polispec::ValidateProfiles.errors(loaded.policy, project, ledger: ledger).each { |detail| findings << finding(project.id, "profile_check", detail) } unless defaults
      findings << finding(project.id, "roster_missing", "#{project.trust_ref}:#{project.roster} not found") if roster.nil? && !defaults
      AgentsRender.drift(project.repo, project.trust_ref, project).each { |detail| findings << finding(project.id, "agents_drift", detail) } unless defaults
      findings << finding(project.id, "not_live", "status #{project.status}: the guard does not enforce this project") unless project.status == "live"
    end

    def check_runtime(findings)
      findings << finding(nil, "ruby_old", "ruby #{RUBY_VERSION} is older than 2.6") if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("2.6")
      findings << finding(nil, "state_unwritable", "#{State.home} is not writable") unless writable?(State.home)
      Classify::Registry.families
      Classify::Registry.load_errors.each { |file, message| findings << finding(nil, "classifier_load", "#{file}: #{message}") }
      findings << finding(nil, "classifier_absent", "no classifier family is installed; every call classifies to no action") if Classify::Registry.families.empty?
      CLI.load_all
      CLI.load_errors.each { |file, message| findings << finding(nil, "command_load", "#{file}: #{message}") }
    end

    def writable?(dir)
      FileUtils.mkdir_p(dir, mode: 0o700)
      File.writable?(dir)
    rescue SystemCallError
      false
    end

    def finding(project, kind, detail)
      { "project" => project, "kind" => kind, "detail" => detail }
    end

    def print_text(findings)
      if findings.empty?
        puts "polispec doctor: 0 findings"
      else
        puts "polispec doctor: #{findings.length} finding#{'s' unless findings.length == 1}"
        findings.each { |item| puts "  #{item['project'] || '-'}  #{item['kind']}  #{item['detail']}" }
      end
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("doctor", Polispec::DoctorCommand, summary: "check the ledger, trust-ref policies, state and classifier")
