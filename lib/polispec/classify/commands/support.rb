#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../shell"

module Polispec
  module Classify
    module Support
      BASH_TOOLS = %w[bash shell sh run_shell_command execute_bash local_shell terminal run_terminal_cmd exec_command shell_command execute_command run_command].freeze
      DISCARD = %r{\A(?:/dev/(?:null|zero|stdout|stderr|stdin|tty|full|random|urandom)\z|/dev/fd/|/proc/self/)}.freeze
      POLICY_PATH = %r{(?:\A|/)specs/polispec(?:/|\z)}.freeze
      ENVS_BODY = %r{/\.agents/directives/envs\.md\z}.freeze
      ENVS_ROW = "[ENVS]"
      EDIT_KEYS = %w[old_string new_string old_str new_str old_text new_text oldText newText].freeze
      CONTENT_KEYS = %w[content file_text text contents].freeze

      module_function

      def dig(hash, *keys)
        return nil unless hash.is_a?(Hash)

        keys.each do |key|
          value = hash[key.to_s]
          value = hash[key.to_sym] if value.nil?
          return value unless value.nil?
        end
        nil
      end

      def command_text(tool_name, input)
        return nil unless BASH_TOOLS.include?(tool_name.to_s.downcase)

        raw = input.is_a?(Hash) ? dig(input, "command", "cmd", "script", "commands") : input
        case raw
        when String then raw
        when Array then raw.map(&:to_s).shelljoin
        end
      end

      def script_for(tool_name, tool_input, cwd)
        text = command_text(tool_name, tool_input)
        return nil if text.nil? || text.strip.empty?

        cwd = Dir.pwd if cwd.to_s.empty?
        key = [text, cwd.to_s]
        return @script if @key == key

        @key = key
        @script = Shell.parse(text, cwd.to_s)
      end

      def dynamic?(word)
        word.respond_to?(:dynamic?) && word.dynamic?
      end

      def abs(path, cwd)
        return cwd.to_s if dynamic?(path)

        File.expand_path(path.to_s, cwd.to_s)
      end

      def discard?(path)
        DISCARD.match?(path.to_s)
      end

      def hint(attrs)
        attrs.each_with_object({}) { |(key, value), memo| memo[key.to_s] = value unless value.nil? }
      end

      def act(klass, raw, attrs)
        Action.new(class: klass, env_hint: hint(attrs), raw: raw.to_s)
      end

      def ledger_file?(path)
        File.expand_path(path) == Ledger.default_path
      end

      def write_class(path, input = nil)
        return "policy.edit" if POLICY_PATH.match?(path) || ledger_file?(path) || ENVS_BODY.match?(path)
        return "fs.write" unless File.basename(path) == "AGENTS.md"

        agents_touches_row?(path, input) ? "policy.edit" : "fs.write"
      end

      def agents_touches_row?(path, input)
        if input.is_a?(Hash)
          edited = edit_strings(input)
          return edited.any? { |text| text.include?(ENVS_ROW) } unless edited.empty?

          content = dig(input, *CONTENT_KEYS)
          return envs_line(content) != envs_line(read_text(path)) if content.is_a?(String)
        end
        !envs_line(read_text(path)).nil?
      end

      def edit_strings(input)
        direct = EDIT_KEYS.filter_map { |key| dig(input, key) }.grep(String)
        nested = Array(dig(input, "edits")).flat_map { |entry| entry.is_a?(Hash) ? edit_strings(entry) : [] }
        direct + nested
      end

      def envs_line(text)
        text.to_s.lines.find { |line| line.start_with?(ENVS_ROW) }&.chomp
      end

      def read_text(path)
        File.file?(path) ? File.read(path) : nil
      rescue SystemCallError
        nil
      end

      def write_action(path, raw, extra = {}, input = nil)
        return nil if discard?(path)

        act(write_class(path, input), raw, extra.merge("path" => path))
      end

      def read_action(path, raw)
        return nil if discard?(path)

        act("secrets.read", raw, "path" => path, "candidate" => true)
      end

      def split_args(args, with_value = [])
        flags = []
        positional = []
        rest = args.dup
        until rest.empty?
          arg = rest.shift
          if arg == "--"
            positional.concat(rest)
            break
          elsif arg.start_with?("-") && arg.length > 1
            flags << arg
            rest.shift if with_value.include?(arg)
          else
            positional << arg
          end
        end
        [positional, flags]
      end

      def option_value(args, *names)
        args.each_with_index do |arg, i|
          names.each do |name|
            return args[i + 1] if arg == name && args[i + 1]
            return arg.sub("#{name}=", "") if name.start_with?("--") && arg.start_with?("#{name}=")
          end
        end
        nil
      end

      def option_values(args, *names)
        values = []
        args.each_with_index do |arg, i|
          names.each do |name|
            values << args[i + 1] if arg == name && args[i + 1]
            values << arg.sub("#{name}=", "") if name.start_with?("--") && arg.start_with?("#{name}=")
          end
        end
        values
      end

      def normalize_remote(url)
        text = url.to_s.strip.downcase.sub(%r{\A[a-z+]+://}, "").sub(%r{\A[^@/]+@}, "")
        text = text.sub(":", "/")
        text.sub(%r{/+\z}, "").sub(/\.git\z/, "")
      end

      def url?(text)
        text.to_s.include?("://") || text.to_s.match?(/\A[\w.-]+@[\w.-]+:/)
      end

      module Repo
        Info = Struct.new(:root, :git_dir, :common_dir)

        module_function

        def find(path)
          dir = nearest_dir(path)
          loop do
            info = probe(dir)
            return info if info

            parent = File.dirname(dir)
            return nil if parent == dir

            dir = parent
          end
        rescue SystemCallError
          nil
        end

        def nearest_dir(path)
          dir = File.expand_path(path.to_s)
          dir = File.dirname(dir) until File.directory?(dir) || dir == "/"
          dir
        end

        def probe(dir)
          dotgit = File.join(dir, ".git")
          return Info.new(dir, dotgit, dotgit) if File.directory?(dotgit)
          return linked(dir, dotgit) if File.file?(dotgit)
          return Info.new(dir, dir, dir) if File.file?(File.join(dir, "HEAD")) && File.directory?(File.join(dir, "objects"))

          nil
        end

        def linked(dir, dotgit)
          target = File.read(dotgit)[/\Agitdir:\s*(.+)$/, 1]
          return nil unless target

          git_dir = File.expand_path(target.strip, dir)
          common = File.join(git_dir, "commondir")
          common_dir = File.file?(common) ? File.expand_path(File.read(common).strip, git_dir) : git_dir
          Info.new(dir, git_dir, common_dir)
        end

        def current_branch(path)
          info = find(path)
          return nil unless info

          File.read(File.join(info.git_dir, "HEAD"))[%r{\Aref:\s*refs/heads/(.+?)\s*\z}, 1]
        rescue SystemCallError
          nil
        end

        def remote_url(path, name)
          info = find(path)
          return nil unless info

          section = nil
          File.foreach(File.join(info.common_dir, "config")) do |line|
            if (match = line.match(/\A\s*\[(\w+)(?:\s+"([^"]*)")?\]/))
              section = [match[1].downcase, match[2]]
            elsif section == ["remote", name.to_s] && (url = line[/\A\s*url\s*=\s*(.+?)\s*\z/, 1])
              return url
            end
          end
          nil
        rescue SystemCallError
          nil
        end
      end

      module Family
        def call(tool_name, tool_input, cwd)
          script = Support.script_for(tool_name, tool_input, cwd)
          return [] unless script

          script.commands.flat_map { |cmd| listed(classify(cmd)) }.compact.uniq { |action| [action.action_class, action.env_hint] }
        end

        def listed(result)
          result.is_a?(Array) ? result : [result]
        end

        def handles
          self::NAMES
        end
      end
    end
  end
end
