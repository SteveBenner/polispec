require_relative "base"
require_relative "../harness_controls/backends/hermes"

module Polispec
  module Harness
    class Hermes < Base
      def ask?
        true
      end

      def parse(text)
        HarnessControls::Backends::Hermes.normalize(text)
      end

      def render(verdict)
        output = HarnessControls::Backends::Hermes.render(verdict, "pre_tool_call")
        @exit_status = output["exit_status"]
        output["stdout"]
      end

      def render_deny(text)
        render(Verdict.new(level: "deny", rule_id: "POLISPEC-INTERNAL", reason: text))
      end
    end
  end
end
