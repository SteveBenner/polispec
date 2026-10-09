#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Commands
    module Options
      Parsed = Struct.new(:ledger_file, :policy_file, :cwd, :json, :rest)

      module_function

      def parse(args)
        parsed = Parsed.new(nil, nil, nil, false, [])
        rest = args.dup
        until rest.empty?
          arg = rest.shift
          case arg
          when "--json" then parsed.json = true
          when "--ledger" then parsed.ledger_file = rest.shift
          when "--policy" then parsed.policy_file = rest.shift
          when "--cwd" then parsed.cwd = rest.shift
          else parsed.rest << arg
          end
        end
        parsed
      end

      def apply(parsed)
        ENV["POLISPEC_POLICY"] = File.expand_path(parsed.policy_file) if parsed.policy_file
        Ledger.load(parsed.ledger_file)
      end

      def plain(value)
        JSON.parse(JSON.generate(value))
      end
    end

    class ClassifyCommand
      USAGE = "usage: polispec classify [--json] [--ledger FILE] [--policy FILE] [--cwd DIR] < hook-json".freeze

      def self.run(args)
        new.run(args)
      end

      def run(args)
        parsed = Options.parse(args)
        return usage if $stdin.tty? || !parsed.rest.empty?

        payload = JSON.parse($stdin.read)
        return usage unless payload.is_a?(Hash)

        ledger = Options.apply(parsed)
        cwd = parsed.cwd || payload["cwd"] || Dir.pwd
        rows = rows_for(payload, cwd, ledger)
        parsed.json ? puts(JSON.generate("tool_name" => payload["tool_name"], "cwd" => cwd, "actions" => rows)) : print_text(rows)
        0
      rescue JSON::ParserError => e
        warn "polispec classify: invalid hook JSON: #{e.message}"
        2
      end

      private

      def usage
        warn USAGE
        2
      end

      def rows_for(payload, cwd, ledger)
        resolver = Resolve.resolver(ledger)
        Classify.call(payload["tool_name"], payload["tool_input"] || {}, cwd).map do |action|
          target = resolver.call(action)
          { "class" => action.action_class, "env_hint" => Options.plain(action.env_hint), "raw" => action.raw, "target" => target && Options.plain(target.to_h) }
        end
      end

      def print_text(rows)
        rows.each do |row|
          target = row["target"]
          where = target ? "#{target['project'] || '-'}@#{target['env']}" : "-"
          puts format("%-16s %-18s %s", row["class"], where, row["raw"])
        end
      end
    end

    CLI.register("classify", ClassifyCommand, summary: "classify a hook tool call into action classes with resolved environments")
  end
end
