#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "hook"
require_relative "../explain/rule_trace"

module Polispec
  module ExplainReadOnly
    @active = false

    class << self
      attr_accessor :active
    end

    def consume!(*args, **kwargs)
      return nil if ExplainReadOnly.active

      super
    end
  end
  Engine::Passes.singleton_class.prepend(ExplainReadOnly)

  module ExplainNoCacheWrites
    private

    def remember_environments(*args)
      return nil if ExplainReadOnly.active

      super
    end

    def write_cache(*args)
      return nil if ExplainReadOnly.active

      super
    end
  end
  PolicySource.singleton_class.prepend(ExplainNoCacheWrites)

  class ExplainCommand
    USAGE = "usage: polispec explain --harness <claude|codex|hermes|pi|deepseek|antigravity> [--json] < hook-json".freeze
    CALL_USAGE = "usage: polispec explain <tool> <input> [--cwd DIR] [--json]  (input: the shell command for Bash, else a JSON object of tool input; a bare path for Read, Write and Edit)\n       #{USAGE.delete_prefix('usage: ')}".freeze
    PATH_TOOLS = %w[Read Write Edit].freeze

    def self.run(args)
      new.run(args)
    end

    def run(args)
      return run_call(args) unless hook_form?(args)

      harness, json = parse(args)
      return usage unless harness && HookCommand::HARNESSES.include?(harness)
      return usage if $stdin.tty?

      raw = $stdin.read(HookCommand::INPUT_LIMIT + 1).to_s
      return fail_input("hook input is empty") if raw.strip.empty?
      return fail_input("hook input exceeds #{HookCommand::INPUT_LIMIT} bytes") if raw.bytesize > HookCommand::INPUT_LIMIT

      begin
        data = JSON.parse(raw)
      rescue JSON::ParserError => e
        return fail_input("invalid hook JSON: #{e.message}")
      end
      return fail_input("hook input is not a JSON object") unless data.is_a?(Hash)

      result = judge(harness, raw)
      return 1 unless result

      json ? puts(JSON.generate(result)) : puts("#{result['verdict']} #{result['rule_id'] || '-'} #{result['reason'] || '-'}")
      0
    end

    private

    def hook_form?(args)
      args.include?("--harness") || (args - ["--json"]).empty?
    end

    def run_call(args)
      tool, input, cwd, json = parse_call(args)
      return call_usage unless tool && input

      tool_input, problem = tool_input_for(tool, input)
      return fail_input(problem) if problem

      cwd = File.expand_path(cwd || Dir.pwd)
      return fail_input("--cwd #{cwd} is not a directory") unless File.directory?(cwd)

      report = traced(tool, tool_input, cwd, input)
      return 1 unless report

      json ? puts(JSON.generate(report)) : print_report(report)
      0
    end

    def parse_call(args)
      list = args.dup
      positional = []
      cwd = nil
      json = false
      until list.empty?
        flag = list.shift
        case flag
        when "--json" then json = true
        when "--cwd"
          cwd = list.shift
          return [nil, nil, nil, json] if cwd.nil? || cwd.start_with?("--")
        when /\A--/ then return [nil, nil, nil, json]
        else positional << flag
        end
      end
      return [nil, nil, nil, json] unless positional.length == 2 && !positional.first.empty?

      [positional[0], positional[1], cwd, json]
    end

    def tool_input_for(tool, input)
      return [{ "command" => input }, nil] if tool == "Bash"

      if input.lstrip.start_with?("{")
        begin
          data = JSON.parse(input)
        rescue JSON::ParserError => e
          return [nil, "invalid tool input JSON: #{e.message}"]
        end
        return [data, nil] if data.is_a?(Hash)

        return [nil, "tool input is not a JSON object"]
      end
      return [{ "file_path" => input }, nil] if PATH_TOOLS.include?(tool)

      [nil, "#{tool} takes its input as a JSON object"]
    end

    def traced(tool, tool_input, cwd, input)
      payload = JSON.generate("hook_event_name" => "PreToolUse", "tool_name" => tool, "tool_input" => tool_input, "cwd" => cwd, "session_id" => "cli-explain")
      hook = HookCommand.new
      RuleTrace.start
      ExplainReadOnly.active = true
      result = hook.explain("claude", payload)
      state = hook.instance_variable_get(:@explain_state) || {}
      command = tool == "Bash" ? input : (tool_input["file_path"] || tool_input["path"] || input)
      targets = RuleTrace::Report.new(tool: tool, command: command, ledger: state["ledger"]).targets
      assemble(tool, tool_input, cwd, result, state, targets)
    rescue Polispec::Error, SystemCallError, Timeout::Error, JSON::ParserError => e
      warn "polispec explain: #{e.class}: #{e.message}"
      nil
    ensure
      RuleTrace.stop
      ExplainReadOnly.active = false
    end

    def assemble(tool, tool_input, cwd, result, state, targets)
      {
        "tool" => tool, "input" => tool_input, "cwd" => cwd, "verdict" => result["verdict"], "rule_id" => result["rule_id"], "reason" => result["reason"],
        "governed" => result["governed"], "control" => result["control"],
        "classified" => Array(state["actions"]).map { |action| { "class" => action.action_class, "raw" => action.raw.to_s, "path" => Engine::Envs.hint_of(action)["path"] } },
        "targets" => targets
      }
    end

    def print_report(report)
      puts "explain #{report['tool']} #{report['input'].to_json}"
      puts "cwd #{report['cwd']}"
      puts "final verdict #{report['verdict']} #{report['rule_id'] || '-'}#{report['reason'] ? " #{report['reason']}" : ''}"
      control = report["control"]
      puts "harness controls #{control['verdict']}#{control['ask_ids'].to_a.empty? ? '' : " (#{control['ask_ids'].join(', ')})"}" if control
      puts "classified:"
      report["classified"].each { |action| puts "  #{action['class']}  #{action['raw']}#{action['path'] ? "  (#{action['path']})" : ''}" }
      puts "  (the call classified to no action)" if report["classified"].empty?
      if report["targets"].empty?
        puts "no live project or governed path owns this call, so no environment rule applies"
        return
      end
      report["targets"].each { |target| print_target(target) }
      worst = report["targets"].map { |target| target["verdict"] }.max_by { |level| RuleTrace::Report::LEVEL_ORDER.index(level).to_i }
      puts "note: the final verdict #{report['verdict']} differs from the environment verdict #{worst}; exceptions or the harness-control ceiling changed it" if worst && worst != report["verdict"]
    end

    def print_target(target)
      puts ""
      puts "project #{target['project']} environment #{target['env']} policy #{target['policy_source']}"
      puts "  verdict #{target['verdict']} #{target['rule_id'] || '-'}"
      puts "  paused: #{target['reason']}" if target["rows"].empty?
      target["rows"].each { |row| print_row(row) }
    end

    def print_row(row)
      action = row["action"]
      puts "  action #{action['class']} (env #{action['env']}) #{action['raw']}"
      puts "    verdict #{row['verdict']} #{row['rule_id']}"
      if row["matched"].empty?
        puts "    matched rules: none"
      else
        puts "    matched rules:"
        row["matched"].each { |match| puts "      #{match_line(match)}" }
      end
      puts "    why: #{row['why']}"
      Array(row["change"]).each do |lever|
        puts "    change (#{lever['lever']}): #{lever['command'] || '-'}"
        puts "      #{lever['note']}" if lever["note"]
      end
    end

    def match_line(match)
      where = match["file"] ? "#{match['file']}#{match['line'] ? ":#{match['line']}" : ''}" : "-"
      parts = ["#{match['verdict']} #{match['rule_id']}", "layer #{match['layer']}", where]
      parts << "module #{match['module']}#{match['params'] && !match['params'].empty? ? " #{match['params'].to_json}" : ''}" if match["module"]
      parts << "package #{match['package'].map { |item| "#{item['name']} #{item['version']}#{item['variant'] ? " (#{item['variant']})" : ''}" }.join(', ')}" if match["package"]
      parts << "overridden by #{match['overridden_by']}" if match["overridden_by"]
      parts << "in effect" if match["in_effect"]
      parts << "WINNER" if match["winner"]
      parts.join("  ")
    end

    def call_usage
      warn CALL_USAGE
      2
    end

    def judge(harness, raw)
      ExplainReadOnly.active = true
      HookCommand.new.explain(harness, raw)
    rescue StandardError, ScriptError => e
      warn "polispec explain: #{e.class}: #{e.message}"
      nil
    ensure
      ExplainReadOnly.active = false
    end

    def parse(args)
      list = args.dup
      harness = nil
      json = false
      until list.empty?
        flag = list.shift
        case flag
        when "--json" then json = true
        when "--harness"
          return [nil, json] if harness

          harness = list.shift
        else return [nil, json]
        end
      end
      [harness, json]
    end

    def usage
      warn USAGE
      2
    end

    def fail_input(message)
      warn "polispec explain: #{message}"
      2
    end
  end

  CLI.register("explain", ExplainCommand, summary: "judge one PreToolUse hook call and print the enforce verdict without side effects")
end
