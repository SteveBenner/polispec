#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../operator/gates"
require_relative "../operator/promote"

module Polispec
  module Commands
    class Promote
      USAGE = "usage: polispec promote <project> --to test|stable [--waive-soak] [--dry-run] [--json]"

      def run(args)
        args = args.dup
        json = args.delete("--json")
        dry_run = args.delete("--dry-run")
        waive_soak = args.delete("--waive-soak")
        target = extract_target(args)
        return usage unless args.length == 1 && target

        result = Polispec::Operator::Promote.call(args.first, to: target, dry_run: !dry_run.nil?, waive_soak: !waive_soak.nil?)
        json ? puts(JSON.generate(result)) : print_text(result)
        0
      rescue Polispec::Operator::Failure => e
        e.report(json: json)
        1
      rescue Polispec::Error => e
        Polispec::Operator::Failure.new("error", e.message).report(json: json)
        1
      end

      private

      def extract_target(args)
        inline = args.find { |arg| arg.start_with?("--to=") }
        return args.delete(inline).sub("--to=", "") if inline

        index = args.index("--to")
        return nil unless index && args[index + 1]

        value = args[index + 1]
        args.slice!(index, 2)
        value
      end

      def usage
        warn USAGE
        2
      end

      def print_text(result)
        head = result["dry_run"] ? "dry run" : "promoted"
        puts "#{head}: #{result['project']} to #{result['to']} at #{result['to_sha'][0, 12]} (#{result['tag']}, actor #{result['actor']})"
        result["gates"].each { |gate| puts "  gate #{gate['id']}: #{gate['result']} (#{gate['duration_ms']} ms)" }
        return if result["dry_run"]

        puts "  record #{result['record_id']}; release #{result.dig('release', 'status')}"
        result["deploys"].each do |deploy|
          puts "  deploy #{deploy['env']}: health #{deploy.dig('health', 'status')}, #{deploy['steps'].length} steps" if deploy.key?("env")
        end
      end
    end
  end

  CLI.register("promote", Commands::Promote, summary: "move code main to test (gated) or test to stable (operator)")
end
