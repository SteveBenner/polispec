#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "classify"

module Polispec
  module Commands
    class ResolveCommand
      USAGE = "usage: polispec resolve <path> [--layers] [--json] [--ledger FILE] [--policy FILE]".freeze

      def self.run(args)
        new.run(args)
      end

      def run(args)
        args = args.dup
        layers = !args.delete("--layers").nil?
        parsed = Options.parse(args)
        return usage unless parsed.rest.length == 1

        ledger = Options.apply(parsed)
        resolver = Resolve::Resolver.new(ledger)
        result = resolver.describe(parsed.rest.first)
        result = result.merge(chain_for(resolver, ledger, parsed.rest.first, result)) if layers
        parsed.json ? puts(JSON.generate(result)) : print_text(parsed.rest.first, result)
        0
      end

      private

      def chain_for(resolver, ledger, path, result)
        project = result["project"] && ledger.project(result["project"])
        info = project && resolver.entry(project)
        policy = info && info.policy.is_a?(Hash) ? info.policy : nil
        Layers.load(project, path, policy: policy, digest: info&.digest, ledger: ledger, policy_source: info&.source).to_h
      end

      def usage
        warn USAGE
        2
      end

      def print_text(path, result)
        return puts("#{path}: not ledgered") unless result["project"] || result["layers"]

        puts "#{path}: #{result['project']} #{result['env']} branch=#{result['branch']} policy=#{result['policy_source']} #{result['policy_digest']}"
        return unless result["layers"]

        result["layers"].each { |layer| puts "  #{layer['layer']}  #{layer['source']}  #{layer['digest']}  rules=#{layer['rules']}" }
        puts "  effective #{result['effective_digest']}"
        result["errors"].each { |error| puts "  error: #{error}" }
      end
    end

    CLI.register("resolve", ResolveCommand, summary: "resolve a path to its project and environment")
  end
end
