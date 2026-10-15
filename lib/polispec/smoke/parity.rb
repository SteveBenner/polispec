#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../smoke"

module Polispec
  module Smoke
    module Parity
      TIMESTAMP = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?/
      GIT_SHA = /\b[0-9a-f]{40}\b/
      DIGEST = /\bsha256:[0-9a-f]{64}\b/
      ENTRY_ID = /\bsmk_[0-9a-f]{12}\b/
      PLAN_ID = /\bplan_[0-9a-f]{24}\b/
      HEX64 = /\b[0-9a-f]{64}\b/
      SHORT_SHA = /\b[0-9a-f]{12}\b/
      DURATION = /\b\d+ ms\b/
      EXCERPT = 160

      module_function

      def normalise(text, roots)
        out = text.to_s.dup
        roots.sort_by { |path, _| -path.length }.each do |path, token|
          next if path.nil? || path.empty? || path == "/"

          out = out.gsub(path, token)
        end
        out = out.gsub(TIMESTAMP, "<TS>").gsub(DIGEST, "sha256:<DIGEST>").gsub(HEX64, "<HEX>").gsub(GIT_SHA, "<SHA>").gsub(ENTRY_ID, "smk_<ID>")
        out.gsub(PLAN_ID, "plan_<ID>").gsub(SHORT_SHA, "<SHORT>").gsub(DURATION, "<N> ms")
      end

      def excerpt(text)
        text.to_s.strip.gsub(/\s+/, " ")[0, EXCERPT]
      end

      def describe(step, other, roots)
        if step["decision"] || other["decision"]
          return nil if step["decision"] == other["decision"] && step["rule"] == other["rule"]

          return [[step["decision"], step["rule"]].compact.join(" "), [other["decision"], other["rule"]].compact.join(" ")]
        end
        return ["exit=#{step['exit'].inspect}", "exit=#{other['exit'].inspect}"] if step["exit"] != other["exit"]

        mine = normalise(step["full_stdout"], roots).lines
        theirs = normalise(other["full_stdout"], roots).lines
        return nil if mine == theirs

        index = (0...[mine.length, theirs.length].max).find { |line| mine[line] != theirs[line] }
        ["line #{index + 1}: #{excerpt(mine[index])}", "line #{index + 1}: #{excerpt(theirs[index])}"]
      end

      def compare(scenario, candidate, against, candidate_roots, against_roots)
        diffs = []
        candidate_steps = candidate.fetch("steps")
        against_steps = against.fetch("steps").to_h { |step| [step["name"], step] }
        candidate_steps.each do |step|
          next if step["parity"] == "ignore"

          other = against_steps[step["name"]]
          if other.nil?
            diffs << { "scenario" => scenario, "step" => step["name"], "candidate" => "ran", "against" => "did not run" }
            next
          end
          next if other["parity"] == "ignore"

          pair = describe(step.merge("full_stdout" => normalise(step["full_stdout"], candidate_roots)), other.merge("full_stdout" => normalise(other["full_stdout"], against_roots)), [])
          diffs << { "scenario" => scenario, "step" => step["name"], "candidate" => pair[0], "against" => pair[1] } if pair
        end
        diffs
      end
    end
  end
end
