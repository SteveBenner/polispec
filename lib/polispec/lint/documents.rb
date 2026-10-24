#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../schema/check"

module Polispec
  module Lint
    module Documents
      STOPPING = %w[yaml_syntax json_syntax yaml_alias yaml_multiple_documents].freeze

      module_function

      def check(target, text, only:, description_error:)
        text ||= target.text || File.read(target.path)
        path = target.path
        format = target.format || Lint.format_for(path)
        out = []
        if only.include?("hygiene")
          hygiene = Hygiene.check(text, path: path, format: format, allow: target.allow || [])
          out.concat(hygiene)
          return stamp(out, target) if hygiene.any? { |item| item.error? && STOPPING.include?(item.code) }
        end
        return stamp(out, target) if format == :text || target.kind.nil?
        return stamp(out, target) unless only.include?("schema") || (only.include?("description") && target.descriptions)

        out.concat(schema_findings(target, text, only, description_error))
        stamp(out, target)
      end

      def stamp(findings, target)
        findings.each { |item| item.project = target.project }
        findings
      end

      def behavior_v2?(data)
        require_relative "../behavior"
        Behavior.v2?(data)
      rescue StandardError
        false
      end

      def finding(severity, rule, code, path, pointer, message)
        Finding.new(severity, rule, code, path, nil, pointer, message, nil)
      end

      def schema_findings(target, text, only, description_error)
        path = target.path
        body = text.dup.force_encoding("UTF-8").sub(Hygiene::BOM, "")
        data = begin
          Schema::Document.parse(body, path)
        rescue Schema::Document::ParseError => e
          return [finding("error", "hygiene", "yaml_syntax", path, nil, e.message)]
        end
        own = Schema.kind_for(data)
        out = []
        if target.kind == "auto" && own.nil? && !behavior_v2?(data)
          out << finding("warn", "schema", "schema_unrecognized", path, "/schema", "no known polispec schema id") if target.unrecognized && only.include?("schema")
          return out
        end
        if target.expect && data.is_a?(Hash) && !own.nil? && own != target.expect && only.include?("schema")
          out << finding("error", "schema", "schema_kind_mismatch", path, "/schema", "declares #{own}, expected #{target.expect}")
          return out
        elsif target.expect && own.nil? && target.unrecognized && only.include?("schema")
          out << finding("warn", "schema", "schema_unrecognized", path, "/schema", "no known polispec schema id")
        end
        outcome = Schema::Check.call(target.kind, path, text: body)
        if only.include?("schema") && !outcome.result.ok
          outcome.result.errors.each do |error|
            out << finding("error", "schema", "schema_invalid", path, error.pointer, error.message)
          end
        end
        if only.include?("description") && target.descriptions
          outcome.warnings.each do |warning|
            out << finding(description_error ? "error" : "warn", "description", warning["code"], path, nil, warning["message"])
          end
        end
        out
      end
    end
  end
end
