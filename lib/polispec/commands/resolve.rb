#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "classify"

module Polispec
  module Commands
    class ResolveCommand
      USAGE = "usage: polispec resolve <path> [--json] [--ledger FILE] [--policy FILE]".freeze

      def self.run(args)
        new.run(args)
      end

      def run(args)
        parsed = Options.parse(args)
        return usage unless parsed.rest.length == 1

        ledger = Options.apply(parsed)
        result = Resolve::Resolver.new(ledger).describe(parsed.rest.first)
        parsed.json ? puts(JSON.generate(result)) : print_text(parsed.rest.first, result)
        0
      end

      private

      def usage
        warn USAGE
        2
      end

      def print_text(path, result)
        return puts("#{path}: not ledgered") unless result["project"]

        puts "#{path}: #{result['project']} #{result['env']} branch=#{result['branch']} policy=#{result['policy_source']} #{result['policy_digest']}"
      end
    end

    CLI.register("resolve", ResolveCommand, summary: "resolve a path to its project and environment")
  end
end
