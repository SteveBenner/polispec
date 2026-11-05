#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../shell"
require_relative "../../exceptions"
require_relative "../../delegate"

module Polispec
  module Classify
    module Support
      BASH_TOOLS = %w[bash shell sh run_shell_command execute_bash local_shell terminal run_terminal_cmd exec_command shell_command execute_command run_command].freeze
      DISCARD = %r{\A(?:/dev/(?:null|zero|stdout|stderr|stdin|tty|full|random|urandom)\z|/dev/fd/|/proc/self/fd/)}.freeze
      PROC_ROOT = %r{\A/proc/(?:self|thread-self|\d+)/root(?=/|\z)}.freeze
      PROC_CWD = %r{\A/proc/(?:self|thread-self)/cwd(?=/|\z)}.freeze
      POLICY_PATH = %r{(?:\A|/)specs/polispec(?:/|\z)}.freeze
      ENVS_BODY = %r{/\.agents/directives/envs\.md\z}.freeze
      PROOF_RECORD = %r{/proofs/[^/]+\.jsonl\z}.freeze
      GIT_INTERNALS = %w[refs packed-refs HEAD config hooks].freeze
      ENVS_ROW = "[ENVS]"
      EDIT_KEYS = %w[old_string new_string old_str new_str old_text new_text oldText newText].freeze
      CONTENT_KEYS = %w[content file_text text contents].freeze
      BYTES_KEYS = %w[content file_text text new_string new_str new_source contents].freeze
      TEXT_LIMIT = 262_144

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

      def unproc(path, cwd = nil)
        text = path.to_s
        if text.match?(PROC_ROOT)
          rest = text.sub(PROC_ROOT, "")
          rest.empty? ? "/" : rest
        elsif cwd && text.match?(PROC_CWD)
          File.join(cwd.to_s, text.sub(PROC_CWD, ""))
        else
          text
        end
      end

      def abs(path, cwd)
        return cwd.to_s if dynamic?(path)

        expand(unproc(path, cwd), cwd.to_s)
      end

      def expand(path, base = nil)
        text = path.to_s.delete("\0")
        base ? File.expand_path(text, base) : File.expand_path(text)
      rescue ArgumentError
        File.expand_path(File.join(".", text), base || Dir.pwd)
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

      def exceptions_file?(path)
        target = Exceptions.path
        !target.nil? && File.expand_path(path) == File.expand_path(target)
      rescue StandardError
        false
      end

      def delegate_grants_file?(path)
        File.expand_path(path) == File.expand_path(Polispec::Delegate.grants_path)
      rescue StandardError
        false
      end

      def web_secret_file?(path)
        base = File.join(State.home, "web")
        %w[launch.secret delegate.token].any? { |name| File.expand_path(path) == File.join(base, name) }
      rescue StandardError
        false
      end

      def proof_record?(path)
        PROOF_RECORD.match?(path) && File.file?(File.join(File.dirname(File.dirname(path)), "specs", "features.yml"))
      end

      def git_internal?(path)
        parts = path.to_s.split("/")
        at = parts.index(".git")
        return false unless at

        rest = parts.drop(at + 1)
        return true if rest.empty?

        rest = rest.drop(2) if rest.first == "worktrees"
        GIT_INTERNALS.include?(rest.first)
      end

      def policy_ancestor?(path)
        return false unless File.directory?(path)
        return true if File.basename(path) == "specs" && File.directory?(File.join(path, "polispec"))

        !File.exist?(File.join(path, ".git")) && File.directory?(File.join(path, "specs", "polispec"))
      rescue SystemCallError
        false
      end

      def real(path)
        existing = File.expand_path(path.to_s)
        existing = File.dirname(existing) until File.exist?(existing) || existing == "/"
        File.join(File.realpath(existing), File.expand_path(path.to_s)[existing.length..].to_s)
      rescue SystemCallError, ArgumentError
        path.to_s
      end

      def write_class(path, input = nil)
        return "proof.write" if proof_record?(path)
        return "policy.edit" if delegate_grants_file?(path)
        return "policy.edit" if web_secret_file?(path)
        return "policy.edit" if exceptions_file?(path)
        return "policy.edit" if POLICY_PATH.match?(path) || ledger_file?(path) || ENVS_BODY.match?(path)
        return "fs.write" unless File.basename(path) == "AGENTS.md"

        agents_touches_row?(path, input) ? "policy.edit" : "fs.write"
      end

      def policy_sensitive?(path)
        return true if git_internal?(path) || policy_ancestor?(path)

        resolved = real(path)
        resolved != path && (POLICY_PATH.match?(resolved) || git_internal?(resolved))
      end

      def with_policy_edits(actions)
        actions.flat_map do |action|
          next [action] unless action.action_class == "fs.write" && action.env_hint["policy_sensitive"]

          [action, Action.new(class: "policy.edit", env_hint: action.env_hint, raw: action.raw)]
        end
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
        direct = EDIT_KEYS.map { |key| dig(input, key) }.compact.grep(String)
        nested = Array(dig(input, "edits")).flat_map { |entry| entry.is_a?(Hash) ? edit_strings(entry) : [] }
        direct + nested
      end

      def envs_line(text)
        text.to_s.lines.find { |line| line.start_with?(ENVS_ROW) }&.chomp
      end

      def read_text(path)
        File.file?(path) ? File.read(path).scrub("\uFFFD") : nil
      rescue SystemCallError
        nil
      end

      def write_action(path, raw, extra = {}, input = nil)
        path = unproc(path)
        return nil if discard?(path)

        klass = write_class(path, input)
        strings = klass == "fs.write" ? write_strings(input) : []
        bytes = strings.empty? ? nil : strings.sum(&:bytesize)
        text, truncated = strings.empty? ? [nil, nil] : clip(strings.join("\n"))
        sensitive = klass == "fs.write" && policy_sensitive?(path) ? { "policy_sensitive" => true } : {}
        act(klass, raw, extra.merge(sensitive).merge("path" => path, "bytes" => bytes, "text" => text, "text_truncated" => truncated))
      end

      def write_strings(input)
        return [] unless input.is_a?(Hash)

        entries = [input] + (dig(input, "edits").is_a?(Array) ? dig(input, "edits").grep(Hash) : [])
        entries.flat_map { |entry| BYTES_KEYS.map { |key| dig(entry, key) } }.grep(String)
      end

      def clip(text)
        return [text, nil] if text.bytesize <= TEXT_LIMIT

        [text.byteslice(0, TEXT_LIMIT).scrub(""), true]
      end

      def read_action(path, raw, extra = {})
        path = unproc(path)
        return nil if discard?(path)

        act("secrets.read", raw, extra.merge("path" => path, "candidate" => true))
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

      def option_value_cluster(args, letters, longs = [])
        args.each_with_index do |arg, i|
          text = arg.to_s
          if text.start_with?("--")
            longs.each do |name|
              return args[i + 1] if text == name && args[i + 1]
              return text.delete_prefix("#{name}=") if text.start_with?("#{name}=")
            end
          elsif text.start_with?("-") && text.length > 1
            text[1..].each_char.with_index do |char, at|
              break unless char.match?(/[A-Za-z]/)
              next unless letters.include?(char)

              rest = text[(at + 2)..].to_s
              return rest unless rest.empty?
              return args[i + 1] if args[i + 1]

              break
            end
          end
        end
        nil
      end

      def cluster_flag?(args, letter)
        args.any? { |arg| arg.to_s.match?(/\A-[A-Za-z]+\z/) && arg.to_s.include?(letter) }
      end

      def expand_paths(word, cwd)
        expanded = Shell.expand_word(word, cwd)
        expanded.nil? ? [word] : expanded
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
