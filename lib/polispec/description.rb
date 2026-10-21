#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "yaml"
require "open3"

module Polispec
  module Description
    EFFECT_WORDS = %w[allow allows allowed ask asks warn warns deny denies denied refuse refuses block blocks stop stops promote promotes freeze freezes require requires forbid forbids].freeze
    MIN_SENTENCES = 2
    MIN_WORDS = 20
    MAX_SENTENCES = 8
    MAX_WORDS = 400
    SEMANTIC_BOUND = 6000
    SEMANTIC_OPTIONS = %w[matches partial contradicts].freeze
    SEMANTIC_QUESTION = "Does this description match what the rules do?".freeze
    SEMANTIC_CRITERIA = {
      "matches" => "every effect the description states is carried by a rule and no rule contradicts it",
      "partial" => "the description is true but omits or overstates part of what the rules do",
      "contradicts" => "the description states an effect that a rule reverses or does not carry"
    }.freeze
    RUNTIME_FLOOR = [0, 35, 0].freeze
    KINDS = %w[policy environments roster global module package spec].freeze
    GIT_ENV = { "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil, "GIT_OPTIONAL_LOCKS" => "0" }.freeze

    module_function

    def lint(doc, kind = nil)
      doc = stringify(doc)
      return [] unless doc.is_a?(Hash)

      text = doc["description"]
      return [finding("missing", "the rulebook carries no description", nil)] unless text.is_a?(String) && !text.strip.empty?

      results = []
      sentences = sentences_of(text)
      words = text.split(/\s+/).reject(&:empty?)
      if sentences.length < MIN_SENTENCES || words.length < MIN_WORDS
        results << finding("too_short", "a description needs at least #{MIN_SENTENCES} sentences and #{MIN_WORDS} words; this has #{sentences.length} and #{words.length}", span_of(text, 0, text.length))
      end
      if sentences.length > MAX_SENTENCES || words.length > MAX_WORDS
        results << finding("too_long", "a description holds at most #{MAX_SENTENCES} sentences and #{MAX_WORDS} words; this has #{sentences.length} and #{words.length}", span_of(text, 0, text.length))
      end
      results.concat(restates(doc, text))
      results.concat(names_nothing(doc, kind, text))
      results.concat(no_effect(text))
      results
    end

    def codes(doc, kind = nil)
      lint(doc, kind).map { |item| item[:code] }
    end

    def describe(results)
      results.map { |item| "description_#{item[:code]}: #{item[:message]}" }
    end

    def warnings(doc, kind = nil)
      results = lint(doc, kind)
      return [] if results.empty?

      missing = results.select { |item| item[:code] == "missing" }
      return missing.map { |item| warning("description_missing", [item]) } unless missing.empty?

      [warning("description_invalid", results)]
    end

    def warning(code, results)
      detail = results.map { |item| item[:code] == "missing" ? item[:message] : "#{item[:code]}: #{item[:message]}" }.join("; ")
      { "code" => code, "message" => detail, "codes" => results.map { |item| item[:code] } }
    end

    def finding(code, message, span)
      { code: code, message: message, span: span }
    end

    def span_of(text, start, finish)
      { start: start, end: finish, text: text[start...finish].to_s[0, 120] }
    end

    def sentences_of(text)
      text.split(/(?<=[.!?])(?:\s+|\z)/).map(&:strip).reject(&:empty?)
    end

    def normalize(text)
      text.to_s.downcase.gsub(/[^[:alnum:]\s]/, " ").gsub(/\s+/, " ").strip
    end

    def restates(doc, text)
      summary = normalize(doc["summary"])
      return [] if summary.empty?

      body = normalize(text)
      return [] unless body == summary || body.start_with?(summary)

      [finding("restates_summary", "the description repeats the summary instead of adding to it", span_of(text, 0, [text.length, doc["summary"].to_s.length].min))]
    end

    def names_nothing(doc, kind, text)
      terms = vocabulary(doc, kind)
      return [] if terms.empty?
      return [] if terms.any? { |term| whole_word?(text, term) }

      [finding("names_nothing", "the description names nothing the rulebook governs (an action class, environment, path, tool, module, gate, rule, role or package it declares)", span_of(text, 0, text.length))]
    end

    def no_effect(text)
      return [] if text.downcase.scan(/[[:alpha:]]+/).any? { |word| EFFECT_WORDS.include?(word) }

      [finding("states_no_effect", "the description states no effect in words (#{%w[allow ask warn deny refuse promote freeze].join(', ')} or an equivalent)", span_of(text, 0, text.length))]
    end

    def whole_word?(text, term)
      return false if term.to_s.strip.empty?

      Regexp.new("(?<![[:alnum:]_])#{Regexp.escape(term.to_s.downcase)}(?![[:alnum:]_])").match?(text.downcase)
    end

    def vocabulary(doc, kind = nil)
      out = []
      collect(doc, out)
      out << doc["project"].to_s if doc["project"].is_a?(String) && %w[ledger project path].include?(kind.to_s)
      Array(doc["includes"]).each { |item| add_name(out, item.is_a?(Hash) ? item["module"] : item) }
      environments(doc, out)
      roles(doc, out)
      package(doc, out)
      ledger_entry(doc, out) if %w[ledger project path].include?(kind.to_s)
      out.map { |term| term.to_s.strip.downcase }.reject(&:empty?).uniq
    end

    def collect(node, out)
      case node
      when Hash
        match = node["match"]
        match_terms(match, out) if match.is_a?(Hash)
        node.each do |key, value|
          if key == "id" && value.is_a?(String)
            add_name(out, value)
          elsif key == "includes" && value.is_a?(Array)
            next
          elsif key != "description" && key != "summary"
            collect(value, out)
          end
        end
      when Array
        node.each { |item| collect(item, out) }
      end
    end

    def match_terms(match, out)
      Array(match["class"]).each do |name|
        name = name.to_s
        out << name
        out << name.split(".").last if name.include?(".")
      end
      out << match["tool"].to_s if match["tool"].is_a?(String)
      out << match["role"].to_s if match["role"].is_a?(String)
      out << match["server"].to_s if match["server"].is_a?(String)
      out << match["domain"].to_s if match["domain"].is_a?(String)
      path_terms(match["path"], out)
    end

    def path_terms(path, out)
      return unless path.is_a?(String)

      parts = path.split("/").reject { |part| part.empty? || part.match?(/\A[*.]+\z/) }
      parts.last(2).each { |part| out << part.delete("*") }
      out << parts.last(2).join("/") if parts.length >= 2
    end

    def add_name(out, name)
      name = name.to_s
      return if name.empty?

      out << name
      out << name.tr("-_", " ") if name.match?(/[-_]/)
    end

    def environments(doc, out)
      envs = doc["environments"]
      return unless envs.is_a?(Hash)

      envs.each do |name, body|
        out << name.to_s
        out << body["branch"].to_s if body.is_a?(Hash) && body["branch"].is_a?(String)
      end
    end

    def roles(doc, out)
      roles = doc["roles"]
      roles.each_key { |name| add_name(out, name) } if roles.is_a?(Hash)
    end

    def package(doc, out)
      return unless doc["steps"].is_a?(Array) || doc["variants"].is_a?(Hash)

      add_name(out, doc["name"])
      doc["variants"].each_key { |name| add_name(out, name) } if doc["variants"].is_a?(Hash)
    end

    def ledger_entry(doc, out)
      add_name(out, doc["id"])
      out << doc["kind"].to_s if doc["kind"].is_a?(String)
      [doc["repo"], doc["path"]].each do |value|
        next unless value.is_a?(String)

        parts = value.split("/").reject(&:empty?)
        parts.last(2).each { |part| add_name(out, part) }
      end
    end

    def stringify(value)
      case value
      when Hash then value.each_with_object({}) { |(key, item), hash| hash[key.to_s] = stringify(item) }
      when Array then value.map { |item| stringify(item) }
      else value
      end
    end

    def rule_list(doc)
      doc = stringify(doc)
      rows = []
      walk_rules(doc, rows)
      lines = rows.map do |rule|
        match = rule["match"].is_a?(Hash) ? rule["match"] : {}
        keys = match.map { |key, value| "#{key}=#{Array(value).join('|')}" }.join(",")
        "#{rule['id'] || '-'} #{rule['verdict']} #{keys}"
      end
      text = lines.join("\n")
      text.length > SEMANTIC_BOUND ? text[0, SEMANTIC_BOUND] : text
    end

    def walk_rules(node, rows)
      case node
      when Hash
        rows << node if node["verdict"].is_a?(String) && node.key?("match")
        node.each_value { |value| walk_rules(value, rows) }
      when Array
        node.each { |item| walk_rules(item, rows) }
      end
    end

    def decide_disabled?
      !ENV["RPLUGIN_DECIDE_DISABLED"].to_s.strip.empty?
    end

    def semantic(doc, kind = nil)
      doc = stringify(doc)
      text = doc.is_a?(Hash) ? doc["description"] : nil
      return { "status" => "skipped", "note" => "no description to judge" } unless text.is_a?(String) && !text.strip.empty?
      return { "status" => "skipped", "note" => "semantic check skipped: RPLUGIN_DECIDE_DISABLED is set" } if decide_disabled?

      require_relative "code/decide"
      return { "status" => "skipped", "note" => "semantic check skipped: the decide port is unavailable" } unless Code::Decide.available?

      context = "description:\n#{text}\n\nrules:\n#{rule_list(doc)}"
      context = context[0, SEMANTIC_BOUND] if context.length > SEMANTIC_BOUND
      answer = Code::Decide.ask(question: SEMANTIC_QUESTION, options: SEMANTIC_OPTIONS, context: context, criteria: SEMANTIC_CRITERIA.map { |name, line| "#{name}: #{line}" })
      return { "status" => "skipped", "note" => "semantic check skipped: the decide port gave no answer" } unless answer

      { "status" => "judged", "choice" => answer["choice"], "probability" => answer["probability"], "provider" => answer["provider"] }
    end

    def version_array(text)
      match = text.to_s.strip.match(/\A(\d+)\.(\d+)\.(\d+)/)
      match ? match.captures.map(&:to_i) : nil
    end

    def installed_release
      candidates = []
      begin
        require_relative "native_pin"
        link = NativePin.current_link
        candidates << File.join(File.realpath(link), "VERSION") if File.symlink?(link) || File.directory?(link)
      rescue StandardError, LoadError
        nil
      end
      begin
        require_relative "stewardship"
        store = Stewardship.store_link
        candidates << File.join(File.realpath(store), "VERSION") if File.directory?(store)
      rescue StandardError, LoadError
        nil
      end
      candidates << File.join(Runtime.root, "VERSION") if Runtime.pinned?
      candidates.each do |file|
        next unless File.file?(file)

        version = version_array(File.read(file))
        return version if version
      end
      nil
    rescue StandardError
      nil
    end

    def ahead_of_runtime?(release = installed_release)
      return false unless release

      (release <=> RUNTIME_FLOOR) == -1
    end

    def doctor_findings(ledger)
      findings = []
      used = false
      Array(ledger.projects).each do |project|
        entry = ledger_doc(project)
        used = true if entry["description"]
        findings.concat(entry_findings(project.id, "ledger project #{project.id}", entry, "project")) if project.status.to_s == "live" || entry["description"]
        next unless project.status.to_s == "live"

        project_documents(project).each do |label, doc, kind|
          used = true if doc.is_a?(Hash) && doc["description"]
          findings.concat(entry_findings(project.id, label, doc, kind))
        end
      end
      Array(ledger.paths).each do |entry|
        doc = ledger_doc(entry)
        used = true if doc["description"]
        next unless entry.status.to_s == "live" || doc["description"]

        findings.concat(entry_findings(entry.id, "ledger path #{entry.id}", doc, "path"))
      end
      shelf_documents.each do |label, doc, kind|
        used = true if doc.is_a?(Hash) && doc["description"]
        findings.concat(entry_findings(nil, label, doc, kind))
      end
      release = installed_release
      if used && ahead_of_runtime?(release)
        findings << { "project" => nil, "kind" => "description_ahead_of_runtime", "severity" => "warn",
                      "detail" => "a trust ref, the shelf or the ledger uses description but the installed release is #{release.join('.')}, older than 0.35.0; that runtime rejects the field (additionalProperties false) and would judge by fallback_rules" }
      end
      findings
    rescue StandardError => e
      findings << { "project" => nil, "kind" => "description_unchecked", "severity" => "info", "detail" => "#{e.class}: #{e.message}" }
      findings
    end

    def entry_findings(project, label, doc, kind)
      return [] unless doc.is_a?(Hash)

      lint(doc, kind).map do |item|
        missing = item[:code] == "missing"
        { "project" => project, "kind" => missing ? "description_missing" : "description_invalid", "severity" => missing ? "info" : "warn",
          "detail" => missing ? "#{label}: #{item[:message]}" : "#{label}: #{item[:code]}: #{item[:message]}" }
      end
    end

    def ledger_doc(entry)
      hash = entry.respond_to?(:to_h) ? entry.to_h : {}
      doc = stringify(hash)
      doc["description"] = entry.description if entry.respond_to?(:description) && entry.description
      doc["id"] ||= entry.id
      doc
    end

    def project_documents(project)
      require_relative "policy_source"
      docs = []
      outcome = PolicySource.raw(project)
      docs << ["#{project.id} policy at #{project.trust_ref}", stringify(outcome.policy), "policy"] if outcome
      roster = PolicySource.load_roster(project)
      docs << ["#{project.id} roster at #{project.trust_ref}", stringify(roster), "roster"] if roster.is_a?(Hash)
      env = PolicySource.send(:lookup, project, Environments.path_for(project.policy), "environments")
      docs << ["#{project.id} environments at #{project.trust_ref}", stringify(env.data), "environments"] if env.respond_to?(:data) && env.data.is_a?(Hash)
      docs
    rescue StandardError
      docs || []
    end

    def shelf_documents
      require_relative "layers"
      store = Layers.store
      return [] unless store

      docs = []
      docs << ["global", stringify(store.global_doc), "global"] if store.global_doc
      module_names(store.source).each do |name|
        text = store.read("modules/#{name}.yml")
        next unless text

        data = Schema::Document.parse(text, "modules/#{name}.yml")
        docs << ["module #{name}", stringify(data), "module"] if data.is_a?(Hash)
      rescue StandardError
        next
      end
      docs
    rescue StandardError
      []
    end

    def module_names(source)
      if source.kind == :dir
        Dir.glob(File.join(source.root, "modules", "*.yml")).map { |file| File.basename(file, ".yml") }.sort
      else
        prefix = [source.path, "modules"].reject { |part| part.to_s.empty? }.join("/")
        out, status = Open3.capture2(GIT_ENV, "git", "-C", source.repo, "ls-tree", "--name-only", "#{source.ref}:#{prefix}", err: File::NULL)
        status.success? ? out.lines.map(&:strip).select { |name| name.end_with?(".yml") }.map { |name| File.basename(name, ".yml") }.sort : []
      end
    rescue SystemCallError
      []
    end
  end
end
