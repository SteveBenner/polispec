#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "../uninstall_all"

module Polispec
  class RestoreCommand
    USAGE = "usage: polispec restore <bkp_id> [--mode rewire|bytes] [--dry-run] [--json]\n       polispec restore --list [--json]"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      options = parse(args)
      return usage unless options
      return UninstallAll::Restore.list(json: options[:json]) if options[:list]

      UninstallAll::Restore.run(id: options[:id], mode: options[:mode], dry_run: options[:dry_run], json: options[:json])
    end

    private

    def parse(args)
      options = { id: nil, mode: "rewire", dry_run: false, json: false, list: false }
      queue = args.dup
      until queue.empty?
        arg = queue.shift
        case arg
        when "--mode"
          value = queue.shift
          return nil unless %w[rewire bytes].include?(value)

          options[:mode] = value
        when "--dry-run" then options[:dry_run] = true
        when "--json" then options[:json] = true
        when "--list" then options[:list] = true
        when /\A--/
          warn "polispec: unknown argument #{arg}"
          return nil
        else
          return nil if options[:id]

          options[:id] = arg
        end
      end
      return nil unless options[:list] ? options[:id].nil? : !options[:id].nil?

      options
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("restore", Polispec::RestoreCommand, summary: "put back what uninstall --all removed, from its backup")
