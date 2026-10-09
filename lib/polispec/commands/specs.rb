#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../code/core"

module Polispec
  module Commands
    class SpecsCommand
      USAGE = "usage: polispec specs link|status|promote [--repo DIR] [--json]".freeze

      def self.run(args)
        new.run(args)
      end

      def run(args)
        args = args.dup
        verb = args.shift
        json = args.delete("--json")
        index = args.index("--repo")
        repo = index ? File.expand_path(args[index + 1].to_s) : Code::Paths.specs_repo
        return usage unless %w[link status promote].include?(verb)

        result = Code::Admin.public_send(verb, repo)
        json ? puts(JSON.generate(result)) : print_text(verb, result)
        0
      rescue Operator::Tty::NotTty, Operator::Tty::PhraseMismatch, Code::Error => e
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
          puts "#{result['link']} -> #{result['target']}#{result['changed'] ? '' : ' (already linked)'}"
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
