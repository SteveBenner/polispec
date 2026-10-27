#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "tmpdir"
require "open3"
require "fileutils"
require_relative "../native_pin"
require_relative "../changes"
require_relative "../replay"

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
      result = Trace.step("pin", ref: options[:ref], dry_run: options[:dry_run] ? true : nil) { NativePin.pin!(ref: options[:ref], source: options[:source], dry_run: options[:dry_run], gate: gate(options)) }
      record_change(result, before, previous) unless options[:dry_run]
      preview = options[:dry_run] ? dry_replay(result, options) : nil
      if options[:json]
        puts JSON.generate(result.reject { |key, _| %w[steps notes].include?(key) }.merge(preview ? { "replay" => preview[:report] } : {}))
      else
        report(result, options[:dry_run])
        render_preview(preview) if preview
      end
      preview && preview[:unexplained] ? 1 : 0
    rescue Operator::Failure => e
      e.report(json: options ? options[:json] : false)
      1
    end

    private

    def gate(options)
      lambda do |result|
        failure = nil
        shown = nil
        begin
          outcome = Replay.run(runtime: result["release"])
          next if outcome.unexplained.empty?

          failure = Replay.failure(outcome)
          shown = outcome
        rescue Replay::Unavailable => e
          failure = Operator::Failure.new("pin_replay_failed", "the candidate could not be replayed against the judgment corpus: #{e.message}")
        end
        override!(failure, shown, options)
      end
    end

    def override!(failure, outcome, options)
      raise failure unless Operator::Tty.terminal? && !options[:json]

      Replay.render(outcome, out: $stderr) if outcome
      warn failure.message
      begin
        Operator::Tty.confirm!(Replay::OVERRIDE_PHRASE)
      rescue Operator::Tty::NotTty, Operator::Tty::PhraseMismatch
        raise failure
      end
    end

    def dry_replay(result, options)
      tree = candidate_tree(result, options[:source])
      return { report: { "skipped" => "no candidate tree to replay yet; run the pin to fetch it" }, text: "replay: skipped, no candidate tree to replay before the fetch", unexplained: false } unless tree

      outcome = Replay.run(runtime: tree[:path])
      { report: outcome.to_h, outcome: outcome, unexplained: !outcome.unexplained.empty? }
    rescue Replay::Unavailable => e
      { report: { "error" => e.message }, text: "replay: #{e.message}", unexplained: true }
    ensure
      FileUtils.remove_entry(tree[:temp]) if tree && tree[:temp] && File.directory?(tree[:temp])
    end

    def candidate_tree(result, given)
      release = result["release"]
      return { path: release } if release && File.directory?(release) && NativePin.release_valid?(release)

      commit = result["commit"]
      return nil unless commit

      source = (given || NativePin.default_source).to_s
      path = NativePin.url?(source) ? NativePin.source_cache : File.expand_path(source)
      return nil unless File.directory?(path)

      temp = Dir.mktmpdir("polispec-pin-replay-")
      statuses = Open3.pipeline(["git", "-C", path, "archive", "--format=tar", commit], ["tar", "-x", "-C", temp])
      return { path: temp, temp: temp } if statuses.all?(&:success?)

      FileUtils.remove_entry(temp)
      nil
    end

    def render_preview(preview)
      if preview[:outcome]
        Replay.render(preview[:outcome])
        puts "the pin would be refused: pin_unexplained_verdicts" if preview[:unexplained]
      else
        puts preview[:text]
      end
    end

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
