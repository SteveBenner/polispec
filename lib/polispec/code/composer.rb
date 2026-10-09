#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    module Composer
      AGENT_CLASSES = %w[agent hybrid].freeze

      module_function

      def compose(pack, chain)
        lines = [header(chain)]
        used = lines.first.length
        chain.specs.each do |spec|
          rules = ordered(chain.rules_of(spec))
          next if rules.empty?

          budget = pack.budget_lines(spec.path)
          shown = rules.first(budget)
          body = shown.map { |rule| rule_line(rule) }
          body << "#{rules.length - shown.length} more: polispec code show #{spec.path}" if rules.length > shown.length
          block = ["-- #{spec.path}"] + body
          block.each do |line|
            break if used + line.length + 1 > INJECT_CAP

            lines << line
            used += line.length + 1
          end
        end
        lines.join("\n")
      end

      def ordered(rules)
        keyed = rules.each_with_index.map { |rule, index| [rule, index] }
        keyed.reject { |rule, _| rule.level == "MAY" }.sort_by { |rule, index| [group(rule), SEVERITIES.index(rule.severity) || 9, index] }.map(&:first)
      end

      def group(rule)
        rule.blocking_level? ? 0 : 1
      end

      def rule_line(rule)
        line = Code.squash(rule.line)
        return line unless AGENT_CLASSES.include?(rule.klass) || rule.klass == "contextual"

        violation = rule.lens && rule.lens["violation"]
        line += " Violation: #{Code.squash(violation)}" if violation
        if AGENT_CLASSES.include?(rule.klass)
          first = Array(rule.data["rationalizations"]).first
          line += " Excuse: \"#{Code.squash(first['excuse'])}\" Rebuttal: #{Code.squash(first['rebuttal'])}" if first.is_a?(Hash)
        end
        line
      end

      def header(chain)
        "POLISPEC code specs for #{chain.language} (#{chain.digest.sub('sha256:', '')[0, 12]}): MUST and MUST_NOT block the write on changed lines, SHOULD warns, agent-class rules are reviewed at task end."
      end
    end
  end
end
