#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "json"

tree = File.expand_path(ARGV.fetch(0))
input = JSON.parse(File.read(ARGV.fetch(1)))
require File.join(tree, "lib", "polispec")
require File.join(tree, "lib", "polispec", "plan")

GLOBAL_ID = "global"

def unowned_outcomes(ledger, id, specs)
  digest = Polispec::Layers.fingerprint
  target = Polispec::Target.new(project: id, env: "dev", policy: { "rules" => [] }, roster: nil, policy_source: id == GLOBAL_ID ? "global" : "path", digest: digest)
  shelf = Polispec::Layers.global
  results = Polispec::PolicySource.memoize do
    specs.to_h do |spec|
      action = Polispec::Journal.action_for(spec)
      cwd = spec["cwd"].to_s.empty? ? Dir.home : File.expand_path(spec["cwd"])
      context = { ledger: ledger, cwd: cwd, global: shelf, session_id: nil, role: nil, tool: spec["tool"].to_s, issue_allow_once: false }
      verdict = Polispec::Engine.explain([action], target, context).verdict
      [spec["key"].to_s, [verdict.level.to_s, verdict.rule_id]]
    end
  end
  { "digest" => digest, "outcomes" => results }
end

ledger = Polispec::Ledger.load
output = { "version" => Polispec.version, "projects" => {} }
Polispec::Probes.silently do
  input.fetch("projects").each do |id, specs|
    project = ledger.projects.find { |item| item.id == id }
    if project
      side = Polispec::Probes.resolved(project, ledger)
      actions = specs.map { |spec| [spec["key"], Polispec::Journal.action_for(spec)] }
      outcomes = Polispec::Probes.outcomes(side, actions)
      results = specs.each_with_index.to_h { |spec, index| [spec["key"].to_s, [outcomes[index].level.to_s, outcomes[index].rule_id]] }
      output["projects"][id] = { "digest" => side.digest, "outcomes" => results }
    elsif id == GLOBAL_ID || ledger.path_entry(id)
      output["projects"][id] = unowned_outcomes(ledger, id, specs)
    end
  end
end
puts JSON.generate(output)
