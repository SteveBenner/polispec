#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    module Classify
      QUESTION = "Which execution class fits this code-spec policy? harness: a deterministic enforcer decides fully. agent: a model must judge it against a lens. hybrid: an enforcer flags candidates and a model judges them. contextual: whether it applies depends on the situation and must be decided per event.".freeze

      module_function

      def propose(rule)
        context = {
          "policy" => rule.id, "statement" => rule.statement, "level" => rule.level,
          "lens" => rule.lens, "enforcer" => rule.enforcer, "current_class" => rule.klass
        }
        answer = Decide.ask(question: QUESTION, options: CLASSES, context: context)
        return nil unless answer && CLASSES.include?(answer["choice"])

        digest = "sha256:#{Digest::SHA256.hexdigest(JSON.generate([rule.statement, rule.lens, rule.enforcer]))}"
        {
          "class" => answer["choice"],
          "classified" => { "by" => answer["provider"].empty? ? "decide" : answer["provider"], "at" => Date.today.iso8601, "confidence" => answer["probability"].round(3), "digest" => digest }
        }
      end
    end
  end
end
