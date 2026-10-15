#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Classify
    module Registry
      DIR = File.join(LIB, "classify", "commands")

      @families = {}
      @load_errors = []
      @loaded = false

      class << self
        attr_reader :load_errors

        def register(family, klass)
          @families[family.to_s] = klass
          klass
        end

        def families
          load_families
          @families.dup
        end

        def family(name)
          load_families
          @families[name.to_s]
        end

        def load_families
          return if @loaded

          @loaded = true
          Dir.glob(File.join(DIR, "*.rb")).sort.each { |file| load_family(file) }
        end

        private

        def load_family(file)
          require file
        rescue StandardError, ScriptError => e
          @load_errors << [file, e.message]
        end
      end
    end

    autoload :Shapes, File.join(LIB, "classify", "shapes")
    autoload :Benign, File.join(LIB, "classify", "benign")

    TOOL = File.join(LIB, "classify", "tool.rb")
    @tool_loaded = false

    def self.call(tool_name, tool_input, cwd)
      if !@tool_loaded && File.file?(TOOL)
        @tool_loaded = true
        require TOOL
        return call(tool_name, tool_input, cwd)
      end
      found = Registry.families.values.flat_map { |klass| Array(klass.call(tool_name, tool_input, cwd)) }
      Shapes.annotate(found, tool_name, tool_input, cwd)
    end

    def self.benign?(tool_name, tool_input, cwd)
      Benign.benign?(tool_name, tool_input, cwd)
    end

    def self.parsed_shell?(tool_name, tool_input, cwd)
      Benign.parsed_shell?(tool_name, tool_input, cwd)
    end

    def self.positive(tool_name, tool_input, cwd)
      Benign.positive(tool_name, tool_input, cwd)
    end
  end
end
