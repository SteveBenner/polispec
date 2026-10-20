#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "yaml"
require_relative "schema/core"

module Polispec
  module Editions
    REGISTRY = "specs/editions.yml"
    SELF = "lib/polispec/editions.rb"
    GATE = /Editions\.(value|allowed\?|included\?)\(\s*"([^"]+)"/
    RAW_LOCK = /==\s*['"]lock['"]|!=\s*['"]lock['"]|['"]lock['"]\s*[!=]=/
    CURRENT = Object.new.freeze
    Finding = Struct.new(:kind, :file, :line, :detail) do
      def to_h
        { "kind" => kind, "file" => file, "line" => line, "detail" => detail }
      end
    end

    module_function

    def lock?(edition)
      edition.to_s == "lock"
    end

    def current
      require_relative "harness_controls/plane"
      HarnessControls::Plane.requested_edition
    rescue StandardError
      "standard"
    end

    def registry
      @registry ||= freeze_deep(load_registry(ROOT))
    end

    def load_registry(root)
      data = YAML.safe_load(File.read(File.join(root, REGISTRY)), permitted_classes: [], aliases: false)
      raise Polispec::Error, "#{REGISTRY} is not a mapping" unless data.is_a?(Hash)

      errors = Schema::Validator.new(Schema.definition("editions")).call(data)
      raise Polispec::Error, "#{REGISTRY} invalid: #{errors.first.pointer} #{errors.first.message}" unless errors.empty?

      data
    rescue SystemCallError, Psych::Exception => e
      raise Polispec::Error, "#{REGISTRY} unreadable: #{e.message}"
    end

    def features
      registry.fetch("features")
    end

    def feature(id)
      row = features.find { |item| item["id"] == id.to_s }
      raise Polispec::Error, "unknown edition feature #{id}" unless row

      row
    end

    def value(id, edition = CURRENT)
      edition = current if edition.equal?(CURRENT)
      feature(id)[lock?(edition) ? "lock" : "standard"]
    end

    def allowed?(id, edition = CURRENT)
      value(id, edition) != "excluded"
    end

    def included?(id, edition = CURRENT)
      value(id, edition) == "included"
    end

    def check(root = ROOT)
      findings = []
      begin
        data = load_registry(root)
      rescue Polispec::Error => e
        return [Finding.new("registry_invalid", REGISTRY, nil, e.message)]
      end
      rows = Array(data["features"])
      ids = rows.map { |row| row["id"] }
      duplicate = ids.find { |id| ids.count(id) > 1 }
      findings << Finding.new("registry_invalid", REGISTRY, nil, "duplicate feature id #{duplicate}") if duplicate
      version = shipped_version(root)
      rows.each do |row|
        next if newer_than?(row["since"], version)
        next if File.exist?(File.join(root, row["code"].to_s))

        findings << Finding.new("row_code_missing", REGISTRY, nil, "#{row['id']}: #{row['code']} does not exist")
      end
      Dir.glob(File.join(root, "lib", "**", "*.rb")).sort.each do |file|
        relative = file.sub("#{root}/", "")
        scan(file, relative, ids, findings)
      end
      findings
    end

    def scan(file, relative, ids, findings)
      File.foreach(file).each_with_index do |text, index|
        text.scan(GATE) do |_kind, id|
          findings << Finding.new("gate_without_row", relative, index + 1, "no row for #{id}") unless ids.include?(id)
        end
        next if relative == SELF

        findings << Finding.new("raw_lock_comparison", relative, index + 1, text.strip) if RAW_LOCK.match?(text)
      end
    rescue SystemCallError, ArgumentError
      nil
    end

    def shipped_version(root)
      File.read(File.join(root, "VERSION")).strip
    rescue SystemCallError
      nil
    end

    def newer_than?(since, version)
      return false if version.nil?

      Gem::Version.new(since.to_s) > Gem::Version.new(version)
    rescue ArgumentError
      false
    end

    def freeze_deep(value)
      case value
      when Hash then value.each { |key, item| freeze_deep(key); freeze_deep(item) }
      when Array then value.each { |item| freeze_deep(item) }
      end
      value.freeze
    end
  end
end
