#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../operator/gates"
require_relative "../operator/deploy"

module Polispec
  module Commands
    class Deploy
      USAGE = "usage: polispec deploy <project> <test|stable> [--tag vX.Y.Z] [--skip-drain] [--dry-run] [--json]"

      def run(args)
        args = args.dup
        json = args.delete("--json")
        dry_run = args.delete("--dry-run")
        skip_drain = args.delete("--skip-drain")
        tag = extract_tag(args)
        return usage unless args.length == 2

        result = Polispec::Operator::Deploy.call(args[0], args[1], tag: tag, dry_run: !dry_run.nil?, skip_drain: !skip_drain.nil?)
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

      def extract_tag(args)
        inline = args.find { |arg| arg.start_with?("--tag=") }
        return args.delete(inline).sub("--tag=", "") if inline

        index = args.index("--tag")
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
        if result["dry_run"]
          puts "dry run: deploy #{result['project']} #{result['env']} into #{result['dir']} from #{result['source']}"
          Array(result["steps"]).each { |step| puts "  step: #{step}" }
          return
        end

        puts "deployed #{result['project']} #{result['env']} #{result['tag'] || result['sha'][0, 12]} (version #{result['version']}) in #{result['dir']}"
        result["steps"].each { |step| puts "  step #{step['command']}: exit #{step['exit']}" }
        puts "  health: #{result.dig('health', 'status')} (#{result.dig('health', 'detail')})"
        puts "  pinned_behind: #{result['pinned_behind']}"
      end
    end
  end

  CLI.register("deploy", Commands::Deploy, summary: "check out an environment and run its deploy steps with a health check")
end
