#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "../deployments"

module Polispec
  class DeploymentsCommand
    USAGE = "usage: polispec deployments [--scan] [--json]"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      unknown = args - %w[--scan --json]
      unless unknown.empty?
        warn "polispec: unknown argument #{unknown.first}"
        warn USAGE
        return 2
      end
      json = args.include?("--json")
      added = args.include?("--scan") ? Deployments.scan! : []
      list = Deployments.with_status
      if json
        puts JSON.generate({ "schema" => Deployments::SCHEMA, "added" => added.map { |entry| entry["id"] }, "entries" => list })
      else
        report(added, list)
      end
      0
    rescue Polispec::Error => e
      warn "polispec: #{e.message}"
      1
    end

    private

    def report(added, list)
      unless added.empty?
        puts "scan added #{added.length}:"
        added.each { |entry| puts "  #{entry['id']}  #{entry['kind']}  #{entry['target']}" }
      end
      puts "no deployments recorded" if list.empty?
      list.each { |entry| puts "#{entry['live_status'].ljust(8)} #{entry['class'].ljust(8)} #{entry['kind'].ljust(10)} #{entry['target']}" }
    end
  end
end

Polispec::CLI.register("deployments", Polispec::DeploymentsCommand, summary: "list where polispec is deployed on this host; --scan backfills the manifest from what exists")
