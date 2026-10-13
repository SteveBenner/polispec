require_relative "base"
require_relative "../harness_controls/backends/antigravity"

module Polispec
  module Harness
    class Antigravity < Base
      def ask?
        true
      end

      def parse(text)
        HarnessControls::Backends::Antigravity.normalize(text)
      end

      def render(verdict)
        output = HarnessControls::Backends::Antigravity.render(verdict, "PreToolUse")
        @exit_status = output["exit_status"]
        output["stdout"]
      end

      def render_deny(text)
        render(Verdict.new(level: "deny", rule_id: "POLISPEC-INTERNAL", reason: text))
      end
    end
  end
end
