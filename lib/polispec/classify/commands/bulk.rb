#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "support"
require_relative "fs"
require_relative "git"

module Polispec
  module Classify
    module Bulk
      extend Support::Family

      NAMES = %w[zip 7z 7za 7zr 7zz ffmpeg mysqldump pg_dump pg_dumpall].freeze
      SEVEN_ZIP = %w[7z 7za 7zr 7zz].freeze
      WRITERS = (NAMES + %w[curl wget cp rsync dd]).freeze
      ZIP_VALUE = %w[-O --output-file -b --temp-path -t --from-date -tt --before-date -P --password -n --suffixes -Z --compression-method].freeze
      FFMPEG_VALUE = %w[-i -f -c -c:v -c:a -b:v -b:a -r -s -t -ss -to -map -vf -af -vframes -preset -crf -ar -ac -pix_fmt -loglevel].freeze
      GENERIC = %w[7z 7za 7zr 7zz ffmpeg mysqldump].freeze
      GIT_BULK = %w[archive bundle].freeze

      class << self
        def classify(cmd)
          found = outputs(cmd).reject { |path| Support.dynamic?(path) }.filter_map do |path|
            Support.write_action(Support.abs(path, cmd.cwd), cmd.text)
          end
          return found unless found.empty? && GENERIC.include?(cmd.name)

          [Support.act("fs.write", cmd.text, "path" => cmd.cwd, "unknown" => true, "command" => cmd.name)]
        end

        def shapes(cmd)
          writer?(cmd) || cmd.upstream.any? { |up| writer?(up) } ? ["bulk_write"] : []
        end

        def writer?(cmd)
          name = cmd.name
          return Fs.create_mode?(cmd.args) if name == "tar"
          return GIT_BULK.include?(Git.invocation(cmd)&.sub) if name == "git"

          WRITERS.include?(name)
        end

        def outputs(cmd)
          case cmd.name
          when "zip" then zip(cmd)
          when *SEVEN_ZIP then seven_zip(cmd)
          when "ffmpeg" then ffmpeg(cmd)
          when "mysqldump" then mysqldump(cmd)
          when "pg_dump", "pg_dumpall" then pg_dump(cmd)
          when "git" then git(cmd)
          else []
          end
        end

        def zip(cmd)
          named = Support.option_value(cmd.args, "-O", "--output-file")
          return [named] if named

          first = Support.split_args(cmd.args, ZIP_VALUE).first.first
          first ? [first] : []
        end

        def seven_zip(cmd)
          pos, = Support.split_args(cmd.args)
          %w[a u].include?(pos.first) && pos[1] ? [pos[1]] : []
        end

        def ffmpeg(cmd)
          last = nil
          value = false
          cmd.args.each do |arg|
            if value
              value = false
              last = [arg, true]
            elsif FFMPEG_VALUE.include?(arg)
              value = true
            elsif !arg.start_with?("-")
              last = [arg, false]
            end
          end
          last && !last.last && !value ? [last.first] : []
        end

        def mysqldump(cmd)
          file = Support.option_value(cmd.args, "--result-file", "-r")
          file ? [file] : []
        end

        def pg_dump(cmd)
          file = Support.option_value(cmd.args, "-f", "--file")
          file.nil? || file.start_with?("-") ? [] : [file]
        end

        def git(cmd)
          inv = Git.invocation(cmd)
          return [] unless inv

          paths = case inv.sub
                  when "archive" then archive_output(inv.args)
                  when "bundle" then bundle_output(inv.args)
                  else []
                  end
          paths.reject { |path| Support.dynamic?(path) }.map { |path| Support.abs(path, inv.path) }
        end

        def archive_output(args)
          file = Support.option_value(args, "-o", "--output")
          file ? [file] : []
        end

        def bundle_output(args)
          pos, = Support.split_args(args)
          pos.first == "create" && pos[1] ? [pos[1]] : []
        end
      end
    end

    Registry.register("bulk", Bulk)
  end
end
