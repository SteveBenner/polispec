#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "support"

module Polispec
  module Classify
    module Gh
      extend Support::Family

      NAMES = %w[gh].freeze
      VALUE_OPTS = %w[-R --repo -t --title -n --notes -F --notes-file --target --discussion-category --notes-start-tag -X --method -H --header -f --raw-field --field --input --jq -q --template --hostname -p --preview --cache -b --body -B --base -H --head -a --assignee -l --label -m --milestone -r --reviewer].freeze
      RELEASE_WRITES = %w[create edit delete upload delete-asset].freeze
      FIELD_FLAGS = %w[-f -F --field --raw-field --input].freeze

      class << self
        def classify(cmd)
          return [] unless cmd.name == "gh"

          pos, flags = Support.split_args(cmd.args, VALUE_OPTS)
          repo = Support.option_value(cmd.args, "-R", "--repo")
          case pos.first
          when "release" then release(cmd, pos, flags, repo)
          when "pr" then pull_request(cmd, pos, repo)
          when "api" then api(cmd, pos, repo)
          else []
          end
        end

        def release(cmd, pos, flags, repo)
          return [] unless RELEASE_WRITES.include?(pos[1])

          prerelease = flags.include?("--prerelease") || flags.include?("--draft")
          channel = prerelease && !flags.include?("--latest") ? "prerelease" : "latest"
          [Support.act("release.publish", cmd.text, "path" => cmd.cwd, "repo" => repo, "tag" => pos[2], "channel" => channel, "env" => channel == "prerelease" ? "test" : "prod")]
        end

        def pull_request(cmd, pos, repo)
          return [] unless pos[1] == "merge"

          [Support.act("git.merge", cmd.text, "path" => cmd.cwd, "repo" => repo)]
        end

        def api(cmd, pos, repo)
          endpoint = pos[1].to_s
          return [] unless mutating?(cmd.args)

          repo ||= endpoint[%r{\Arepos/([^/]+/[^/]+)}, 1]
          base = { "path" => cmd.cwd, "repo" => repo }
          api_actions(cmd, endpoint, base)
        end

        def mutating?(args)
          method = Support.option_value(args, "-X", "--method").to_s.upcase
          return method != "GET" unless method.empty?

          args.any? { |arg| FIELD_FLAGS.include?(arg) || arg.start_with?("--field=", "--raw-field=", "--input=") }
        end

        def api_actions(cmd, endpoint, base)
          method = Support.option_value(cmd.args, "-X", "--method").to_s.upcase
          case endpoint
          when %r{/releases}
            [Support.act("release.publish", cmd.text, base.merge("channel" => "latest", "env" => "prod"))]
          when %r{/git/refs}
            ref_actions(cmd, endpoint, base, method)
          when %r{/pulls/\d+/merge}, %r{/merges\z}
            [Support.act("git.merge", cmd.text, base)]
          when %r{/contents/}
            [Support.act("git.commit", cmd.text, base.merge(Support.hint("ref" => Support.option_value(cmd.args, "-f", "-F", "--field", "--raw-field").to_s[/\Abranch=(.+)/, 1])))]
          else
            []
          end
        end

        def ref_actions(cmd, endpoint, base, method)
          ref = endpoint[%r{/git/refs/(?:heads/)?(.+)\z}, 1]
          hint = base.merge(Support.hint("ref" => ref))
          classes = ["git.push"]
          classes << "git.branch" if method == "DELETE"
          classes << "git.rewrite" if method == "PATCH"
          classes.map { |klass| Support.act(klass, cmd.text, hint) }
        end
      end
    end

    Registry.register("gh", Gh)
  end
end
