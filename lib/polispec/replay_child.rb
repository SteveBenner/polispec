#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "json"

tree = File.expand_path(ARGV.fetch(0))
input = JSON.parse(File.read(ARGV.fetch(1)))
require File.join(tree, "lib", "polispec")
require File.join(tree, "lib", "polispec", "plan")

ledger = Polispec::Ledger.load
output = { "version" => Polispec.version, "projects" => {} }
Polispec::Probes.silently do
  input.fetch("projects").each do |id, specs|
    project = ledger.projects.find { |item| item.id == id }
    next unless project

    side = Polispec::Probes.resolved(project, ledger)
    actions = specs.map { |spec| [spec["key"], Polispec::Journal.action_for(spec)] }
    outcomes = Polispec::Probes.outcomes(side, actions)
    results = specs.each_with_index.to_h { |spec, index| [spec["key"].to_s, [outcomes[index].level.to_s, outcomes[index].rule_id]] }
    output["projects"][id] = { "digest" => side.digest, "outcomes" => results }
  end
end
puts JSON.generate(output)
