#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "support"

module Polispec
  module Classify
    module Secrets
      extend Support::Family

      NAMES = %w[cat head tail less more bat tac nl od xxd hexdump strings base64 grep egrep fgrep rg ag awk cut sort uniq wc diff cmp comm jq yq file stat source . openssl gpg sqlite3 zip].freeze
      PATTERN_FIRST = %w[grep egrep fgrep rg ag awk].freeze
      PATTERN_FLAGS = %w[-e -f --regexp --file].freeze
      VALUE_OPTS = %w[-e -f -m -A -B -C -d -k -t -T -o --regexp --file --max-count --context --include --exclude --glob -g].freeze
      ALSO_READS = %w[cp mv scp rsync].freeze

      class << self
        def classify(cmd)
          candidates(cmd).filter_map { |path| Support.read_action(Support.abs(path, cmd.cwd), cmd.text) } + redirected(cmd)
        end

        def redirected(cmd)
          cmd.redirects.select(&:read?).filter_map { |redirect| Support.read_action(Support.abs(redirect.target, cmd.cwd), cmd.text) }
        end

        def candidates(cmd)
          return [] unless NAMES.include?(cmd.name) || ALSO_READS.include?(cmd.name)

          pos, flags = Support.split_args(cmd.args, VALUE_OPTS)
          pos = pos.drop(1) if PATTERN_FIRST.include?(cmd.name) && (flags & PATTERN_FLAGS).empty?
          pos = pos.first([pos.length - 1, 0].max) if ALSO_READS.include?(cmd.name) && !cmd.args.include?("-t")
          pos.reject { |arg| arg == "-" || arg.start_with?("<(", ">(") }
        end
      end
    end

    Registry.register("secrets", Secrets)
  end
end
