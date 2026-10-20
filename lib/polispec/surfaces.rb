#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "digest"
require_relative "agents_render"

module Polispec
  module Surfaces
    PLACEHOLDER = /\{\{([^{}]*)\}\}/.freeze
    PLAIN = %w[rows frames controls].freeze
    PREFIXED = %w[row body message].freeze
    STUB_ALLOWED = %w[rows row message].freeze
    MIN_TOKENS = 8
    OVERLAP = 0.8
    SENTENCE_END = /(?<=[.!?;])\s+/.freeze
    LIST_MARKER = /\A\s*(?:[-*+]|\d+[.)])\s+/.freeze

    module_function

    def policy(compiled)
      compiled.fetch("policy")
    end

    def surface(compiled, surface_id)
      policy(compiled).fetch("surfaces", {}).fetch(surface_id) { raise Polispec::Error, "unknown surface #{surface_id}" }
    end

    def directive_lookup(compiled)
      policy(compiled).fetch("directives").each_with_object({}) do |entry, index|
        index[entry["id"]] = entry
        index[entry["opcode"]] = entry if entry["opcode"]
      end
    end

    def resolve(compiled, surface_id)
      spec = surface(compiled, surface_id)
      directives = directive_lookup(compiled)
      messages = policy(compiled).fetch("messages", {})
      refs = Array(spec["refs"])
      refs = policy(compiled).fetch("directives").map { |entry| entry["id"] } if refs.empty? && spec["kind"] == "rows"
      refs.map do |ref|
        if directives.key?(ref)
          entry = directives.fetch(ref)
          { "type" => "directive", "id" => entry["id"], "row" => AgentsRender.directive_row(entry), "directive" => entry }
        elsif messages.key?(ref)
          { "type" => "message", "id" => ref, "text" => messages.fetch(ref)["text"] }
        else
          raise Polispec::Error, "surface #{surface_id} references unknown #{ref}"
        end
      end
    end

    def render(compiled, surface_id, root:)
      spec = surface(compiled, surface_id)
      entries = resolve(compiled, surface_id)
      template = spec["template"] ? read(root, spec["template"], "template of #{surface_id}") : "{{rows}}\n"
      pieces = template.scan(PLACEHOLDER).flatten.map { |inner| inner.strip.split(":", 2) }
      pieces.each { |name, argument| check_placeholder(surface_id, spec, entries, name, argument) }
      template.gsub(PLACEHOLDER) do
        name, argument = Regexp.last_match(1).strip.split(":", 2)
        expand(compiled, surface_id, entries, root, name, argument)
      end
    end

    def check_placeholder(surface_id, spec, entries, name, argument)
      valid = argument.nil? ? PLAIN.include?(name) : PREFIXED.include?(name) && !argument.empty?
      raise Polispec::Error, "surface #{surface_id} uses the unknown placeholder {{#{[name, argument].compact.join(':')}}}" unless valid
      raise Polispec::Error, "stub surface #{surface_id} may use only rows, row and message placeholders, not #{name}" if spec["kind"] == "stub" && !STUB_ALLOWED.include?(name)
      return if argument.nil?

      found = entries.any? { |entry| entry_matches?(entry, name, argument) }
      raise Polispec::Error, "surface #{surface_id} uses {{#{name}:#{argument}}} that its refs do not list" unless found
    end

    def entry_matches?(entry, name, argument)
      if name == "message"
        entry["type"] == "message" && entry["id"] == argument
      else
        entry["type"] == "directive" && (entry["id"] == argument || entry["directive"]["opcode"] == argument)
      end
    end

    def expand(compiled, surface_id, entries, root, name, argument)
      case name
      when "rows" then rows(compiled, entries).join("\n")
      when "frames" then frames(compiled).join("\n")
      when "controls" then controls(compiled).join("\n")
      when "row" then entries.find { |entry| entry_matches?(entry, "row", argument) }.fetch("row")
      when "message" then entries.find { |entry| entry_matches?(entry, "message", argument) }.fetch("text")
      else body(entries.find { |entry| entry_matches?(entry, "body", argument) }.fetch("directive"), root)
      end
    end

    def rows(compiled, entries)
      found = entries.select { |entry| entry["type"] == "directive" }
      return found.map { |entry| entry["row"] } unless found.empty?

      AgentsRender.directive_rows(policy(compiled).fetch("directives"))
    end

    def frames(compiled)
      messages = policy(compiled).fetch("messages", {})
      policy(compiled).fetch("frames", []).sort_by { |frame| [frame["order"], frame["id"]] }.map do |frame|
        "- #{frame['id']} (#{frame['tier']}; #{frame['channels'].join(', ')}): #{messages.fetch(frame['text_ref'])['text']}"
      end
    end

    def controls(compiled)
      messages = policy(compiled).fetch("messages", {})
      policy(compiled).fetch("controls", {}).sort.map do |name, control|
        tools = control["allowed_tools"].empty? ? "none" : control["allowed_tools"].join(", ")
        "- #{name} (tools: #{tools}): #{messages.fetch(control['text_ref'])['text']}"
      end
    end

    def body(directive, root)
      return directive["body"] if directive["body"]
      raise Polispec::Error, "directive #{directive['id']} has no body" unless directive["body_ref"]

      path = File.join(root, directive["body_ref"]["path"])
      raise Polispec::Error, "private body of #{directive['id']} is not present under #{root}; only its owner renders it" unless File.file?(path)

      text = File.read(path)
      actual = Digest::SHA256.hexdigest(text)
      raise Polispec::Error, "body of #{directive['id']} has sha256 #{actual}, the policy carries #{directive['body_sha256']}" unless actual == directive["body_sha256"]

      text
    end

    def read(root, relative, label)
      path = File.join(root, relative)
      raise Polispec::Error, "#{label} #{relative} is missing under #{root}" unless File.file?(path)

      File.read(path)
    end

    def drift(compiled, root:, surfaces: nil)
      policy(compiled).fetch("surfaces", {}).filter_map do |surface_id, spec|
        next if surfaces && !surfaces.include?(surface_id)

        expected = Digest::SHA256.hexdigest(render(compiled, surface_id, root: root))
        target = File.join(root, spec["target"])
        actual = File.file?(target) ? Digest::SHA256.file(target).hexdigest : nil
        next if expected == actual

        { "surface" => surface_id, "target" => spec["target"], "expected_sha256" => expected, "actual_sha256" => actual }
      end
    end

    def when_matches?(directive, event)
      Array(directive["when"]).any? { |condition| condition_matches?(condition, event) }
    end

    def condition_matches?(condition, event)
      kind, argument = condition.split(":", 2)
      return true if condition == "always"
      return false if argument.nil? || argument.empty?

      case kind
      when "task" then Array(event["task"]).include?(argument)
      when "event" then Array(event["event"]).include?(argument)
      when "path" then Array(event["path"] || event["paths"]).any? { |path| File.fnmatch?(argument, path.to_s, File::FNM_PATHNAME | File::FNM_DOTMATCH | File::FNM_EXTGLOB) }
      when "tool" then tool_matches?(argument, event)
      else false
      end
    end

    def tool_matches?(argument, event)
      name, pattern = argument.match(/\A([^(]+)(?:\((.*)\))?\z/m)&.captures
      return false unless name && Array(event["tool"]).include?(name)
      return true if pattern.nil?

      Array(event["command"] || event["input"]).any? { |text| File.fnmatch?(pattern, text.to_s, File::FNM_EXTGLOB) }
    end

    def lint(compiled, corpus_paths, root: nil)
      directives = policy(compiled).fetch("directives")
      links = link_pairs(directives)
      candidates = directives.map { |entry| candidate(entry, root) }
      findings = []
      sources(compiled, corpus_paths, root).each do |label, kind, text, skip|
        sentences(text).each do |raw|
          tokens = tokens(strip_placeholders(raw))
          next if tokens.length < MIN_TOKENS

          candidates.each do |item|
            next if item[:entry]["id"] == skip || references?(raw, item[:entry]) || item[:path] == skip || links.include?([skip, item[:entry]["id"]])

            hit = item[:units].filter_map { |unit| score(tokens, unit) }.max
            findings << { "source" => label, "kind" => kind, "directive" => item[:entry]["id"], "sentence" => raw.strip, "overlap" => hit.round(2) } if hit
          end
        end
      end
      findings
    end

    def link_pairs(directives)
      index = directive_lookup("policy" => { "directives" => directives })
      directives.each_with_object([]) do |entry, pairs|
        target = index[entry["duplicate_of"]]
        next unless target

        pairs << [entry["id"], target["id"]]
        pairs << [target["id"], entry["id"]]
      end
    end

    def candidate(entry, root)
      text = directive_body(entry, root)
      units = (sentences(entry["rule"]) + (text ? sentences(text) : [])).map { |sentence| tokens(sentence) }.select { |list| list.length >= MIN_TOKENS }
      { entry: entry, units: units, path: entry.dig("body_ref", "path") }
    end

    def directive_body(entry, root)
      return entry["body"] if entry["body"]

      path = root && entry["body_ref"] ? File.join(root, entry["body_ref"]["path"]) : nil
      path && File.file?(path) ? File.read(path) : nil
    end

    def sources(compiled, corpus_paths, root)
      found = []
      policy(compiled).fetch("surfaces", {}).each do |surface_id, spec|
        next unless spec["template"] && root

        path = File.join(root, spec["template"])
        found << ["surface #{surface_id}", "surface", File.read(path), nil] if File.file?(path)
      end
      policy(compiled).fetch("messages", {}).each { |id, message| found << ["message #{id}", "message", message["text"], nil] }
      policy(compiled).fetch("directives").each do |entry|
        text = [entry["rule"], directive_body(entry, root)].compact.join("\n\n")
        found << ["directive #{entry['id']}", "directive", text, entry["id"]]
      end
      corpus_paths.each do |path|
        next unless File.file?(path)

        relative = root && path.start_with?("#{root}/") ? path.delete_prefix("#{root}/") : path
        found << [relative, "corpus", File.read(path), relative]
      end
      found
    end

    def sentences(text)
      units = []
      buffer = []
      fenced = false
      flush = lambda do
        units.concat(buffer.join(" ").split(SENTENCE_END)) unless buffer.empty?
        buffer = []
      end
      text.to_s.each_line do |line|
        stripped = line.strip
        if stripped.start_with?("```")
          flush.call
          fenced = !fenced
        elsif fenced || stripped.empty? || stripped.start_with?("#", "|")
          flush.call
        elsif LIST_MARKER.match?(line)
          flush.call
          buffer << line.sub(LIST_MARKER, "").strip
        else
          buffer << stripped
        end
      end
      flush.call
      units.map(&:strip).reject(&:empty?)
    end

    def strip_placeholders(text)
      text.gsub(PLACEHOLDER, " ")
    end

    def tokens(text)
      text.downcase.scan(/[[:alnum:]]+/)
    end

    def references?(raw, entry)
      names = [entry["id"], entry["opcode"]].compact
      names.any? { |name| raw.match?(/(?<![A-Za-z0-9_-])#{Regexp.escape(name)}(?![A-Za-z0-9_-])/) }
    end

    def score(tokens, unit)
      left = tokens.uniq
      right = unit.uniq
      value = (left & right).length.to_f / [left.length, right.length].max
      value >= OVERLAP ? value : nil
    end
  end
end
