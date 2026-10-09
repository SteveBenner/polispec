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

      class << self
        def classify(cmd)
          return operator(cmd) if cmd.name == "polispec"

          publish(cmd) ? [Support.act("release.publish", cmd.text, "path" => cmd.cwd, "channel" => "latest")] : []
        end

        def operator(cmd)
          pos, = Support.split_args(cmd.args, %w[--to --tag --minutes --reason --since --role --pipeline --phase --profile --policy --ledger])
          verb = pos.first
          return [] unless OPERATOR_VERBS.include?(verb)

          project = pos[1]
          target = verb == "promote" ? Support.option_value(cmd.args, "--to") : pos[2]
          env = ENV_NAMES[target.to_s]
          [Support.act(verb, cmd.text, "path" => cmd.cwd, "project" => project, "env" => env)]
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
