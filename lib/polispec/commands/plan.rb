#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../plan"

module Polispec
  class PlanCommand
    def self.run(args)
      new.run(args)
    end

    def run(args)
      parsed = Plan::Args.parse(args, "plan")
      plan = Plan.build(parsed.spec)
      parsed.json ? puts(plan.to_json) : plan.render_text
      0
    rescue Packages::Usage => e
      warn "polispec: #{e.message}"
      warn Plan::Args.usage("plan")
      2
    rescue Operator::Failure => e
      e.report(json: args.include?("--json"))
      1
    end
  end
end

Polispec::CLI.register("plan", Polispec::PlanCommand, summary: "preview a package, project spec, global shelf or ledger change: files, policy diff, verdict probes, plan id")
