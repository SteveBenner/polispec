#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "install"

module Polispec
  class UninstallCommand < InstallCommand
    USAGE = "usage: polispec uninstall --harness claude|codex|all [--scope user|project] [--project <dir>] [--dry-run] [--json]\n       polispec uninstall --all [--keep wiring,pins,rplugin,data] [--dry-run] [--json]"
    VERB = "uninstall"

    def run(args)
      return run_all(args) if args.include?("--all")

      super
    end

    private

    def run_all(args)
      options = parse_all(args)
      return usage unless options

      require_relative "../uninstall_all"
      UninstallAll.run(keep: options[:keep], dry_run: options[:dry_run], json: options[:json])
    end

    def parse_all(args)
      options = { keep: "", dry_run: false, json: false }
      queue = args.reject { |arg| arg == "--all" }
      until queue.empty?
        arg = queue.shift
        case arg
        when "--keep"
          value = queue.shift
          return nil if value.nil? || value.start_with?("--")

          options[:keep] = value
        when "--dry-run" then options[:dry_run] = true
        when "--json" then options[:json] = true
        else
          warn "polispec: unknown argument #{arg}"
          return nil
        end
      end
      require_relative "../uninstall_all"
      UninstallAll.parse_keep(options[:keep])
      options
    rescue Polispec::Error => e
      warn "polispec: #{e.message}"
      nil
    end

    def perform(harness, options)
      NativeInstall.uninstall(harness, scope: options[:scope], project: options[:project], dry_run: options[:dry_run])
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("uninstall", Polispec::UninstallCommand, summary: "remove the hooks, skill and rule links that polispec install added; --all removes every deployment after a backup")
