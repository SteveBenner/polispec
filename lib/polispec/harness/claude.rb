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

      def render(verdict)
        output = HarnessControls::Backends::Claude.render(verdict, "PreToolUse")
        @exit_status = output["exit_status"]
        output["stdout"]
      end

      def render_deny(text)
        render(Verdict.new(level: "deny", rule_id: "POLISPEC-INTERNAL", reason: text))
      end
    end
  end
end
