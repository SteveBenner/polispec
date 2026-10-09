#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module ValidateProfiles
    DEFAULT_PROFILE = "personal"
    STRICT = %w[service live].freeze
    WRITE_CLASSES = %w[fs.write fs.delete].freeze
    PLACEHOLDERS = { "sha" => "0000000", "VERSION" => "0.0.0", "project" => "project", "tag" => "v0.0.0", "stable_tag" => "v0.0.0" }.freeze

    module_function

    def errors(policy, entry = nil, ledger: nil)
      profile = profile_of(entry, ledger)
      found = personal_no_warn_errors
      return found unless policy.is_a?(Hash) && STRICT.include?(profile)

      found + version_reported_errors(policy) + protected_writers_errors(policy)
    end

    def profile_of(entry, ledger = nil)
      return DEFAULT_PROFILE if entry.nil?

      named = entry.respond_to?(:profile) ? entry.profile : nil
      named = ledger_profile(entry, ledger) if named.to_s.empty?
      named.to_s.empty? ? DEFAULT_PROFILE : named.to_s
    end

    def ledger_profile(entry, ledger)
      path = ledger.respond_to?(:path) ? ledger.path : nil
      return nil unless path && File.file?(path)

      data = Polispec::Schema::Document.parse(File.read(path), path)
      row = data.is_a?(Hash) ? Array(data["projects"]).find { |item| item.is_a?(Hash) && item["id"].to_s == entry.id.to_s } : nil
      row && row["profile"]
    rescue Polispec::Error, SystemCallError
      nil
    end

    def global_protected_roots
      layer = global_layer
      return [] unless layer.is_a?(Hash)

      Array(layer["protected_roots"]).filter_map do |item|
        next unless item.is_a?(Hash) && item["path"].is_a?(String) && !item["path"].empty?

        { "path" => File.expand_path(Polispec::Operator::Gates.expand_home(item["path"])), "writers" => Array(item["writers"]).map(&:to_s) }
      end
    end

    def global_layer
      if defined?(Polispec::Layers) && Polispec::Layers.respond_to?(:global)
        found = Polispec::Layers.global
        return found.is_a?(Hash) ? found : nil
      end
      directory_layer
    end

    def directory_layer
      dir = ENV["POLISPEC_GLOBAL"].to_s
      return nil if dir.empty? || !File.directory?(dir)

      global = read_yaml(File.join(dir, "global.yml")) || {}
      profiles = read_yaml(File.join(dir, "profiles.yml")) || {}
      profiles = profiles["profiles"] if profiles["profiles"].is_a?(Hash)
      modules = Dir.glob(File.join(dir, "modules", "*.yml")).sort.each_with_object({}) do |file, memo|
        data = read_yaml(file)
        memo[File.basename(file, ".yml")] = data if data
      end
      global.merge("profiles" => profiles, "modules" => modules)
    end

    def read_yaml(path)
      return nil unless File.file?(path)

      data = Polispec::Schema::Document.parse(File.read(path), path)
      data.is_a?(Hash) ? data : nil
    rescue Polispec::Error, SystemCallError
      nil
    end

    def personal_no_warn_errors
      layer = global_layer
      return [] unless layer.is_a?(Hash)

      profiles = layer["profiles"].is_a?(Hash) ? layer["profiles"] : {}
      modules = layer["modules"].is_a?(Hash) ? layer["modules"] : {}
      selected(Array(profiles[DEFAULT_PROFILE]), modules).flat_map do |name|
        Array(modules[name].is_a?(Hash) ? modules[name]["rules"] : nil).filter_map do |rule|
          next unless rule.is_a?(Hash) && rule["verdict"] == "warn"

          "module #{name} is selected by the personal profile and carries warn rule #{rule['id']}"
        end
      end
    end

    def selected(names, modules, seen = [])
      names.each_with_object(seen) do |name, memo|
        next if memo.include?(name)

        memo << name
        selected(Array(modules[name].is_a?(Hash) ? modules[name]["includes"] : nil), modules, memo)
      end
    end

    def version_reported_errors(policy)
      (policy["environments"] || {}).filter_map do |name, config|
        health = config.is_a?(Hash) && config["deploy"].is_a?(Hash) ? config["deploy"]["health"] : nil
        next unless health.is_a?(Hash) && health["url"]
        next if health["expect_version"] == true

        "env #{name} health does not prove the deployed version"
      end
    end

    def protected_writers_errors(policy)
      roots = global_protected_roots
      return [] if roots.empty?

      (policy["environments"] || {}).flat_map do |name, config|
        deploy = config.is_a?(Hash) ? config["deploy"] : nil
        next [] unless deploy.is_a?(Hash)

        checkout = File.expand_path(Polispec::Operator::Gates.expand_home(config["checkout"].to_s))
        own = File.dirname(checkout)
        commands = Array(deploy["steps"]).map { |text| ["deploy step", text] } + Array(deploy["activate"]).map { |text| ["activate", text] }
        commands.flat_map { |kind, text| writer_errors(name, kind, text.to_s, checkout, own, roots) }
      end
    end

    def writer_errors(name, kind, text, checkout, own, roots)
      command = Polispec::Operator::Gates.expand_home(Polispec::Operator::Gates.interpolate(text, PLACEHOLDERS))
      Polispec::Classify.call("Bash", { "command" => command }, checkout).filter_map do |action|
        next unless WRITE_CLASSES.include?(action.action_class)

        hint = action.env_hint
        path = hint.is_a?(Hash) ? hint["path"] : nil
        next if path.nil? || hint["unknown"]

        target = File.expand_path(path, checkout)
        next if under?(target, own)

        root = roots.find { |item| under?(target, item["path"]) }
        next unless root

        writer = File.basename(first_word(action.raw.to_s, command))
        next if root["writers"].include?(writer)

        "env #{name} #{kind} #{text.inspect} writes under protected root #{root['path']}, whose writers do not include #{writer}"
      end
    end

    def first_word(raw, command)
      Shellwords.split(raw).first || Shellwords.split(command).first.to_s
    rescue ArgumentError
      command.split.first.to_s
    end

    def under?(path, root)
      path == root || path.start_with?("#{root}/")
    end
  end
end
