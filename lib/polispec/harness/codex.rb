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
