#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "digest"
require "fileutils"
require "time"
require "yaml"
require_relative "hook_memo"

module Polispec
  module Catalog
    ORDER = %w[tools delete-guard mcp].freeze
    DIR = File.join(Polispec::ROOT, "catalog").freeze
    STATE_SCHEMA = "polispec.catalog-state/v1".freeze
    STATE_FILE = "active.yml".freeze
    LOCK_FILE = "catalog.lock".freeze
    PROVISION_DIR = "provisioned".freeze
    PROVISION_LIMIT = 65_536
    PROVISION_KEYS = %w[schema name summary description rules].freeze
    PROVISION_RULE_KEYS = %w[id match verdict reason].freeze
    PROVISION_MATCH_KEYS = %w[class server operation].freeze
    GLOB_CHARS = /[*?\[\]{}]/

    Spec = Struct.new(:name, :summary, :dir, :subspecs, keyword_init: true)
    Subspec = Struct.new(:spec, :id, :summary, :module_path, :gate, :provision, keyword_init: true)

    module_function

    def specs
      @specs ||= load_specs
    end

    def spec(name)
      specs.find { |entry| entry.name == name.to_s }
    end

    def subspec(spec_name, subspec_id)
      spec(spec_name)&.subspecs&.find { |entry| entry.id == subspec_id.to_s }
    end

    def state_dir
      File.join(State.home, "catalog")
    end

    def state_path
      File.join(state_dir, STATE_FILE)
    end

    def state
      HookMemo.fetch(:catalog_state) { read_state }
    end

    def active?(spec_name, subspec_id)
      sub = subspec(spec_name, subspec_id)
      return false unless sub

      current = state
      return sub.provision.nil? if current.key?("invalid")

      current["active"].any? { |entry| entry["spec"] == sub.spec && entry["subspec"] == sub.id }
    end

    def gate?(name)
      specs.any? { |entry| entry.subspecs.any? { |sub| sub.gate == name.to_s && active?(sub.spec, sub.id) } }
    end

    def active_modules(errors = [])
      entries, notes = HookMemo.fetch(:catalog_modules) do
        found = []
        [build_modules(found), found]
      end
      notes.each { |message| errors << message unless errors.include?(message) }
      entries
    end

    def module_name(label)
      label.to_s.delete_prefix("catalog:").tr("/", "-")
    end

    def entry_named(name)
      active_modules.find { |entry| module_name(entry["label"]) == name.to_s }
    end

    def shipped_files
      specs.flat_map { |entry| entry.subspecs.map { |sub| [sub, File.join("catalog", sub.spec, File.basename(sub.module_path))] } }
    end

    def digest
      entries = active_modules
      return "" if entries.empty?

      Digest::SHA256.hexdigest(entries.map { |entry| "#{entry['label']}\n#{entry['text']}" }.join("\n--\n"))
    end

    def shipped_rules_of(spec_name, subspec_id)
      sub = subspec(spec_name, subspec_id)
      return [] unless sub

      doc = Schema::Document.parse(File.read(sub.module_path), sub.module_path)
      doc.is_a?(Hash) ? Array(doc["rules"]) : []
    rescue SystemCallError, Polispec::Error
      []
    end

    def activate!(spec_name, subspec_ids, release:)
      subs = resolve(spec_name, subspec_ids)
      mutate do |current|
        subs.each do |sub|
          if sub.provision && provisioned_text(current, sub).nil?
            raise Polispec::Error, "not_provisioned: #{sub.spec}/#{sub.id} has no valid provisioned file"
          end
          next if current["active"].any? { |entry| entry["spec"] == sub.spec && entry["subspec"] == sub.id }

          current["active"] << { "spec" => sub.spec, "subspec" => sub.id, "activated_at" => now, "release" => release.to_s }
        end
        current
      end
    end

    def deactivate!(spec_name, subspec_ids)
      subs = resolve(spec_name, subspec_ids)
      mutate do |current|
        current["active"].reject! { |entry| subs.any? { |sub| entry["spec"] == sub.spec && entry["subspec"] == sub.id } }
        current
      end
    end

    def provision!(spec_name, subspec_id, text)
      problems = validate_provision(spec_name, subspec_id, text)
      raise Polispec::Error, "provision_invalid: #{problems.join('; ')}" unless problems.empty?

      sub = subspec(spec_name, subspec_id)
      relative = File.join(PROVISION_DIR, sub.spec, "#{sub.id}.yml")
      mutate do |current|
        write_private(File.join(state_dir, relative), text)
        current["provisioned"].reject! { |entry| entry["spec"] == sub.spec && entry["subspec"] == sub.id }
        current["provisioned"] << { "spec" => sub.spec, "subspec" => sub.id, "file" => relative, "sha256" => Digest::SHA256.hexdigest(text), "provisioned_at" => now }
        current
      end
    end

    def validate_provision(spec_name, subspec_id, text)
      sub = subspec(spec_name, subspec_id)
      return ["#{spec_name}/#{subspec_id} is not a catalog subspec"] unless sub
      return ["#{sub.spec}/#{sub.id} takes no provisioned file"] unless sub.provision
      return ["the file must be text"] unless text.is_a?(String)
      return ["the file exceeds #{PROVISION_LIMIT} bytes"] if text.bytesize > PROVISION_LIMIT

      doc = Schema::Document.parse(text, "#{sub.spec}/#{sub.id}")
      return ["the document must be a mapping"] unless doc.is_a?(Hash)

      problems = Schema.validate("module", doc).map { |error| "#{error.pointer} #{error.message}".strip }
      return problems unless problems.empty?

      extra = doc.keys - PROVISION_KEYS
      problems << "keys not accepted: #{extra.join(', ')}" unless extra.empty?
      Array(doc["rules"]).each_with_index { |rule, index| problems.concat(provision_rule_problems(rule, index)) }
      ids = Array(doc["rules"]).filter_map { |rule| rule["id"] if rule.is_a?(Hash) }
      problems << "rule ids must be unique" unless ids.uniq.length == ids.length
      problems
    rescue Polispec::Error => e
      [e.message]
    end

    def load_specs
      names = Dir.children(DIR).select { |name| File.file?(File.join(DIR, name, "catalog.yml")) }
      ordered = ORDER.select { |name| names.include?(name) } + (names - ORDER).sort
      ordered.map { |name| load_spec(name) }
    rescue SystemCallError => e
      raise Polispec::Error, "catalog_invalid: #{e.message}"
    end
    private_class_method :load_specs

    def load_spec(name)
      dir = File.join(DIR, name)
      file = File.join(dir, "catalog.yml")
      data = Schema::Document.parse(File.read(file), file)
      problems = Schema.validate("catalog", data).map { |error| "#{error.pointer} #{error.message}".strip }
      problems << "/name must equal #{name}" if problems.empty? && data["name"] != name
      if problems.empty?
        ids = data["subspecs"].map { |entry| entry["id"] }
        problems << "/subspecs ids must be unique" unless ids.uniq.length == ids.length
        data["subspecs"].each { |entry| problems << "#{entry['module']} not found" unless File.file?(File.join(dir, entry["module"])) }
      end
      raise Polispec::Error, "catalog_invalid: #{file}: #{problems.first(3).join('; ')}" unless problems.empty?

      subs = data["subspecs"].map do |entry|
        Subspec.new(spec: name, id: entry["id"], summary: entry["summary"], module_path: File.join(dir, entry["module"]), gate: entry["gate"], provision: entry["provision"])
      end
      Spec.new(name: name, summary: data["summary"], dir: dir, subspecs: subs)
    rescue Polispec::Error => e
      raise e if e.message.start_with?("catalog_invalid")

      raise Polispec::Error, "catalog_invalid: #{e.message}"
    rescue SystemCallError => e
      raise Polispec::Error, "catalog_invalid: #{e.message}"
    end
    private_class_method :load_spec

    def empty_state
      { "active" => [], "provisioned" => [] }
    end
    private_class_method :empty_state

    def read_state
      path = state_path
      return empty_state unless File.file?(path)

      data = Schema::Document.parse(File.read(path), path)
      problems = Schema.validate("catalog-state", data)
      return { "invalid" => problems.first(3).map { |error| "#{error.pointer} #{error.message}".strip }.join("; ") } unless problems.empty?

      { "active" => Array(data["active"]), "provisioned" => Array(data["provisioned"]) }
    rescue StandardError => e
      { "invalid" => e.message }
    end
    private_class_method :read_state

    def resolve(spec_name, subspec_ids)
      found = spec(spec_name)
      raise Polispec::Error, "catalog_unknown: #{spec_name} is not a catalog spec" unless found

      ids = Array(subspec_ids).map(&:to_s)
      ids = found.subspecs.map(&:id) if ids.empty?
      ids.map do |id|
        found.subspecs.find { |sub| sub.id == id } || raise(Polispec::Error, "catalog_unknown: #{found.name}/#{id} is not a catalog subspec")
      end
    end
    private_class_method :resolve

    def build_modules(notes)
      current = state
      notes << "catalog state is invalid (#{current['invalid']}); every gate counts on until it is fixed" if current.key?("invalid")
      specs.flat_map do |entry|
        entry.subspecs.filter_map do |sub|
          next unless active?(sub.spec, sub.id)

          text = sub.provision ? provisioned_text(current, sub) : read_module(sub)
          if text.nil?
            notes << "catalog #{sub.spec}/#{sub.id}: the provisioned file is missing or changed"
            next
          end
          doc = Schema::Document.parse(text, sub.module_path)
          unless doc.is_a?(Hash)
            notes << "catalog #{sub.spec}/#{sub.id}: the module must be a mapping"
            next
          end
          { "label" => "catalog:#{sub.spec}/#{sub.id}", "doc" => doc, "text" => text }
        end
      end
    rescue Polispec::Error => e
      notes << "catalog: #{e.message}"
      []
    end
    private_class_method :build_modules

    def read_module(sub)
      File.read(sub.module_path)
    rescue SystemCallError
      nil
    end
    private_class_method :read_module

    def provisioned_text(current, sub)
      return nil if current.key?("invalid")

      record = current["provisioned"].find { |entry| entry["spec"] == sub.spec && entry["subspec"] == sub.id }
      return nil unless record

      path = File.expand_path(record["file"], state_dir)
      return nil unless path.start_with?("#{File.expand_path(state_dir)}/") && File.file?(path)

      text = File.read(path)
      Digest::SHA256.hexdigest(text) == record["sha256"] ? text : nil
    rescue SystemCallError
      nil
    end
    private_class_method :provisioned_text

    def provision_rule_problems(rule, index)
      pointer = "/rules/#{index}"
      return ["#{pointer} must be a mapping"] unless rule.is_a?(Hash)

      problems = []
      extra = rule.keys - PROVISION_RULE_KEYS
      problems << "#{pointer} keys not accepted: #{extra.join(', ')}" unless extra.empty?
      problems << "#{pointer}/id is required" if rule["id"].to_s.empty?
      problems << "#{pointer}/reason is required" if rule["reason"].to_s.empty?
      problems << "#{pointer}/verdict must be allow" unless rule["verdict"] == "allow"
      match = rule["match"]
      unless match.is_a?(Hash)
        problems << "#{pointer}/match must be a mapping"
        return problems
      end
      extra = match.keys - PROVISION_MATCH_KEYS
      problems << "#{pointer}/match keys not accepted: #{extra.join(', ')}" unless extra.empty?
      problems << "#{pointer}/match/class must be [mcp.call]" unless match["class"] == ["mcp.call"]
      %w[server operation].each do |key|
        value = match[key]
        problems << "#{pointer}/match/#{key} must be an exact name" unless value.is_a?(String) && !value.strip.empty? && !GLOB_CHARS.match?(value)
      end
      problems
    end
    private_class_method :provision_rule_problems

    def mutate
      FileUtils.mkdir_p(state_dir, mode: 0o700)
      File.chmod(0o700, state_dir)
      File.open(File.join(state_dir, LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        current = read_state
        current = empty_state if current.key?("invalid")
        result = yield(current)
        order = specs.flat_map { |entry| entry.subspecs.map { |sub| [sub.spec, sub.id] } }
        position = ->(entry) { order.index([entry["spec"], entry["subspec"]]) || order.length }
        result["active"] = result["active"].sort_by(&position)
        result["provisioned"] = result["provisioned"].sort_by(&position)
        document = { "schema" => STATE_SCHEMA, "active" => result["active"], "provisioned" => result["provisioned"] }
        write_private(state_path, YAML.dump(document))
        result
      end
    end
    private_class_method :mutate

    def write_private(path, text)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      temp = "#{path}.#{Process.pid}.tmp"
      File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(text) }
      File.rename(temp, path)
    ensure
      File.delete(temp) if temp && File.exist?(temp)
    end
    private_class_method :write_private

    def now
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end
    private_class_method :now
  end
end
