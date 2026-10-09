#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "document"
require_relative "validator"

module Polispec
  module Schema
    KINDS = %w[policy environments roster ledger behavior spec waivers].freeze
    DIR = File.join(ROOT, "schemas")
    Result = Struct.new(:ok, :schema, :errors) do
      def to_h
        { "ok" => ok, "schema" => schema, "errors" => errors.map(&:to_h) }
      end
    end

    module_function

    def kinds
      KINDS
    end

    def schema_id(kind)
      "polispec.#{kind}/v1"
    end

    def kind_for(data)
      id = data.is_a?(Hash) ? data["schema"] : nil
      KINDS.find { |kind| schema_id(kind) == id }
    end

    def definition(kind)
      @definitions ||= {}
      @definitions[kind.to_s] ||= Document.load(File.join(DIR, "#{kind}.v1.yml"))
    end

    def validate(kind, data)
      kind = kind.to_s
      return [Error.new("", "unknown schema kind #{kind}")] unless KINDS.include?(kind)

      errors = Validator.new(definition(kind)).call(data)
      if kind == "behavior" && errors.empty?
        require_relative "../behavior"
        errors.concat(Behavior.semantic_errors(data))
      end
      errors
    end

    def validate_file(kind, path)
      data = Document.load(path)
      kind = kind_for(data) if kind.to_s == "auto"
      return Result.new(false, nil, [Error.new("/schema", "not a recognized polispec document")]) if kind.nil?

      errors = validate(kind, data)
      Result.new(errors.empty?, schema_id(kind), errors)
    rescue Document::ParseError => e
      Result.new(false, kind.to_s == "auto" ? nil : schema_id(kind), [Error.new("", e.message)])
    end
  end
end
