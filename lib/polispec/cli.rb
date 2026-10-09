#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "layers"

module Polispec
  module CLI
    COMMANDS_DIR = File.join(LIB, "commands")
    VERB = /\A[a-z][a-z0-9-]*\z/
    Entry = Struct.new(:name, :klass, :summary)

    @commands = {}
    @load_errors = []
    @all_loaded = false

    class Validate
      USAGE = "usage: polispec validate <policy|environments|roster|ledger|behavior|global|module|profiles|auto> <file> [--json]"

      def run(args)
        json = args.delete("--json")
        kind, file = args
        return usage unless file && args.length == 2 && (Schema::KINDS + ["auto"]).include?(kind)

        result = merged_result(kind, file) || Schema.validate_file(kind, file)
        result = with_semantics(result, kind, file)
        json ? puts(JSON.generate(result.to_h)) : print_text(result, file)
        result.ok ? 0 : 1
      end

      private

      def merged_result(kind, file)
        return nil unless %w[policy auto].include?(kind)

        data = Schema::Document.load(file)
        return nil unless data.is_a?(Hash) && data["schema"] == Schema.schema_id("policy") && !data.key?("environments")

        sibling = Environments.read_file(File.expand_path(file))
        return nil unless sibling

        errors = sibling.errors ? sibling.errors.map { |item| Schema::Error.new("/environments.yml#{item['pointer']}", item["message"]) } : []
        if errors.empty?
          merged, finding = Environments.merge(data, sibling.data)
          @merged = merged
          errors = finding ? [Schema::Error.new("/environments.yml", finding["detail"])] : Schema.validate("policy", merged)
        end
        Schema::Result.new(errors.empty?, errors.empty? ? "#{Schema.schema_id('policy')} + environments.yml" : Schema.schema_id("policy"), errors)
      rescue Schema::Document::ParseError
        nil
      end

      def with_semantics(result, kind, file)
        return result unless result.ok

        data = @merged || Schema::Document.load(file)
        kind = Schema.kind_for(data).to_s if kind == "auto"
        errors = semantic_errors(kind, data, file)
        errors.empty? ? result : Schema::Result.new(false, result.schema, errors)
      rescue Schema::Document::ParseError
        result
      end

      def semantic_errors(kind, data, file)
        case kind
        when "policy"
          health = Operator::Gates.health_required_errors(data).map { |message| Schema::Error.new("/environments", message) }
          health + Layers.policy_errors(data).map { |message| Schema::Error.new("/layers", message) }
        when "global", "module"
          Layers.document_errors(kind, data, file).map { |message| Schema::Error.new("/layers", message) }
        else
          []
        end
      end

      def usage
        warn USAGE
        2
      end

      def print_text(result, file)
        if result.ok
          puts "#{file}: ok (#{result.schema})"
        else
          puts "#{file}: invalid#{" (#{result.schema})" if result.schema}"
          result.errors.each { |error| puts "  #{error.pointer.empty? ? '/' : error.pointer}  #{error.message}" }
        end
      end
    end

    class << self
      attr_reader :load_errors

      def register(name, klass, summary: nil)
        @commands[name.to_s] = Entry.new(name.to_s, klass, summary)
        klass
      end

      def commands
        @commands.dup
      end

      def run(argv)
        verb, *rest = argv
        return help(0) if verb.nil? || %w[help --help -h].include?(verb)
        return version if %w[version --version -V].include?(verb)

        entry = find(verb)
        return unknown(verb) unless entry

        invoke(entry, rest)
      rescue Polispec::Error => e
        warn "polispec: #{e.message}"
        1
      end

      def load_all
        return if @all_loaded

        @all_loaded = true
        Dir.glob(File.join(COMMANDS_DIR, "*.rb")).sort.each { |file| load_command_file(file) }
      end

      private

      def find(verb)
        return @commands[verb] if @commands.key?(verb)
        return nil unless VERB.match?(verb)

        load_command_file(File.join(COMMANDS_DIR, "#{verb.tr('-', '_')}.rb"))
        return @commands[verb] if @commands.key?(verb)

        load_all
        @commands[verb]
      end

      def load_command_file(file)
        require file if File.file?(file)
      rescue StandardError, ScriptError => e
        @load_errors << [file, e.message]
      end

      def invoke(entry, args)
        klass = entry.klass
        status = klass.respond_to?(:run) ? klass.run(args) : klass.new.run(args)
        status.is_a?(Integer) ? status : 0
      end

      def version
        puts "polispec #{Polispec.version}"
        0
      end

      def unknown(verb)
        warn "polispec: unknown command #{verb}"
        @load_errors.each { |file, message| warn "polispec: failed to load #{file}: #{message}" }
        help(2, io: $stderr)
      end

      def help(status, io: $stdout)
        load_all
        io.puts "polispec #{Polispec.version}: spec-based policy guardrails"
        io.puts
        io.puts "  validate <policy|environments|roster|ledger|behavior|global|module|profiles|auto> <file> [--json]   check a file against its schema"
        @commands.values.reject { |entry| entry.name == "validate" }.sort_by(&:name).each do |entry|
          io.puts format("  %-12s %s", entry.name, entry.summary)
        end
        io.puts "  version                                                print the version"
        status
      end
    end

    register("validate", Validate, summary: "check a file against its schema")
  end
end
