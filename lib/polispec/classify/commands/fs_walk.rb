#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require_relative "support"

module Polispec
  module Classify
    module FsWalk
      FIND_NAMES = %w[find bfs].freeze
      FD_NAMES = %w[fd fdfind].freeze
      GREP_NAMES = %w[grep egrep fgrep].freeze
      FIND_LEADING = %w[-H -L -P].freeze
      BFS_LEADING = %w[-E -X -d -s].freeze
      FIND_ONE_FS = %w[-xdev -mount].freeze
      DU_VALUE = %w[-B -d -t -X --block-size --max-depth --threshold --exclude --exclude-from --files0-from].freeze
      FD_VALUE = %w[-d --max-depth --min-depth --exact-depth -t --type -e --extension -E --exclude -c --color -j --threads -S --size -o --owner --changed-within --changed-before --changed-after --newer --older --max-results --base-directory --ignore-file --path-separator --strip-cwd-prefix --batch-size --format].freeze
      FD_EXEC = %w[-x --exec -X --exec-batch].freeze
      FD_ONE_FS = %w[--one-file-system --mount --xdev].freeze
      RG_VALUE = %w[-e --regexp -f --file -g --glob --iglob -t --type -T --type-not -A --after-context -B --before-context -C --context -m --max-count -j --threads -d --max-depth --maxdepth -M --max-columns -E --encoding -r --replace --ignore-file --pre --pre-glob --sort --sortr --type-add --type-clear --colors --color --max-filesize --path-separator --context-separator --field-context-separator --field-match-separator --engine --dfa-size-limit --regex-size-limit --hostname-bin --hyperlink-format --generate --glob-case-insensitive].freeze
      RG_PATTERN = %w[-e --regexp -f --file].freeze
      GREP_VALUE = %w[-e -f -m -A -B -C -d -D -T --regexp --file --max-count --after-context --before-context --context --include --exclude --exclude-dir --exclude-from --include-dir --label --color --colour --directories --devices --binary-files].freeze
      GREP_PATTERN = %w[-e -f --regexp --file].freeze
      GREP_RECURSIVE = %w[--recursive --dereference-recursive --directories=recurse].freeze
      LS_VALUE = %w[-I -w -T --ignore --width --tabsize --block-size --time-style --format --sort --color --indicator-style --hide --quoting-style --time].freeze
      TREE_VALUE = %w[-L -P -I -o --charset --filelimit --sort --timefmt --fromfile --matchdirs --level --prune --ignore].freeze
      SLOW_TYPES = %w[fuse fuseblk nfs nfs4 cifs smb3 smbfs sshfs 9p].freeze
      SLOW_ROOTS = %w[/run/media /media /mnt].freeze
      MOUNTINFO = "/proc/self/mountinfo"

      Mount = Struct.new(:point, :type)

      module_function

      def actions(cmd)
        starts = starts(cmd)
        return [] if starts.nil?

        stay = one_filesystem?(cmd)
        starts.flat_map { |start| walks(cmd, start, stay) }
      end

      def shapes(cmd)
        actions(cmd).filter_map do |action|
          case action.env_hint["walk"]
          when "root" then "root_walk"
          when "slow_mount" then "slow_mount_walk"
          end
        end.uniq
      end

      def walks(cmd, start, stay)
        return [] if start.nil?

        path = root?(start) ? "/" : start
        found = []
        found << Support.act("fs.walk", cmd.text, "path" => "/", "walk" => "root", "command" => cmd.name) if path == "/" && !stay
        mount = owner(path)
        if mount && slow?(mount)
          found << slow_action(cmd, path, mount.type)
        elsif !stay
          under = slow_under(path)
          found << slow_action(cmd, under.point, under.type) if under
        end
        found
      end

      def slow_under(path)
        real = resolve(path)
        prefix = real == "/" ? "/" : "#{real}/"
        mounts.select { |mount| mount.point != real && mount.point.start_with?(prefix) && slow?(mount) }.min_by(&:point)
      end

      def resolve(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end

      def slow_action(cmd, path, type)
        Support.act("fs.walk", cmd.text, "path" => path, "walk" => "slow_mount", "command" => cmd.name, "fstype" => type)
      end

      def root?(path)
        path == "/" || path == "/*"
      end

      def starts(cmd)
        list = raw_starts(cmd)
        return nil if list.nil?

        list = ["."] if list.empty?
        list.reject { |path| Support.dynamic?(path) }.map { |path| normalize(Support.abs(path, cmd.cwd), path) }
      end

      def normalize(absolute, given)
        return "/*" if given.to_s.match?(%r{\A/+\*\z})

        File.expand_path(absolute)
      end

      def raw_starts(cmd)
        args = cmd.args
        case cmd.name
        when *FIND_NAMES then find_starts(cmd)
        when "du" then Support.split_args(args, DU_VALUE).first
        when *FD_NAMES then fd_starts(args)
        when "rg" then rg_starts(args)
        when *GREP_NAMES then grep_recursive?(args) ? grep_starts(args) : nil
        when "ls" then ls_recursive?(args) ? Support.split_args(args, LS_VALUE).first : nil
        when "tree" then Support.split_args(args, TREE_VALUE).first
        end
      end

      def find_starts(cmd)
        leading = FIND_LEADING + (cmd.name == "bfs" ? BFS_LEADING : [])
        args = cmd.args.drop_while { |arg| leading.include?(arg) }
        args.take_while { |arg| !arg.start_with?("-") && !%w[( ! ,].include?(arg) }
      end

      def fd_starts(args)
        cut = args.index { |arg| FD_EXEC.include?(arg) } || args.length
        head = args.first(cut)
        searched = Support.option_values(head, "--search-path")
        return searched unless searched.empty?

        Support.split_args(head, FD_VALUE).first.drop(1)
      end

      def rg_starts(args)
        positional, flags = Support.split_args(args, RG_VALUE)
        return positional if flags.include?("--files") || explicit_pattern?(flags, RG_PATTERN)

        positional.drop(1)
      end

      def grep_starts(args)
        positional, flags = Support.split_args(args, GREP_VALUE)
        explicit_pattern?(flags, GREP_PATTERN) ? positional : positional.drop(1)
      end

      def explicit_pattern?(flags, names)
        flags.any? { |flag| names.include?(flag) || flag.start_with?("--regexp=", "--file=") }
      end

      def grep_recursive?(args)
        return true if args.each_cons(2).any? { |flag, value| %w[-d --directories].include?(flag) && value == "recurse" }

        Support.split_args(args, GREP_VALUE).last.any? do |flag|
          GREP_RECURSIVE.include?(flag) || (!flag.start_with?("--") && flag.match?(/\A-[A-Za-z]*[rR]/))
        end
      end

      def ls_recursive?(args)
        Support.split_args(args, LS_VALUE).last.any? do |flag|
          flag == "--recursive" || (!flag.start_with?("--") && flag.match?(/\A-[A-Za-z]*R/))
        end
      end

      def one_filesystem?(cmd)
        args = cmd.args
        case cmd.name
        when *FIND_NAMES then args.any? { |arg| FIND_ONE_FS.include?(arg) }
        when "du" then Support.split_args(args, DU_VALUE).last.any? { |flag| flag == "--one-file-system" || (!flag.start_with?("--") && flag.match?(/\A-[A-Za-z]*x/)) }
        when "rg" then args.include?("--one-file-system")
        when *FD_NAMES then args.any? { |arg| FD_ONE_FS.include?(arg) }
        else false
        end
      end

      def slow?(mount)
        type = mount.type.to_s
        return true if SLOW_TYPES.include?(type) || type.start_with?("fuse.")

        SLOW_ROOTS.any? { |root| mount.point == root || mount.point.start_with?("#{root}/") }
      end

      def owner(path)
        real = resolve(path)
        mounts.select { |mount| mount.point == "/" || real == mount.point || real.start_with?("#{mount.point}/") }.max_by { |mount| mount.point.length }
      end

      def mounts
        file = ENV["POLISPEC_MOUNTINFO"].to_s
        file = MOUNTINFO if file.empty?
        @mounts ||= {}
        @mounts[file] ||= parse(file)
      end

      def parse(file)
        File.foreach(file).filter_map do |line|
          head, tail = line.chomp.split(" - ", 2)
          next unless head && tail

          point = head.split(" ")[4]
          type = tail.split(" ").first
          next unless point && type

          Mount.new(unescape(point), type)
        end
      rescue SystemCallError, IOError
        []
      end

      def unescape(text)
        text.gsub(/\\([0-7]{3})/) { Regexp.last_match(1).to_i(8).chr }
      end
    end
  end
end
