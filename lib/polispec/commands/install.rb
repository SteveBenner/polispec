#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "../native_install"
require_relative "../changes"

module Polispec
  class InstallCommand
    USAGE = "usage: polispec install --harness claude|codex|all [--scope user|project] [--project <dir>] [--force] [--dry-run] [--json]"
    VERB = "install"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      options = parse(args)
      return usage unless options

      plans = []
      status = 0
      before = options[:dry_run] ? nil : Changes.epoch
      options[:harnesses].each do |harness|
        begin
          plans << perform(harness, options)
          record_change(plans.last, before) unless options[:dry_run] || plans.last.changes.empty?
        rescue Polispec::Error => e
          warn "polispec: #{e.message}"
          status = 1
        end
      end
      options[:json] ? puts(JSON.generate(plans.map(&:to_h))) : plans.each { |plan| report(plan, options[:dry_run]) }
      status
    end

    private

    def record_change(plan, before)
      Changes.record(kind: "install", subject: { "harness" => plan.harness, "scope" => plan.scope }, epoch_before: before)
    end

    def perform(harness, options)
      Trace.step("#{self.class::VERB} #{harness}", scope: options[:scope], project: Trace.on? ? Trace.path(options[:project]) : nil, force: options[:force], dry_run: options[:dry_run]) do
        NativeInstall.install(harness, scope: options[:scope], project: options[:project], force: options[:force], dry_run: options[:dry_run])
      end
    end

    def parse(args)
      options = { harness: nil, scope: "user", project: Dir.pwd, force: false, dry_run: false, json: false }
      queue = args.dup
      until queue.empty?
        arg = queue.shift
        case arg
        when "--harness" then options[:harness] = queue.shift
        when "--scope" then options[:scope] = queue.shift
        when "--project" then options[:project] = queue.shift
        when "--force" then options[:force] = true
        when "--dry-run" then options[:dry_run] = true
        when "--json" then options[:json] = true
        else
          warn "polispec: unknown argument #{arg}"
          return nil
        end
      end
      return nil unless valid?(options)

      options[:harnesses] = options[:harness] == "all" ? NativeInstall::HARNESSES : [options[:harness]]
      options
    end

    def valid?(options)
      unless (NativeInstall::HARNESSES + ["all"]).include?(options[:harness])
        warn "polispec: --harness claude|codex|all is required"
        return false
      end
      unless NativeInstall::SCOPES.include?(options[:scope])
        warn "polispec: --scope must be user or project"
        return false
      end
      return true unless options[:project].to_s.empty?

      warn "polispec: --project needs a directory"
      false
    end

    def report(plan, dry_run)
      puts "#{dry_run ? 'dry run: ' : ''}#{self.class::VERB} #{plan.harness} (#{plan.scope}) -> #{plan.target}"
      plan.changes.each { |change| puts "  #{change['action']}  #{change['file']}" }
      puts "  no changes" if plan.changes.empty?
      if dry_run && plan.preview
        puts "--- before"
        plan.preview["before"].each_line { |line| puts "- #{line.chomp}" }
        puts "+++ after"
        plan.preview["after"].each_line { |line| puts "+ #{line.chomp}" }
      end
      plan.messages.each { |message| puts message }
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("install", Polispec::InstallCommand, summary: "wire the guard hooks, skill and rules into Claude Code or Codex without rplugin")
