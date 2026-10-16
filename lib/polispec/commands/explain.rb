#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "hook"

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

    def self.run(args)
      new.run(args)
    end

    def run(args)
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
