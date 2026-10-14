#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "base"
require_relative "../harness_controls/backends/codex"

module Polispec
  module Harness
    class Codex < Base
      def ask?
        false
      end

      def parse(text)
        HarnessControls::Backends::Codex.normalize(text)
      end

      CODE_HOOK_EVENTS = { "pre" => "PreToolUse", "post" => "PostToolUse", "stop" => "Stop", "session" => "SessionStart" }.freeze

      def parse_for(text, mode)
        HarnessControls::Backends::Codex.normalize(text, events: [CODE_HOOK_EVENTS.fetch(mode)])
      end

      def render(verdict)
        output = HarnessControls::Backends::Codex.render(verdict)
        @exit_status = output["exit_status"]
        output["stdout"]
      end

      def render_deny(text)
        render(Verdict.new(level: "deny", rule_id: "POLISPEC-INTERNAL", reason: text))
      end
    end
  end
end
