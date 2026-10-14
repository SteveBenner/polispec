#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../smoke"

module Polispec
  module Commands
    class SmokeCommand
      USAGE = <<~TEXT.chomp.freeze
        usage: polispec smoke record --spec FILE [--at PATH] --verdict pass|fail|partial|blocked --summary TEXT [--step-file FILE] [--evidence PATH[:KIND]]... [--runner human|agent] [--harness H] [--model M] [--effort E] [--started ISO] [--finished ISO] [--json]
               polispec smoke list [--spec FILE] [--at PATH] [--verdict V] [--json]
               polispec smoke show <id> [--json]
               polispec smoke verify [--json]
               polispec smoke coverage [--spec FILE] [--at PATTERN]... [--json]
      TEXT
      VALUE_FLAGS = {
        "record" => %w[--spec --at --verdict --summary --step-file --evidence --runner --harness --model --effort --started --finished],
        "list" => %w[--spec --at --verdict],
        "show" => [],
        "verify" => [],
        "coverage" => %w[--spec --at]
      }.freeze
      MULTI = %w[--evidence --at].freeze

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
        opts = { json: false, rest: [], values: Hash.new { |hash, key| hash[key] = [] } }
        queue = args.dup
        until queue.empty?
          arg = queue.shift
          name, inline = arg.start_with?("--") ? arg.split("=", 2) : [arg, nil]
          if name == "--json"
            raise Usage unless inline.nil?

            opts[:json] = true
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
        verdict = one(opts, "--verdict")
        summary = one(opts, "--summary")
        raise Usage if spec.nil? || verdict.nil? || summary.nil?
        raise Usage unless Smoke::VERDICTS.include?(verdict)
        raise Usage if summary.strip.empty?

        runner_kind = one(opts, "--runner")
        raise Usage if runner_kind && !%w[human agent].include?(runner_kind)

        started = timestamp(one(opts, "--started"), "--started")
        finished = timestamp(one(opts, "--finished"), "--finished")
        top = Smoke.toplevel
        path = Smoke.ledger_path(top)
        at = (one(opts, "--at") || "").to_s
        clean, full = Smoke.relative_spec(spec, top)
        bytes, data = Smoke.load_spec(clean, full)
        node = Smoke.resolve_node(data, clean, at)
        raise Polispec::Error, "#{clean}##{at} resolves to an empty node" if node.nil?

        steps = load_steps(one(opts, "--step-file"), top)
        evidence = opts[:values]["--evidence"].map { |item| evidence_for(item, top) }
        runner = Smoke.runner(runner: runner_kind, harness: one(opts, "--harness"), model: one(opts, "--model"), effort: one(opts, "--effort"))
        runtime = Smoke.runtime
        target = Smoke.target(top, path)
        proves = { "spec" => clean, "at" => at, "spec_digest" => Smoke.sha256(bytes), "at_digest" => Smoke.node_digest(node) }
        recorded = Time.now.utc.iso8601

        entry = Smoke.append(path, top, lambda { |prev|
          base = { "recorded_at" => recorded }
          base["started_at"] = started if started
          base["finished_at"] = finished if finished
          base.merge(
            "proves" => proves, "verdict" => verdict, "summary" => Smoke.scrub(summary, top),
            "steps" => steps, "evidence" => evidence, "runner" => runner, "runtime" => runtime,
            "target" => target, "prev" => prev
          )
        })
        Events.emit("polispec.smoke", project: target["project"], id: entry["id"], spec: clean, at: at, verdict: verdict)
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

      def evidence_for(item, top)
        path, kind = item, "file"
        head, sep, tail = item.rpartition(":")
        if !sep.empty? && !head.empty? && tail.match?(/\A[a-z][a-z0-9_-]*\z/)
          path = head
          kind = tail
        end
        full = File.expand_path(path)
        raise Polispec::Error, "evidence #{Smoke.scrub(path, top)} is not a regular file" unless File.file?(full)

        bytes = File.binread(full)
        shown = Smoke.display_path(full, top)
        { "path" => Smoke.scrub(shown, top), "sha256" => Smoke.sha256(bytes), "bytes" => bytes.bytesize, "kind" => kind }
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
        verdict = one(opts, "--verdict")
        entries = Smoke.entries_of(Smoke.read(path)).select do |entry|
          proves = entry["proves"].is_a?(Hash) ? entry["proves"] : {}
          (spec.nil? || proves["spec"] == spec) && (at.nil? || proves["at"].to_s == at) && (verdict.nil? || entry["verdict"] == verdict)
        end
        if opts[:json]
          puts JSON.generate({ "ledger" => shown, "entries" => entries })
        else
          entries.each do |entry|
            proves = entry["proves"].is_a?(Hash) ? entry["proves"] : {}
            puts "#{entry['id']} #{entry['verdict']} #{proves['spec']}##{proves['at']} #{entry['recorded_at']} #{entry['summary']}"
          end
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

      def usage
        warn USAGE
        2
      end
    end

    CLI.register("smoke", SmokeCommand, summary: "record, verify and report smoke tests that proved a spec")
  end
end
