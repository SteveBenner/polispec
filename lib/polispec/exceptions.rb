#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "yaml"
require "time"
require "digest"
require "fileutils"
require_relative "state"
require_relative "schema/core"
require_relative "harness/base"
require_relative "editions"

module Polispec
  module Exceptions
    FILE = "exceptions.yml"
    SCHEMA = "polispec.exceptions/v1"
    MAX_ENTRIES = 256
    MAX_BYTES = 65_536
    PROPOSAL_TTL = 604_800
    MAX_PROPOSALS = 256
    ENTRY_ID = /\Aaex_[0-9a-f]{12}\z/
    PROPOSAL_ID = /\Aapr_[0-9a-f]{12}\z/
    GLOB_CHARS = /[*?\[{]/
    PROPOSALS = "exception_proposals.jsonl"
    PROPOSALS_LOCK = "exception_proposals.lock"
    Result = Struct.new(:entries, :problems, :present)

    module_function

    def enabled?
      defined?(Engine::Settings) && Engine::Settings.respond_to?(:exceptions?) ? Engine::Settings.exceptions? : false
    rescue StandardError
      false
    end

    def active?(edition, _plane_status = nil)
      enabled? && Editions.allowed?("exceptions", edition)
    end

    def path
      source = Layers.source
      return nil unless source

      source.kind == :dir ? File.join(source.root, FILE) : File.join(source.repo, source.path, FILE)
    rescue StandardError
      nil
    end

    def normalize(text)
      text.to_s.gsub(/\s+/, " ").strip
    end

    def literal(text)
      normalize(text).gsub(/[\\*?\[\]{}]/) { |char| "\\#{char}" }
    end

    def canonical_tool(name)
      Harness::Base::SHELL_TOOLS.include?(name.to_s) ? "Bash" : name.to_s
    end

    def canonical_path(value)
      expanded = File.expand_path(value.to_s)
      existing = expanded
      existing = File.dirname(existing) until File.exist?(existing) || existing == "/"
      joined = File.join(File.realpath(existing), expanded[existing.length..-1].to_s).sub(%r{/+\z}, "")
      joined.empty? ? "/" : joined
    rescue SystemCallError
      expanded
    end

    def first_word(command)
      normalize(command).split(" ", 2).first.to_s
    end

    def scope_key(scope)
      scope.is_a?(Hash) && scope["project"] ? scope["project"].to_s : "global"
    end

    def entry_id(kind, tool, command, rule, scope)
      "aex_#{Digest::SHA256.hexdigest([kind, tool, command.to_s, rule.to_s, scope_key(scope)].join("\0"))[0, 12]}"
    end

    def proposal_id(kind, tool, command, rule)
      "apr_#{Digest::SHA256.hexdigest([kind, tool, command.to_s, rule.to_s].join("\0"))[0, 12]}"
    end

    def build_entry(kind:, tool:, command:, rule:, scope:, note:, now:)
      text = command.nil? ? nil : normalize(command)
      entry = { "id" => entry_id(kind, tool, text, rule, scope), "kind" => kind, "tool" => tool }
      entry["command"] = text if text
      entry["rule"] = rule if rule
      entry["scope"] = scope
      entry["note"] = note if note && !note.to_s.empty?
      entry["added"] = now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      entry
    end

    def validate(document)
      problems = Schema.validate("exceptions", document).map { |error| "#{error.pointer.empty? ? '/' : error.pointer} #{error.message}" }
      return problems unless problems.empty?

      entries = document["exceptions"]
      problems << "/exceptions has more than #{MAX_ENTRIES} entries" if entries.length > MAX_ENTRIES
      seen = {}
      entries.each_with_index do |entry, index|
        at = "/exceptions/#{index}"
        problems << "#{at}/id duplicates #{entry['id']}" if seen[entry["id"]]
        seen[entry["id"]] = true
        problems.concat(entry_problems(entry, at))
      end
      problems
    end

    def entry_problems(entry, at)
      problems = []
      bash = entry["tool"] == "Bash"
      problems << "#{at}/tool a rule exception requires tool Bash" if entry["kind"] == "rule" && !bash
      problems << "#{at}/rule is required for kind rule" if entry["kind"] == "rule" && !entry.key?("rule")
      problems << "#{at}/rule is forbidden for kind control" if entry["kind"] == "control" && entry.key?("rule")
      if bash
        command = entry["command"]
        if command.nil? || normalize(command).empty?
          problems << "#{at}/command is required for tool Bash"
        else
          problems << "#{at}/command must be at most 1024 characters" if normalize(command).length > 1024
          problems << "#{at}/command first word must not contain a glob character" if first_word(command).match?(GLOB_CHARS)
        end
      elsif entry.key?("command")
        problems << "#{at}/command is forbidden for a tool other than Bash"
      end
      problems
    end

    def load
      @loaded ||= read_document
    end

    def reset!
      @loaded = nil
    end

    def read_document
      store = Layers.store
      text = store ? store.read(FILE) : nil
      return Result.new([], [], false) if text.nil?
      return Result.new([], ["#{FILE} exceeds #{MAX_BYTES} bytes"], true) if text.bytesize > MAX_BYTES

      document = Schema::Document.parse(text, FILE)
      problems = validate(document)
      Trace.info("exceptions read", file: FILE, bytes: text.bytesize, entries: problems.empty? ? document["exceptions"].length : 0, problems: problems.length) if Trace.on?
      problems.empty? ? Result.new(document["exceptions"], [], true) : Result.new([], problems, true)
    rescue Schema::Document::ParseError => error
      Result.new([], [error.message], true)
    rescue StandardError => error
      Result.new([], ["#{FILE} cannot be read: #{error.class}"], true)
    end

    def scope_covers?(entry, cwd)
      scope = entry["scope"]
      return false unless scope.is_a?(Hash)
      return true if scope["global"] == true

      project = scope["project"].to_s
      return false if project.empty?

      here = canonical_path(cwd)
      here == project || here.start_with?("#{project}/")
    end

    def covers(entries, kind:, tool:, cwd:, command: nil, rule: nil)
      wanted = canonical_tool(tool)
      text = command.nil? ? nil : normalize(command)
      found = Array(entries).find do |entry|
        next false unless entry["kind"] == kind && entry["tool"] == wanted
        next false if kind == "rule" && entry["rule"] != rule
        next false if wanted == "Bash" && (text.nil? || !File.fnmatch?(entry["command"].to_s, text, File::FNM_EXTGLOB))

        scope_covers?(entry, cwd)
      end
      found && found["id"]
    end

    def proposals_path
      File.join(State.home, PROPOSALS)
    end

    def read_proposals
      return [] unless File.file?(proposals_path)

      File.foreach(proposals_path).filter_map { |line| State.parse_line(line) }
    rescue SystemCallError
      []
    end

    def fresh(list, now)
      cutoff = now - PROPOSAL_TTL
      list.select do |item|
        stamp = Time.iso8601(item["created"].to_s)
        item["id"].to_s.match?(PROPOSAL_ID) && stamp >= cutoff
      rescue ArgumentError
        false
      end
    end

    def write_proposals(list)
      temp = "#{proposals_path}.#{Process.pid}.tmp"
      File.write(temp, list.map { |item| "#{JSON.generate(item)}\n" }.join, perm: 0o600)
      File.rename(temp, proposals_path)
    end

    def with_proposals_lock
      State.ensure_dirs
      File.open(File.join(State.home, PROPOSALS_LOCK), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def propose(kind:, tool:, cwd:, command: nil, rule: nil)
      text = command.nil? ? nil : normalize(command)
      id = proposal_id(kind, tool, text, rule)
      now = Time.now.utc
      with_proposals_lock do
        kept = fresh(read_proposals, now).reject { |item| item["id"] == id }
        kept << { "id" => id, "kind" => kind, "tool" => tool, "command" => text, "rule" => rule, "cwd" => cwd.to_s, "created" => now.iso8601 }
        write_proposals(kept.last(MAX_PROPOSALS))
      end
      id
    rescue StandardError
      nil
    end

    def proposals
      fresh(read_proposals, Time.now.utc)
    end

    def find_proposals(ids)
      wanted = Array(ids)
      proposals.each_with_object({}) { |item, memo| memo[item["id"]] = item if wanted.include?(item["id"]) }
    end

    def forget(ids)
      drop = Array(ids)
      with_proposals_lock { write_proposals(read_proposals.reject { |item| drop.include?(item["id"]) }) }
      true
    rescue StandardError
      false
    end

    def quote(value)
      JSON.generate(value.to_s)
    end

    def dump(entries)
      lines = ["schema: #{SCHEMA}"]
      if entries.empty?
        lines << "exceptions: []"
      else
        lines << "exceptions:"
        entries.each { |entry| lines.concat(dump_entry(entry)) }
      end
      "#{lines.join("\n")}\n"
    end

    def dump_entry(entry)
      scope = entry["scope"]
      lines = ["  - id: #{entry['id']}", "    kind: #{entry['kind']}", "    tool: #{quote(entry['tool'])}"]
      lines << "    command: #{quote(entry['command'])}" if entry.key?("command")
      lines << "    rule: #{quote(entry['rule'])}" if entry.key?("rule")
      lines << (scope["global"] == true ? "    scope: {global: true}" : "    scope: {project: #{quote(scope['project'])}}")
      lines << "    note: #{quote(entry['note'])}" if entry.key?("note")
      lines << "    added: #{entry['added']}"
      lines
    end
  end
end
