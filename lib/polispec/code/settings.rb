#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    module Settings
      OPTIONS = {
        "polispec.code.enforce" => %w[tiered advise],
        "polispec.code.check_at" => %w[pre_write post_write],
        "polispec.code.inject" => %w[once every_write]
      }.freeze

      module_function

      def value(key)
        options = OPTIONS.fetch(key)
        require_relative "../harness_controls/plane"
        if defined?(HarnessControls::Plane) && HarnessControls::Plane.respond_to?(:resolve)
          plane = HarnessControls::Plane.resolve
          raise Polispec::Error, "sealed authority is broken" if plane["status"] == "broken"
          if plane["status"] == "active"
            protected_value = plane.dig("settings", key)
            return options.include?(protected_value) ? protected_value : options.first
          end
        end
        found = Engine::Settings.lookup(key) { |raw| options.include?(raw.is_a?(String) ? raw.downcase : raw) }
        found = found.downcase if found.is_a?(String)
        options.include?(found) ? found : options.first
      end

      def enforce
        value("polispec.code.enforce")
      end

      def check_at
        value("polispec.code.check_at")
      end

      def inject
        value("polispec.code.inject")
      end

      def tiered?
        enforce == "tiered"
      end

      def context_on_pre?(harness)
        require_relative "../harness_controls/plane"
        if defined?(HarnessControls::Plane) && HarnessControls::Plane.respond_to?(:resolve)
          plane = HarnessControls::Plane.resolve
          raise Polispec::Error, "sealed authority is broken" if plane["status"] == "broken"
          if plane["status"] == "active"
            value = plane.dig("settings", "polispec.code.pre_context").to_s
            return value == "context" if %w[context deny].include?(value)
            return %w[claude claude-code].include?(harness.to_s)
          end
        end
        forced = ENV["POLISPEC_CODE_PRE_CONTEXT"].to_s.strip.downcase
        return forced == "context" if %w[context deny].include?(forced)

        %w[claude claude-code].include?(harness.to_s)
      end
    end
  end
end
