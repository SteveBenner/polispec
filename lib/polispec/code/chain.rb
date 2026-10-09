#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    class Chain
      attr_reader :pack, :language, :specs, :rules, :digest

      def self.for(pack, language)
        new(pack, language)
      end

      def initialize(pack, language)
        @pack = pack
        @language = language.to_s
        @specs = []
        @rules = []
        build
        @digest = pack.digest_for(@specs.map(&:path))
      end

      def spec_paths
        specs.map(&:path)
      end

      def rules_of(spec)
        rules.select { |rule| rule.spec == spec.path }
      end

      def rules_for_path(relative)
        rules.select { |rule| path_in_scope?(rule, relative) }
      end

      def path_in_scope?(rule, relative)
        scope = rule.effective_scope
        paths = Array(scope["paths"])
        return false if Array(scope["exclude"]).any? { |glob| glob_match?(glob, relative) }
        return paths.any? { |glob| glob_match?(glob, relative) } unless paths.empty?

        Array(pack.inherited_defaults(rule.spec)["exclude"]).none? { |glob| glob_match?(glob, relative) }
      end

      def glob_match?(glob, relative)
        flags = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
        File.fnmatch?(glob, relative, flags) || File.fnmatch?("**/#{glob}", relative, flags)
      end

      private

      def build
        roots = pack.specs.values.select { |spec| spec.languages.include?("*") || spec.languages.include?(language) }
        roots.sort_by { |spec| [spec.depth, spec.path] }.each { |spec| visit(spec) }
        seen = Set.new
        @specs.each do |spec|
          collect(spec, spec.root, seen) if spec.root
        end
      end

      def visit(spec)
        return if @specs.include?(spec)

        @specs << spec
        spec.refs.each do |ref|
          target = pack.specs[ref]
          visit(target) if target
        end
      end

      def collect(spec, node, seen)
        node.items.each do |kind, item|
          if kind == :node
            collect(spec, item, seen)
          elsif !pack.specs.key?(item) && pack.nodes.key?(item)
            collect_node(pack.nodes[item], seen)
          end
        end
        add_rule(node, seen) if node.rule?
      end

      def collect_node(node, seen)
        if node.rule?
          add_rule(node, seen)
        else
          node.items.each { |kind, item| collect_node(item, seen) if kind == :node }
        end
      end

      def add_rule(node, seen)
        return if seen.include?(node.id)
        return unless node.active?
        return unless language_in_scope?(node)

        seen << node.id
        @rules << node
      end

      def language_in_scope?(node)
        languages = Array(node.effective_scope["languages"])
        languages.empty? || languages.include?("*") || languages.include?(language)
      end
    end
  end
end
