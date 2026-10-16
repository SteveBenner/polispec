#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "install"

module Polispec
  class UninstallCommand < InstallCommand
    USAGE = "usage: polispec uninstall --harness claude|codex|all [--scope user|project] [--project <dir>] [--dry-run] [--json]"
    VERB = "uninstall"

    private

    def perform(harness, options)
      NativeInstall.uninstall(harness, scope: options[:scope], project: options[:project], dry_run: options[:dry_run])
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("uninstall", Polispec::UninstallCommand, summary: "remove the hooks, skill and rule links that polispec install added")
