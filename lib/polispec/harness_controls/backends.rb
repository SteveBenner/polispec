#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module HarnessControls
    module Backends
      DIRECTORY = File.join(LIB, "harness_controls", "backends")

      class UnavailableBackend
        def initialize(name)
          @name = name
        end

        %i[plan normalize render probe].each do |operation|
          define_method(operation) do |*|
            raise Unavailable.new(operation, "backend #{@name}")
          end
        end
      end

      module_function

      def register(name, backend)
        registry[name.to_s] = backend
      end

      def fetch(name)
        load_all
        return registry[name.to_s] if registry.key?(name.to_s)
        return UnavailableBackend.new(name.to_s) if known_names.include?(name.to_s)

        raise Polispec::Error, "unknown harness backend #{name}"
      end

      def names
        load_all
        (known_names + registry.keys).uniq.sort
      end

      def load_all
        return if @loaded

        @loaded = true
        Dir.glob(File.join(DIRECTORY, "*.rb")).sort.each { |path| require path }
      end

      def registry
        @registry ||= {}
      end

      def known_names
        @known_names ||= begin
          data = YAML.safe_load(File.read(File.join(ROOT, "data", "harness-capabilities.yml")), aliases: false) || {}
          Array(data["harnesses"]).each_with_object([]) do |entry, names|
            name = entry["harness"] if entry.is_a?(Hash)
            names << name if name
          end.uniq
        rescue SystemCallError, Psych::Exception
          []
        end
      end
      private_class_method :registry, :known_names
    end
  end
end
