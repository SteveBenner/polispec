#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "support"

module Polispec
  module Classify
    module Postgres
      extend Support::Family

      NAMES = %w[psql createdb dropdb pg_dump pg_dumpall pg_restore vacuumdb reindexdb clusterdb].freeze
      CONNECT_VALUE = %w[-h --host -p --port -U --username -d --dbname -c --command -f --file -o --output -L --log-file -v --set --variable -F --field-separator -R --record-separator -P --pset -T --table-attr -O --owner -E --encoding -l --locale -D --tablespace -j --jobs -n --schema -N --exclude-schema -t --table -Z --compress -S --superuser --role --format].freeze
      DUMP_VALUE = (CONNECT_VALUE + %w[-T --exclude-table --exclude-table-data --lock-wait-timeout --section]).uniq.freeze
      WRITE_SQL = /\A\s*(?:insert|update|delete|drop|create|alter|truncate|grant|revoke|vacuum|reindex|cluster|comment|merge|upsert|call|do|refresh|reset|import|security|lock|listen|notify|discard|prepare|execute|set\s+role|\\i\b|\\ir\b|\\!|\\copy\b.*\bfrom\b|copy\b(?!.*\bto\b))/i.freeze
      CTE_WRITE = /\b(?:insert\s+into|update\s+\S+\s+set|delete\s+from)\b/i.freeze
      MAX_SQL = 1_000_000
      OPAQUE = "drop opaque input".freeze

      class << self
        def classify(cmd)
          return [] unless NAMES.include?(cmd.name)

          case cmd.name
          when "psql" then psql(cmd)
          when "pg_dump", "pg_dumpall" then dump(cmd)
          when "pg_restore" then restore(cmd)
          when "createdb" then createdb(cmd)
          else maintenance(cmd)
          end
        end

        def psql(cmd)
          return [] if dump_fed?(cmd) || cmd.args.any? { |arg| arg == "-l" || arg == "--list" }

          sources = sql_sources(cmd)
          return [] if sources.nil? || (sources != :unknown && !sources.any? { |sql| write_sql?(sql) })

          [write_action(cmd, database(cmd, CONNECT_VALUE))]
        end

        def dump_fed?(cmd)
          cmd.piped_in? && cmd.upstream.any? { |up| %w[pg_dump pg_dumpall].include?(up.name) }
        end

        def sql_sources(cmd)
          texts = Support.option_values(cmd.args, "-c", "--command")
          files = Support.option_values(cmd.args, "-f", "--file")
          texts.concat(redirect_sql(cmd))
          files.each do |file|
            body = read_sql(Support.abs(file, cmd.cwd))
            return :unknown unless body

            texts << body
          end
          return :unknown if texts.empty? && cmd.piped_in?
          return nil if texts.empty?

          texts
        end

        def redirect_sql(cmd)
          cmd.redirects.filter_map do |redirect|
            if redirect.here? then redirect.op == "<<<" ? redirect.target : redirect.body
            elsif redirect.read? then read_sql(Support.abs(redirect.target, cmd.cwd)) || OPAQUE
            end
          end
        end

        def read_sql(path)
          return nil unless File.file?(path) && File.size(path) <= MAX_SQL

          File.read(path)
        rescue SystemCallError
          nil
        end

        def write_sql?(sql)
          sql.to_s.gsub(%r{/\*.*?\*/}m, " ").gsub(/--[^\n]*/, " ").split(";").any? do |statement|
            WRITE_SQL.match?(statement) || (statement.strip.match?(/\Awith\b/i) && CTE_WRITE.match?(statement))
          end
        end

        def database(cmd, value_opts)
          named = Support.option_value(cmd.args, "-d", "--dbname")
          pos, = Support.split_args(cmd.args, value_opts)
          raw = named || pos.first || cmd.env["PGDATABASE"]
          extract_name(raw)
        end

        def extract_name(raw)
          return nil if raw.nil? || raw.to_s.empty?

          text = raw.to_s
          return text[/dbname=(\S+)/, 1] if text.include?("dbname=")
          return text.sub(%r{\A[a-z]+://[^/]*/?}, "").sub(/\?.*\z/, "") if text.include?("://")

          text
        end

        def write_action(cmd, db)
          Support.act("data.write", cmd.text, "db" => db, "path" => cmd.cwd)
        end

        def dump(cmd)
          source = cmd.name == "pg_dumpall" ? "*" : database(cmd, DUMP_VALUE)
          [Support.act("data.copy", cmd.text, "from" => Support.hint("db" => source), "to" => destination(cmd), "path" => cmd.cwd)]
        end

        def destination(cmd)
          consumer = cmd.downstream.find { |down| %w[psql pg_restore].include?(down.name) }
          return Support.hint("db" => database(consumer, CONNECT_VALUE)) if consumer

          file = Support.option_value(cmd.args, "-f", "--file") || redirect_target(cmd) || cmd.downstream.filter_map { |down| redirect_target(down) }.first
          file ? { "path" => Support.abs(file, cmd.cwd) } : { "stdout" => true }
        end

        def redirect_target(cmd)
          cmd.redirects.find(&:write?)&.target
        end

        def restore(cmd)
          db = Support.option_value(cmd.args, "-d", "--dbname")
          db ? [write_action(cmd, extract_name(db))] : []
        end

        def createdb(cmd)
          pos, = Support.split_args(cmd.args, CONNECT_VALUE)
          name = pos.first
          template = Support.option_value(cmd.args, "-T", "--template")
          return [] unless name
          return [Support.act("data.write", cmd.text, "db" => name, "path" => cmd.cwd)] unless template

          [Support.act("data.copy", cmd.text, "from" => { "db" => template }, "to" => { "db" => name }, "path" => cmd.cwd)]
        end

        def maintenance(cmd)
          pos, = Support.split_args(cmd.args, CONNECT_VALUE)
          db = Support.option_value(cmd.args, "-d", "--dbname") || pos.first
          db ? [write_action(cmd, extract_name(db))] : []
        end
      end
    end

    Registry.register("postgres", Postgres)
  end
end
