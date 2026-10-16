#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    module Decide
      module_function

      def off?
        ENV["POLISPEC_CODE_DECIDE"].to_s == "off"
      end

      def ask(question:, options:, context:, criteria: nil)
        return nil if off?

        ports = Events.port_set
        return nil unless ports

        result = ports.decide.decide(question: question, options: options, context: context, criteria: criteria)
        return nil unless result.is_a?(Hash)

        choice = result[:choice] || result["choice"]
        probability = result[:probability] || result["probability"]
        return nil if choice.nil? || probability.nil?

        { "choice" => choice.to_s, "probability" => probability.to_f, "provider" => (result[:provider] || result["provider"]).to_s, "latency_ms" => result[:latency_ms] || result["latency_ms"] }
      rescue StandardError, NoMethodError
        nil
      end

      def available?
        return false if off?

        ports = Events.port_set
        !ports.nil? && ports != false && ports.respond_to?(:decide)
      rescue StandardError
        false
      end
    end
  end
end
