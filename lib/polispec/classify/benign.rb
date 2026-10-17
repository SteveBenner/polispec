#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "commands/support"

module Polispec
  module Classify
    module Benign
      INTERNAL_TOOLS = %w[todowrite todoread skill toolsearch askuserquestion enterplanmode exitplanmode taskoutput tasklist taskget listagents update_plan view_image glob ls taskcreate taskupdate taskstop sendmessage subagenthandback structuredoutput schedulewakeup].freeze
      WEB_TOOLS = %w[webfetch web_fetch websearch web_search].freeze
      SEARCH_TOOLS = %w[websearch web_search].freeze
      AGENT_TOOLS = %w[agent task].freeze
      GENERIC_OK = %w{ls ll dir pwd echo printf true false test [ id whoami hostname uname date which type whereis ps pgrep printenv df du free uptime tree basename dirname realpath readlink seq tr column fold fmt rev nproc lscpu lsblk locale md5sum sha1sum sha256sum sha512sum cksum tty groups}.freeze
      SECRETS_OK = %w[cat head tail wc file stat grep egrep fgrep rg sort uniq cut diff cmp jq less more md5sum].freeze
      GIT_READ = %w[status log show diff rev-parse ls-files blame describe].freeze
      GIT_OUTPUT_FLAGS = /\A(?:--output|--ext-diff|--open-files-in-pager|-O)/.freeze
      GIT_BRANCH_FLAGS = %w[--list -l -a --all -r --remotes -v -vv --verbose].freeze
      GIT_CONFIG_READ = %w[--get --get-all --get-regexp --list -l].freeze
      GIT_CONFIG_SCOPE = %w[--global --local --system --worktree --show-origin --show-scope --null -z --name-only].freeze
      JSON_FLAG = { "--json" => false }.freeze
      POLISPEC_READ = {
        "version" => [nil, {}],
        "resolve" => [nil, JSON_FLAG],
        "status" => [nil, JSON_FLAG],
        "digest" => [nil, JSON_FLAG.merge("--since" => true)],
        "doctor" => [nil, JSON_FLAG],
        "classify" => [nil, JSON_FLAG.merge("--ledger" => true, "--policy" => true, "--cwd" => true)],
        "validate" => [nil, JSON_FLAG],
        "plan" => [nil, JSON_FLAG.merge("--repo" => true, "--variant" => true, "--param" => true, "--from" => true)],
        "steward" => [nil, JSON_FLAG.merge("--check" => false), "--check"],
        "smoke" => [{
          "list" => JSON_FLAG.merge("--spec" => true, "--at" => true, "--verdict" => true),
          "show" => JSON_FLAG,
          "verify" => JSON_FLAG,
          "coverage" => JSON_FLAG.merge("--spec" => true, "--at" => true)
        }],
        "roster" => [{
          "resolve" => JSON_FLAG.merge("--role" => true, "--pipeline" => true, "--phase" => true, "--env" => true, "--roster" => true),
          "check" => JSON_FLAG.merge("--pipeline" => true, "--profile" => true, "--env" => true, "--roster" => true)
        }],
        "code" => [{
          "detect" => JSON_FLAG.merge("--ref" => true, "--repo" => true),
          "chain" => JSON_FLAG.merge("--ref" => true, "--repo" => true),
          "show" => JSON_FLAG.merge("--ref" => true, "--repo" => true, "--type" => true, "--domain" => true),
          "list" => JSON_FLAG.merge("--ref" => true, "--repo" => true, "--type" => true, "--domain" => true, "--spec" => true),
          "check" => JSON_FLAG.merge("--before" => true, "--ref" => true, "--repo" => true),
          "validate" => JSON_FLAG.merge("--ref" => true, "--repo" => true)
        }],
        "specs" => [{ "status" => JSON_FLAG.merge("--repo" => true) }],
        "harness" => [{
          "grammar" => JSON_FLAG,
          "parse" => JSON_FLAG.merge("--file" => true),
          "plan" => JSON_FLAG.merge("--harness" => true, "--scope" => true, "--project" => true),
          "verify" => JSON_FLAG
        }],
        "agents" => [{ "render" => JSON_FLAG.merge("--from" => true, "--check" => false) }, "--check"],
        "behavior" => [{ "compile" => {}, "decide" => {} }],
        "exceptions" => [{ "list" => JSON_FLAG }]
      }.freeze
      WRAPPERS = %w[eval exec source env sudo doas nohup timeout xargs command builtin nice ionice stdbuf setsid unbuffer flock time bash sh zsh dash ksh ash].freeze
      OPAQUE = %w[eval source .].freeze
      SUBSTITUTION = /\$\(|`|<\(|>\(/.freeze
      SHORT_OUTPUT = /\A-[A-Za-z]*o/.freeze
      REDIRECT_DUP = /\A(?:\d+|-)\z/.freeze

      module_function

      def benign?(tool_name, tool_input, cwd)
        name = tool_name.to_s.downcase
        return true if INTERNAL_TOOLS.include?(name)
        return shell?(tool_name, tool_input, cwd) if Support::BASH_TOOLS.include?(name)

        false
      end

      def positive(tool_name, tool_input, cwd)
        name = tool_name.to_s.downcase
        if WEB_TOOLS.include?(name)
          hint = { "path" => cwd.to_s, "tool" => tool_name.to_s }
          if SEARCH_TOOLS.include?(name)
            hint["search"] = true
          else
            host = Support.dig(tool_input, "url", "uri").to_s[%r{\A(?:[a-z]+://)?([^/:?#]+)}i, 1]
            hint["domain"] = host.downcase if host
          end
          [Action.new(class: "web.fetch", env_hint: hint, raw: tool_name.to_s)]
        elsif AGENT_TOOLS.include?(name)
          [Action.new(class: "agent.spawn", env_hint: { "path" => cwd.to_s, "tool" => tool_name.to_s }, raw: tool_name.to_s)]
        else
          []
        end
      end

      def read_only_names
        @read_only_names ||= begin
          generic = Registry.family("generic")::NAMES & GENERIC_OK
          secrets = Registry.family("secrets")::NAMES & SECRETS_OK
          (generic + Registry.family("fs")::READ_ONLY_EXEC + secrets).uniq.freeze
        end
      end

      def shell?(tool_name, tool_input, cwd)
        text = Support.command_text(tool_name, tool_input)
        return false if text.nil? || text.strip.empty? || text.match?(SUBSTITUTION)
        return false if words(text).any? { |word| WRAPPERS.include?(word) }

        script = Support.script_for(tool_name, tool_input, cwd)
        return false unless script && !script.commands.empty?

        script.commands.all? { |cmd| command?(cmd) }
      rescue StandardError
        false
      end

      def parsed_shell?(tool_name, tool_input, cwd)
        return false unless Support::BASH_TOOLS.include?(tool_name.to_s.downcase)

        script = Support.script_for(tool_name, tool_input, cwd)
        return false if script.nil? || script.commands.empty?

        script.commands.none? { |cmd| OPAQUE.include?(cmd.name.to_s) }
      rescue StandardError
        false
      end

      def opaque_shell?(tool_name, tool_input, cwd)
        return false unless Support::BASH_TOOLS.include?(tool_name.to_s.downcase)

        script = Support.script_for(tool_name, tool_input, cwd)
        return false if script.nil? || script.commands.empty?

        script.opaque == true || script.commands.any? { |cmd| OPAQUE.include?(cmd.name.to_s) }
      rescue StandardError
        false
      end

      def opaque_commands(tool_name, tool_input, cwd)
        return [] unless Support::BASH_TOOLS.include?(tool_name.to_s.downcase)

        script = Support.script_for(tool_name, tool_input, cwd)
        return [] if script.nil? || script.commands.empty?

        named = script.commands.select { |cmd| OPAQUE.include?(cmd.name.to_s) }.map { |cmd| cmd.text.to_s }
        named.empty? ? [script.text.to_s] : named
      rescue StandardError
        []
      end

      def words(text)
        text.split(/[\s;|&()<>{}]+/).map { |word| word.delete("'\"\\") }
      end

      def command?(cmd)
        return false if cmd.argv.empty? || cmd.sudo || !cmd.env.empty?
        return false if cmd.argv.any? { |word| Support.dynamic?(word) }
        return false unless cmd.argv.first == cmd.name
        return false unless cmd.redirects.all? { |redirect| discarded?(redirect) }
        return false unless lead(cmd) == cmd.name

        return git?(cmd) if cmd.name == "git"
        return polispec?(cmd) if cmd.name == "polispec"

        plain?(cmd)
      end

      def polispec?(cmd)
        args = cmd.args
        verb = args.first
        entry = POLISPEC_READ[verb]
        return false unless entry

        rest = args.drop(1)
        subs, required = entry[0].is_a?(Hash) ? [entry[0], entry[1]] : [nil, entry[2]]
        flags = entry[1]
        if subs
          sub = rest.first
          return false unless sub && subs.key?(sub)

          rest = rest.drop(1)
          flags = subs[sub]
        end
        seen = []
        positional = 0
        until rest.empty?
          arg = rest.shift
          if arg == "--"
            positional += rest.length
            break
          elsif arg.start_with?("-") && arg.length > 1
            name, inline = arg.split("=", 2)
            return false unless flags.key?(name)

            seen << name
            takes_value = flags[name]
            return false if inline && !takes_value
            return false if takes_value && inline.nil? && (rest.empty? || rest.first.start_with?("--"))

            rest.shift if takes_value && inline.nil?
          else
            positional += 1
          end
        end
        required.nil? || seen.include?(required)
      end

      def lead(cmd)
        cmd.text.to_s.split(/\s+/).find { |word| !word.match?(Shell::ASSIGNMENT) && !Shell::KEYWORDS.include?(word) }
      end

      def discarded?(redirect)
        return false if redirect.here? || redirect.read?
        return true if redirect.write? && redirect.target.to_s == "/dev/null" && !Support.dynamic?(redirect.target)

        %w[>& <&].include?(redirect.op) && redirect.target.to_s.match?(REDIRECT_DUP) && !Support.dynamic?(redirect.target)
      end

      def plain?(cmd)
        return false unless read_only_names.include?(cmd.name)

        args = cmd.args
        positional = Support.split_args(args).first
        case cmd.name
        when "sort" then args.none? { |arg| arg.match?(SHORT_OUTPUT) || arg.start_with?("--output", "--compress-program") }
        when "tree" then args.none? { |arg| arg.match?(SHORT_OUTPUT) || arg.start_with?("--output") }
        when "rg" then args.none? { |arg| arg.start_with?("--pre", "--hostname-bin") }
        when "less", "more" then args.none? { |arg| arg.match?(/\A-[oO]\z/) || arg.start_with?("--log-file", "--LOG-FILE") }
        when "uniq" then positional.length <= 1
        when "hostname" then positional.empty?
        when "date" then args.none? { |arg| arg.match?(/\A-[A-Za-z]*s/) || arg.start_with?("--set") } && positional.all? { |arg| arg.start_with?("+") }
        else true
        end
      end

      def git?(cmd)
        inv = Registry.family("git").invocation(cmd)
        return false unless inv
        args = inv.args
        globals = cmd.args.first(cmd.args.length - args.length - 1)
        return false if globals.any? { |arg| arg == "-c" || arg.start_with?("--config-env", "--exec-path", "--paginate", "-p") }

        case inv.sub
        when *(GIT_READ & Registry.family("git")::READ_ONLY) then args.none? { |arg| arg.match?(GIT_OUTPUT_FLAGS) }
        when "branch" then args.all? { |arg| GIT_BRANCH_FLAGS.include?(arg) }
        when "remote" then args.empty? || %w[-v --verbose] == args
        when "tag" then args.empty? || (args.any? { |arg| %w[-l --list].include?(arg) } && args.all? { |arg| !arg.start_with?("-") || %w[-l --list].include?(arg) })
        when "config" then config?(args)
        else false
        end
      end

      def config?(args)
        flags = args.select { |arg| arg.start_with?("-") }
        flags.any? { |arg| GIT_CONFIG_READ.include?(arg) } && flags.all? { |arg| (GIT_CONFIG_READ + GIT_CONFIG_SCOPE).include?(arg) }
      end
    end
  end
end
