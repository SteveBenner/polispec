#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    class Validator
      Problem = Struct.new(:rule, :spec, :policy, :message) do
        def to_h
          { "rule" => rule, "spec" => spec, "policy" => policy, "message" => message }
        end

        def to_s
          "[#{rule}] #{spec}#{policy ? " #{policy}" : ''}: #{message}"
        end
      end

      def initialize(pack)
        @pack = pack
        @problems = []
      end

      def call
        load_errors
        schema
        layout
        id_prefix
        execution
        rejected
        refs
        unique_ids
        paths
        opcodes
        @problems
      end

      private

      def add(rule, spec, policy, message)
        @problems << Problem.new(rule, spec, policy, message)
      end

      def load_errors
        @pack.load_errors.each { |file, message| add("schema", file, nil, message) }
      end

      def schema
        @pack.specs.each_value do |spec|
          Schema.validate("spec", spec.data).each { |error| add("schema", spec.path, nil, "#{error.pointer.empty? ? '/' : error.pointer} #{error.message}") }
        end
        text = @pack.read("specs/polispec/code-waivers.yml")
        return unless text

        data = Schema::Document.parse(text, "code-waivers.yml")
        Schema.validate("waivers", data).each { |error| add("schema", "code-waivers.yml", nil, "#{error.pointer} #{error.message}") }
      rescue Schema::Document::ParseError => e
        add("schema", "code-waivers.yml", nil, e.message)
      end

      def layout
        @pack.specs.each_value do |spec|
          add("layout", spec.path, nil, "spec field is #{spec.data['spec'].inspect} but the file lives at #{spec.file}") unless spec.data["spec"] == spec.path
          parent = spec.parent_path
          add("layout", spec.path, nil, "parent #{parent} does not exist") if parent && !@pack.specs.key?(parent)
        end
      end

      def id_prefix
        @pack.nodes.each_value do |node|
          prefix = "#{node.spec.tr('/', '.')}."
          add("1", node.spec, node.id, "policy id must start with #{prefix}") unless node.id.start_with?(prefix)
        end
      end

      def execution
        @pack.rules.each do |rule|
          next unless rule.lifecycle == "active"

          klass = rule.klass
          if %w[harness hybrid].include?(klass)
            add("2", rule.spec, rule.id, "active #{klass} rule requires execution.enforcer") unless rule.enforcer
            add("2", rule.spec, rule.id, "active #{klass} rule requires control") unless rule.control
          end
          add("3", rule.spec, rule.id, "#{klass} rule requires execution.lens") if %w[agent hybrid contextual].include?(klass) && !rule.lens
          add("3", rule.spec, rule.id, "contextual rule requires execution.applies_if") if klass == "contextual" && !rule.applies_if
        end
      end

      def rejected
        @pack.rules.each do |rule|
          add("4", rule.spec, rule.id, "lifecycle rejected requires rejected:") if rule.lifecycle == "rejected" && !rule.data["rejected"].is_a?(Hash)
        end
      end

      def refs
        edges = Hash.new { |hash, key| hash[key] = [] }
        @pack.specs.each_value do |spec|
          next unless spec.root

          spec.root.each_node do |node|
            node.items.each do |kind, item|
              next unless kind == :ref

              unless @pack.specs.key?(item) || @pack.nodes.key?(item)
                add("5", spec.path, node.id, "ref #{item} resolves to no spec path or policy id")
                next
              end
              edges[node_key(node)] << (@pack.specs.key?(item) ? "spec:#{item}" : "node:#{item}")
            end
            node.items.each { |kind, item| edges[node_key(node)] << node_key(item) if kind == :node }
          end
          edges["spec:#{spec.path}"] << node_key(spec.root)
        end
        cycle = find_cycle(edges)
        add("5", cycle.first, nil, "ref cycle: #{cycle.join(' -> ')}") if cycle
      end

      def node_key(node)
        "node:#{node.id}"
      end

      def find_cycle(edges)
        state = {}
        stack = []
        visit = lambda do |key|
          state[key] = :open
          stack << key
          edges[key].each do |target|
            if state[target] == :open
              return stack[stack.index(target)..-1] + [target]
            elsif state[target].nil?
              found = visit.call(target)
              return found if found
            end
          end
          stack.pop
          state[key] = :done
          nil
        end
        edges.keys.each do |key|
          next if state[key]

          found = visit.call(key)
          return found if found
        end
        nil
      end

      def unique_ids
        @pack.duplicates.each { |id, first, second| add("6", second, id, "id already defined in spec #{first}") }
      end

      def paths
        @pack.rules.each do |rule|
          control = rule.control
          if control
            fixture = fixture_path(rule, control["fixture"])
            add("7", rule.spec, rule.id, "control fixture #{control['fixture']} does not exist") unless fixture
            if control["compliant"]
              add("7", rule.spec, rule.id, "compliant file #{control['compliant']} does not exist") unless fixture_path(rule, control["compliant"])
            end
          end
          body = rule.data.dig("directive", "body")
          add("7", rule.spec, rule.id, "directive body #{body} does not exist") if body && !@pack.exist?(body)
          exemplars = rule.data["exemplars"]
          next unless exemplars.is_a?(Hash)

          %w[good bad].each do |kind|
            Array(exemplars[kind]).each { |file| add("7", rule.spec, rule.id, "exemplar #{file} does not exist") unless fixture_path(rule, file) }
          end
        end
      end

      def fixture_path(rule, file)
        [file, File.join("controls", rule.spec, file.to_s)].find { |candidate| @pack.exist?(candidate) }
      end

      def opcodes
        seen = {}
        @pack.rules.each do |rule|
          directive = rule.data["directive"]
          next unless directive.is_a?(Hash)

          opcode = directive["opcode"]
          add("8", rule.spec, rule.id, "directive opcode #{opcode} already used by #{seen[opcode]}") if seen.key?(opcode)
          seen[opcode] ||= rule.id
        end
      end
    end
  end
end
