#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Schema
    module Document
      class ParseError < Polispec::Error; end

      module_function

      def load(path)
        text = File.read(path)
        parse(text, path)
      rescue SystemCallError => e
        raise ParseError, "cannot read #{path}: #{e.message}"
      end

      def parse(text, label = "document")
        normalize(YAML.safe_load(text, permitted_classes: [Date, Time], aliases: false))
      rescue Psych::Exception => e
        raise ParseError, "#{label}: #{e.message}"
      end

      def normalize(value)
        case value
        when Hash then value.each_with_object({}) { |(key, item), memo| memo[key.to_s] = normalize(item) }
        when Array then value.map { |item| normalize(item) }
        when Time then value.utc.iso8601
        when Date then value.iso8601
        else value
        end
      end
    end
  end
end
