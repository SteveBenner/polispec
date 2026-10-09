#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "shell"
require_relative "commands/support"

module Polispec
  module Classify
    module Shapes
      NAMES = %w[bulk_stage chained_release latest_flip lockfile_edit pattern_kill cargo_clean worktree_force].freeze
      LOCKFILES = %w[Cargo.lock Gemfile.lock package-lock.json pnpm-lock.yaml yarn.lock uv.lock poetry.lock].freeze
      CHAIN_CLASSES = %w[git.tag git.push release.publish promote].freeze
      PATTERN_PRODUCERS = %w[pgrep].freeze
      PKILL_FORCE = /\A-[A-Za-z0-9]*f[A-Za-z0-9]*\z/.freeze

      module_function

      def annotate(actions, tool_name, tool_input, cwd)
        script = Support.script_for(tool_name, tool_input, cwd)
        return tag_tool(actions, tool_name) unless script

        by_text = Hash.new { |hash, key| hash[key] = [] }
        hints = Hash.new { |hash, key| hash[key] = {} }
        extra = []
        script.commands.each do |cmd|
          by_text[cmd.text].concat(command_shapes(cmd))
          hints[cmd.text].merge!(command_hints(cmd))
          extra.concat(kill_actions(cmd))
        end
        chained = effective_count(script) > 1
        (actions + extra).each do |action|
          apply(action, by_text.fetch(action.raw, []).uniq, chained)
          merge_hints(action, hints.fetch(action.raw, {}))
        end
      end

      def names(action)
        Array((action.env_hint || {})["shape"]).map(&:to_s)
      end

      def command_shapes(cmd)
        found = []
        Registry.families.each_value do |family|
          found.concat(Array(family.shapes(cmd))) if family.respond_to?(:shapes)
        end
        found.concat(kill_shapes(cmd))
        found.uniq
      end

      def command_hints(cmd)
        Registry.families.each_value.with_object({}) do |family, memo|
          memo.merge!(family.hints(cmd)) if family.respond_to?(:hints)
        end
      end

      def merge_hints(action, extra)
        return if extra.empty?

        action.env_hint = action.env_hint.merge(extra)
      end

      def kill_shapes(cmd)
        case cmd.name
        when "killall" then %w[pattern_kill]
        when "pkill" then pkill_shapes(cmd)
        when "kill" then pattern_pids?(cmd) ? %w[pattern_kill] : []
        else []
        end
      end

      def pkill_shapes(cmd)
        forced = cmd.args.any? { |arg| PKILL_FORCE.match?(arg) }
        forced || pattern_pids?(cmd) ? %w[pattern_kill] : []
      end

      def pattern_pids?(cmd)
        return true if cmd.args.any? { |arg| Support.dynamic?(arg) && PATTERN_PRODUCERS.any? { |name| arg.include?(name) } }

        cmd.name == "kill" && pids(cmd).empty? && cmd.upstream.any? { |up| PATTERN_PRODUCERS.include?(up.name) }
      end

      def pids(cmd)
        pos, = Support.split_args(cmd.args.reject { |arg| arg.match?(/\A-(?:\d+|[A-Z]+)\z/) }, %w[-s -n])
        pos.select { |arg| arg.match?(/\A\d+\z/) }
      end

      def kill_actions(cmd)
        return [] unless cmd.name == "kill"

        found = pids(cmd).map { |pid| Support.act("service.control", cmd.text, "pid" => pid.to_i, "command" => "kill") }
        found << Support.act("service.control", cmd.text, "fuzzy" => true, "command" => "kill") if pattern_pids?(cmd)
        found
      end

      def effective_count(script)
        script.commands.count { |cmd| !embed_host?(cmd) }
      end

      def embed_host?(cmd)
        (Shell::SHELLS.include?(cmd.name) || Shell::INTERPRETERS.include?(cmd.name)) && !Shell.embedded_sources(cmd).empty?
      end

      def apply(action, found, chained)
        found = found.select { |name| applies?(name, action) }
        found += ["chained_release"] if chained && CHAIN_CLASSES.include?(action.action_class)
        return action if found.empty?

        action.env_hint = action.env_hint.merge("shape" => (names(action) + found).uniq)
        action
      end

      def applies?(name, action)
        return true unless name == "lockfile_edit"

        path = action.env_hint["path"]
        action.action_class == "fs.write" && path.is_a?(String) && LOCKFILES.include?(File.basename(path))
      end

      def tag_tool(actions, tool_name)
        return actions unless Registry.family("tool") && writer_tool?(tool_name)

        actions.each { |action| apply(action, %w[lockfile_edit], false) }
      end

      def writer_tool?(tool_name)
        name = tool_name.to_s.downcase
        Tool::WRITE_TOOLS.include?(name) || Tool::PATCH_TOOLS.include?(name)
      end
    end
  end
end
