#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    module Generate
      DEFAULT_HARNESSES = "[claude, codex, hermes, pi, dsh]".freeze

      module_function

      def rubocop(pack)
        rules = pack.rules.select { |rule| rule.lifecycle == "active" && rule.enforcer && rule.enforcer["kind"] == "rubocop" }
        YAML.dump(Runner.new(pack).rubocop_config(rules))
      end

      def directives(pack)
        rules = pack.rules.select { |rule| rule.data["directive"].is_a?(Hash) && rule.lifecycle == "active" }
        rows = rules.map { |rule| row(rule) }
        files = rules.each_with_object({}) { |rule, memo| memo["directives/#{rule.data['directive']['opcode'].downcase}.md"] = body(rule, pack) }
        { "rows" => rows, "files" => files }
      end

      def row(rule)
        directive = rule.data["directive"]
        opcode = directive["opcode"]
        enforce = directive["enforce"] || "none"
        condition = bracket(directive["condition"])
        format("%-20s %-90s d/%-10s ⚙ %-26s ⚡ %s", "[#{opcode}]", directive["row"], opcode.downcase, enforce, condition)
      end

      def bracket(value)
        text = value.to_s.strip
        return "[always]" if text.empty?

        text.start_with?("[") ? text : "[#{text}]"
      end

      def body(rule, pack)
        directive = rule.data["directive"]
        head = [
          "---", "id: #{directive['opcode']}", "harness: #{DEFAULT_HARNESSES}", "model: [all]", "env: [all]",
          "rule: #{directive['row']}", "when: #{bracket(directive['condition'])}", "enforce: #{directive['enforce'] || 'none'}", "---", ""
        ]
        parts = ["## #{rule.title}", "", "> **#{rule.statement.strip}**", ""]
        parts += ["### Why", "", rule.data["rationale"].to_s.strip, ""] if rule.data["rationale"]
        origin = rule.data["origin"]
        parts += ["### Origin", "", "#{origin['date']}: #{origin['cause']}", ""] if origin.is_a?(Hash)
        excuses = Array(rule.data["rationalizations"])
        unless excuses.empty?
          parts += ["### Rationalizations", ""]
          excuses.each { |item| parts << "- \"#{Code.squash(item['excuse'])}\" is wrong: #{Code.squash(item['rebuttal'])}" }
          parts << ""
        end
        flags = Array(rule.data["red_flags"])
        parts += ["### Red flags", ""] + flags.map { |flag| "- #{flag}" } + [""] unless flags.empty?
        guidance = directive["body"] && pack.exist?(directive["body"]) ? pack.read(directive["body"]).to_s.strip : ""
        parts += ["### Guidance", "", guidance, ""] unless guidance.empty?
        parts += ["### Enforcement", "", "Enforced by #{directive['enforce'] || 'no mechanical guard'}; policy #{rule.id} in polispec-specs is the source of this directive.", ""]
        (head + parts).join("\n")
      end

      def skill(pack)
        out = [
          "# polispec-reviewer brief", "",
          "Review the listed files against the listed policies. Read each policy's lens, read the files (or the diff), and judge every policy once per file.",
          "Return only JSON: a list of {\"policy\": id, \"file\": path, \"line\": integer or null, \"verdict\": \"violation\" | \"compliant\" | \"unclear\", \"evidence\": one sentence quoting the code}.",
          "Do not edit files. Do not report style preferences outside the lens. A violation needs a quoted line.", ""
        ]
        pack.specs.values.sort_by(&:path).each do |spec|
          rules = spec.root ? spec.root.each_rule.select { |rule| rule.active? && %w[agent hybrid contextual].include?(rule.klass) && rule.lens } : []
          next if rules.empty?

          out << "## #{spec.path}"
          rules.each do |rule|
            out << ""
            out << "### #{rule.id} (#{rule.level}, #{rule.severity}, #{rule.klass})"
            out << rule.statement.strip
            out << "Look for: #{Code.squash(rule.lens['look_for'])}"
            out << "Violation: #{Code.squash(rule.lens['violation'])}"
            out << "Compliant if: #{Code.squash(rule.lens['compliant_if'])}" if rule.lens["compliant_if"]
            Array(rule.data["rationalizations"]).each { |item| out << "Excuse to reject: \"#{Code.squash(item['excuse'])}\" -- #{Code.squash(item['rebuttal'])}" }
          end
          out << ""
        end
        out.join("\n")
      end
    end
  end
end
