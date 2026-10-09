#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "support"

module Polispec
  module Classify
    module Fs
      extend Support::Family

      NAMES = %w[rm rmdir unlink shred touch mkdir chmod chown chgrp truncate tee patch install ln mv cp rsync scp dd sed perl curl wget tar unzip gzip gunzip bzip2 xz find rename].freeze
      READ_ONLY_EXEC = %w{cat grep egrep fgrep rg ls head tail wc file stat echo printf md5sum sha1sum sha256sum du test [ true false basename dirname readlink realpath}.freeze
      REMOTE = %r{\A[\w.@-]+:(?!/)}.freeze
      DEST_VALUE = %w[-t --target-directory -S --suffix -m --mode -o -g --owner --group -e --rsh --exclude --include --filter --files-from --exclude-from --include-from].freeze
      SCP_VALUE = %w[-P -i -o -F -J -l -S -c].freeze
      SED_VALUE = %w[-e -f -l --expression --file --line-length].freeze
      PERL_VALUE = %w[-e -E -I -M -m -0 -x].freeze
      IN_PLACE = /\A--in-place|\A-[a-zA-Z]*i/.freeze

      class << self
        def classify(cmd)
          writes = write_paths(cmd).map { |path| Support.write_action(path, cmd.text) }
          writes + redirect_writes(cmd)
        end

        def redirect_writes(cmd)
          cmd.redirects.filter_map do |redirect|
            next unless redirect.write?
            next if redirect.target.to_s.match?(/\A(?:\d+|-)\z/)

            Support.write_action(Support.abs(redirect.target, cmd.cwd), cmd.text)
          end
        end

        def write_paths(cmd)
          return [] unless NAMES.include?(cmd.name)

          paths = targets(cmd)
          paths = [cmd.cwd] if paths.nil?
          paths.map { |path| Support.abs(path, cmd.cwd) }
        end

        def targets(cmd)
          args = cmd.args
          case cmd.name
          when "rm", "rmdir", "unlink", "shred", "mkdir", "rename"
            nonempty(Support.split_args(args).first)
          when "gzip", "gunzip", "bzip2", "xz", "tee" then Support.split_args(args).first
          when "touch" then nonempty(Support.split_args(args, %w[-d -r -t --date --reference]).first)
          when "chmod", "chown", "chgrp" then nonempty(Support.split_args(args).first.drop(1))
          when "truncate" then nonempty(Support.split_args(args, %w[-s -r --size --reference]).first)
          when "mv" then moved(args)
          when "cp", "rsync", "scp", "install", "ln" then destination(cmd)
          else specific(cmd)
          end
        end

        def specific(cmd)
          case cmd.name
          when "dd" then nonempty(cmd.args.filter_map { |arg| arg[/\Aof=(.+)/, 1] })
          when "sed", "perl" then in_place(cmd)
          when "patch" then nonempty(Support.split_args(cmd.args, %w[-p -i -d -o --input --directory --strip]).first)
          when "curl" then curl(cmd)
          when "wget" then wget(cmd)
          when "tar" then archive(cmd)
          when "unzip" then unzip(cmd)
          when "find" then find(cmd)
          end
        end

        def nonempty(list)
          list.nil? || list.empty? ? nil : list
        end

        def moved(args)
          pos, = Support.split_args(args, DEST_VALUE)
          target = Support.option_value(args, "-t", "--target-directory")
          nonempty(target ? pos + [target] : pos)
        end

        def destination(cmd)
          value = cmd.name == "scp" ? DEST_VALUE + SCP_VALUE : DEST_VALUE
          pos, flags = Support.split_args(cmd.args, value)
          target = Support.option_value(cmd.args, "-t", "--target-directory")
          return [target] if target
          return pos if cmd.name == "install" && flags.include?("-d")
          return nil if pos.length < 2

          pos.last.to_s.match?(REMOTE) ? [] : [pos.last]
        end

        def in_place(cmd)
          value = cmd.name == "sed" ? SED_VALUE : PERL_VALUE
          pos, flags = Support.split_args(cmd.args, value)
          return [] unless flags.any? { |flag| IN_PLACE.match?(flag) }

          scripted = flags.any? { |flag| %w[-e -E -f --expression --file].include?(flag) }
          nonempty(scripted ? pos : pos.drop(1))
        end

        def curl(cmd)
          out = Support.option_value(cmd.args, "-o", "--output")
          return [] if out == "-"

          dir = Support.option_value(cmd.args, "--output-dir")
          out ||= "." if cmd.args.include?("-O") || cmd.args.include?("--remote-name")
          out ? [dir ? File.join(dir, out) : out] : []
        end

        def wget(cmd)
          out = Support.option_value(cmd.args, "-O", "--output-document")
          return [] if out == "-"

          dir = Support.option_value(cmd.args, "-P", "--directory-prefix")
          out ||= "."
          [dir ? File.join(dir, out) : out]
        end

        def archive(cmd)
          args = cmd.args
          extract = args.first.to_s.match?(/\A[a-zA-Z]*x/) || args.any? { |arg| arg.match?(/\A-[a-zA-Z]*x/) || arg == "--extract" }
          return [Support.option_value(args, "-C", "--directory") || "."] if extract

          create = args.first.to_s.match?(/\A-?[a-zA-Z]*c/) || args.include?("--create")
          file = Support.option_value(args, "-f", "--file")
          create && file && file != "-" ? [file] : []
        end

        def unzip(cmd)
          return [] if cmd.args.any? { |arg| %w[-l -p -t -v].include?(arg) }

          [Support.option_value(cmd.args, "-d") || "."]
        end

        def find(cmd)
          args = cmd.args
          starts = args.take_while { |arg| !arg.start_with?("-") && !%w[( ! ,].include?(arg) }
          starts = ["."] if starts.empty?
          return starts if args.include?("-delete")

          exec_at = args.index { |arg| %w[-exec -execdir -ok -okdir].include?(arg) }
          return [] unless exec_at

          READ_ONLY_EXEC.include?(File.basename(args[exec_at + 1].to_s)) ? [] : starts
        end
      end
    end

    Registry.register("fs", Fs)
  end
end
