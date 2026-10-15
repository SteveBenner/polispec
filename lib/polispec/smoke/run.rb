#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "securerandom"
require_relative "scenario"
require_relative "process"
require_relative "fixture"
require_relative "step"
require_relative "parity"
require_relative "host_copy"

module Polispec
  module Smoke
    class Run
      SCHEMA = "polispec.smoke.run/v1"
      REPORT_SCHEMA = "polispec.smoke.report/v1"
      SEVERITY = %w[pass partial blocked fail].freeze
      SUITE_RUNNER = { "kind" => "suite", "harness" => nil, "harness_version" => nil, "model" => nil, "effort" => nil }.freeze

      Options = Struct.new(:units, :scenarios, :against, :host_copy, :live, :out, :record, :accept, :json, keyword_init: true)

      attr_reader :options, :tree

      def initialize(options, tree: ROOT)
        @options = options
        @tree = tree
      end

      def call
        against = options.against ? validated_against(options.against) : nil
        out = prepare_out
        results = []
        host = nil
        if select_scenarios?
          results = scenarios.map { |entry| run_entry(entry, out, against) }
          recorded = options.record ? record_all(results) : []
        end
        host = HostCopy.run(tree: tree, out: out, polispec: polispec_for(tree), against: against) if options.host_copy
        diffs = results.flat_map { |item| item["diffs"] || [] } + (host ? host["diffs"] : [])
        ok = finish_ok?(results, diffs)
        payload = { "schema" => SCHEMA, "tree" => tree, "against" => against, "out" => out, "scenarios" => results.map { |item| public_result(item) },
                    "recorded" => recorded || [], "diffs" => diffs, "ok" => ok }
        payload["host_copy"] = host if host
        options.json ? puts(JSON.generate(payload)) : render(payload, results, host)
        ok ? 0 : 1
      end

      private

      def select_scenarios?
        !options.host_copy || !options.units.empty? || options.scenarios || !options.live.empty?
      end

      def polispec_for(root)
        File.join(root, "bin", "polispec")
      end

      def validated_against(path)
        root = File.expand_path(path)
        raise Polispec::Error, "--against #{path} has no bin/polispec" unless File.executable?(polispec_for(root))

        root
      end

      def prepare_out
        out = File.expand_path(options.out || File.join(tree, ".polispec-smoke", "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(3)}"))
        FileUtils.mkdir_p(out)
        out
      end

      def scenario_dir
        File.expand_path(options.scenarios || File.join(tree, "smoke", "scenarios"))
      end

      def unit_match?(unit)
        return true if options.units.empty?

        options.units.any? { |pattern| pattern.end_with?("*") ? unit.start_with?(pattern.delete_suffix("*")) : unit == pattern }
      end

      def scenarios
        files = Dir.glob(File.join(scenario_dir, "*.yml")).sort
        files.concat(Dir.glob(File.join(tree, "smoke", "live", "*.yml")).sort) unless options.live.empty?
        files.map do |path|
          begin
            scenario = Scenario.load(path)
            { path: path, scenario: scenario, error: nil }
          rescue ScenarioError => e
            { path: path, scenario: nil, error: e.message }
          end
        end.select { |entry| entry[:scenario].nil? || unit_match?(entry[:scenario].unit) }
      end

      def run_entry(entry, out, against)
        if entry[:error]
          return { "file" => File.basename(entry[:path]), "path" => entry[:path], "unit" => nil, "verdict" => "error", "reason" => entry[:error], "steps" => [], "diffs" => [] }
        end

        scenario = entry[:scenario]
        scratch = File.join(out, scenario.stem)
        result = execute(scenario, scratch, tree, polispec_for(tree), out)
        result["diffs"] = []
        if against && result["layout"]
          other_scratch = File.join(out, "against", scenario.stem)
          other = execute(scenario, other_scratch, against, polispec_for(against), out)
          roots = [[scratch, "<SCRATCH>"], [tree, "<TREE>"]]
          other_roots = [[other_scratch, "<SCRATCH>"], [against, "<TREE>"]]
          result["diffs"] = Parity.compare(scenario.stem, result, other, roots, other_roots) if other["layout"]
          result["diffs"] << { "scenario" => scenario.stem, "step" => "-", "candidate" => "ran", "against" => "blocked: #{other['reason']}" } unless other["layout"]
        end
        result
      end

      def execute(scenario, scratch, root, binary, out)
        started = Time.now.utc.iso8601
        result = { "file" => File.basename(scenario.path), "path" => scenario.path, "stem" => scenario.stem, "unit" => scenario.unit, "spec" => scenario.spec,
                   "summary" => scenario.summary, "steps" => [], "reason" => nil, "started" => started, "scratch" => scratch }
        problem = precheck(scenario)
        return finish(result, scratch, "error", problem) if problem

        missing = scenario.requires.reject { |flag| flag_enabled?(flag) }
        return finish(result, scratch, "blocked", "requires #{missing.join(', ')}: feature flag off") unless missing.empty?

        begin
          layout = Fixture.build(scenario, scratch: scratch, tree: root, polispec: binary, builder: polispec_for(tree), out: out)
        rescue FixtureError, Polispec::Error, SystemCallError => e
          return finish(result, scratch, "blocked", "fixture: #{e.message}")
        end
        result["layout"] = layout
        run_steps(scenario, layout, result)
        verdict = if result["steps"].any? { |item| !item["ok"] && !item["blocked"] } then "fail"
                  elsif result["steps"].any? { |item| item["blocked"] } then "blocked"
                  else "pass"
                  end
        finish(result, scratch, verdict, result["steps"].find { |item| item["blocked"] }&.fetch("blocked", nil))
      end

      def precheck(scenario)
        top = toplevel
        clean, full = Smoke.relative_spec(scenario.spec, top)
        _, data = Smoke.load_spec(clean, full)
        node = Smoke.resolve_node(data, clean, scenario.unit)
        node.nil? ? "#{clean}##{scenario.unit} resolves to an empty node" : nil
      rescue Polispec::Error => e
        e.message
      end

      def flag_enabled?(flag)
        values = YAML.safe_load(File.read(File.join(tree, "config", "harness-features.yml")), aliases: false) || {}
        values[flag] == true
      rescue SystemCallError, Psych::Exception
        false
      end

      def run_steps(scenario, layout, result)
        scenario.steps.each do |step|
          outcome = if step.key?("live")
                      live_step(step, scenario, layout)
                    else
                      Step.execute(step, layout)
                    end
          result["steps"] << outcome
          break if !outcome["ok"] && !outcome["blocked"] && outcome["stop"]
        end
      end

      def live_step(step, scenario, layout)
        require_relative "live" if File.file?(File.join(__dir__, "live.rb"))
        if defined?(Smoke::Live) && Smoke::Live.respond_to?(:run_step)
          Smoke::Live.run_step(step, { "scenario" => scenario, "layout" => layout, "harnesses" => options.live, "tree" => tree })
        else
          Step.failure(step, "live_unavailable").merge("blocked" => "live_unavailable", "ok" => false)
        end
      end

      def finish(result, scratch, verdict, reason)
        result["verdict"] = verdict
        result["reason"] = reason
        result["finished"] = Time.now.utc.iso8601
        if File.directory?(scratch)
          report = File.join(scratch, "report.json")
          File.write(report, JSON.pretty_generate(report_body(result)))
          result["report"] = report
        end
        result
      end

      def report_body(result)
        {
          "schema" => REPORT_SCHEMA, "scenario" => result["file"], "unit" => result["unit"], "verdict" => result["verdict"], "reason" => result["reason"],
          "started" => result["started"], "finished" => result["finished"],
          "steps" => result["steps"].map { |item| item.reject { |key, _| %w[full_stdout parity stop expect].include?(key) } }
        }
      end

      def toplevel
        @toplevel ||= Smoke.git(tree, "rev-parse", "--show-toplevel") || tree
      end

      def record_all(results)
        ids = []
        path = Smoke.ledger_path(toplevel)
        results.reject { |item| item["verdict"] == "error" }.group_by { |item| [item["spec"], item["unit"]] }.each do |(spec, unit), group|
          verdict = group.map { |item| item["verdict"] }.max_by { |name| SEVERITY.index(name) }
          steps = group.flat_map { |item| item["steps"].map { |step| recorded_step(step) } }
          evidence = group.flat_map { |item| evidence_for(item) }
          entry = Smoke.record(top: toplevel, path: path, spec: spec, at: unit, verdict: verdict, summary: summary_for(group, verdict),
                               steps: steps, evidence: evidence, runner: SUITE_RUNNER, started: group.map { |item| item["started"] }.min, finished: group.map { |item| item["finished"] }.max)
          ids << entry["id"]
          group.each { |item| item["recorded"] = entry["id"] }
        rescue Polispec::Error => e
          group.each { |item| item["record_error"] = e.message }
        end
        ids
      end

      def recorded_step(step)
        expect = step["expect"]
        observed = step["blocked"] ? "blocked: #{step['blocked']}" : Step.observed(step)
        { "run" => Smoke.scrub(step["run"], toplevel), "exit" => step["exit"], "expect" => expect ? Smoke.scrub(JSON.generate(expect), toplevel) : nil,
          "observed" => Smoke.scrub(observed, toplevel) }
      end

      def evidence_for(item)
        list = []
        list << Smoke.evidence("#{item['report']}:report", toplevel) if item["report"]
        list << Smoke.evidence("#{item['path']}:scenario", toplevel)
        list
      end

      def summary_for(group, verdict)
        text = group.map { |item| item["summary"] }.join("; ")
        steps = group.flat_map { |item| item["steps"] }
        suffix = "suite: #{steps.count { |step| step['ok'] }}/#{steps.length} steps passed"
        blocked = group.map { |item| item["reason"] }.compact.first
        verdict == "blocked" && blocked ? "#{text} (#{suffix}; blocked: #{blocked})" : "#{text} (#{suffix})"
      end

      def finish_ok?(results, diffs)
        scenarios_ok = results.all? { |item| %w[pass blocked].include?(item["verdict"]) && !item["record_error"] }
        scenarios_ok && (diffs.empty? || options.accept)
      end

      def public_result(item)
        failing = item["steps"].reject { |step| step["ok"] }.map { |step| step["name"] }
        {
          "file" => item["file"], "unit" => item["unit"], "verdict" => item["verdict"], "reason" => item["reason"], "failing" => failing,
          "recorded" => item["recorded"], "record_error" => item["record_error"], "report" => item["report"],
          "steps" => item["steps"].map { |step| step.reject { |key, _| %w[full_stdout parity stop expect argv].include?(key) } }
        }.compact
      end

      def render(payload, results, host)
        results.each do |item|
          failing = item["steps"].reject { |step| step["ok"] }.map { |step| step["name"] }
          line = "#{item['verdict']} #{item['unit'] || '-'} #{item['file']}"
          line += " failing: #{failing.join(', ')}" if item["verdict"] == "fail"
          line += " (#{item['reason']})" if item["reason"] && item["verdict"] != "pass"
          line += " record error: #{item['record_error']}" if item["record_error"]
          puts line
          item["steps"].reject { |step| step["ok"] }.each do |step|
            step["checks"].reject { |entry| entry["ok"] }.each { |entry| puts "  #{step['name']}: #{entry['check']} #{entry['detail']}" }
          end
        end
        render_host(host) if host
        payload["diffs"].each { |diff| puts "diff #{diff['scenario']} #{diff['step']}: #{diff['candidate']} | #{diff['against']}" }
        return if results.empty? && host

        counts = results.group_by { |item| item["verdict"] }.transform_values(&:length)
        puts "suite: #{counts.fetch('pass', 0)}/#{results.length} scenarios passed, #{counts.fetch('fail', 0) + counts.fetch('error', 0)} failed, #{counts.fetch('blocked', 0)} blocked" \
             "#{payload['against'] ? ", #{payload['diffs'].length} diff(s)" : ''}#{payload['recorded'].empty? ? '' : ", #{payload['recorded'].length} recorded"}"
      end

      def render_host(host)
        width = host["rows"].map { |row| row["probe"].length }.max.to_i
        pwidth = host["rows"].map { |row| row["project"].length }.max.to_i
        host["rows"].each { |row| puts "#{row['probe'].ljust(width)}  #{row['project'].ljust(pwidth)}  #{row['decision']}#{row['rule'] ? " #{row['rule']}" : ''}" }
        puts "host-copy: #{host['rows'].length} verdicts across #{host['projects'].length} project(s), enforce #{host['mode']}"
      end
    end
  end
end
