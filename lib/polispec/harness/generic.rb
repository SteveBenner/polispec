#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "base"

module Polispec
  module Harness
    class Generic < Base
      def ask?
        false
      end

      def render(verdict)
        json = super
        return nil unless json

        data = JSON.parse(json)
        data["decision"] = "block"
        data["reason"] = data["hookSpecificOutput"]["permissionDecisionReason"]
        JSON.generate(data)
      end

      def render_deny(text, _rule_id = nil)
        data = JSON.parse(super(text))
        data["decision"] = "block"
        data["reason"] = text
        JSON.generate(data)
      end
    end
  end
end
