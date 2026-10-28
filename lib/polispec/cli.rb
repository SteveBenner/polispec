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
      USAGE = "usage: polispec validate <policy|environments|roster|ledger|behavior|spec|waivers|global|module|profiles|control|smoke|smoke-scenario|package|judgment|exceptions|delegate_grants|editions|session|change|manifest|app|index|contract|contract-vocabulary|catalog|catalog-state|features|proof|auto> <file> [--json] [--semantic]"

      def run(args)
        json = args.delete("--json")
        semantic = args.delete("--semantic")
        kind, file = args
        return usage unless file && args.length == 2 && (Schema::KINDS + ["auto"]).include?(kind)

        require_relative "schema/check"
        outcome = Schema::Check.call(kind, file, semantic: semantic)
        result = outcome.result
        extra = { "warnings" => outcome.warnings }
        extra["semantic"] = outcome.semantic if outcome.semantic
        warnings = extra.fetch("warnings", [])
        failed = !result.ok || (!warnings.empty? && Engine::Settings.description_strict?)
        json ? puts(JSON.generate(result.to_h.merge(json_extra(extra, failed)))) : print_text(result, file, extra)
        failed ? 1 : 0
      end

      private

      def json_extra(extra, failed)
        out = {}
        out["warnings"] = extra["warnings"] unless extra.fetch("warnings", []).empty?
        out["semantic"] = extra["semantic"] if extra["semantic"]
        out["ok"] = false if failed
        out
      end

      def usage
        warn USAGE
        2
      end

      def print_text(result, file, extra = {})
        if result.ok
          puts "#{file}: ok (#{result.schema})"
        else
          puts "#{file}: invalid#{" (#{result.schema})" if result.schema}"
          result.errors.each { |error| puts "  #{error.pointer.empty? ? '/' : error.pointer}  #{error.message}" }
        end
        strict = Engine::Settings.description_strict?
        extra.fetch("warnings", []).each { |item| puts "  #{strict ? 'error' : 'warning'}: #{item['code']}: #{item['message']}" }
        print_semantic(extra["semantic"]) if extra["semantic"]
      end

      def print_semantic(semantic)
        if semantic["status"] == "judged"
          puts "  semantic: #{semantic['choice']} (probability #{format('%.2f', semantic['probability'].to_f)})"
        else
          puts "  semantic: #{semantic['note']}"
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
        argv, mode, error = extract_trace(argv)
        if error
          warn error
          return 2
        end
        verb, *rest = argv
        return help(0) if verb.nil? || %w[help --help -h].include?(verb)
        return version if %w[version --version -V].include?(verb)

        entry = find(verb)
        return unknown(verb) unless entry

        mode ? invoke_traced(entry, verb, rest, mode) : invoke(entry, rest)
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

      def extract_trace(argv)
        wanted = ENV.key?("POLISPEC_VERBOSE") || argv.any? { |token| token.start_with?("-v", "--verbose") }
        wanted ? Trace.extract(argv, ENV) : [argv, nil, nil]
      end

      def invoke_traced(entry, verb, args, mode)
        owner = !Trace.on?
        Trace.configure(mode, op: verb)
        status = 1
        begin
          status = invoke(entry, args)
        rescue Polispec::Error => e
          warn "polispec: #{e.message}"
          status = 1
        rescue SystemExit => e
          status = e.status
          raise
        ensure
          Trace.finish(status) if owner
        end
        status
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
        io.puts "  validate <policy|environments|roster|ledger|behavior|spec|waivers|global|module|profiles|control|smoke|smoke-scenario|package|judgment|exceptions|delegate_grants|editions|session|change|manifest|app|index|contract|contract-vocabulary|catalog|catalog-state|features|proof|auto> <file> [--json] [--semantic]   check a file against its schema"
        @commands.values.reject { |entry| entry.name == "validate" }.sort_by(&:name).each do |entry|
          io.puts format("  %-12s %s", entry.name, entry.summary)
        end
        io.puts "  version                                                print the version"
        io.puts "  --verbose[=json] | -v   stream what the operation does, on stderr (any verb except hook)"
        status
      end
    end

    register("validate", Validate, summary: "check a file against its schema")
  end
end
