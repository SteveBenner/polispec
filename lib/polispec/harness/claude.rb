#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "base"
require_relative "../harness_controls/backends/claude"

module Polispec
  module Harness
    class Claude < Base
      def ask?
        true
      end

      def parse(text)
        HarnessControls::Backends::Claude.normalize(text)
      end

      CODE_HOOK_EVENTS = { "pre" => "PreToolUse", "post" => "PostToolUse", "stop" => "Stop", "session" => "SessionStart" }.freeze

      def parse_for(text, mode)
        HarnessControls::Backends::Claude.normalize(text, events: [CODE_HOOK_EVENTS.fetch(mode)])
      end

      def render(verdict)
        output = HarnessControls::Backends::Claude.render(verdict, "PreToolUse")
        @exit_status = output["exit_status"]
        output["stdout"]
      end

      def render_deny(text, _rule_id = nil)
        render(Verdict.new(level: "deny", rule_id: "POLISPEC-INTERNAL", reason: text))
      end

      def with_notice(output, text, event = nil)
        return render_context(text, event) if output.nil? || output.to_s.strip.empty?

        data = JSON.parse(output.to_s)
        specific = data.is_a?(Hash) ? data["hookSpecificOutput"] : nil
        return output unless specific.is_a?(Hash)

        specific["additionalContext"] = [specific["additionalContext"], text].compact.join("\n")
        JSON.generate(data)
      rescue JSON::ParserError
        output
      end
    end
  end
end
