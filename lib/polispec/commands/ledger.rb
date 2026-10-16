#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "../operator/git"

module Polispec
  class LedgerCommand
    USAGE = "usage: polispec ledger init [--dry-run] [--json]"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      queue = args.dup
      return usage unless queue.shift == "init"

      options = { dry_run: false, json: false }
      until queue.empty?
        arg = queue.shift
        case arg
        when "--dry-run" then options[:dry_run] = true
        when "--json" then options[:json] = true
        else return usage
        end
      end
      init(options)
    end

    private

    def init(options)
      result = Ledger.create_starter!(Ledger.default_path, dry: options[:dry_run])
      path = result["path"]
      if options[:json]
        puts JSON.generate("path" => path, "created" => result["created"], "dry_run" => options[:dry_run])
      elsif !result["created"]
        puts "kept #{path}: a ledger is already there"
      else
        puts "#{options[:dry_run] ? 'would create' : 'created'} #{path}: no projects yet; add one with polispec apply environment-control --repo <repo>"
      end
      0
    rescue Operator::Failure => e
      e.report(json: options[:json])
      1
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("ledger", Polispec::LedgerCommand, summary: "create a starter ledger of governed projects when the host has none")
