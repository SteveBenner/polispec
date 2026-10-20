#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Author
    module Draft
      FENCE = /^[ \t]*```[ \t]*(?:ya?ml)[ \t]*\r?\n(.*?)^[ \t]*```[ \t]*$/m
      RATIONALE = /^[ \t]*(?:\#{1,6}[ \t]*)?\**Rationale\**[ \t]*:?\**[ \t]*$/i

      module_function

      def extract_yaml(text)
        blocks = text.to_s.scan(FENCE).flatten
        blocks.last
      end

      def rationale(text)
        text = text.to_s
        match = RATIONALE.match(text)
        return text[(match.end(0))..-1].to_s.strip if match

        text.gsub(FENCE, "").strip
      end

      def schema_kind(kind, context)
        return kind.to_s unless kind.to_s == "description"

        id = context[:schema_id].to_s
        found = Schema.kinds.find { |item| Schema.schema_id(item) == id }
        found
      end

      def finding(code, message, extra = {})
        { code: code, message: message }.merge(extra)
      end

      def build(kind, text, context)
        yaml = extract_yaml(text)
        result = { yaml: yaml, rationale: rationale(text), findings: [], plan: nil }
        if yaml.nil?
          result[:findings] << finding("no_yaml_block", "the reply carries no fenced yaml block")
          return result
        end

        doc = parse(yaml, result[:findings])
        return result if doc.nil?

        result[:findings].concat(schema_findings(kind, context, doc))
        result[:findings].concat(lint_findings(kind, doc))
        result[:plan] = plan(kind, yaml, doc, context)
        result
      end

      def parse(yaml, findings)
        doc = YAML.safe_load(yaml, permitted_classes: [Date], aliases: false)
        unless doc.is_a?(Hash)
          findings << finding("yaml_not_mapping", "the yaml block is not one mapping document")
          return nil
        end
        doc
      rescue Psych::Exception => e
        findings << finding("yaml_invalid", e.message)
        nil
      end

      def schema_findings(kind, context, doc)
        target = schema_kind(kind, context)
        return [] unless target && Schema.kinds.include?(target)

        Schema.validate(target, doc).map { |error| finding("schema", error.message, pointer: error.pointer) }
      rescue StandardError => e
        [finding("schema_unchecked", e.message)]
      end

      def lint_findings(kind, doc)
        lint = description_lint
        return [] unless lint

        Array(lint.call(doc, kind.to_s)).map do |item|
          code = item[:code] || item["code"]
          message = item[:message] || item["message"]
          finding("description_#{code}", message.to_s, span: item[:span] || item["span"])
        end
      rescue StandardError => e
        [finding("lint_unchecked", e.message)]
      end

      def description_lint
        file = File.join(LIB, "description.rb")
        require file if !defined?(Polispec::Description) && File.file?(file)
        return nil unless defined?(Polispec::Description) && Polispec::Description.respond_to?(:lint)

        Polispec::Description.method(:lint)
      end

      def plan(kind, yaml, doc, context)
        planner = Author.planner
        return nil unless planner && (context[:project] || context[:target_file])

        planner.call(kind: kind.to_s, yaml: yaml, doc: doc, context: context)
      rescue StandardError => e
        { error: e.message }
      end
    end
  end
end
