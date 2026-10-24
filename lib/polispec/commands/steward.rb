#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "../stewardship"
require_relative "../deployments"

module Polispec
  class StewardCommand
    USAGE = "usage: polispec steward [--check] [--json]"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      unknown = args - %w[--check --json]
      unless unknown.empty?
        warn "polispec: unknown argument #{unknown.first}"
        warn USAGE
        return 2
      end
      json = args.include?("--json")
      if args.include?("--check")
        steps = Trace.step("steward check") { Stewardship.check }
        report(steps, json)
      else
        steps = Trace.step("steward ensure") { Stewardship.ensure!(quiet: json) }
        Trace.step("refresh stewardship record") { Deployments.refresh_stewardship }
        report(steps, json) if json
      end
      steps.all? { |step| %w[ok installed warn].include?(step.status) } ? 0 : 1
    rescue Operator::Failure => e
      e.report(json: json)
      1
    end

    private

    def report(steps, json)
      if json
        ok = steps.all? { |step| %w[ok installed warn].include?(step.status) }
        puts JSON.generate({ "runtime" => { "kind" => Runtime.kind, "commit" => Runtime.commit, "root" => Runtime.root }, "steps" => steps.map(&:to_h), "ok" => ok })
      else
        steps.each { |step| puts step.line }
      end
    end
  end
end

Polispec::CLI.register("steward", Polispec::StewardCommand, summary: "check or set up the stewardship rule, the runtime protection and a pinned runtime; --check only reports")
