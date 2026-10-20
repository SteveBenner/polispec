#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Author
    module Prompt
      LINT_RULES = [
        "The description has at least 2 sentences and at least 20 words, and at most 8 sentences and 400 words.",
        "The description does not merely restate the summary.",
        "The description names at least one thing the document governs: an action class, an environment, a module, a rule id, a tool, a path, a role or a package, as a whole word.",
        "The description states an effect with one of these words: allow, ask, warn, deny, refuse, block, stop, promote, freeze, require, forbid, in any inflection."
      ].freeze

      module_function

      def schema_id(kind, context)
        explicit = context[:schema_id].to_s
        return explicit unless explicit.empty?

        kind.to_s == "description" ? nil : "polispec.#{kind}/v1"
      end

      def schema_text(kind, context)
        id = schema_id(kind, context)
        return "" unless id

        name = id.sub(/\Apolispec\./, "").sub(%r{/v1\z}, "")
        file = File.join(ROOT, "schemas", "#{name}.v1.yml")
        File.file?(file) ? File.read(file) : ""
      end

      def system_prompt(kind, context)
        id = schema_id(kind, context)
        parts = []
        parts << "You draft polispec rulebooks. Output exactly one fenced yaml block containing one document of schema #{id || 'the schema named by the request'}, then a section headed Rationale that explains each choice."
        parts << "Read the project and the shelf with Read, Grep and Glob using absolute paths; you may not run commands or write files."
        parts << "The description field, when the schema has one, must pass these rules:\n#{LINT_RULES.map { |rule| "- #{rule}" }.join("\n")}"
        parts << "Never invent rule ids that collide with ones already listed in the project or the shelf."
        modules = Array(context[:shelf_modules]).map(&:to_s)
        parts << "Shelf modules available to include: #{modules.join(', ')}." unless modules.empty?
        schema = schema_text(kind, context)
        parts << "Schema file text:\n#{schema}" unless schema.empty?
        current = context[:current_yaml].to_s
        parts << "Current document:\n#{current}" unless current.strip.empty?
        parts.join("\n\n")
      end

      def user_turn(intent, findings = nil)
        return intent.to_s if findings.nil? || findings.empty?

        lines = findings.map { |item| "- #{item[:code] || item['code']}: #{item[:message] || item['message']}" }
        "#{intent}\n\nThe previous draft had these validation findings; fix them and output the whole document again:\n#{lines.join("\n")}"
      end
    end
  end
end
