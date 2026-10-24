#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../code/core"

module Polispec
  module Commands
    class SpecsCommand
      USAGE = "usage: polispec specs link|status|promote [--repo DIR] [--dry-run] [--json]".freeze

      def self.run(args)
        new.run(args)
      end

      def run(args)
        args = args.dup
        verb = args.shift
        json = args.delete("--json")
        dry_run = !args.delete("--dry-run").nil?
        index = args.index("--repo")
        repo = index ? File.expand_path(args[index + 1].to_s) : Code::Paths.specs_repo
        return usage unless %w[link status promote].include?(verb)
        return usage if dry_run && verb != "link"

        Trace.info("specs repo", repo: Trace.path(repo), dry_run: (dry_run if verb == "link")) if Trace.on?
        result = Trace.step("specs #{verb}", repo: (Trace.path(repo) if Trace.on?)) do
          verb == "link" ? Code::Admin.link(repo, dry_run: dry_run) : Code::Admin.public_send(verb, repo)
        end
        Trace.info("specs result", link: result["link"], changed: result["changed"], target: result["target"], stable: result["stable"].to_s[0, 12], from: result["from"].to_s[0, 12], to: result["to"].to_s[0, 12]) if Trace.on? && result.is_a?(Hash)
        json ? puts(JSON.generate(result)) : print_text(verb, result)
        0
      rescue Operator::Tty::NotTty => e
        warn "polispec specs: not_tty: #{e.message}"
        1
      rescue Operator::Tty::PhraseMismatch => e
        warn "polispec specs: confirmation_failed: #{e.message}"
        1
      rescue Code::Error => e
        warn "polispec specs: #{e.message}"
        1
      end

      private

      def usage
        warn USAGE
        2
      end

      def print_text(verb, result)
        case verb
        when "link"
          note = result["changed"] ? "" : " (already linked)"
          note = " (dry run: would #{result['replaces'] ? "replace #{result['replaces']}, needs a terminal and the typed phrase relink #{result['target']}" : 'create the link'})" if result["dry_run"]
          puts "#{result['link']} -> #{result['target']}#{note}"
        when "status"
          puts "repo #{result['repo']}"
          puts "link #{result['link']} #{result['linked'] ? 'ok' : 'not linked'}"
          puts "stable #{result['stable'] || 'missing (hooks fail open until the first promote)'}"
          puts "main   #{result['main']}  ahead of stable by #{result['main_ahead'].inspect}"
          puts "controls main #{controls(result['controls_main'])}; stable #{controls(result['controls_stable'])}"
        else
          puts "promoted stable #{result['from'].to_s[0, 12]} -> #{result['to'][0, 12]} (#{result['controls']} controls)"
        end
      end

      def controls(state)
        state ? "#{state['ok'] ? 'clean' : 'FAILED'} (#{state['total']} at #{state['at']})" : "not recorded"
      end
    end
  end

  CLI.register("specs", Commands::SpecsCommand, summary: "polispec-specs: link, status, promote")
end
