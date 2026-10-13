#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Controls
    module_function

    def parse(text)
      dispatch(:parse, text)
    end

    def validate(data)
      dispatch(:validate, data)
    end

    def monotonic(current, proposed, actor)
      dispatch(:monotonic, current, proposed, actor)
    end

    def evaluate(input, context)
      dispatch(:evaluate, input, context)
    end

    def dispatch(operation, *args)
      implementation = implementation_for(operation)
      return implementation.public_send(operation, *args) if implementation

      raise HarnessControls::Unavailable.new(operation, "controls")
    end

    def implementation_for(operation)
      load_implementation(operation)
      candidates = case operation
                   when :parse, :validate then [:Language]
                   when :monotonic then [:Monotonicity]
                   when :evaluate then [:Guard]
                   end
      candidates&.each do |name|
        candidate = HarnessControls.const_get(name, false) if HarnessControls.const_defined?(name, false)
        return candidate if candidate&.respond_to?(operation)
      end
      nil
    end

    def load_implementation(operation)
      path = {
        parse: "language",
        validate: "language",
        monotonic: "monotonicity",
        evaluate: "evaluate"
      }[operation]
      return unless path

      file = File.join(LIB, "harness_controls", "#{path}.rb")
      require file if File.file?(file)
    end
    private_class_method :dispatch, :implementation_for, :load_implementation
  end
end
