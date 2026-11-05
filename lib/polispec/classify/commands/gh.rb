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
      TRUE_WORDS = %w[1 t T TRUE true True].freeze
      FALSE_WORDS = %w[0 f F FALSE false False].freeze
      MAX_BODY = 1_000_000
      REPO_WRITES = %w[delete archive unarchive rename transfer edit].freeze
      SECRET_WRITES = %w[set delete remove].freeze
      RULESET_READS = %w[list view check].freeze

      class << self
        def classify(cmd)
          return [] unless cmd.name == "gh"

          pos, flags = Support.split_args(cmd.args, VALUE_OPTS)
          repo = Support.option_value(cmd.args, "-R", "--repo")
          case pos.first
          when "release" then release(cmd, pos, flags, repo)
          when "pr" then pull_request(cmd, pos, repo)
          when "api" then api(cmd, pos, repo)
          when "repo", "secret", "variable", "ruleset" then remote_change(cmd, pos, flags)
          else []
          end
        end

        def remote_change(cmd, pos, flags)
          reason = change_reason(pos, flags)
          reason ? [change_action(cmd, reason)] : []
        end

        def change_reason(pos, flags)
          verb = pos[1].to_s
          case pos.first
          when "repo"
            return "gh repo #{verb}" if REPO_WRITES.include?(verb)

            "gh repo sync --force" if verb == "sync" && flags.any? { |flag| flag == "--force" || flag.match?(/\A-[a-zA-Z]*f[a-zA-Z]*\z/) }
          when "secret", "variable"
            "gh #{pos.first} #{verb}" if SECRET_WRITES.include?(verb)
          when "ruleset"
            "gh ruleset #{verb}" unless verb.empty? || RULESET_READS.include?(verb)
          end
        end

        def change_action(cmd, reason)
          Action.new(class: "shell.exec", env_hint: { "path" => cmd.cwd }, raw: { "remote_change" => reason })
        end

        def shapes(cmd)
          return [] unless cmd.name == "gh"

          latest_flip?(cmd) ? ["latest_flip"] : []
        end

        def flag_value(flags, name)
          flags.reduce(nil) do |value, flag|
            if flag == name
              true
            elsif flag.start_with?("#{name}=")
              word = flag.split("=", 2).last
              TRUE_WORDS.include?(word) ? true : (FALSE_WORDS.include?(word) ? false : value)
            else
              value
            end
          end
        end

        def latest_flip?(cmd)
          pos, flags = Support.split_args(cmd.args, VALUE_OPTS)
          case pos.first
          when "release" then %w[create edit].include?(pos[1]) && flag_value(flags, "--latest") == true
          when "api" then make_latest?(cmd)
          else false
          end
        end

        def make_latest?(cmd)
          values = Support.option_values(cmd.args, "-f", "-F", "--field", "--raw-field")
          return true if values.any? { |value| true_field?(value.to_s) }

          Support.option_values(cmd.args, "--input").any? { |file| body_make_latest?(file, cmd.cwd) }
        end

        def true_field?(value)
          name, text = value.split("=", 2)
          name == "make_latest" && %w[true "true"].include?(text.to_s.strip)
        end

        def body_make_latest?(file, cwd)
          return false if file == "-"

          path = Support.expand(file, cwd.to_s)
          return false unless File.file?(path) && File.size(path) <= MAX_BODY

          [true, "true"].include?(JSON.parse(File.read(path))["make_latest"])
        rescue SystemCallError, JSON::ParserError, NoMethodError, TypeError
          false
        end

        def release(cmd, pos, flags, repo)
          return [] unless RELEASE_WRITES.include?(pos[1])

          prerelease = flag_value(flags, "--prerelease") == true || flag_value(flags, "--draft") == true
          channel = prerelease && flag_value(flags, "--latest") != true ? "prerelease" : "latest"
          [Support.act("release.publish", cmd.text, "path" => cmd.cwd, "repo" => repo, "tag" => pos[2], "channel" => channel, "env" => channel == "prerelease" ? "test" : "prod")]
        end

        def pull_request(cmd, pos, repo)
          case pos[1]
          when "merge" then [Support.act("git.merge", cmd.text, "path" => cmd.cwd, "repo" => repo), change_action(cmd, "gh pr merge")]
          when "edit"
            base = Support.option_value(cmd.args, "-B", "--base")
            base ? [change_action(cmd, "gh pr edit --base #{base}")] : []
          else []
          end
        end

        def api(cmd, pos, repo)
          endpoint = pos[1].to_s
          return [] unless mutating?(cmd.args)

          repo ||= endpoint[%r{\Arepos/([^/]+/[^/]+)}, 1]
          base = { "path" => cmd.cwd, "repo" => repo }
          return graphql(cmd) if endpoint == "graphql"

          found = api_actions(cmd, endpoint, base)
          found.empty? ? [change_action(cmd, "gh api #{Support.option_value(cmd.args, '-X', '--method').to_s.upcase} #{endpoint}".squeeze(" "))] : found
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
          when %r{/pulls/\d+/merge}
            [Support.act("git.merge", cmd.text, base)]
          when %r{/merges\z}
            merge_actions(cmd, base)
          when %r{/contents/}
            [Support.act("git.commit", cmd.text, base.merge(Support.hint("contents" => true, "ref" => Support.option_value(cmd.args, "-f", "-F", "--field", "--raw-field").to_s[/\Abranch=(.+)/, 1])))]
          else
            []
          end
        end

        def graphql(cmd)
          query = api_fields(cmd.args)["query"].to_s
          query.match?(/\bmutation\b/) ? [change_action(cmd, "gh api graphql mutation")] : []
        end

        def api_fields(args)
          Support.option_values(args, "-f", "-F", "--field", "--raw-field").each_with_object({}) do |value, memo|
            name, text = value.to_s.split("=", 2)
            memo[name] = text
          end
        end

        def merge_actions(cmd, base)
          target = api_fields(cmd.args)["base"]
          out = [Support.act("git.merge", cmd.text, base)]
          out << Support.act("git.push", cmd.text, base.merge(Support.hint("ref" => target))) if target
          out
        end

        def ref_actions(cmd, endpoint, base, method)
          raw = endpoint[%r{/git/refs/(.+)\z}, 1] || api_fields(cmd.args)["ref"]
          tag = raw.to_s.match?(%r{\A(?:refs/)?tags/})
          name = raw.to_s.sub(%r{\A(?:refs/)?(?:heads|tags)/}, "")
          name = nil if name.empty?
          hint = base.merge(Support.hint(tag ? { "tag" => name, "delete" => (method == "DELETE" ? true : nil) } : { "ref" => name }))
          classes = ["git.push"]
          classes << "git.branch" if method == "DELETE" && !tag
          classes << "git.rewrite" if method == "PATCH" && !tag
          classes.map { |klass| Support.act(klass, cmd.text, hint) }
        end
      end
    end

    Registry.register("gh", Gh)
  end
end
