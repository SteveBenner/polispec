#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "../registration"
require_relative "../plan"
require_relative "apply"

module Polispec
  class RegisterCommand
    USAGE = "usage: polispec register <path> [--id ID] [--kind software|directory|system] [--description TEXT] [--dry-run] [--confirm PLAN_ID] [--json]\n       polispec unregister <id> [--dry-run] [--confirm PLAN_ID] [--json]"

    def self.run(args)
      new.run(args)
    end

    def self.run_unregister(args)
      new.run(args, unregister: true)
    end

    def run(args, unregister: false)
      options = parse(args)
      @json = options[:json]
      return usage unless options[:rest].length == 1

      ledger = Ledger.load
      target = options[:rest].first
      if unregister
        id = target
        text = Registration.propose_unregister(ledger, id)
      else
        id, text = Registration.propose_register(ledger, target, id: options[:id], kind: options[:kind] || "directory", description: options[:description])
      end
      file = Registration.proposal_file(id, text)
      plan = Plan.build(Plan::SPEC.new(kind: :ledger, file: file))
      @json ? puts(plan.to_json) : plan.render_text
      return 0 if options[:dry_run]

      apply = ["ledger", "--from", file]
      apply.push("--confirm", options[:confirm]) if options[:confirm]
      apply << "--json" if @json
      ApplyCommand.run(apply)
    rescue Packages::Usage, ArgumentError => e
      warn "polispec: #{e.message}"
      usage
    rescue Operator::Failure => e
      e.report(json: @json)
      1
    end

    private

    def parse(args)
      queue = args.dup
      options = { rest: [], json: false, dry_run: false }
      until queue.empty?
        arg = queue.shift
        flag, inline = arg.start_with?("--") ? arg.split("=", 2) : [arg, nil]
        case flag
        when "--id" then options[:id] = value(flag, inline, queue)
        when "--kind" then options[:kind] = value(flag, inline, queue)
        when "--description" then options[:description] = value(flag, inline, queue)
        when "--confirm" then options[:confirm] = value(flag, inline, queue)
        when "--dry-run" then options[:dry_run] = true
        when "--json" then options[:json] = true
        else
          raise ArgumentError, "unknown option #{arg}" if arg.start_with?("-")

          options[:rest] << arg
        end
      end
      options
    end

    def value(flag, inline, queue)
      found = inline || queue.shift
      raise ArgumentError, "#{flag} needs a value" if found.nil?

      found
    end

    def usage
      warn USAGE
      2
    end
  end
end

module Polispec
  class UnregisterCommand
    def self.run(args)
      RegisterCommand.run_unregister(args)
    end
  end
end

Polispec::CLI.register("register", Polispec::RegisterCommand, summary: "govern software, a directory or the system scope that is not a git repository: plan and apply a ledger path entry")
Polispec::CLI.register("unregister", Polispec::UnregisterCommand, summary: "retire a registered path entry through a ledger plan; needs --confirm PLAN_ID")
