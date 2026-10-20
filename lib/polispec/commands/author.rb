#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "../author"

module Polispec
  module Commands
    class AuthorCommand
      USAGE = <<~TEXT.freeze
        usage: polispec author draft <policy|module|package|environments|roster|global|spec|description> --intent TEXT [--for PROJECT] [--adapter ID] [--json]
               polispec author adapters [--json]
      TEXT

      def self.run(args)
        new.run(args)
      end

      def run(args)
        args = args.dup
        verb = args.shift
        opts = parse(args)
        return usage unless opts

        json = opts[:json]
        begin
          Author.ensure_available!
          case verb
          when "draft" then draft(opts)
          when "adapters" then adapters(opts)
          else usage
          end
        rescue Author::Unavailable => e
          refuse(json, e)
        rescue Polispec::Error => e
          fail_with(json, e.message)
        end
      end

      private

      def parse(args)
        opts = { json: false, positional: [] }
        until args.empty?
          arg = args.shift
          case arg
          when "--json" then opts[:json] = true
          when "--intent", "--for", "--adapter"
            value = args.shift
            return nil if value.nil?

            opts[arg.delete_prefix("--").to_sym] = value
          when /\A-./ then return nil
          else opts[:positional] << arg
          end
        end
        opts
      end

      def usage
        warn USAGE
        2
      end

      def refuse(json, error)
        if json
          puts JSON.generate("ok" => false, "error" => error.reason, "message" => error.message)
        else
          warn "polispec: author unavailable (#{error.reason}): #{error.message}"
        end
        2
      end

      def fail_with(json, message)
        if json
          puts JSON.generate("ok" => false, "error" => message)
        else
          warn "polispec: #{message}"
        end
        1
      end

      def adapters(opts)
        return usage unless opts[:positional].empty?

        info = Author.adapters
        if opts[:json]
          puts JSON.generate(info)
        else
          puts "builtin: #{info['builtin'].join(', ')}"
          puts "extension: #{info['extension'].empty? ? 'none' : info['extension'].join(', ')}"
          puts "extension_note: #{info['extension_note']}" if info["extension_note"]
          puts "selected: #{info['selected']}"
        end
        0
      end

      def draft(opts)
        kind = opts[:positional].first
        return usage unless opts[:positional].length == 1 && Author::KINDS.include?(kind) && opts[:intent] && !opts[:intent].strip.empty?

        context = { project: opts[:for], target_file: nil, current_yaml: nil, shelf_modules: shelf_modules, schema_id: kind == "description" ? nil : "polispec.#{kind}/v1" }
        port = Author.port(adapter: opts[:adapter])
        result = port.draft(kind: kind, intent: opts[:intent], context: context)
        port.close(result[:session])
        report(opts, kind, result)
      end

      def shelf_modules
        Dir.glob(File.join(ROOT, "modules", "*.yml")).map { |file| File.basename(file, ".yml") }.sort
      end

      def report(opts, kind, result)
        if opts[:json]
          puts JSON.generate("ok" => !result[:yaml].nil?, "kind" => kind, "yaml" => result[:yaml], "rationale" => result[:rationale],
                             "adapter" => result[:adapter], "session" => result[:session], "findings" => result[:findings].map { |item| stringify(item) },
                             "plan" => result[:plan])
        else
          puts "adapter: #{result[:adapter]}"
          puts "session: #{result[:session]}"
          puts "findings: #{result[:findings].length}"
          result[:findings].each { |item| puts "  #{item[:code]}: #{item[:message]}" }
          puts "plan: #{result[:plan] ? JSON.generate(result[:plan]) : 'none'}"
          puts "---"
          puts result[:yaml].to_s
          puts "--- rationale"
          puts result[:rationale].to_s
        end
        result[:yaml].nil? ? 1 : 0
      end

      def stringify(hash)
        hash.each_with_object({}) { |(key, value), memo| memo[key.to_s] = value }
      end
    end
  end

  CLI.register("author", Commands::AuthorCommand, summary: "draft a rulebook with an AI session and validate it; writes nothing")
end
