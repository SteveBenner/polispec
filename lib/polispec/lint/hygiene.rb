#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "psych"

module Polispec
  module Lint
    module Hygiene
      BOM = "﻿".freeze
      BOOLEAN_WORD = /\A(yes|no|on|off)\z/i
      TAB_INDENT = /\A[ \t]*\t/
      TAB_AFTER_INDICATOR = /(?:\A|[ ])-\t|:\t/
      TRAILING_SPACE = /[ \t]+\z/
      SCANNER_CLASSES = %w[Date Time].freeze

      module_function

      def check(text, path:, format:, allow: [])
        findings =
          case format
          when :json then json_findings(text, path)
          when :text then text_findings(text, path)
          else yaml_findings(text, path)
          end
        findings.reject { |finding| allow.include?(finding.code) }
      end

      def finding(severity, code, path, line, message, pointer = nil)
        Finding.new(severity, "hygiene", code, path, line, pointer, message, nil)
      end

      def line_count(text)
        text.empty? ? 1 : text.count("\n") + (text.end_with?("\n") ? 0 : 1)
      end

      def yaml_findings(raw, path)
        text = raw.dup.force_encoding("UTF-8")
        return [finding("error", "yaml_syntax", path, nil, "not valid UTF-8")] unless text.valid_encoding?

        out = []
        if text.start_with?(BOM)
          out << finding("warn", "yaml_bom", path, 1, "the file starts with a byte order mark")
          text = text.sub(BOM, "")
        end
        crlf = text.scan("\r\n").length
        if crlf.positive?
          first = text.index("\r\n")
          out << finding("warn", "yaml_crlf", path, text[0, first].count("\n") + 1, "#{crlf} #{crlf == 1 ? 'line ends' : 'lines end'} in CRLF")
        end
        out << finding("warn", "yaml_no_final_newline", path, line_count(text), "the file does not end in a newline") if !text.empty? && !text.end_with?("\n")
        stream = begin
          Psych.parse_stream(text)
        rescue Psych::SyntaxError => e
          out << finding("error", "yaml_syntax", path, e.line, syntax_message(e))
          return out
        end
        if stream.children.length > 1
          out << finding("error", "yaml_multiple_documents", path, stream.children[1].start_line + 1, "the loader reads only the first document")
        end
        blocks = []
        stream.children.each { |document| walk(document, [], path, out, blocks, true) }
        out.concat(text_line_findings(text, path, blocks))
        out
      end

      def syntax_message(error)
        message = [error.problem, error.context].compact.join(" ")
        message.empty? ? "invalid YAML" : message
      end

      def scanner
        @scanner ||= Psych::ScalarScanner.new(Psych::ClassLoader::Restricted.new(SCANNER_CLASSES, []))
      end

      def key_value(node)
        return node.value unless node.plain

        scanner.tokenize(node.value)
      rescue StandardError
        node.value
      end

      def key_string(node)
        key_value(node).to_s
      end

      def pointer_for(path)
        path.map { |part| part.to_s.gsub("~", "~0").gsub("/", "~1") }.map { |part| "/#{part}" }.join
      end

      def kind_word(value)
        case value
        when true, false then "a boolean"
        when nil then "null"
        when Integer, Float then "a number"
        else "a date"
        end
      end

      def walk(node, path, file, out, blocks, yaml)
        if yaml
          if node.is_a?(Psych::Nodes::Alias) || (node.respond_to?(:anchor) && node.anchor)
            out << finding("error", "yaml_alias", file, node.start_line + 1, "anchors and aliases are refused by the loader")
          end
        end
        case node
        when Psych::Nodes::Mapping
          walk_mapping(node, path, file, out, blocks, yaml)
        when Psych::Nodes::Sequence
          node.children.each_with_index { |child, index| walk(child, path + [index], file, out, blocks, yaml) }
        when Psych::Nodes::Scalar
          scalar_value(node, file, out, blocks) if yaml
        when Psych::Nodes::Document
          node.children.each { |child| walk(child, path, file, out, blocks, yaml) }
        end
      end

      def scalar_value(node, file, out, blocks)
        if [Psych::Nodes::Scalar::LITERAL, Psych::Nodes::Scalar::FOLDED].include?(node.style)
          last = node.end_column.zero? ? node.end_line - 1 : node.end_line
          blocks << [node.start_line + 2, last + 1] if last > node.start_line
        elsif node.plain && BOOLEAN_WORD.match?(node.value)
          out << finding("warn", "yaml_bool_word", file, node.start_line + 1, "plain #{node.value} reads as a boolean; quote it to keep the string")
        end
      end

      def walk_mapping(node, path, file, out, blocks, yaml)
        seen = {}
        pairs = node.children.each_slice(2).to_a
        pairs.each do |key, value|
          if key.is_a?(Psych::Nodes::Scalar)
            name = key_string(key)
            line = key.start_line + 1
            if seen.key?(name)
              out << finding("error", yaml ? "yaml_duplicate_key" : "json_duplicate_key", file, line, "key #{name} repeats the one at line #{seen[name]}; the loader keeps the last", pointer_for(path))
            else
              seen[name] = line
            end
            if yaml && key.plain
              typed = key_value(key)
              out << finding("warn", "yaml_non_string_key", file, line, "key #{key.value} reads as #{kind_word(typed)} and the loader turns it into a string") unless typed.is_a?(String)
            end
          else
            walk(key, path, file, out, blocks, yaml)
          end
          child_path = key.is_a?(Psych::Nodes::Scalar) ? path + [key_string(key)] : path + [""]
          walk(value, child_path, file, out, blocks, yaml)
        end
      end

      def text_line_findings(text, path, blocks)
        tabs = []
        trailing = []
        text.each_line.with_index(1) do |line, number|
          next if blocks.any? { |from, to| number >= from && number <= to }

          body = line.chomp
          tabs << number if TAB_INDENT.match?(body) || TAB_AFTER_INDICATOR.match?(body)
          trailing << number if TRAILING_SPACE.match?(body)
        end
        out = []
        out << finding("warn", "yaml_tab", path, tabs.first, "#{tabs.length} #{tabs.length == 1 ? 'line contains' : 'lines contain'} a tab used for indentation or after an indicator") unless tabs.empty?
        out << finding("warn", "yaml_trailing_space", path, trailing.first, "#{trailing.length} #{trailing.length == 1 ? 'line has' : 'lines have'} trailing whitespace") unless trailing.empty?
        out
      end

      def json_findings(raw, path)
        text = raw.dup.force_encoding("UTF-8")
        return [finding("error", "json_syntax", path, nil, "not valid UTF-8")] unless text.valid_encoding?

        begin
          JSON.parse(text)
        rescue JSON::ParserError => e
          found = e.message[/line (\d+)/, 1]
          return [finding("error", "json_syntax", path, found && found.to_i, e.message.lines.first.to_s.strip[0, 160])]
        end
        stream = begin
          Psych.parse_stream(text)
        rescue Psych::SyntaxError
          return []
        end
        out = []
        stream.children.each { |document| walk(document, [], path, out, [], false) }
        out
      end

      def text_findings(raw, path)
        text = raw.dup.force_encoding("UTF-8")
        return [finding("error", "text_invalid", path, nil, "not valid UTF-8")] unless text.valid_encoding?

        out = []
        out << finding("error", "text_invalid", path, text[0, text.index("\0")].count("\n") + 1, "the text contains a NUL byte") if text.include?("\0")
        out << finding("warn", "text_final_newline", path, line_count(text), "the text must end in a newline") if text.empty? || !text.end_with?("\n")
        out
      end
    end
  end
end
