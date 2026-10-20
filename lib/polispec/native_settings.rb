#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "yaml"
require "fileutils"
require "time"
require_relative "hook_memo"

module Polispec
  module NativeSettings
    Definition = Struct.new(:key, :type, :options, :default)
    TRUE_WORDS = %w[true on yes].freeze
    FALSE_WORDS = %w[false off no].freeze

    module_function

    def path
      explicit = ENV["POLISPEC_SETTINGS"].to_s.strip
      explicit = "" if sealed?
      return File.expand_path(explicit) unless explicit.empty?

      base = ENV["XDG_CONFIG_HOME"].to_s
      base = File.join(Dir.home, ".config") if base.empty?
      File.expand_path(File.join(base, "polispec", "settings.yml"))
    end

    def sealed?
      require_relative "harness_controls/plane"
      return false unless defined?(HarnessControls::Plane) && HarnessControls::Plane.respond_to?(:resolve)

      HarnessControls::Plane.resolve["status"] == "active"
    rescue StandardError
      false
    end

    def definitions
      HookMemo.fetch(:native_definitions) { definitions_uncached }
    end

    def definitions_uncached
      manifest = YAML.safe_load(File.read(File.join(ROOT, "polispec.rplugin.yml")), permitted_classes: [], aliases: false)
      list = manifest.is_a?(Hash) ? Array(manifest["settings"]) : []
      list.select { |item| item.is_a?(Hash) && item["key"].is_a?(String) }.map do |item|
        Definition.new(item["key"], item["type"].to_s, Array(item["options"]).map(&:to_s), item["default"])
      end
    end

    def definition(key)
      definitions.find { |item| item.key == key.to_s }
    end

    def read
      HookMemo.copy(:native_read, path) { read_uncached }
    end

    def read_uncached
      data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      data.is_a?(Hash) ? data.each_with_object({}) { |(key, value), memo| memo[key.to_s] = value } : {}
    rescue StandardError
      {}
    end

    def coerce(key, raw)
      item = definition(key)
      raise Polispec::Error, "unknown setting #{key}" unless item

      text = raw.to_s
      case item.type
      when "enum"
        return text if item.options.include?(text)

        raise Polispec::Error, "#{key} must be one of #{item.options.join(', ')}"
      when "bool"
        word = text.strip.downcase
        return true if TRUE_WORDS.include?(word)
        return false if FALSE_WORDS.include?(word)

        raise Polispec::Error, "#{key} must be one of true, false, on, off, yes, no"
      when "integer"
        Integer(text.strip, 10)
      when "number"
        Float(text.strip)
      else
        text
      end
    rescue ArgumentError
      raise Polispec::Error, "#{key} must be #{item.type == 'integer' ? 'an integer' : 'a number'}"
    end

    def env_alias(key)
      key = key.to_s
      return nil if key == "polispec.edition"
      return "POLISPEC_OPERATOR_NAME" if key == "polispec.operator"
      return "POLISPEC_AUTHOR" if key == "polispec.author.enabled"

      "POLISPEC_#{key.sub(/\Apolispec\./, '').upcase.gsub(/[^A-Z0-9]+/, '_')}"
    end

    def write(hash)
      file = path
      FileUtils.mkdir_p(File.dirname(file), mode: 0o700)
      backup(file)
      body = YAML.dump(hash.sort_by { |key, _| key.to_s }.to_h.transform_keys(&:to_s))
      tmp = "#{file}.#{Process.pid}.tmp"
      File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |handle| handle.write(body) }
      File.rename(tmp, file)
      file
    end

    def backup(file)
      return nil unless File.file?(file)

      target = "#{file}.polispec-backup-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}"
      FileUtils.cp(file, target)
      target
    end
  end
end
