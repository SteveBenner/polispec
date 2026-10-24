#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../description"

module Polispec
  module Schema
    module Check
      Outcome = Struct.new(:result, :data, :kind, :warnings, :semantic)

      module_function

      def call(kind, file, text: nil, semantic: false)
        kind = kind.to_s
        merged = nil
        result = nil
        begin
          merged = merged_result(kind, file, text)
        rescue Document::ParseError
          merged = nil
        end
        result = merged[:result] if merged
        result ||= validated(kind, file, text)
        result = with_semantics(result, kind, file, text, merged && merged[:data])
        data = merged ? merged[:data] : load_data(file, text)
        resolved = kind == "auto" ? Schema.kind_for(data).to_s : kind
        warnings = []
        semantics = nil
        if result.ok && Description::KINDS.include?(resolved) && data.is_a?(Hash)
          warnings = Description.warnings(data, resolved)
          semantics = Description.semantic(data, resolved) if semantic
        end
        Outcome.new(result, data, resolved, warnings, semantics)
      rescue Document::ParseError
        Outcome.new(result, nil, kind, [], nil)
      end

      def load_data(file, text)
        text ? Document.parse(text, file) : Document.load(file)
      end

      def behavior_v2(kind, file, text)
        return nil unless %w[behavior auto].include?(kind)

        require_relative "../behavior"
        data = load_data(file, text)
        return nil unless Behavior.v2?(data)

        errors = Behavior.validate(data)
        Schema::Result.new(errors.empty?, Behavior::V2, errors)
      rescue Schema::Document::ParseError
        nil
      end

      def validate_text(kind, file, text)
        data = load_data(file, text)
        kind = Schema.kind_for(data) if kind.to_s == "auto"
        return Schema::Result.new(false, nil, [Schema::Error.new("/schema", "not a recognized polispec document")]) if kind.nil?

        errors = Schema.validate(kind, data)
        Schema::Result.new(errors.empty?, Schema.schema_id(kind), errors)
      rescue Document::ParseError => e
        Schema::Result.new(false, kind.to_s == "auto" ? nil : Schema.schema_id(kind), [Schema::Error.new("", e.message)])
      end

      def validated(kind, file, text)
        v2 = behavior_v2(kind, file, text)
        return v2 if v2

        result = validate_text(kind, file, text)
        return result if result.ok

        data = load_data(file, text)
        kind = Schema.kind_for(data).to_s if kind == "auto"
        parameterised = kind == "module" && data.is_a?(Hash) && data.key?("params")
        parameterised ? Schema::Result.new(true, result.schema, []) : result
      rescue Schema::Document::ParseError
        result
      end

      def merged_result(kind, file, text)
        return nil unless %w[policy auto].include?(kind)

        data = load_data(file, text)
        return nil unless data.is_a?(Hash) && data["schema"] == Schema.schema_id("policy") && !data.key?("environments")

        sibling = Environments.read_file(File.expand_path(file))
        return nil unless sibling

        errors = sibling.errors ? sibling.errors.map { |item| Schema::Error.new("/environments.yml#{item['pointer']}", item["message"]) } : []
        merged = nil
        if errors.empty?
          merged, finding = Environments.merge(data, sibling.data)
          errors = finding ? [Schema::Error.new("/environments.yml", finding["detail"])] : Schema.validate("policy", merged)
        end
        result = Schema::Result.new(errors.empty?, errors.empty? ? "#{Schema.schema_id('policy')} + environments.yml" : Schema.schema_id("policy"), errors)
        { result: result, data: merged }
      end

      def with_semantics(result, kind, file, text, merged)
        return result unless result.ok

        data = merged || load_data(file, text)
        kind = Schema.kind_for(data).to_s if kind == "auto"
        errors = semantic_errors(kind, data, file)
        errors.empty? ? result : Schema::Result.new(false, result.schema, errors)
      rescue Schema::Document::ParseError
        result
      end

      def semantic_errors(kind, data, file)
        case kind
        when "policy"
          health = Operator::Gates.health_required_errors(data).map { |message| Schema::Error.new("/environments", message) }
          unreachable = Operator::Gates.unreachable_errors(data).map { |message| Schema::Error.new("/promotion", message) }
          health + unreachable + Layers.policy_errors(data, file: file).map { |message| Schema::Error.new("/layers", message) }
        when "global", "module"
          Layers.document_errors(kind, data, file).map { |message| Schema::Error.new("/layers", message) }
        else
          []
        end
      end
    end
  end
end
