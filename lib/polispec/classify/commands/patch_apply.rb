#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "support"
require_relative "../tool"

module Polispec
  module Classify
    module PatchApply
      extend Support::Family

      NAMES = %w[apply_patch applypatch].freeze
      HEADER = /^\s*\*\*\* (?:Update|Add|Delete) File:/.freeze

      class << self
        def classify(cmd)
          bodies(cmd).flat_map do |body|
            Tool.call(cmd.name, { "input" => body }, cmd.cwd).map do |action|
              action.raw = cmd.text
              action
            end
          end
        end

        def bodies(cmd)
          found = cmd.redirects.select(&:here?).map { |redirect| redirect.op == "<<<" ? redirect.target : redirect.body }
          found += cmd.args.map(&:to_s)
          found.compact.map(&:to_s).select { |body| HEADER.match?(body) }
        end
      end
    end

    Registry.register("patch_apply", PatchApply)
  end
end
