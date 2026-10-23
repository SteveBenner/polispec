#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "document"
require_relative "validator"

module Polispec
  module Schema
    KINDS = %w[policy environments roster ledger behavior spec waivers global module profiles control smoke smoke-scenario package judgment exceptions delegate_grants editions session change manifest app index].freeze
    CONTROL_EFFECT_KEYS = {
      "deny" => [],
      "ask" => [],
      "restrict" => %w[network paths],
      "inject" => %w[text],
      "observe" => %w[event metadata],
      "verify" => []
    }.freeze
    CONTROL_LIMIT = 256
    CALENDAR_LIMIT = 256
    DIR = File.join(ROOT, "schemas")
    Result = Struct.new(:ok, :schema, :errors) do
      def to_h
        { "ok" => ok, "schema" => schema, "errors" => errors.map(&:to_h) }
      end
    end

    module_function

    def kinds
      KINDS
    end

    def schema_id(kind)
      "polispec.#{kind}/v1"
    end

    def kind_for(data)
      id = data.is_a?(Hash) ? data["schema"] : nil
      KINDS.find { |kind| schema_id(kind) == id }
    end

    def definition(kind)
      @definitions ||= {}
      @definitions[kind.to_s] ||= Document.load(File.join(DIR, "#{kind}.v1.yml"))
    end

    def validate(kind, data)
      kind = kind.to_s
      return [Error.new("", "unknown schema kind #{kind}")] unless KINDS.include?(kind)

      errors = Validator.new(definition(kind)).call(data)
      if kind == "behavior" && errors.empty?
        require_relative "../behavior"
        errors.concat(Behavior.semantic_errors(data))
      elsif kind == "control" && errors.empty?
        errors.concat(control_errors(data))
      elsif kind == "package" && errors.empty?
        errors.concat(package_errors(data))
      elsif %w[policy module global].include?(kind) && errors.empty?
        require_relative "../text_match"
        errors.concat(TextMatch.source_errors(data))
      elsif kind == "smoke-scenario" && errors.empty?
        require_relative "../smoke/scenario"
        errors.concat(Smoke::Scenario.semantic_errors(data))
      end
      errors
    end

    def package_errors(data)
      errors = []
      variants = data["variants"].is_a?(Hash) ? data["variants"] : {}
      errors << Error.new("/default_variant", "must name a declared variant") if data.key?("default_variant") && !variants.key?(data["default_variant"])
      errors << Error.new("/default_variant", "is required when variants are declared") if !variants.empty? && !data.key?("default_variant")
      maps = [["/files", data["files"]]] + variants.map { |name, body| ["/variants/#{name}/files", body.is_a?(Hash) ? body["files"] : nil] }
      maps.each do |pointer, map|
        next unless map.is_a?(Hash)

        map.each do |target, source|
          errors << Error.new("#{pointer}/#{target}", "target must be a repository-relative path without ..") unless safe_relative?(target)
          errors << Error.new("#{pointer}/#{target}", "source must be a path inside the package without ..") unless safe_relative?(source)
        end
      end
      params = data["params"].is_a?(Hash) ? data["params"] : {}
      Array(data["steps"]).each_with_index do |step, index|
        condition = step.is_a?(Hash) ? step["when"] : nil
        errors << Error.new("/steps/#{index}/when/param", "must name a declared param") if condition && !params.key?(condition["param"])
      end
      params.each do |name, body|
        errors << Error.new("/params/#{name}", "name must match ^[a-z][a-z0-9_]*$") unless name.match?(/\A[a-z][a-z0-9_]*\z/)
        errors << Error.new("/params/#{name}/allowed", "is supported for string params only") if body["allowed"] && body["type"] != "string"
      end
      errors
    end

    def safe_relative?(path)
      text = path.to_s
      !text.empty? && !text.start_with?("/") && text.split("/").none? { |part| part == ".." || part.empty? }
    end

    def control_errors(data)
      controls = Array(data["controls"])
      errors = duplicate_control_errors(controls)
      errors << Error.new("/controls", "must have at most #{CONTROL_LIMIT} items") if controls.length > CONTROL_LIMIT
      tool_ids = controls.reject { |control| control["trigger"] == "schedule" }.map { |control| control["id"] }

      controls.each_with_index do |control, index|
        pointer = "/controls/#{index}"
        effect = control["effect"]
        params = control["effect_params"]
        allowed = CONTROL_EFFECT_KEYS[effect]
        errors.concat(effect_param_errors(effect, params, allowed, pointer))
        errors.concat(restrict_param_errors(params, pointer)) if effect == "restrict" && params.is_a?(Hash)
        errors.concat(inject_param_errors(params, pointer)) if effect == "inject" && params.is_a?(Hash)
        calendar = control["calendar"]
        if control["trigger"] == "schedule" && calendar.is_a?(String) && calendar.length > CALENDAR_LIMIT
          errors << Error.new("#{pointer}/calendar", "must be at most #{CALENDAR_LIMIT} characters")
        end
        if control["trigger"] == "schedule" && !tool_ids.include?(control["target_control_id"])
          errors << Error.new("#{pointer}/target_control_id", "must name a tool control in this document")
        end
      end
      errors
    end

    def duplicate_control_errors(controls)
      controls.each_with_index.group_by { |(control, _)| control["id"] }.values.flat_map do |entries|
        next [] if entries.length == 1

        entries.drop(1).map { |(_, index)| Error.new("/controls/#{index}/id", "must be unique within the document") }
      end
    end

    def effect_param_errors(effect, params, allowed, pointer)
      return [] unless allowed
      return params.nil? ? [] : [Error.new("#{pointer}/effect_params", "is not allowed for #{effect}")] if allowed.empty?
      return [Error.new("#{pointer}/effect_params", "is required for #{effect}")] unless params.is_a?(Hash)

      (params.keys - allowed).map { |key| Error.new("#{pointer}/effect_params/#{key}", "is not allowed for #{effect}") }
    end

    def restrict_param_errors(params, pointer)
      errors = []
      errors << Error.new("#{pointer}/effect_params", "must declare paths or network") if (params.keys & %w[paths network]).empty?
      paths = params["paths"]
      if paths.is_a?(Hash) && (paths.keys & %w[read write]).empty?
        errors << Error.new("#{pointer}/effect_params/paths", "must declare read or write")
      end
      network = params["network"]
      if network.is_a?(Hash)
        mode = network["mode"]
        errors << Error.new("#{pointer}/effect_params/network/domains", "is required for allowlist mode") if mode == "allowlist" && !network.key?("domains")
        errors << Error.new("#{pointer}/effect_params/network/domains", "is not allowed for open mode") if mode == "open" && network.key?("domains")
      end
      errors
    end

    def inject_param_errors(params, pointer)
      text = params["text"]
      return [] unless text.is_a?(String)

      errors = []
      errors << Error.new("#{pointer}/effect_params/text", "must be valid UTF-8") unless text.encoding == Encoding::UTF_8 && text.valid_encoding?
      errors << Error.new("#{pointer}/effect_params/text", "must be at most 8192 bytes") if text.bytesize > 8192
      errors
    end

    def validate_file(kind, path)
      data = Document.load(path)
      kind = kind_for(data) if kind.to_s == "auto"
      return Result.new(false, nil, [Error.new("/schema", "not a recognized polispec document")]) if kind.nil?

      errors = validate(kind, data)
      Result.new(errors.empty?, schema_id(kind), errors)
    rescue Document::ParseError => e
      Result.new(false, kind.to_s == "auto" ? nil : schema_id(kind), [Error.new("", e.message)])
    end
  end
end
