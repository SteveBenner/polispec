#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "../native_pin"
require_relative "../changes"

module Polispec
  class PinCommand
    USAGE = "usage: polispec pin [--ref <tag>] [--source <path-or-git-url>] [--dry-run] [--json]"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      options = parse(args)
      return usage unless options

      before = options[:dry_run] ? nil : Changes.epoch
      previous = options[:dry_run] ? nil : current_release
      result = Trace.step("pin", ref: options[:ref], dry_run: options[:dry_run] ? true : nil) { NativePin.pin!(ref: options[:ref], source: options[:source], dry_run: options[:dry_run]) }
      record_change(result, before, previous) unless options[:dry_run]
      if options[:json]
        puts JSON.generate(result.reject { |key, _| %w[steps notes].include?(key) })
      else
        report(result, options[:dry_run])
      end
      0
    end

    private

    def current_release
      File.realpath(NativePin.current_link)
    rescue SystemCallError
      nil
    end

    def record_change(result, before, previous)
      Changes.record(kind: "pin", subject: { "tag" => result["ref"], "commit" => result["commit"] }, epoch_before: before,
                     details: { "old_release" => previous, "new_release" => result["release"], "runtime_dir" => result["release"] })
    end

    def parse(args)
      options = { ref: nil, source: nil, dry_run: false, json: false }
      queue = args.dup
      until queue.empty?
        arg = queue.shift
        case arg
        when "--ref" then options[:ref] = queue.shift
        when "--source" then options[:source] = queue.shift
        when "--dry-run" then options[:dry_run] = true
        when "--json" then options[:json] = true
        else
          warn "polispec: unknown argument #{arg}"
          return nil
        end
        if %w[--ref --source].include?(arg) && options[arg.delete_prefix("--").to_sym].to_s.empty?
          warn "polispec: #{arg} needs a value"
          return nil
        end
      end
      options
    end

    def report(result, dry_run)
      puts "dry run: nothing was changed" if dry_run
      puts result["fetched"] if result["fetched"]
      result["steps"].each { |step| puts "#{dry_run ? 'would ' : ''}#{step}" }
      result["notes"].each { |note| puts note }
      return if dry_run

      puts "pinned #{result['ref']} -> #{result['commit'][0, 12]} at #{result['current']}"
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("pin", Polispec::PinCommand, summary: "pin a read-only release of polispec under the data home without rplugin")
