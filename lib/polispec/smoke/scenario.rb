#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../smoke"

module Polispec
  module Smoke
    class ScenarioError < Polispec::Error; end

    class Scenario
      SCHEMA = "polispec.smoke-scenario/v1"
      PLACEHOLDER = /\{\{\s*([^{}\s]+)\s*\}\}/
      FIXED = %w[scratch home files global ledger polispec tree out].freeze
      CHECKOUT_ENVS = %w[test stable].freeze
      HOOK_EXPECT = %w[decision rule stdout_includes stdout_excludes exit files_exist files_absent git].freeze
      RUN_EXPECT = %w[exit stdout_includes stdout_excludes stderr_includes json files_exist files_absent git].freeze
      LIVE_EXPECT = %w[hook_log files_exist files_absent git].freeze

      attr_reader :path, :stem, :data

      def self.load(path)
        data = Schema::Document.load(path)
        errors = Schema.validate("smoke-scenario", data)
        unless errors.empty?
          raise ScenarioError, "#{path}: #{errors.map { |item| "#{item.pointer.empty? ? '/' : item.pointer} #{item.message}" }.join('; ')}"
        end

        new(path, data)
      rescue Schema::Document::ParseError => e
        raise ScenarioError, e.message
      end

      def self.strings(value, &block)
        case value
        when String then yield value
        when Hash then value.each { |key, item| strings(key, &block) if key.is_a?(String); strings(item, &block) }
        when Array then value.each { |item| strings(item, &block) }
        end
      end

      def self.known?(name, data)
        return true if FIXED.include?(name)

        projects = Array(data.dig("fixture", "projects")).select { |item| item.is_a?(Hash) }
        parts = name.split(".")
        if parts.length == 2 && parts[0] == "project"
          projects.any? { |item| item["id"] == parts[1] }
        elsif parts.length == 3 && parts[0] == "checkout"
          CHECKOUT_ENVS.include?(parts[2]) && projects.any? { |item| item["id"] == parts[1] && item["checkouts"] == true }
        else
          false
        end
      end

      def self.semantic_errors(data)
        errors = []
        names = {}
        Array(data["steps"]).each_with_index do |step, index|
          pointer = "/steps/#{index}"
          errors << Schema::Error.new("#{pointer}/name", "must be unique within the file") if names[step["name"]]
          names[step["name"]] = true
          errors.concat(step_errors(step, pointer))
        end
        ids = Array(data.dig("fixture", "projects")).map { |item| item["id"] }
        ids.each_with_index { |id, index| errors << Schema::Error.new("/fixture/projects/#{index}/id", "must be unique within the file") if ids.index(id) != index }
        errors.concat(fixture_errors(data["fixture"]))
        seen = {}
        strings(data) do |text|
          text.scan(PLACEHOLDER).flatten.each do |name|
            next if seen[name]

            seen[name] = true
            errors << Schema::Error.new("", "unknown placeholder {{#{name}}}") unless known?(name, data)
          end
        end
        errors
      end

      def self.fixture_errors(fixture)
        return [] unless fixture.is_a?(Hash)

        errors = []
        errors << Schema::Error.new("/fixture/global_files", "is required when global is files") if fixture["global"] == "files" && !fixture["global_files"].is_a?(Hash)
        errors << Schema::Error.new("/fixture/global_files", "is only allowed when global is files") if fixture.key?("global_files") && fixture["global"] != "files"
        (fixture["global_files"] || {}).each_key do |name|
          errors << Schema::Error.new("/fixture/global_files/#{name}", "must be a relative path without ..") unless Schema.safe_relative?(name)
        end
        (fixture["files"] || {}).each_key do |name|
          errors << Schema::Error.new("/fixture/files/#{name}", "must be a relative path without ..") unless Schema.safe_relative?(name)
        end
        Array(fixture["projects"]).each_with_index do |project, index|
          (project["files"] || {}).each_key do |name|
            errors << Schema::Error.new("/fixture/projects/#{index}/files/#{name}", "must be a relative path without ..") unless Schema.safe_relative?(name)
          end
        end
        errors
      end

      def self.step_errors(step, pointer)
        errors = []
        expect = step["expect"].is_a?(Hash) ? step["expect"] : {}
        if step.key?("live")
          errors.concat(live_errors(step, expect, pointer))
        elsif step.key?("run") && step.key?("hook")
          errors << Schema::Error.new(pointer, "must declare run or hook, not both")
        elsif step.key?("hook")
          errors.concat(hook_errors(step, expect, pointer))
        else
          (expect.keys - RUN_EXPECT).each { |key| errors << Schema::Error.new("#{pointer}/expect/#{key}", "is only allowed on a hook step") }
          errors << Schema::Error.new("#{pointer}/expect/exit", "is required for a run step") unless expect.key?("exit")
        end
        errors << Schema::Error.new("#{pointer}/tty", "is only allowed on a run step") if step.key?("tty") && step.key?("hook")
        errors << Schema::Error.new("#{pointer}/stdin", "is only allowed on a run step") if step.key?("stdin") && step.key?("hook")
        errors << Schema::Error.new("#{pointer}/tty", "cannot be combined with stdin") if step.key?("tty") && step.key?("stdin")
        errors
      end

      def self.live_errors(step, expect, pointer)
        errors = []
        errors << Schema::Error.new(pointer, "must declare live alone, without run or hook") if step.key?("run") || step.key?("hook")
        %w[tty stdin timeout].each { |key| errors << Schema::Error.new("#{pointer}/#{key}", "is not allowed on a live step") if step.key?(key) }
        (expect.keys - LIVE_EXPECT).each { |key| errors << Schema::Error.new("#{pointer}/expect/#{key}", "is not allowed on a live step") }
        errors << Schema::Error.new("#{pointer}/expect/hook_log", "is required for a live step") unless expect.key?("hook_log")
        errors
      end

      def self.hook_errors(step, expect, pointer)
        errors = []
        hook = step["hook"]
        (expect.keys - HOOK_EXPECT).each { |key| errors << Schema::Error.new("#{pointer}/expect/#{key}", "is not allowed on a hook step") }
        errors << Schema::Error.new("#{pointer}/expect/decision", "is required for a hook step") unless expect.key?("decision")
        errors << Schema::Error.new("#{pointer}/hook/tool", "is required for a pretool hook") if hook["event"] == "pretool" && !hook.key?("tool")
        errors << Schema::Error.new("#{pointer}/hook/tool", "is not allowed for a session hook") if hook["event"] == "session" && (hook.key?("tool") || hook.key?("input"))
        errors
      end

      def self.expand(value, vars)
        case value
        when String
          value.gsub(PLACEHOLDER) do
            name = Regexp.last_match(1)
            raise ScenarioError, "unknown placeholder {{#{name}}}" unless vars.key?(name)

            vars.fetch(name)
          end
        when Hash then value.to_h { |key, item| [expand(key, vars), expand(item, vars)] }
        when Array then value.map { |item| expand(item, vars) }
        else value
        end
      end

      def initialize(path, data)
        @path = File.expand_path(path)
        @stem = File.basename(path, ".*")
        @data = data
      end

      def unit
        data["unit"]
      end

      def spec
        data["spec"] || DEFAULT_SPEC
      end

      def summary
        data["summary"]
      end

      def requires
        Array(data["requires"])
      end

      def fixture
        data["fixture"] || {}
      end

      def steps
        data["steps"]
      end
    end
  end
end
