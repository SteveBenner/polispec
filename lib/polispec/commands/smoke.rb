#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../smoke"

module Polispec
  module Commands
    class SmokeCommand
      USAGE = <<~TEXT.chomp.freeze
        usage: polispec smoke record (--spec FILE [--at PATH] | --feature SLUG) --verdict pass|fail|partial|blocked|inconclusive|unsmokable [--reason TEXT] --summary TEXT [--step-file FILE] [--evidence PATH[:KIND]]... [--runner human|agent|suite] [--harness H] [--model M] [--effort E] [--started ISO] [--finished ISO] [--json]
               polispec smoke list [--spec FILE] [--at PATH] [--feature SLUG] [--verdict V] [--json]
               polispec smoke show <id> [--json]
               polispec smoke verify [--json]
               polispec smoke coverage [--spec FILE] [--at PATTERN]... [--feature] [--json]
               polispec smoke migrate [--from PATH] [--to PATH] [--keep] [--dry-run] [--json]
               polispec smoke run [--unit PATTERN]... [--scenarios DIR] [--against TREE] [--host-copy] [--live claude-code|codex]... [--out DIR] [--no-record] [--accept-changes] [--strict] [--json]
      TEXT
      VALUE_FLAGS = {
        "record" => %w[--spec --at --feature --reason --verdict --summary --step-file --evidence --runner --harness --model --effort --started --finished],
        "list" => %w[--spec --at --feature --verdict],
        "show" => [],
        "verify" => [],
        "coverage" => %w[--spec --at],
        "migrate" => %w[--from --to],
        "run" => %w[--unit --scenarios --against --live --out]
      }.freeze
      BOOLEAN_FLAGS = { "run" => %w[--host-copy --no-record --accept-changes --strict], "coverage" => %w[--feature], "migrate" => %w[--keep --dry-run] }.freeze
      MULTI = %w[--evidence --at --unit --live].freeze
      LIVE_HARNESSES = %w[claude-code codex].freeze

      class Usage < StandardError; end

      def self.run(args)
        new.run(args)
      end

      def run(args)
        verb, *rest = args
        return usage unless VALUE_FLAGS.key?(verb)

        opts = parse(verb, rest)
        send("run_#{verb}", opts)
      rescue Usage
        usage
      end

      private

      def parse(verb, args)
        allowed = VALUE_FLAGS.fetch(verb)
        opts = { json: false, rest: [], flags: [], values: Hash.new { |hash, key| hash[key] = [] } }
        booleans = BOOLEAN_FLAGS.fetch(verb, [])
        queue = args.dup
        until queue.empty?
          arg = queue.shift
          name, inline = arg.start_with?("--") ? arg.split("=", 2) : [arg, nil]
          if name == "--json"
            raise Usage unless inline.nil?

            opts[:json] = true
          elsif booleans.include?(name)
            raise Usage unless inline.nil?

            opts[:flags] << name
          elsif allowed.include?(name)
            value = inline || queue.shift
            raise Usage if value.nil?
            raise Usage if !MULTI.include?(name) && !opts[:values][name].empty?

            opts[:values][name] << value
          elsif arg.start_with?("--")
            raise Usage
          else
            opts[:rest] << arg
          end
        end
        opts
      end

      def one(opts, flag)
        opts[:values][flag].first
      end

      def run_record(opts)
        raise Usage unless opts[:rest].empty?

        spec = one(opts, "--spec")
        feature = one(opts, "--feature")
        verdict = one(opts, "--verdict")
        summary = one(opts, "--summary")
        raise Usage if verdict.nil? || summary.nil?
        raise Usage if spec.nil? == feature.nil?
        raise Usage if feature && !one(opts, "--at").nil?
        raise Usage unless Smoke::VERDICTS.include?(verdict)
        raise Usage if summary.strip.empty?

        runner_kind = one(opts, "--runner")
        raise Usage if runner_kind && !%w[human agent suite].include?(runner_kind)

        started = timestamp(one(opts, "--started"), "--started")
        finished = timestamp(one(opts, "--finished"), "--finished")
        top = Smoke.toplevel
        path = Smoke.ledger_path(top)
        at = (one(opts, "--at") || "").to_s
        steps = load_steps(one(opts, "--step-file"), top)
        evidence = opts[:values]["--evidence"].map { |item| Smoke.evidence(item, top) }
        runner = Smoke.runner(runner: runner_kind, harness: one(opts, "--harness"), model: one(opts, "--model"), effort: one(opts, "--effort"))
        entry = Smoke.record(top: top, path: path, spec: spec, at: at, feature: feature, reason: one(opts, "--reason"), verdict: verdict, summary: summary,
                             steps: steps, evidence: evidence, runner: runner, started: started, finished: finished)
        opts[:json] ? puts(JSON.generate(entry)) : puts(entry["id"])
        0
      end

      def timestamp(value, flag)
        return nil if value.nil?

        Time.iso8601(value)
        value
      rescue ArgumentError
        raise Polispec::Error, "#{flag} must be an ISO 8601 timestamp"
      end

      def load_steps(file, top)
        return [] if file.nil?

        raise Polispec::Error, "#{file} is not a regular file" unless File.file?(file)

        data = Schema::Document.parse(File.read(file), file)
        raise Polispec::Error, "#{file}: steps must be a list" unless data.is_a?(Array)

        data.each_with_index.map do |item, index|
          raise Polispec::Error, "#{file}: step #{index} must be a mapping" unless item.is_a?(Hash)
          raise Polispec::Error, "#{file}: step #{index} needs a run string" unless item["run"].is_a?(String)
          raise Polispec::Error, "#{file}: step #{index} exit must be an integer or null" unless item["exit"].nil? || item["exit"].is_a?(Integer)

          %w[expect observed].each do |key|
            raise Polispec::Error, "#{file}: step #{index} #{key} must be a string or null" unless item[key].nil? || item[key].is_a?(String)
          end
          { "run" => Smoke.scrub(item["run"], top), "exit" => item["exit"], "expect" => Smoke.scrub(item["expect"], top), "observed" => Smoke.scrub(item["observed"], top) }
        end
      rescue Schema::Document::ParseError => e
        raise Polispec::Error, e.message
      end

      def ledger_context
        top = Smoke.toplevel
        path = Smoke.ledger_path(top)
        [top, path, Smoke.display_path(path, top)]
      end

      def run_list(opts)
        raise Usage unless opts[:rest].empty?

        top, path, shown = ledger_context
        spec = one(opts, "--spec")
        spec = Smoke.relative_spec(spec, top).first if spec
        at = one(opts, "--at")
        feature = one(opts, "--feature")
        verdict = one(opts, "--verdict")
        entries = Smoke.entries_of(Smoke.read(path)).select do |entry|
          proves = entry["proves"].is_a?(Hash) ? entry["proves"] : {}
          (spec.nil? || proves["spec"] == spec) && (at.nil? || proves["at"].to_s == at) && (feature.nil? || proves["feature"] == feature) && (verdict.nil? || entry["verdict"] == verdict)
        end
        if opts[:json]
          puts JSON.generate({ "ledger" => shown, "entries" => entries })
        else
          entries.each { |entry| puts "#{entry['id']} #{entry['verdict']} #{Smoke.subject_of(entry)} #{entry['recorded_at']} #{entry['summary']}" }
        end
        0
      end

      def run_show(opts)
        raise Usage unless opts[:rest].length == 1

        _, path, = ledger_context
        entry = Smoke.entries_of(Smoke.read(path)).find { |item| item["id"] == opts[:rest].first }
        raise Polispec::Error, "#{opts[:rest].first} is not in the smoke ledger" unless entry

        opts[:json] ? puts(JSON.generate(entry)) : puts(YAML.dump(entry))
        0
      end

      def run_verify(opts)
        raise Usage unless opts[:rest].empty?

        top, path, shown = ledger_context
        data = Smoke.read(path)
        findings = Smoke.verify(path, top)
        count = Smoke.entries_of(data).length
        if opts[:json]
          puts JSON.generate({ "ledger" => shown, "entries" => count, "findings" => findings })
        else
          puts "smoke: #{count} entries, #{findings.length} finding(s)"
          findings.each { |finding| puts "  #{finding['kind']} #{finding['id'] || '-'} #{finding['detail']}" }
        end
        findings.any? { |finding| Smoke::BLOCKING.include?(finding["kind"]) } ? 1 : 0
      end

      def run_coverage(opts)
        raise Usage unless opts[:rest].empty?

        return run_proof_cells(opts) if Smoke.ledger_frozen?
        return run_feature_coverage(opts) if opts[:flags].include?("--feature")

        top, path, = ledger_context
        clean, full = Smoke.relative_spec(one(opts, "--spec") || Smoke::DEFAULT_SPEC, top)
        _, data = Smoke.load_spec(clean, full)
        patterns = opts[:values]["--at"]
        if patterns.empty?
          declared = data.is_a?(Hash) && data["smoke"].is_a?(Hash) ? data["smoke"]["coverage_units"] : nil
          patterns = declared.is_a?(Array) && declared.all?(String) ? declared : Smoke::DEFAULT_UNITS
        end
        report = Smoke.coverage(data, clean, Smoke.entries_of(Smoke.read(path)), patterns)
        if opts[:json]
          puts JSON.generate(report)
        else
          report["units"].each { |row| puts "#{row['status']} #{row['unit']} #{row['latest'] || '-'}" }
          puts "coverage: #{report['proven']}/#{report['total']} proven"
        end
        0
      end

      def run_feature_coverage(opts)
        raise Usage unless opts[:values].values.all?(&:empty?)

        _, path, = ledger_context
        report = Smoke.feature_coverage(Smoke.entries_of(Smoke.read(path)))
        if opts[:json]
          puts JSON.generate(report)
        else
          report["features"].each { |row| puts "#{row['status']} #{row['unit']} #{row['latest'] || '-'}" }
          puts "coverage: #{report['proven']}/#{report['total']} features proven"
        end
        0
      end

      def run_migrate(opts)
        raise Usage unless opts[:rest].empty?

        top = Smoke.toplevel
        raise Polispec::Error, "not in a git repository; pass --from and --to" if top.nil? && (one(opts, "--from").nil? || one(opts, "--to").nil?)

        from = File.expand_path(one(opts, "--from") || File.join(top, Smoke::LEGACY_NAME))
        to = File.expand_path(one(opts, "--to") || File.join(top, Smoke::MARKDOWN_NAME))
        result = Smoke.migrate(from: from, to: to, top: top, keep: opts[:flags].include?("--keep"), dry_run: opts[:flags].include?("--dry-run"))
        if opts[:json]
          puts JSON.generate(result)
        else
          verb = result["dry_run"] ? "would move" : "moved"
          puts "smoke: #{verb} #{result['entries']} entries from #{result['from']} to #{result['to']}, #{result['findings'].length} finding(s)"
          result["findings"].each { |finding| puts "  #{finding['kind']} #{finding['id'] || '-'} #{finding['detail']}" }
          puts "smoke: removed #{result['from']}" if result["removed"]
        end
        0
      end

      def run_proof_cells(opts)
        require_relative "proof"
        ProofCommand.run(opts[:json] ? ["status", "--json"] : ["status"])
      end

      def run_run(opts)
        raise Usage unless opts[:rest].empty?

        live = opts[:values]["--live"]
        raise Usage unless live.all? { |name| LIVE_HARNESSES.include?(name) }

        require_relative "../smoke/run"
        record = !opts[:flags].include?("--no-record")
        if record && Smoke.ledger_frozen?
          record = false
          notice = Smoke.frozen_notice(Smoke.ledger_path)
          opts[:json] ? warn(notice) : puts(notice)
        end
        options = Smoke::Run::Options.new(
          units: opts[:values]["--unit"], scenarios: one(opts, "--scenarios"), against: one(opts, "--against"), host_copy: opts[:flags].include?("--host-copy"),
          live: live.uniq, out: one(opts, "--out"), record: record, accept: opts[:flags].include?("--accept-changes"), json: opts[:json],
          strict: opts[:flags].include?("--strict")
        )
        require_relative "../smoke/sandbox"
        if Smoke::Sandbox.needed?(live: options.live, host_copy: options.host_copy)
          reason = Smoke::Sandbox.unavailable
          return Smoke::Sandbox.run(options) if reason.nil?

          warn "smoke: a sealed plane is active and the sandbox cannot start (#{reason}); fixtures that need a scratch ledger will be blocked"
        end
        Smoke::Run.new(options).call
      end

      def usage
        warn USAGE
        2
      end
    end

    CLI.register("smoke", SmokeCommand, summary: "record, verify and report smoke tests that proved a spec or a feature")
  end
end
