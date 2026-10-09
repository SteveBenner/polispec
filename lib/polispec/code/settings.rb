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
        forced = ENV[Engine::Settings.env_name(key)].to_s.strip.downcase
        return forced if options.include?(forced)

        machine = Engine::Settings.snapshot.dig("machine", key)
        options.include?(machine) ? machine : options.first
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
        forced = ENV["POLISPEC_CODE_PRE_CONTEXT"].to_s.strip.downcase
        return forced == "context" if %w[context deny].include?(forced)

        %w[claude claude-code].include?(harness.to_s)
      end
    end
  end
end
