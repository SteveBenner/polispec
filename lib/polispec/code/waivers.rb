#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    class Waivers
      FILE = "specs/polispec/code-waivers.yml".freeze
      Entry = Struct.new(:policy, :paths, :kind, :level, :reason, :review_after, :approved, :expired, keyword_init: true)

      attr_reader :entries, :problems

      def self.load(root, today: Date.today)
        new(root, today)
      end

      def initialize(root, today)
        @entries = []
        @problems = []
        return unless root

        text = Code.git(root, "show", "HEAD:#{FILE}")
        return unless text

        data = Schema::Document.parse(text, FILE)
        errors = Schema.validate("waivers", data)
        unless errors.empty?
          @problems << "#{FILE}: #{errors.first.pointer} #{errors.first.message}"
          return
        end
        data["waivers"].each do |item|
          expired = Date.parse(item["review_after"]) < today
          @entries << Entry.new(
            policy: item["policy"], paths: Array(item["paths"]), kind: item["kind"] || "waive", level: item["level"],
            reason: item["reason"], review_after: item["review_after"], approved: item["approved"], expired: expired
          )
        end
      rescue Schema::Document::ParseError, ArgumentError => e
        @problems << e.message
      end

      def matching(rule_id, relative)
        entries.select { |entry| covers?(entry, rule_id) && path_match?(entry, relative) }
      end

      def suppressed?(rule, relative)
        return false if rule.data["waivable"] == "never"

        matching(rule.id, relative).any? do |entry|
          entry.kind == "waive" && !entry.expired && (rule.data["waivable"] != "waiver_tty" || !entry.approved.to_s.empty?)
        end
      end

      def tightened(rule, relative)
        entry = matching(rule.id, relative).find { |item| item.kind == "tighten" && !item.expired && item.level }
        entry && entry.level
      end

      def expired_for(rule_id, relative)
        matching(rule_id, relative).select(&:expired)
      end

      private

      def covers?(entry, rule_id)
        rule_id == entry.policy || rule_id.start_with?("#{entry.policy}.")
      end

      def path_match?(entry, relative)
        return true if entry.paths.empty?

        flags = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH
        entry.paths.any? { |glob| File.fnmatch?(glob, relative, flags) || File.fnmatch?("**/#{glob}", relative, flags) }
      end
    end
  end
end
