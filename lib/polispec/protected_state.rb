#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "state"
require_relative "native_settings"
require_relative "native_pin"
require_relative "stewardship"
require_relative "runtime"
require_relative "exceptions"

module Polispec
  module ProtectedState
    module_function

    def paths(ledger)
      list = [entry { State.home }]
      list << entry { ledger.pauses_log } if ledger.respond_to?(:pauses_log)
      list << entry { ledger.allow_once_log } if ledger.respond_to?(:allow_once_log)
      list << entry { NativeSettings.path }
      list << entry { File.join(config_home, "rplugin", "polispec", "settings.yml") }
      list << entry { File.join(state_base, "rplugin", "polispec", "settings.resolved.json") }
      list.concat(launcher_paths)
      list.compact.map { |item| File.expand_path(item) }.uniq
    end

    def launcher_paths
      found = []
      found.concat(entries { Dir.glob(File.join(Stewardship.claude_home, "plugins", "cache", "*", "polispec")) })
      found << entry { Stewardship.store_link }
      stored = entry { Stewardship.stored_root }
      if stored
        found << stored
        parent = File.dirname(stored)
        found << parent if File.basename(parent) == "polispec"
      end
      found << entry { NativePin.current_link }
      found << entry { NativePin.releases_dir }
      found << entry { File.join(bin_home, "polispec") }
      found << entry { Runtime.root unless Runtime.kind == "clone" }
      found.compact.map { |item| File.expand_path(item) }.uniq
    end

    def needles(ledger)
      extra = [entry { ledger&.path }, entry { Exceptions.path }].compact
      (paths(ledger) + extra + ["polispec"]).map { |item| item.to_s.downcase }.reject(&:empty?).uniq
    end

    def config_home
      base = ENV["XDG_CONFIG_HOME"].to_s
      base.empty? ? File.join(Dir.home, ".config") : base
    end

    def state_base
      base = ENV["XDG_STATE_HOME"].to_s
      base.empty? ? File.join(Dir.home, ".local", "state") : base
    end

    def bin_home
      base = ENV["RPLUGIN_BIN_HOME"].to_s
      base.empty? ? File.join(Dir.home, ".local", "bin") : base
    end

    def entry
      value = yield
      value.nil? || value.to_s.empty? ? nil : value.to_s
    rescue StandardError
      nil
    end

    def entries
      Array(yield)
    rescue StandardError
      []
    end
  end
end
