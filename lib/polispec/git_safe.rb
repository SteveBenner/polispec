#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

module Polispec
  module GitSafe
    OPEN = %w[-c core.fsmonitor=false -c core.untrackedCache=false].freeze
    CONFIG = (OPEN + %w[-c safe.bareRepository=explicit]).freeze
    CLEARED = %w[GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_PARAMETERS GIT_EXTERNAL_DIFF].freeze
    CONFIG_ENV = {
      "GIT_CONFIG_COUNT" => "2",
      "GIT_CONFIG_KEY_0" => "core.fsmonitor", "GIT_CONFIG_VALUE_0" => "false",
      "GIT_CONFIG_KEY_1" => "core.untrackedCache", "GIT_CONFIG_VALUE_1" => "false"
    }.freeze

    module_function

    def argv(dir, *args)
      ["git", *CONFIG, "-C", dir.to_s, *args]
    end

    def argv_bare(*args)
      ["git", *OPEN, *args]
    end

    def env(extra = {})
      CLEARED.to_h { |name| [name, nil] }.merge("GIT_OPTIONAL_LOCKS" => "0").merge(extra)
    end
  end
end
