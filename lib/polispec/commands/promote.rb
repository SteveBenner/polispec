#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../operator/gates"
require_relative "../operator/promote"
require_relative "../changes"

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

        before = dry_run ? nil : Changes.epoch
        result = Polispec::Operator::Promote.call(args.first, to: target, dry_run: !dry_run.nil?, waive_soak: !waive_soak.nil?)
        record_change(result, before) unless dry_run
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

      def record_change(result, before)
        Changes.record(kind: "promote", subject: { "project" => result["project"], "env" => result["to"], "tag" => result["tag"], "sha" => result["to_sha"] },
                       epoch_before: before, details: { "project" => result["project"], "files" => session_files(result) })
      end

      def session_files(result)
        project = Ledger.load.project(result["project"])
        return [] unless project && project.trust_ref == result["to"] && result["from_sha"].to_s.match?(/\A[0-9a-f]{40,64}\z/) && result["from_sha"].to_s.count("0") != result["from_sha"].to_s.length

        out, status = Open3.capture2(Polispec::Operator::Git.env, "git", "-C", File.expand_path(project.repo), "diff", "--name-only", result["from_sha"], result["to_sha"], err: File::NULL)
        status.success? ? out.lines.map(&:strip) : []
      rescue StandardError
        []
      end

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
