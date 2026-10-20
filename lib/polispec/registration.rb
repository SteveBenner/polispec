#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "etc"
require "json"
require "fileutils"
require_relative "operator/git"

module Polispec
  module Registration
    KINDS = %w[software directory system].freeze
    ID_PATTERN = /\A[a-z0-9][a-z0-9-]{0,40}\z/

    module_function

    def owner
      uid = Process.uid
      name = begin
        Etc.getpwuid(uid)&.name
      rescue StandardError
        nil
      end
      { "uid" => uid, "name" => name.to_s.empty? ? "uid#{uid}" : name }
    end

    def actor
      value = ENV["POLISPEC_ACTOR"].to_s.strip
      value.empty? ? "cli" : value
    end

    def owner_flow(record = owner)
      "{uid: #{record['uid']}, name: #{JSON.generate(record['name'])}}"
    end

    def default_id(path)
      base = File.basename(File.expand_path(path)).downcase.gsub(/[^a-z0-9-]+/, "-").gsub(/\A-+|-+\z/, "")
      base = "path-#{base}" unless base.match?(/\A[a-z0-9]/)
      base[0, 41]
    end

    def entry_lines(id:, kind:, path:, description: nil)
      lines = ["  - id: #{id}", "    kind: #{kind}", "    path: #{JSON.generate(path)}", "    status: onboarding"]
      lines << "    owner: #{owner_flow}"
      lines << "    registered_by: #{JSON.generate(actor)}"
      lines << "    description: #{JSON.generate(description)}" unless description.to_s.empty?
      lines << "    policy: paths/#{id}.yml"
      lines
    end

    def add_entry(text, lines)
      rows = text.lines
      rows[-1] = "#{rows[-1]}\n" if !rows.empty? && !rows[-1].end_with?("\n")
      start = rows.index { |line| line.match?(/\Apaths:/) }
      return "#{rows.join}paths:\n#{lines.join("\n")}\n" if start.nil?

      if rows[start].strip == "paths: []"
        rows[start] = "paths:\n"
        return (rows[0..start] + lines.map { |line| "#{line}\n" } + rows[(start + 1)..]).join
      end

      stop = ((start + 1)...rows.length).find { |index| !rows[index].strip.empty? && !rows[index].start_with?(" ", "\t") } || rows.length
      last = (stop - 1).downto(start) { |index| break index unless rows[index].strip.empty? }
      (rows[0..last] + lines.map { |line| "#{line}\n" } + rows[(last + 1)..]).join
    end

    def retire_entry(text, id)
      rows = text.lines
      start = rows.index { |line| line.match?(/\A  - id: #{Regexp.escape(id)}\s*\z/) }
      return nil if start.nil?

      stop = ((start + 1)...rows.length).find { |index| rows[index].match?(/\A  - /) || (!rows[index].strip.empty? && !rows[index].start_with?(" ", "\t")) } || rows.length
      status = (start...stop).find { |index| rows[index].match?(/\A    status:/) }
      return nil if status.nil?

      rows[status] = "    status: retired\n"
      rows.join
    end

    def validated(text, path)
      data = Schema::Document.parse(text, path)
      errors = Schema.validate("ledger", data)
      return data if errors.empty?

      raise Operator::Failure.new("ledger_invalid", "the ledger with the change does not validate", "problems" => errors.map { |error| "#{error.pointer} #{error.message}".strip })
    rescue Schema::Document::ParseError => e
      raise Operator::Failure.new("ledger_invalid", e.message)
    end

    def proposal_file(id, text)
      dir = File.join(State.home, "register")
      FileUtils.mkdir_p(dir, mode: 0o700)
      file = File.join(dir, "#{id}.ledger.yml")
      File.write(file, text)
      File.chmod(0o600, file)
      file
    end

    def current_text(ledger)
      File.file?(ledger.path) ? File.read(ledger.path) : Ledger.starter_text
    end

    def refuse_restricted!
      return unless Editions.value("register.path") == "restricted"

      raise Operator::Failure.new("edition_restricted", "registering a governed path is restricted in this edition; the protected ledger the sealed plane names is the only way to add one")
    end

    def propose_register(ledger, path, id:, kind:, description:)
      refuse_restricted!
      raise Operator::Failure.new("kind_invalid", "kind must be one of #{KINDS.join(', ')}") unless KINDS.include?(kind)

      absolute = File.expand_path(path)
      raise Operator::Failure.new("path_missing", "#{absolute} does not exist") unless File.exist?(absolute)

      if kind == "system"
        home = File.expand_path("~")
        raise Operator::Failure.new("system_path_invalid", "kind system registers the home directory #{home} only", "path" => absolute) unless absolute == home
      end
      id ||= default_id(absolute)
      raise Operator::Failure.new("id_invalid", "#{id} is not a valid id (lowercase letters, digits and hyphens, at most 41 characters)") unless id.match?(ID_PATTERN)

      owner_of = ledger.locate(absolute)
      raise Operator::Failure.new("inside_project", "#{absolute} is inside the ledgered project #{owner_of.project.id}; the project's own policy governs it", "project" => owner_of.project.id) if owner_of
      raise Operator::Failure.new("id_collision", "#{id} is already in the ledger") if ledger.entry(id)

      duplicate = ledger.paths.find { |entry| entry.status != "retired" && File.expand_path(entry.path) == absolute }
      raise Operator::Failure.new("path_registered", "#{absolute} is already registered as #{duplicate.id}", "id" => duplicate.id) if duplicate

      text = add_entry(current_text(ledger), entry_lines(id: id, kind: kind, path: absolute, description: description))
      validated(text, ledger.path)
      [id, text]
    end

    def propose_unregister(ledger, id)
      entry = ledger.path_entry(id)
      raise Operator::Failure.new("path_unknown", "#{id} is not a registered path") unless entry
      raise Operator::Failure.new("already_retired", "#{id} is already retired") if entry.status == "retired"

      text = retire_entry(current_text(ledger), id)
      raise Operator::Failure.new("ledger_invalid", "could not set #{id} to retired in #{ledger.path}") unless text

      validated(text, ledger.path)
      text
    end
  end
end
