#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "../native_settings"

module Polispec
  class SettingsCommand
    USAGE = "usage: polispec settings list|get <key>|set <key> <value>|unset <key> [--json]"
    SEALED = "polispec: the sealed plane owns settings; ask the operator"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      args = args.dup
      json = args.delete("--json")
      verb = args.shift
      case verb
      when "list" then args.empty? ? list(json) : usage
      when "get" then args.length == 1 ? get(args.first) : usage
      when "set" then args.length == 2 ? set(args[0], args[1]) : usage
      when "unset" then args.length == 1 ? unset(args.first) : usage
      else usage
      end
    rescue Polispec::Error => e
      warn "polispec: #{e.message.sub(/\Apolispec: /, '')}"
      1
    end

    private

    def usage
      warn USAGE
      2
    end

    def plane
      require_relative "../harness_controls/plane"
      return nil unless defined?(HarnessControls::Plane) && HarnessControls::Plane.respond_to?(:resolve)

      state = HarnessControls::Plane.resolve
      raise Polispec::Error, "sealed authority is broken" if state["status"] == "broken"

      state["status"] == "active" ? state.fetch("settings", {}) : nil
    end

    def present?(value)
      !value.nil? && !(value.is_a?(String) && value.strip.empty?)
    end

    def resolve(item, sealed, file)
      key = item.key
      return [sealed.key?(key) ? sealed[key] : item.default, "plane"] if sealed

      rname = Engine::Settings.env_name(key)
      return [ENV[rname].to_s.strip, "env:#{rname}"] unless ENV[rname].to_s.strip.empty?

      short = NativeSettings.env_alias(key)
      return [ENV[short].to_s.strip, "env:#{short}"] if short && !ENV[short].to_s.strip.empty?

      machine = Engine::Settings.snapshot.dig("machine", key)
      return [machine, "rplugin"] if present?(machine)
      return [file[key], "file"] if present?(file[key])

      [item.default, "default"]
    end

    def rows
      sealed = plane
      file = NativeSettings.read
      NativeSettings.definitions.map do |item|
        value, source = resolve(item, sealed, file)
        { "key" => item.key, "value" => value, "source" => source, "options" => item.options }
      end
    end

    def list(json)
      table = rows
      if json
        settings = table.map { |row| row["options"].empty? ? row.reject { |name, _| name == "options" } : row }
        puts JSON.generate({ "file" => NativeSettings.path, "settings" => settings })
      else
        table.each { |row| puts "#{row['key']} = #{row['value']} (#{row['source']})" }
      end
      0
    end

    def known!(key)
      return NativeSettings.definition(key) if NativeSettings.definition(key)

      warn "polispec: unknown setting #{key}"
      warn NativeSettings.definitions.map(&:key).join("\n")
      nil
    end

    def get(key)
      return 2 unless known!(key)

      puts rows.find { |row| row["key"] == key }["value"]
      0
    end

    def set(key, raw)
      return 2 unless known!(key)

      if plane
        warn SEALED
        return 1
      end
      value = NativeSettings.coerce(key, raw)
      data = NativeSettings.read
      data[key] = value
      file = NativeSettings.write(data)
      puts "set #{key} = #{value} in #{file}"
      overriding = overriding_source(key)
      puts "note: #{overriding} overrides this file for #{key}" if overriding
      0
    end

    def unset(key)
      return 2 unless known!(key)

      if plane
        warn SEALED
        return 1
      end
      data = NativeSettings.read
      data.delete(key)
      file = NativeSettings.write(data)
      puts "unset #{key} in #{file}"
      0
    end

    def overriding_source(key)
      row = rows.find { |item| item["key"] == key }
      return nil unless row

      source = row["source"]
      source.start_with?("env:") || source == "rplugin" ? source : nil
    end
  end
end

Polispec::CLI.register("settings", Polispec::SettingsCommand, summary: "show and change polispec settings without rplugin; rplugin settings still win where present")
