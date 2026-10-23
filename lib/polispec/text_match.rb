#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "predicates"

module Polispec
  module TextMatch
    KEY = "text_matches".freeze
    TIMEOUT = 0.25
    TIMEOUT_SUPPORTED = Regexp.respond_to?(:timeout)
    COMPILED = {}

    module_function

    def holds?(match, action, ctx)
      return true unless match.key?(KEY)

      source = match[KEY]
      text = Predicates.hint(action)["text"]
      return false unless source.is_a?(String) && text.is_a?(String)

      regexp = compile(source)
      if regexp.is_a?(String)
        Predicates.record(Predicates::Result.new(false, nil, "#{KEY}: #{regexp}"), ctx)
        return false
      end
      regexp.match?(text)
    rescue StandardError => e
      Predicates.record(Predicates::Result.new(false, nil, "#{KEY}: #{e.message}"), ctx)
      false
    end

    def compile(source)
      COMPILED[source] ||= build(source)
    end

    def build(source)
      TIMEOUT_SUPPORTED ? Regexp.new(source, timeout: TIMEOUT) : Regexp.new(source)
    rescue StandardError => e
      e.message
    end

    def source_errors(data)
      errors = []
      walk(data, "", errors)
      errors
    end

    def walk(node, pointer, errors)
      case node
      when Hash
        match = node["match"]
        if match.is_a?(Hash) && match[KEY].is_a?(String)
          reason = build(match[KEY])
          if reason.is_a?(String)
            errors << Schema::Error.new("#{pointer}/match/#{KEY}", "rule #{node['id'] || '(no id)'}: #{KEY} does not compile: #{reason}")
          end
        end
        node.each { |key, value| walk(value, "#{pointer}/#{key}", errors) if value.is_a?(Hash) || value.is_a?(Array) }
      when Array
        node.each_with_index { |value, index| walk(value, "#{pointer}/#{index}", errors) if value.is_a?(Hash) || value.is_a?(Array) }
      end
    end
  end
end
