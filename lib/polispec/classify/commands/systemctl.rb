#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "support"

module Polispec
  module Classify
    module Systemctl
      extend Support::Family

      NAMES = %w[systemctl service pkill killall busctl kill dbus-send].freeze
      CLAIMED = %w[systemctl service pkill killall].freeze
      BUS_METHODS = %w[StopUnit RestartUnit KillUnit].freeze
      INIT_SCRIPT = %r{\A/etc/(?:rc\.d/)?init\.d/([^/]+)\z}.freeze
      INIT_VERBS = %w[start stop restart reload force-reload try-restart condrestart force-stop].freeze
      FED_UNIT = /(?:\$\(|`)\s*(?:pidof|pgrep)(?:\s+-\S+)*\s+([^\s)`]+)/.freeze
      CONTROL = %w[start stop restart reload try-restart reload-or-restart try-reload-or-restart condrestart force-reload kill isolate freeze thaw clean reset-failed].freeze
      CONFIG = %w[enable disable mask unmask edit set-property set-environment unset-environment import-environment daemon-reload daemon-reexec link revert preset preset-all add-wants add-requires reenable].freeze
      VALUE_OPTS = %w[-H --host -M --machine -t --type -p --property -s --signal -n --lines -o --output --job-mode --root --kill-who --kill-whom --state -T --message --what --reason].freeze
      KILL_VALUE = %w[-u -U -g -G -P -s -t -n -o -F -e].freeze
      UNIT_SUFFIX = /\.(?:service|timer|socket|target|path|mount)\z/.freeze

      class << self
        def handles
          CLAIMED
        end

        def classify(cmd)
          return init_script(cmd) if INIT_SCRIPT.match?(cmd.argv.first.to_s)
          return [] unless NAMES.include?(cmd.name)

          case cmd.name
          when "systemctl" then systemctl(cmd)
          when "service" then service(cmd)
          when "busctl" then busctl(cmd)
          when "dbus-send" then dbus_send(cmd)
          when "kill" then kill_fed(cmd)
          else killer(cmd)
          end
        end

        def kill_fed(cmd)
          names = cmd.args.flat_map { |arg| arg.to_s.scan(FED_UNIT).flatten }
          names += cmd.upstream.select { |up| %w[pidof pgrep].include?(up.name) }.flat_map { |up| Support.split_args(up.args).first } if cmd.xargs
          names.reject(&:empty?).map { |name| Support.act("service.control", cmd.text, "unit" => name, "fuzzy" => true, "command" => "kill") }
        end

        def init_script(cmd)
          unit = INIT_SCRIPT.match(cmd.argv.first.to_s)[1]
          verb = cmd.args.first.to_s
          INIT_VERBS.include?(verb) ? [Support.act("service.control", cmd.text, "unit" => unit.sub(UNIT_SUFFIX, ""))] : []
        end

        def dbus_send(cmd)
          args = cmd.args.map(&:to_s)
          at = args.index { |arg| BUS_METHODS.include?(arg.split(".").last) }
          return [] unless at

          unit = args.drop(at + 1).find { |arg| arg.start_with?("string:") }
          unit ? [Support.act("service.control", cmd.text, "unit" => unit.delete_prefix("string:").sub(UNIT_SUFFIX, ""))] : []
        end

        def busctl(cmd)
          args = cmd.args.map(&:to_s)
          at = args.index { |arg| BUS_METHODS.include?(arg) }
          return [] unless args.first == "call" && at

          unit = args[at + 2]
          unit ? [Support.act("service.control", cmd.text, "unit" => unit.sub(UNIT_SUFFIX, ""))] : []
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

          hints = { "unit" => pos.last, "fuzzy" => true }
          hints["regexp"] = true if cmd.name == "pkill" || (cmd.name == "killall" && cmd.args.any? { |arg| arg == "-r" || arg == "--regexp" })
          [Support.act("service.control", cmd.text, hints)]
        end
      end
    end

    Registry.register("systemctl", Systemctl)
  end
end
