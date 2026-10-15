#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "commands/support"

module Polispec
  module Classify
    module Benign
      INTERNAL_TOOLS = %w[todowrite todoread skill toolsearch askuserquestion enterplanmode exitplanmode taskoutput tasklist taskget listagents update_plan view_image glob ls taskcreate taskupdate taskstop sendmessage].freeze
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
      WRAPPERS = %w[eval exec source env sudo doas nohup timeout xargs command builtin nice ionice stdbuf setsid unbuffer flock time bash sh zsh dash ksh ash].freeze
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

      def words(text)
        text.split(/[\s;|&()<>{}]+/).map { |word| word.delete("'\"\\") }
      end

      def command?(cmd)
        return false if cmd.argv.empty? || cmd.sudo || !cmd.env.empty?
        return false if cmd.argv.any? { |word| Support.dynamic?(word) }
        return false unless cmd.argv.first == cmd.name
        return false unless cmd.redirects.all? { |redirect| discarded?(redirect) }
        return false unless lead(cmd) == cmd.name

        cmd.name == "git" ? git?(cmd) : plain?(cmd)
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
        return false if cmd.args.any? { |arg| arg == "-c" || arg.start_with?("--config-env", "--exec-path", "--paginate", "-p") }

        args = inv.args
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
