#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "json"
require_relative "../shadow"

module Polispec
  class ShadowCommand
    USAGE = <<~TEXT.chomp.freeze
      usage: polispec shadow start --runtime <tree>
             polispec shadow status [--json]
             polispec shadow report [--json]
             polispec shadow stop
    TEXT

    def self.run(args)
      new.run(args)
    end

    def run(args)
      verb, *rest = args
      case verb
      when "start" then start(rest)
      when "status", "report" then show(verb, rest)
      when "stop" then rest.empty? ? stop : usage
      when "work" then rest.length == 1 ? work(rest.first) : usage
      else usage
      end
    rescue Polispec::Error => e
      warn "polispec shadow: #{e.message}"
      1
    end

    private

    def start(args)
      return usage unless args.length == 2 && args.first == "--runtime"

      record = Shadow.start(args.last)
      puts "shadowing #{record['runtime']} (#{record['version']}) beside the live guard (#{record['live_version']}); disagreements go to #{Shadow.log_path}"
      0
    end

    def show(verb, args)
      json = args.delete("--json")
      return usage unless args.empty?

      report = Shadow.report
      if json
        puts JSON.generate(report)
        return 0
      end

      current = report["shadow"]
      puts current ? "shadow: #{current['runtime']} (#{current['version']}) since #{current['started_at']}" : "shadow: none running"
      puts "disagreements: #{report['disagreements']}, errors: #{report['errors']}"
      report["changes"].each do |change|
        puts "  rule #{change['rule_before'] || '-'} -> #{change['rule_after'] || '-'}  verdict #{change['verdict_before']} -> #{change['verdict_after']}  x#{change['count']}  tools #{change['tools'].join(',')}  e.g. #{change['example_call_digest'].to_s[0, 19]}  last #{change['last_seen']}"
      end
      puts "last error: #{report['last_error']['ts']} #{report['last_error']['error']}" if verb == "report" && report["last_error"]
      0
    end

    def stop
      previous = Shadow.stop
      puts previous ? "stopped shadowing #{previous['runtime']}; the log stays at #{Shadow.log_path}" : "no shadow was running"
      0
    end

    def work(file)
      Shadow.work(file)
      0
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("shadow", Polispec::ShadowCommand, summary: "run a candidate runtime in shadow beside the live guard and record where its verdicts differ before cutover")
