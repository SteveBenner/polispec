#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "support"

module Polispec
  module Classify
    module Systemctl
      extend Support::Family

      NAMES = %w[systemctl service pkill killall].freeze
      CONTROL = %w[start stop restart reload try-restart reload-or-restart try-reload-or-restart condrestart force-reload kill isolate freeze thaw clean reset-failed].freeze
      CONFIG = %w[enable disable mask unmask edit set-property set-environment unset-environment import-environment daemon-reload daemon-reexec link revert preset preset-all add-wants add-requires reenable].freeze
      VALUE_OPTS = %w[-H --host -M --machine -t --type -p --property -s --signal -n --lines -o --output --job-mode --root --kill-who --kill-whom --state -T].freeze
      KILL_VALUE = %w[-u -U -g -G -P -s -t -n -o -F -e].freeze
      UNIT_SUFFIX = /\.(?:service|timer|socket|target|path|mount)\z/.freeze

      class << self
        def classify(cmd)
          return [] unless NAMES.include?(cmd.name)

          case cmd.name
          when "systemctl" then systemctl(cmd)
          when "service" then service(cmd)
          else killer(cmd)
          end
        end

        def systemctl(cmd)
          pos, = Support.split_args(cmd.args, VALUE_OPTS)
          verb = pos.shift
          verb_actions(cmd, verb, pos)
        end

        def service(cmd)
          pos, = Support.split_args(cmd.args)
          return [] if pos.length < 2

          verb_actions(cmd, pos[1], [pos[0]])
        end

        def verb_actions(cmd, verb, units)
          klass = CONTROL.include?(verb) ? "service.control" : (CONFIG.include?(verb) ? "service.config" : nil)
          return [] unless klass

          names = units.map { |unit| unit.sub(UNIT_SUFFIX, "") }
          return [Support.act(klass, cmd.text, "path" => cmd.cwd)] if names.empty? && klass == "service.config"

          names.map { |name| Support.act(klass, cmd.text, "unit" => name) }
        end

        def killer(cmd)
          pos, = Support.split_args(cmd.args.reject { |arg| arg.match?(/\A-(?:\d+|[A-Z]+)\z/) }, KILL_VALUE)
          return [] if pos.empty?

          [Support.act("service.control", cmd.text, "unit" => pos.last, "fuzzy" => true)]
        end
      end
    end

    Registry.register("systemctl", Systemctl)
  end
end
