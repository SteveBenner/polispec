#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "scenario"
require_relative "process"
require_relative "fixture"

module Polispec
  module Smoke
    module Step
      REPORT_LIMIT = 4096
      DEFAULT_TIMEOUT = 30
      HOOK_EVENTS = { "pretool" => "PreToolUse", "session" => "SessionStart" }.freeze
      RULE = /\[POLISPEC ([^\]\s]+)\]/

      module_function

      def template(step)
        if step["hook"]
          hook = step["hook"]
          detail = hook["event"] == "pretool" ? " #{hook['tool']} #{JSON.generate(hook['input'] || {})}" : ""
          "hook #{hook['event']} --harness #{hook['harness']}#{detail}"
        else
          step["run"].map { |word| word.empty? || word.match?(/\s/) ? word.inspect : word }.join(" ")
        end
      end

      def clip(text)
        text.bytesize > REPORT_LIMIT ? "#{text.byteslice(0, REPORT_LIMIT).scrub}\n[truncated]" : text
      end

      def execute(step, layout)
        vars = layout.vars
        expanded = Scenario.expand(step.reject { |key, _| key == "name" }, vars)
        expect = expanded["expect"] || {}
        shas = git_before(expect["git"])

        argv, payload = invocation(expanded, layout)
        cwd = expanded["cwd"] || layout.scratch
        env = layout.env(expanded["env"] || {}, home: expanded["home"] == true)
        timeout = expanded["timeout"] || DEFAULT_TIMEOUT
        Polispec::Trace.step("step #{step['name']}", argv: argv.is_a?(Array) ? argv.join(" ") : argv, cwd: Polispec::Trace.on? ? Polispec::Trace.path(cwd) : nil) do
          result = if expanded["tty"]
                     Exec.run_pty(argv, env: env, chdir: cwd, lines: expanded["tty"], timeout: timeout)
                   else
                     Exec.run(argv, env: env, chdir: cwd, stdin: payload || expanded["stdin"], timeout: timeout)
                   end
          verdict = expanded["hook"] ? hook_verdict(expanded["hook"], result.stdout) : nil
          checks = check(expect, result, verdict, shas, expanded["hook"])
          trace_outcome(result, checks)
          {
            "name" => step["name"], "run" => template(step), "argv" => argv, "exit" => result.exit,
            "duration_ms" => (result.duration * 1000).round, "timed_out" => result.timed_out,
            "stdout" => clip(result.stdout), "stderr" => clip(result.stderr), "decision" => verdict && verdict["decision"],
            "rule" => verdict && verdict["rule"], "checks" => checks, "ok" => checks.all? { |item| item["ok"] },
            "parity" => step["parity"] || "compare", "stop" => step["stop"] == true, "expect" => step["expect"],
            "full_stdout" => result.stdout
          }
        end
      rescue ScenarioError => e
        failure(step, e.message)
      end

      def trace_outcome(result, checks)
        return unless Polispec::Trace.on?

        failed = checks.reject { |item| item["ok"] }
        if failed.empty?
          Polispec::Trace.info("step passed", exit: result.exit, stdout_bytes: result.stdout.bytesize, stderr_bytes: result.stderr.bytesize, ms: (result.duration * 1000).round)
          return
        end
        Polispec::Trace.info("step failed", exit: result.exit, stdout_bytes: result.stdout.bytesize, stderr_bytes: result.stderr.bytesize, ms: (result.duration * 1000).round)
        failed.each { |item| Polispec::Trace.info("check failed", check: item["check"], detail: item["detail"]) }
        [[:out, result.stdout], [:err, result.stderr]].each do |stream, text|
          lines = text.lines
          lines.first(40).each { |line| Polispec::Trace.output(line, stream: stream) }
          Polispec::Trace.info("#{stream == :out ? 'stdout' : 'stderr'} truncated", lines_total: lines.length) if lines.length > 40
        end
      end

      def failure(step, message)
        {
          "name" => step["name"], "run" => template(step), "argv" => [], "exit" => nil, "duration_ms" => 0, "timed_out" => false,
          "stdout" => "", "stderr" => "", "decision" => nil, "rule" => nil, "checks" => [{ "check" => "step", "ok" => false, "detail" => message }],
          "ok" => false, "parity" => step["parity"] || "compare", "stop" => step["stop"] == true, "expect" => step["expect"], "full_stdout" => ""
        }
      end

      def invocation(step, layout)
        return [step["run"], nil] unless step["hook"]

        hook = step["hook"]
        cwd = hook["cwd"] || layout.scratch
        body = { "hook_event_name" => HOOK_EVENTS.fetch(hook["event"]), "session_id" => "smoke", "cwd" => cwd }
        if hook["event"] == "pretool"
          body["tool_name"] = hook["tool"]
          body["tool_input"] = hook["input"] || {}
        else
          body["source"] = "startup"
        end
        [[layout.polispec, "hook", hook["event"], "--harness", hook["harness"]], JSON.generate(body)]
      end

      def hook_verdict(_hook, output)
        text = output.to_s.strip
        return { "decision" => "allow", "rule" => nil } if text.empty?

        data = JSON.parse(text)
        specific = data.is_a?(Hash) && data["hookSpecificOutput"].is_a?(Hash) ? data["hookSpecificOutput"] : {}
        reason = specific["permissionDecisionReason"] || data["reason"] || data["message"]
        decision = specific["permissionDecision"] || (specific["additionalContext"] ? "context" : nil) || data["decision"] || data["action"]
        decision = { "block" => "deny" }.fetch(decision, decision)
        rule = reason.to_s[RULE, 1]
        { "decision" => decision || "unrecognised", "rule" => rule }
      rescue JSON::ParserError
        { "decision" => "unparsed", "rule" => nil }
      end

      def git_before(spec)
        return nil unless spec

        Smoke.git(spec["repo"], "rev-parse", spec["ref"])
      end

      def subset?(expected, actual)
        case expected
        when Hash then actual.is_a?(Hash) && expected.all? { |key, value| actual.key?(key) && subset?(value, actual[key]) }
        when Array then actual.is_a?(Array) && actual.length == expected.length && expected.each_with_index.all? { |value, index| subset?(value, actual[index]) }
        else expected == actual
        end
      end

      def item(name, ok, detail)
        { "check" => name, "ok" => ok, "detail" => detail }
      end

      def check(expect, result, verdict, shas, hook)
        checks = []
        checks << item("timeout", false, "timed out") if result.timed_out
        checks << item("spawn", false, result.error) if result.error
        checks.concat(exit_check(expect, result)) if expect.key?("exit")
        checks.concat(text_checks(expect, result))
        checks.concat(json_check(expect, result)) if expect.key?("json")
        checks.concat(hook_checks(expect, verdict)) if hook
        Array(expect["files_exist"]).each { |path| checks << item("files_exist", File.exist?(path), path) }
        Array(expect["files_absent"]).each { |path| checks << item("files_absent", !File.exist?(path), path) }
        checks.concat(git_check(expect["git"], shas)) if expect["git"]
        checks
      end

      def exit_check(expect, result)
        wanted = Array(expect["exit"])
        [item("exit", wanted.include?(result.exit), "expected #{wanted.join('|')}, got #{result.exit.inspect}")]
      end

      def text_checks(expect, result)
        checks = []
        Array(expect["stdout_includes"]).each { |text| checks << item("stdout_includes", result.stdout.include?(text), text) }
        Array(expect["stdout_excludes"]).each { |text| checks << item("stdout_excludes", !result.stdout.include?(text), text) }
        Array(expect["stderr_includes"]).each { |text| checks << item("stderr_includes", result.stderr.include?(text), text) }
        checks
      end

      def json_check(expect, result)
        data = JSON.parse(result.stdout)
        [item("json", subset?(expect["json"], data), "stdout JSON contains #{JSON.generate(expect['json'])}")]
      rescue JSON::ParserError
        [item("json", false, "stdout is not JSON")]
      end

      def hook_checks(expect, verdict)
        checks = []
        checks << item("decision", verdict["decision"] == expect["decision"], "expected #{expect['decision']}, got #{verdict['decision']}")
        checks << item("rule", verdict["rule"] == expect["rule"], "expected #{expect['rule']}, got #{verdict['rule'].inspect}") if expect.key?("rule")
        checks
      end

      def git_check(spec, before)
        after = Smoke.git(spec["repo"], "rev-parse", spec["ref"])
        return [item("git", false, "#{spec['ref']} does not resolve in #{File.basename(spec['repo'])}")] if before.nil? || after.nil?

        same = before == after
        [item("git", spec["unchanged"] ? same : !same, "#{spec['ref']} #{same ? 'unchanged' : 'moved'}, expected #{spec['unchanged'] ? 'unchanged' : 'moved'}")]
      end

      def observed(result)
        failed = result["checks"].reject { |entry| entry["ok"] }
        base = result["decision"] ? "decision=#{result['decision']} rule=#{result['rule'] || '-'} exit=#{result['exit'].inspect}" : "exit=#{result['exit'].inspect}"
        failed.empty? ? "#{base} ok" : "#{base} failed: #{failed.map { |entry| "#{entry['check']} (#{entry['detail']})" }.join('; ')}"
      end
    end
  end
end
