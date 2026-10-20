#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "psych"
require_relative "../proposals"

module Polispec
  module Web
    module LintRoute
      KIND_MAP = { "project" => "policy", "path" => "module" }.freeze

      module_function

      def unescape(segment)
        segment.gsub("~1", "/").gsub("~0", "~")
      end

      def node_at(root, pointer)
        node = root
        best = root
        pointer.to_s.split("/").reject(&:empty?).map { |segment| unescape(segment) }.each do |segment|
          break unless node

          if node.is_a?(Psych::Nodes::Mapping)
            pair = node.children.each_slice(2).find { |key, _| key.respond_to?(:value) && key.value == segment }
            break unless pair

            best = pair[0]
            node = pair[1]
          elsif node.is_a?(Psych::Nodes::Sequence)
            child = segment.match?(/\A\d+\z/) ? node.children[segment.to_i] : nil
            break unless child

            best = child
            node = child
          else
            break
          end
        end
        best
      end

      def position(root, pointer)
        return {} unless root

        node = node_at(root, pointer)
        { "line" => node.start_line + 1, "col" => node.start_column + 1, "end_line" => node.end_line + 1, "end_col" => node.end_column + 1 }
      rescue StandardError
        {}
      end

      def description_node(root)
        return nil unless root.is_a?(Psych::Nodes::Mapping)

        pair = root.children.each_slice(2).find { |key, _| key.respond_to?(:value) && key.value == "description" }
        pair && pair[1]
      end

      def finding(severity, code, message, place = {})
        { "severity" => severity, "code" => code, "message" => message, "line" => place["line"], "col" => place["col"], "end_line" => place["end_line"], "end_col" => place["end_col"] }
      end

      def counts(text)
        { "sentences" => Description.sentences_of(text).length, "words" => text.split(/\s+/).reject(&:empty?).length }
      end

      def lint_severity
        Engine::Settings.description_strict? ? "error" : "warning"
      end

      def description_text(body)
        text = body["yaml"].to_s
        doc = { "description" => text }
        findings = Description.lint(doc, nil).map { |item| finding(lint_severity, "description_#{item[:code]}", item[:message]) }
        if Description.ahead_of_runtime? && !text.strip.empty?
          findings << finding("error", "description_ahead_of_runtime", "readers of this rulebook run a polispec older than 0.34.0; a description makes it invalid there")
        end
        { "findings" => findings, "schema_id" => nil, "description" => counts(text) }
      end

      def run(body)
        kind = body["kind"].to_s
        return description_text(body) if kind == "description"

        text = body["yaml"].to_s
        root = begin
          Psych.parse(text)&.root
        rescue Psych::SyntaxError
          nil
        end
        begin
          doc = Proposals.parse_yaml(text)
        rescue Operator::Failure => e
          problem = Array(e.payload["problems"]).first || {}
          place = problem["line"] ? { "line" => problem["line"], "col" => problem["col"].to_i + 1, "end_line" => problem["line"], "end_col" => problem["col"].to_i + 2 } : {}
          return { "findings" => [finding("error", problem["code"] || "yaml_invalid", problem["message"] || e.message, place)], "schema_id" => nil }
        end
        schema_kind = Schema.kind_for(doc) || KIND_MAP.fetch(kind, kind)
        findings = []
        if Schema.kinds.include?(schema_kind)
          Schema.validate(schema_kind, doc).first(200).each do |error|
            findings << finding("error", "schema", "#{error.pointer} #{error.message}".strip, position(root, error.pointer))
          end
        else
          findings << finding("error", "unknown_kind", "no schema kind #{kind}")
        end
        out = { "findings" => findings, "schema_id" => Schema.kinds.include?(schema_kind) ? Schema.schema_id(schema_kind) : nil }
        description_findings(doc, schema_kind, root, findings, out)
        out
      end

      def description_findings(doc, schema_kind, root, findings, out)
        return unless doc["description"].is_a?(String)

        node = description_node(root)
        place = node ? { "line" => node.start_line + 1, "col" => node.start_column + 1, "end_line" => node.end_line + 1, "end_col" => node.end_column + 1 } : {}
        Description.lint(doc, Description::KINDS.include?(schema_kind) ? schema_kind : nil).each do |item|
          findings << finding(lint_severity, "description_#{item[:code]}", item[:message], place)
        end
        if Description.ahead_of_runtime?
          findings << finding("error", "description_ahead_of_runtime", "readers of this rulebook run a polispec older than 0.34.0; a description makes it invalid there", place)
        end
        out["description"] = counts(doc["description"])
      end
    end

    Web.route("lint") do |r|
      r.is do
        r.post do
          body = r.POST
          fail!(400, "bad_json", "kind and yaml are required") unless body.is_a?(Hash) && body["kind"].is_a?(String) && body["yaml"].is_a?(String)
          fail!(413, "too_large", "the text is larger than #{Proposals::MAX_TEXT} bytes") if body["yaml"].bytesize > Proposals::MAX_TEXT
          LintRoute.run(body)
        end
        fail!(405, "method_not_allowed", "unsupported method")
      end
    end
  end
end
