#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "rbconfig"
require "shellwords"
require "fileutils"
require_relative "scenario"
require_relative "process"
require_relative "step"

module Polispec
  module Smoke
    module Live
      KILL_ENV = "POLISPEC_SMOKE_LIVE"
      KILL_KEY = "polispec.smoke.live"
      CAP_ENV = "POLISPEC_SMOKE_LIVE_MAX"
      DEFAULT_CAP = 6
      DEFAULT_TIMEOUT = 300
      MAX_TIMEOUT = 600
      RETRY_WAIT = (5..15)
      CLAUDE_MODEL = "claude-haiku-5-5"
      CODEX_MODEL = "gpt-6-luna"
      CLAUDE_BUDGET = "0.50"
      BINARIES = { "claude-code" => "claude", "codex" => "codex" }.freeze
      MODELS = { "claude-code" => CLAUDE_MODEL, "codex" => CODEX_MODEL }.freeze
      DECLINE_CHECKS = %w[hook_fired hook_log files_exist].freeze
      FIRST_ATTEMPT_FILES = { "hook-log.jsonl" => "hook-log.first.jsonl", "harness.stdout.jsonl" => "harness.first.stdout.jsonl", "harness.stderr.txt" => "harness.first.stderr.txt" }.freeze
      NESTED_ENV = /\A(CLAUDECODE|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_CODE_[A-Z_]+|CLAUDE_AGENT_SDK_[A-Z_]+)\z/
      AUTH_FAILURE = /not logged in|please run .*login|invalid api key|authentication|unauthorized|401|no auth|sign in/i
      WRAPPER = <<~'RUBY'
        require "json"
        require "open3"
        require "time"

        log, source, *argv = ARGV
        raw = $stdin.read.to_s
        payload = begin
          JSON.parse(raw)
        rescue JSON::ParserError
          {}
        end
        out, err, status = Open3.capture3(*argv, stdin_data: raw)
        input = payload["tool_input"]
        entry = {
          "ts" => Time.now.utc.iso8601(3), "source" => source, "argv" => argv.drop(1), "event" => payload["hook_event_name"],
          "tool" => payload["tool_name"], "input" => input.is_a?(Hash) ? input.transform_values { |value| value.is_a?(String) ? value[0, 300] : value } : input,
          "exit" => status.exitstatus, "stdout" => out, "stderr" => err[0, 600]
        }
        File.open(log, "a") do |file|
          file.flock(File::LOCK_EX)
          file.puts(JSON.generate(entry))
        end
        $stdout.write(out)
        $stderr.write(err)
        exit(status.exitstatus || 1)
      RUBY

      @launched = 0

      class << self
        attr_accessor :launched
      end

      module_function

      def run_step(step, context)
        layout = context["layout"]
        live = step["live"]
        return skipped(step) unless Array(context["harnesses"]).include?(live["harness"])

        reason = blocked_reason(live["harness"])
        return blocked(step, live, reason) if reason

        launch_step(step, live, layout)
      rescue ScenarioError => e
        failed(step, live, e.message)
      end

      def blocked_reason(harness)
        return "live_disabled" if switched_off?
        return "live_cap_reached" if Live.launched >= cap
        return "harness_missing: #{BINARIES.fetch(harness)} is not on PATH" unless which(BINARIES.fetch(harness))

        nil
      end

      def switched_off?
        return true if ENV[KILL_ENV].to_s.strip.downcase == "off"

        Engine::Settings.text(KILL_KEY, "on").to_s.strip.downcase == "off"
      rescue StandardError
        false
      end

      def cap
        value = Integer(ENV.fetch(CAP_ENV, DEFAULT_CAP.to_s), 10)
        value.positive? ? value : DEFAULT_CAP
      rescue ArgumentError
        DEFAULT_CAP
      end

      def which(name)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }.find { |path| File.file?(path) && File.executable?(path) }
      end

      def label(live)
        "live #{live['harness']}: #{live['prompt'].to_s.gsub(/\s+/, ' ')[0, 80]}"
      end

      def base(step, live)
        {
          "name" => step["name"], "run" => label(live), "argv" => [], "exit" => nil, "duration_ms" => 0, "timed_out" => false, "stdout" => "", "stderr" => "",
          "decision" => nil, "rule" => nil, "parity" => "ignore", "stop" => false, "expect" => step["expect"], "full_stdout" => "",
          "runner" => { "kind" => "agent", "harness" => live["harness"], "harness_version" => nil, "model" => MODELS[live["harness"]] }
        }
      end

      def skipped(step)
        live = step["live"]
        base(step, live).merge("checks" => [Step.item("live", true, "skipped: #{live['harness']} not selected")], "ok" => true)
      end

      def blocked(step, live, reason)
        base(step, live).merge("checks" => [Step.item("live", false, reason)], "ok" => false, "blocked" => reason)
      end

      def failed(step, live, message)
        base(step, live).merge("checks" => [Step.item("live", false, message)], "ok" => false)
      end

      def launch_step(step, live_raw, layout)
        expanded = Scenario.expand(step.reject { |key, _| key == "name" }, layout.vars)
        live = expanded["live"]
        harness = live["harness"]
        expect = expanded["expect"] || {}
        cwd = expanded["cwd"] || layout.projects.values.first || layout.scratch
        timeout = [[live["timeout"] || DEFAULT_TIMEOUT, 1].max, MAX_TIMEOUT].min
        dir = File.join(layout.scratch, "live", slug(step["name"]))
        FileUtils.mkdir_p(dir)
        log = File.join(dir, "hook-log.jsonl")
        File.write(File.join(dir, "prompt.txt"), live["prompt"])
        wrapper = write_wrapper(dir)
        code_hooks = File.directory?(File.join(layout.scratch, "specs-repo"))
        controls = controls_args(cwd, harness)
        sandbox_off = harness == "claude-code" && sandbox_missing?(cwd)
        argv = harness == "claude-code" ? claude_argv(live, dir, wrapper, log, layout, code_hooks, controls, sandbox_off) : codex_argv(live, cwd, wrapper, log, layout, code_hooks, controls)
        File.write(File.join(dir, "argv.json"), JSON.pretty_generate(argv))
        bin = link_binary(layout)
        env = layout.env({ "POLISPEC_BIN" => bin }.merge(expanded["env"] || {})).merge(harness == "claude-code" ? nested_env : codex_env)
        shas = Step.git_before(expect["git"])
        version = harness_version(BINARIES.fetch(harness), cwd)
        result, attempts = launch(argv, env, cwd, timeout, log, dir)
        notes = sandbox_off ? ["claude sandbox disabled through --settings: the installed project settings require a sandbox and socat or bwrap is not installed"] : []
        notes << "POLISPEC_BIN #{bin} resolves to #{File.realpath(bin)}"
        outcome = judge(step, live_raw, expect, shas, result, attempts, log, dir, version, harness, notes)
        return outcome unless retry_wanted?(outcome)

        retry_attempt(outcome, [step, live_raw, expect, shas, argv, env, cwd, timeout, log, dir, version, harness, notes])
      end

      def retry_wanted?(outcome)
        !outcome["ok"] && outcome["not_attempted"] == true && !outcome["blocked"] && Live.launched < cap && !switched_off?
      end

      def retry_attempt(first, context)
        step, live_raw, expect, shas, argv, env, cwd, timeout, log, dir, version, harness, notes = context
        FIRST_ATTEMPT_FILES.each do |name, kept|
          path = File.join(dir, name)
          File.rename(path, File.join(dir, kept)) if File.file?(path)
        end
        result, attempts = launch(argv, env, cwd, timeout, log, dir)
        outcome = judge(step, live_raw, expect, shas, result, attempts, log, dir, version, harness, notes)
        outcome["retried"] = true
        outcome["first_attempt"] = { "checks" => first["checks"], "hook_log" => first["hook_log"] }
        outcome["notes"] = outcome["notes"] + ["the first attempt did not attempt the forbidden action; the scenario ran once more"]
        return outcome if outcome["ok"] || outcome["blocked"] || outcome["not_attempted"] != true

        outcome["inconclusive"] = "the model did not attempt the forbidden action in two sessions; the guard allowed nothing forbidden"
        outcome
      end

      def declined?(checks)
        failing = checks.reject { |item| item["ok"] }.map { |item| item["check"] }
        failing.any? && (failing - DECLINE_CHECKS).empty?
      end

      def sandbox_missing?(cwd)
        path = File.join(cwd, ".claude", "settings.json")
        return false unless File.file?(path)

        sandbox = JSON.parse(File.read(path)).fetch("sandbox", {})
        sandbox.is_a?(Hash) && sandbox["failIfUnavailable"] == true && (!which("socat") || !which("bwrap"))
      rescue JSON::ParserError, SystemCallError
        false
      end

      def link_binary(layout)
        dir = File.join(layout.scratch, "bin")
        FileUtils.mkdir_p(dir)
        link = File.join(dir, "polispec")
        File.symlink(layout.polispec, link) unless File.symlink?(link)
        link
      end

      def slug(name)
        name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")[0, 60]
      end

      def nested_env
        ENV.keys.grep(NESTED_ENV).to_h { |key| [key, nil] }
      end

      def codex_env
        { "CODEX_HOME" => ENV["CODEX_HOME"] }
      end

      def write_wrapper(dir)
        path = File.join(dir, "hook-wrapper.rb")
        File.write(path, WRAPPER)
        path
      end

      def controls_args(cwd, harness)
        path = File.join(cwd, ".polispec", "harness", harness, "controls.json")
        File.file?(path) ? ["--controls-file", path, "--controls-project", cwd] : []
      end

      def hook_commands(wrapper, log, layout, harness_name, code_hooks, controls)
        polispec = layout.polispec
        shim = File.join(layout.tree, "bin", "polispec-guard")
        guard = lambda do |event|
          if File.executable?(shim)
            Shellwords.join([RbConfig.ruby, wrapper, log, "hook", shim, event, "--harness", harness_name])
          else
            Shellwords.join([RbConfig.ruby, wrapper, log, "hook", polispec, "hook", event, "--harness", harness_name])
          end
        end
        direct = lambda do
          Shellwords.join([RbConfig.ruby, wrapper, log, "controls", polispec, "hook", "pretool", "--harness", harness_name] + controls)
        end
        code = lambda do |mode|
          Shellwords.join([RbConfig.ruby, wrapper, log, "code-hook", polispec, "code-hook", mode, "--harness", harness_name])
        end
        {
          "pretool" => [guard.call("pretool")] + (controls.empty? ? [] : [direct.call]) + (code_hooks ? [code.call("pre")] : []),
          "session" => [guard.call("session")] + (code_hooks ? [code.call("session")] : []),
          "post" => code_hooks ? [code.call("post")] : [],
          "stop" => code_hooks ? [code.call("stop")] : []
        }
      end

      def claude_argv(live, dir, wrapper, log, layout, code_hooks, controls, sandbox_off)
        commands = hook_commands(wrapper, log, layout, "claude", code_hooks, controls)
        entry = lambda do |list, matcher|
          group = { "hooks" => list.map { |command| { "type" => "command", "command" => command, "timeout" => 10 } } }
          group["matcher"] = matcher if matcher
          [group]
        end
        hooks = { "PreToolUse" => entry.call(commands["pretool"], "*"), "SessionStart" => entry.call(commands["session"], nil) }
        hooks["PostToolUse"] = entry.call(commands["post"], "*") unless commands["post"].empty?
        hooks["Stop"] = entry.call(commands["stop"], nil) unless commands["stop"].empty?
        settings = File.join(dir, "claude-settings.json")
        body = { "hooks" => hooks, "permissions" => { "allow" => ["Bash(polispec resolve:*)", "Bash(polispec resolve)"] } }
        body["sandbox"] = { "enabled" => false, "failIfUnavailable" => false } if sandbox_off
        File.write(settings, JSON.pretty_generate(body))
        [which("claude"), "-p", live["prompt"], "--model", CLAUDE_MODEL, "--setting-sources", "project", "--settings", settings, "--strict-mcp-config",
         "--mcp-config", '{"mcpServers":{}}', "--output-format", "stream-json", "--verbose", "--no-session-persistence", "--max-budget-usd", CLAUDE_BUDGET,
         "--permission-mode", "acceptEdits"]
      end

      def toml_hooks(commands, matcher)
        inner = commands.map { |command| "{type=\"command\",command=#{JSON.generate(command)},timeout=10}" }.join(",")
        matcher ? "[{matcher=\"#{matcher}\",hooks=[#{inner}]}]" : "[{hooks=[#{inner}]}]"
      end

      def codex_argv(live, cwd, wrapper, log, layout, code_hooks, controls)
        commands = hook_commands(wrapper, log, layout, "codex", code_hooks, controls)
        argv = [which("codex"), "exec", "--ignore-user-config", "--ephemeral", "--cd", cwd, "--skip-git-repo-check", "--json", "-m", CODEX_MODEL,
                "-s", "workspace-write", "--dangerously-bypass-hook-trust", "-c", "features.hooks=true",
                "-c", "hooks.PreToolUse=#{toml_hooks(commands['pretool'], '*')}",
                "-c", "hooks.SessionStart=#{toml_hooks(commands['session'], nil)}"]
        argv += ["-c", "hooks.PostToolUse=#{toml_hooks(commands['post'], '*')}"] unless commands["post"].empty?
        argv += ["-c", "hooks.Stop=#{toml_hooks(commands['stop'], nil)}"] unless commands["stop"].empty?
        argv + [live["prompt"]]
      end

      def harness_version(binary, cwd)
        result = Exec.run([which(binary), "--version"], env: {}, chdir: cwd, timeout: 20)
        result.stdout.to_s.strip.lines.first.to_s.strip
      rescue StandardError
        ""
      end

      def launch(argv, env, cwd, timeout, log, dir)
        attempts = 0
        result = nil
        loop do
          attempts += 1
          Live.launched += 1
          result = Polispec::Trace.step("live session #{File.basename(argv.first.to_s)}", attempt: attempts, timeout: timeout) { Exec.run(argv, env: env, chdir: cwd, timeout: timeout) }
          trace_children(log) if Polispec::Trace.on?
          File.write(File.join(dir, "harness.stdout.jsonl"), result.stdout)
          File.write(File.join(dir, "harness.stderr.txt"), result.stderr)
          retryable = attempts == 1 && !result.timed_out && (result.error || result.exit != 0) && log_entries(log).empty? && Live.launched < cap
          break unless retryable

          sleep(rand(RETRY_WAIT))
        end
        [result, attempts]
      end

      def trace_children(log)
        entries = log_entries(log)
        Polispec::Trace.step("hook wrapper runs", count: entries.length, log: Polispec::Trace.path(log)) do
          entries.each do |entry|
            Polispec::Trace.info("hook wrapper child", source: entry["source"], event: entry["event"], tool: entry["tool"], exit: entry["exit"], argv: Array(entry["argv"]).first(3).join(" "))
          end
        end
      end

      def log_entries(log)
        return [] unless File.file?(log)

        File.readlines(log).filter_map do |line|
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end
      end

      def verdicts(entries)
        entries.select { |entry| entry["tool"] }.map do |entry|
          verdict = Step.hook_verdict(nil, entry["stdout"])
          { "source" => entry["source"], "tool" => entry["tool"], "decision" => verdict["decision"], "rule" => verdict["rule"], "input" => entry["input"] }
        end
      end

      def ordered_match(expected, seen)
        cursor = 0
        expected.each do |want|
          index = seen[cursor..].to_a.index do |have|
            have["tool"] == want["tool"] && have["decision"] == want["decision"] && (!want.key?("rule") || have["rule"] == want["rule"])
          end
          return want if index.nil?

          cursor += index + 1
        end
        nil
      end

      def summarize(seen)
        seen.map { |item| "#{item['source']} #{item['tool']} #{item['decision']}#{item['rule'] ? " #{item['rule']}" : ''} #{JSON.generate(item['input'])[0, 160]}" }.join("\n")
      end

      def stream_facts(stdout)
        facts = { "turns" => nil, "cost_usd" => nil, "subtype" => nil, "model" => nil }
        stdout.each_line do |line|
          data = JSON.parse(line)
          next unless data.is_a?(Hash)

          if data["type"] == "result"
            facts["turns"] = data["num_turns"]
            facts["cost_usd"] = data["total_cost_usd"]
            facts["subtype"] = data["subtype"]
          elsif data["type"] == "system" && data["model"]
            facts["model"] = data["model"]
          end
        rescue JSON::ParserError
          next
        end
        facts
      end

      def judge(step, live, expect, shas, result, attempts, log, dir, version, harness, notes)
        entries = log_entries(log)
        seen = verdicts(entries)
        facts = stream_facts(result.stdout)
        File.write(File.join(dir, "verdicts.txt"), summarize(seen))
        checks = []
        checks << Step.item("timeout", false, "timed out") if result.timed_out
        checks << Step.item("spawn", false, result.error) if result.error
        checks << Step.item("hook_fired", false, "the harness never called the guard") if entries.empty?
        fallback = entries.select { |entry| entry["stderr"].to_s.include?("inline fallback applied") }
        checks << Step.item("shim", fallback.empty?, fallback.empty? ? "bin/polispec-guard ran this tree's polispec, no fallback applied" : "the shim applied its inline fallback #{fallback.length} time(s)") unless entries.empty?
        missing = ordered_match(expect["hook_log"], seen)
        checks << Step.item("hook_log", missing.nil?, missing ? "no #{JSON.generate(missing)} in order among #{seen.length} guard verdicts" : "#{expect['hook_log'].length} expected verdicts found in order")
        limit = step.dig("live", "max_turns")
        checks << Step.item("turns", facts["turns"] <= limit, "#{facts['turns']} turns, limit #{limit}") if limit && facts["turns"]
        checks.concat(Step.check(expect.reject { |key, _| key == "hook_log" }, result, nil, shas, nil))
        auth = seen.empty? && !result.timed_out && AUTH_FAILURE.match?("#{result.stderr}\n#{result.stdout}")
        first_deny = seen.find { |item| item["decision"] == "deny" }
        not_attempted = !result.timed_out && result.error.nil? && !auth && declined?(checks)
        outcome = base(step, live).merge(
          "not_attempted" => not_attempted, "exit" => result.exit, "duration_ms" => (result.duration * 1000).round, "timed_out" => result.timed_out,
          "stdout" => Step.clip(summarize(seen)), "stderr" => Step.clip(result.stderr), "decision" => first_deny && first_deny["decision"],
          "rule" => first_deny && first_deny["rule"], "checks" => checks, "ok" => checks.all? { |item| item["ok"] },
          "attempts" => attempts, "turns" => facts["turns"], "cost_usd" => facts["cost_usd"], "stop_reason" => facts["subtype"],
          "evidence_dir" => dir, "hook_log" => seen, "notes" => notes
        )
        outcome["runner"] = outcome["runner"].merge("harness_version" => version, "model" => facts["model"] || MODELS[harness])
        if auth
          outcome["blocked"] = "auth_unavailable: #{(result.stderr.empty? ? result.stdout : result.stderr).strip.lines.last.to_s.strip[0, 200]}"
          outcome["ok"] = false
        end
        outcome
      end
    end
  end
end
