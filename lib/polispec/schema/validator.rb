#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Schema
    Error = Struct.new(:pointer, :message) do
      def to_h
        { "pointer" => pointer, "message" => message }
      end
    end

    class Validator
      TYPES = {
        "null" => ->(v) { v.nil? },
        "string" => ->(v) { v.is_a?(String) },
        "integer" => ->(v) { v.is_a?(Integer) },
        "number" => ->(v) { v.is_a?(Numeric) },
        "boolean" => ->(v) { v == true || v == false },
        "object" => ->(v) { v.is_a?(Hash) },
        "array" => ->(v) { v.is_a?(Array) }
      }.freeze

      def initialize(schema)
        @root = schema
      end

      def call(data)
        errors = []
        visit(@root, data, "", errors)
        errors
      end

      private

      def visit(schema, value, pointer, errors)
        schema = deref(schema)
        return unless schema.is_a?(Hash)
        return unless check_type(schema, value, pointer, errors)

        check_value(schema, value, pointer, errors)
        check_combinators(schema, value, pointer, errors)
        visit_children(schema, value, pointer, errors)
      end

      def deref(schema)
        return schema unless schema.is_a?(Hash) && schema.key?("$ref")

        target = schema["$ref"].to_s.sub(%r{\A#/}, "").split("/").reduce(@root) do |node, key|
          node.is_a?(Hash) ? node[key] : nil
        end
        deref(target)
      end

      def check_type(schema, value, pointer, errors)
        return true unless schema.key?("type")

        names = Array(schema["type"])
        return true if names.any? { |name| TYPES.fetch(name).call(value) }

        errors << Error.new(pointer, "must be #{names.join(' or ')}, got #{describe(value)}")
        false
      end

      def describe(value)
        return "null" if value.nil?
        return "boolean" if value == true || value == false

        { Hash => "object", Array => "array", String => "string", Integer => "integer", Float => "number" }.fetch(value.class, value.class.name.to_s.downcase)
      end

      def check_value(schema, value, pointer, errors)
        check_const(schema, value, pointer, errors)
        check_enum(schema, value, pointer, errors)
        check_string(schema, value, pointer, errors) if value.is_a?(String)
        check_number(schema, value, pointer, errors) if value.is_a?(Numeric)
        check_array_size(schema, value, pointer, errors) if value.is_a?(Array)
      end

      def check_const(schema, value, pointer, errors)
        return unless schema.key?("const") && value != schema["const"]

        errors << Error.new(pointer, "must equal #{schema['const'].inspect}")
      end

      def check_enum(schema, value, pointer, errors)
        return unless schema.key?("enum") && !schema["enum"].include?(value)

        errors << Error.new(pointer, "must be one of #{schema['enum'].join(', ')}")
      end

      def check_string(schema, value, pointer, errors)
        if schema["minLength"] && value.length < schema["minLength"]
          errors << Error.new(pointer, "must be at least #{schema['minLength']} characters")
        end
        return unless schema["pattern"] && !Regexp.new(schema["pattern"]).match?(value)

        errors << Error.new(pointer, "must match #{schema['pattern']}")
      end

      def check_number(schema, value, pointer, errors)
        errors << Error.new(pointer, "must be at least #{schema['minimum']}") if schema["minimum"] && value < schema["minimum"]
        errors << Error.new(pointer, "must be at most #{schema['maximum']}") if schema["maximum"] && value > schema["maximum"]
      end

      def check_array_size(schema, value, pointer, errors)
        return unless schema["minItems"] && value.length < schema["minItems"]

        errors << Error.new(pointer, "must have at least #{schema['minItems']} items")
      end

      def check_combinators(schema, value, pointer, errors)
        any = schema["anyOf"]
        errors << Error.new(pointer, "must match at least one allowed form") if any && none_match?(any, value)
        one = schema["oneOf"]
        errors << Error.new(pointer, "must match exactly one allowed form") if one && one.count { |sub| matches?(sub, value) } != 1
      end

      def none_match?(subschemas, value)
        subschemas.none? { |sub| matches?(sub, value) }
      end

      def matches?(schema, value)
        found = []
        visit(schema, value, "", found)
        found.empty?
      end

      def visit_children(schema, value, pointer, errors)
        visit_object(schema, value, pointer, errors) if value.is_a?(Hash)
        return unless value.is_a?(Array) && schema["items"]

        value.each_with_index { |item, index| visit(schema["items"], item, "#{pointer}/#{index}", errors) }
      end

      def visit_object(schema, value, pointer, errors)
        Array(schema["required"]).each do |key|
          errors << Error.new(child(pointer, key), "required key is missing") unless value.key?(key)
        end
        properties = schema["properties"] || {}
        properties.each { |key, sub| visit(sub, value[key], child(pointer, key), errors) if value.key?(key) }
        visit_extras(schema["additionalProperties"], value.reject { |key, _| properties.key?(key) }, pointer, errors)
      end

      def visit_extras(rule, extras, pointer, errors)
        return if rule.nil? || rule == true

        extras.each do |key, item|
          if rule == false
            errors << Error.new(child(pointer, key), "unknown key")
          else
            visit(rule, item, child(pointer, key), errors)
          end
        end
      end

      def child(pointer, key)
        "#{pointer}/#{key.to_s.gsub('~', '~0').gsub('/', '~1')}"
      end
    end
  end
end
