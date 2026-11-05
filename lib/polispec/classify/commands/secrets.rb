#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "support"

module Polispec
  module Classify
    module Secrets
      extend Support::Family

      NAMES = %w[cat head tail less more bat tac nl od xxd hexdump strings base64 grep egrep fgrep rg ag awk cut sort uniq wc diff cmp comm jq yq file stat source . openssl gpg sqlite3 zip zcat zgrep zegrep zfgrep zless zmore bzcat xzcat zstdcat].freeze
      PATTERN_FIRST = %w[grep egrep fgrep rg ag awk zgrep zegrep zfgrep].freeze
      PATTERN_FLAGS = %w[-e -f --regexp --file].freeze
      VALUE_OPTS = %w[-e -f -m -A -B -C -d -k -t -T -o --regexp --file --max-count --context --include --exclude --glob -g].freeze
      ALSO_READS = %w[cp mv scp rsync install ln].freeze
      OTHER_READERS = %w[sed rev paste shuf base32 dd tar vim vi view nvim nano emacs ed ex perl ruby].freeze
      EDITORS = %w[vim vi view nvim nano emacs ed ex].freeze
      EDITOR_VALUE = %w[-c -S -u -i -T -t -d -s -w -W -U --cmd -l -x].freeze
      LOOP_VALUE_LETTERS = %w[e E I r M m C F].freeze
      GIT_GLOBAL_VALUE = %w[-C -c --git-dir --work-tree --namespace --super-prefix --attr-source --config-env --exec-path].freeze
      HTTP_CLIENTS = %w[curl wget http https].freeze
      RECURSIVE_ALWAYS = %w[rg ag].freeze
      RECURSIVE_FLAGS = /\A-[A-Za-z]*[rRa][A-Za-z]*\z|\A--recursive\z/.freeze
      CURL_FILE_FLAGS = %w[-d --data --data-binary --data-ascii --data-urlencode -F --form --form-string --json].freeze
      CURL_UPLOAD_FLAGS = %w[-T --upload-file].freeze
      WGET_FILE_FLAGS = %w[--post-file --body-file -i --input-file].freeze
      TAR_VALUE = %w[-C --directory -f --file -T --files-from -X --exclude-from --exclude].freeze

      class << self
        def classify(cmd)
          recursive = recursive_reader?(cmd)
          reads = candidates(cmd).filter_map do |path|
            extra = recursive ? { "recursive" => true } : {}
            Support.read_action(Support.abs(path, cmd.cwd), cmd.text, extra)
          end
          reads + redirected(cmd) + declared_reads(cmd)
        end

        def declared_reads(cmd)
          Array(cmd.reads).filter_map { |path| Support.read_action(Support.abs(path, cmd.cwd), cmd.text) }
        end

        def sourced(tool_name, tool_input, cwd)
          script = Support.script_for(tool_name, tool_input, cwd)
          return [] unless script

          Array(script.sourced).filter_map { |path| Support.read_action(path, script.text, { "sourced" => true }) }
        end

        def redirected(cmd)
          cmd.redirects.select(&:read?).filter_map { |redirect| Support.read_action(Support.abs(redirect.target, cmd.cwd), cmd.text) }
        end

        def recursive_reader?(cmd)
          return true if cmd.recursive || RECURSIVE_ALWAYS.include?(cmd.name)

          flags = Support.split_args(cmd.args, VALUE_OPTS).last
          case cmd.name
          when "grep", "egrep", "fgrep", "cp", "rsync", "scp", "zip" then flags.any? { |flag| RECURSIVE_FLAGS.match?(flag) } || (cmd.name == "grep" && cmd.args.each_cons(2).any? { |a, b| a == "-d" && b == "recurse" })
          when "tar" then Fs.create_mode?(cmd.args)
          else false
          end
        end

        def candidates(cmd)
          return [Shell.syntax_invocation(cmd.argv)[:file]].compact if cmd.syntax_only

          return Support.split_args(cmd.args, Fs::COMPRESSOR_VALUE).first.reject { |arg| arg == "-" } if Fs.to_stdout?(cmd)
          return shell_file(cmd) if Shell::SHELLS.include?(cmd.name)
          return git_files(cmd) if cmd.name == "git"
          return http_files(cmd) if HTTP_CLIENTS.include?(cmd.name)
          return other_reader(cmd) if OTHER_READERS.include?(cmd.name)
          return [] unless NAMES.include?(cmd.name) || ALSO_READS.include?(cmd.name)

          pos, flags = Support.split_args(cmd.args, VALUE_OPTS)
          pos = pos.drop(1) if PATTERN_FIRST.include?(cmd.name) && (flags & PATTERN_FLAGS).empty?
          pos += pattern_files(cmd) if PATTERN_FIRST.include?(cmd.name)
          pos = pos.first([pos.length - 1, 0].max) if ALSO_READS.include?(cmd.name) && !Support.option_value_cluster(cmd.args, %w[t], %w[--target-directory])
          pos = pos.reject { |arg| arg == "-" || arg.start_with?("<(", ">(") }
          pos = pos + piped_operands(cmd) if cmd.xargs
          pos = ["."] if pos.empty? && (RECURSIVE_ALWAYS.include?(cmd.name) || (%w[grep egrep fgrep].include?(cmd.name) && recursive_reader?(cmd))) && !cmd.piped_in?
          pos
        end

        def pattern_files(cmd)
          Support.option_values(cmd.args, "-f", "--file").reject { |file| file == "-" }
        end

        def piped_operands(cmd)
          up = cmd.upstream.last
          return [] unless up && %w[echo printf].include?(up.name)

          up.args.map(&:to_s).reject { |arg| arg.start_with?("-") }
        end

        def shell_file(cmd)
          file = Shell.script_operand(cmd.args)
          file.nil? || Support.dynamic?(file) ? [] : [file.to_s]
        end

        def other_reader(cmd)
          case cmd.name
          when "sed" then Fs.sed_parse(cmd.args.map(&:to_s))[1]
          when "dd" then cmd.args.filter_map { |arg| arg[/\Aif=(.+)/, 1] }
          when "perl", "ruby" then loop_files(cmd)
          when *EDITORS then Support.split_args(cmd.args.map(&:to_s).reject { |arg| arg.start_with?("+") }, EDITOR_VALUE).first.reject { |arg| arg == "-" }
          when "tar" then tar_sources(cmd.args)
          else Support.split_args(cmd.args).first.reject { |arg| arg == "-" }
          end
        end

        def loop_files(cmd)
          rest = cmd.args.map(&:to_s)
          looping = false
          files = []
          until rest.empty?
            arg = rest.shift
            if arg == "--"
              files.concat(rest)
              break
            elsif arg.match?(/\A-[A-Za-z0-9]+\z/)
              letters = arg[1..].chars
              looping = true if letters.any? { |letter| %w[n p].include?(letter) }
              at = letters.index { |letter| LOOP_VALUE_LETTERS.include?(letter) }
              rest.shift if at && at == letters.length - 1
            elsif !arg.start_with?("-")
              files << arg
            end
          end
          looping ? files : []
        end

        def git_files(cmd)
          args = cmd.args.map(&:to_s)
          until args.empty? || !args.first.start_with?("-")
            opt = args.shift
            args.shift if GIT_GLOBAL_VALUE.include?(opt)
          end
          sub = args.shift
          case sub
          when "hash-object"
            Support.split_args(args, %w[-t --path --stdin-paths]).first.reject { |arg| arg == "-" }
          when "diff"
            args.include?("--no-index") ? Support.split_args(args, %w[-U --unified --output]).first.reject { |arg| arg == "-" } : []
          else []
          end
        end

        def tar_sources(args)
          return [] unless Fs.create_mode?(args)

          rest = args.map(&:to_s)
          at = Fs.clusters(rest).find { |i| rest[i].include?("f") }
          rest.delete_at(at + 1) if at && rest[at + 1]
          rest = rest.drop(1) if rest.first.to_s.match?(Fs::BARE)
          skip = %w[-C --directory -T --files-from -X --exclude-from --exclude]
          out = []
          until rest.empty?
            arg = rest.shift
            if skip.include?(arg)
              rest.shift
            elsif !arg.start_with?("-")
              out << arg
            end
          end
          out
        end

        def http_files(cmd)
          args = cmd.args.map(&:to_s)
          found = []
          args.each_with_index do |arg, i|
            if arg.start_with?("file://")
              found << arg.sub(%r{\Afile://(?:localhost)?}, "")
            elsif cmd.name == "curl"
              flag, value = flag_value(arg, args[i + 1], CURL_FILE_FLAGS + CURL_UPLOAD_FLAGS)
              next unless flag

              found << (CURL_UPLOAD_FLAGS.include?(flag) ? value : upload_path(value))
            elsif cmd.name == "wget"
              flag, value = flag_value(arg, args[i + 1], WGET_FILE_FLAGS)
              found << value if flag
            else
              found << arg[/\A[A-Za-z0-9_.-]+(?:=@|:=@)(.+)\z/, 1].to_s unless arg.start_with?("-")
            end
          end
          found.compact.reject { |path| path.empty? || path == "-" }
        end

        def flag_value(arg, following, flags)
          return [arg, following] if flags.include?(arg) && following
          return nil unless arg.start_with?("-")

          flags.each do |flag|
            return [flag, arg.delete_prefix("#{flag}=")] if flag.start_with?("--") && arg.start_with?("#{flag}=")
            return [flag, arg[2..]] if !flag.start_with?("--") && arg.start_with?(flag) && arg.length > 2 && !arg.start_with?("--")
          end
          nil
        end

        def upload_path(value)
          text = value.to_s
          text[/\A@(.+)/, 1] || text[/\A[^=@]*=[@<](.+)/, 1] || text[/\A[^=@]+@(.+)/, 1]
        end
      end
    end

    Registry.register("secrets", Secrets)
  end
end
