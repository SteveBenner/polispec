#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "support"

module Polispec
  module Classify
    module Release
      extend Support::Family

      NAMES = %w[polispec].freeze
      PUBLISHERS = { "gem" => "push", "npm" => "publish", "yarn" => "publish", "pnpm" => "publish", "cargo" => "publish", "twine" => "upload" }.freeze
      RELEASE_SCRIPT = /(?:release_stable|stable_promote|promote_stable|release_publish)\.rb\z/.freeze
      ENV_NAMES = { "stable" => "prod", "prod" => "prod", "production" => "prod", "test" => "test", "dev" => "dev", "main" => "dev" }.freeze
      OPERATOR_VERBS = %w[promote deploy].freeze
      APPLY_VALUE_FLAGS = %w[--to --tag --minutes --reason --since --role --pipeline --phase --profile --policy --ledger --confirm --repo --variant --param --from].freeze
      GOVERNED_TARGETS = %w[global ledger].freeze

      class << self
        def classify(cmd)
          return operator(cmd) if cmd.name == "polispec"

          publish(cmd) ? [Support.act("release.publish", cmd.text, "path" => cmd.cwd, "channel" => "latest")] : []
        end

        def operator(cmd)
          pos, = Support.split_args(cmd.args, APPLY_VALUE_FLAGS)
          verb = pos.first
          return apply(cmd, pos) if verb == "apply"
          return [] unless OPERATOR_VERBS.include?(verb)

          project = pos[1]
          target = verb == "promote" ? Support.option_value(cmd.args, "--to") : pos[2]
          env = ENV_NAMES[target.to_s]
          [Support.act(verb, cmd.text, "path" => cmd.cwd, "project" => project, "env" => env)]
        end

        def apply(cmd, pos)
          target = pos[1].to_s
          confirmed = !Support.option_value(cmd.args, "--confirm").nil?
          return [] unless confirmed || GOVERNED_TARGETS.include?(target)

          repo = Support.option_value(cmd.args, "--repo")
          attrs = { "path" => repo ? File.expand_path(repo, cmd.cwd.to_s) : cmd.cwd }
          attrs["project"] = target.delete_prefix("project:") if target.start_with?("project:")
          [Support.act("policy.edit", cmd.text, attrs)]
        end

        def publish(cmd)
          return true if cmd.argv.any? { |arg| RELEASE_SCRIPT.match?(arg) }

          words = cmd.argv.first(4).map { |arg| File.basename(arg) }
          rake_release?(cmd, words) || publisher?(cmd, words)
        end

        def rake_release?(cmd, words)
          idx = words.index("rake")
          return false unless idx

          cmd.argv.drop(idx + 1).any? { |arg| arg == "release" || arg.start_with?("release:") }
        end

        def publisher?(cmd, words)
          PUBLISHERS.any? do |tool, verb|
            idx = words.index(tool)
            idx && cmd.argv.drop(idx + 1).first == verb
          end
        end
      end
    end

    Registry.register("release", Release)
  end
end
