#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "support"
require_relative "../../protected_state"

module Polispec
  module Classify
    module RpluginSettings
      extend Support::Family

      NAMES = %w[rplugin].freeze
      VALUE_FLAGS = %w[--scope --plugin --file --config --home].freeze

      class << self
        def classify(cmd)
          return [] unless cmd.name == "rplugin"

          pos, = Support.split_args(cmd.args, VALUE_FLAGS)
          return [] unless pos[0] == "settings" && %w[set unset].include?(pos[1].to_s) && pos[2].to_s == "polispec"

          sub = pos[1]
          [Support.act("policy.edit", cmd.text, "path" => settings_path, "settings_change" => true, "settings_key" => pos[3], "settings_value" => (sub == "set" ? pos[4] : "(unset)"))]
        end

        def handles
          []
        end

        def settings_path
          File.join(ProtectedState.config_home, "rplugin", "polispec", "settings.yml")
        end
      end
    end

    Registry.register("rplugin_settings", RpluginSettings)
  end
end
