#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "operator/git"

module Polispec
  module Lint
    RULES = %w[schema hygiene drift refs description].freeze
    SEVERITIES = %w[error warn info].freeze
    CAP = 20

    Finding = Struct.new(:severity, :rule, :code, :path, :line, :pointer, :message, :project) do
      def to_h
        { "severity" => severity, "rule" => rule, "code" => code, "path" => path, "line" => line, "pointer" => pointer, "message" => message }
      end

      def error?
        severity == "error"
      end
    end

    Target = Struct.new(:path, :text, :format, :kind, :expect, :unrecognized, :allow, :project, :descriptions, keyword_init: true)

    Report = Struct.new(:findings, :targets) do
      def counts
        tally = { "error" => 0, "warn" => 0, "info" => 0 }
        findings.each { |finding| tally[finding.severity] += 1 if tally.key?(finding.severity) }
        tally
      end

      def ok?(strict = false)
        tally = counts
        tally["error"].zero? && (!strict || tally["warn"].zero?)
      end

      def to_h(ok = ok?)
        { "ok" => ok, "targets" => targets, "counts" => counts, "findings" => findings.map(&:to_h) }
      end
    end

    module_function

    def lint_on_write?
      Engine::Settings.lint_on_write?
    end

    def lint_doctor?
      Engine::Settings.lint_doctor?
    end

    def lint_strict?
      Engine::Settings.lint_strict?
    end

    def sort_findings(findings)
      findings.each_with_index.sort_by do |finding, index|
        [finding.path.to_s, finding.line.nil? ? 1 : 0, finding.line || 0, finding.code.to_s, index]
      end.map(&:first)
    end

    def finalize(findings)
      kept = []
      seen = Hash.new(0)
      dropped = Hash.new(0)
      first = {}
      sort_findings(findings.uniq).each do |finding|
        key = [finding.path, finding.code]
        first[key] ||= finding
        seen[key] += 1
        seen[key] > CAP ? dropped[key] += 1 : kept << finding
      end
      dropped.each do |key, count|
        base = first[key]
        kept << Finding.new("info", base.rule, base.code, base.path, nil, nil, "#{count} more like this", base.project)
      end
      sort_findings(kept)
    end

    def format_for(path)
      case File.extname(path.to_s).downcase
      when ".json" then :json
      when ".yml", ".yaml" then :yaml
      else :text
      end
    end

    def check_text(text, path:, format: nil, kind: nil, only: %w[hygiene schema])
      target = Target.new(path: path, text: text, format: format || format_for(path), kind: kind, expect: nil, unrecognized: false, allow: [], project: nil, descriptions: false)
      Documents.check(target, text, only: only, description_error: false)
    end

    def guard_write!(text, path:, kind: nil, format: nil)
      return text unless Engine::Settings.lint_on_write?

      only = kind.is_a?(String) ? %w[hygiene schema] : %w[hygiene]
      errors = check_text(text, path: path, format: format, kind: kind, only: only).select(&:error?)
      if errors.empty?
        Trace.info("lint gate", kind: kind, path: Trace.path(path), result: "ok") if Trace.on?
        return text
      end

      first = errors.first
      shown = path.to_s.length > 80 ? File.basename(path.to_s) : path.to_s
      problems = errors.map do |finding|
        [finding.code, finding.line ? "line #{finding.line}" : nil, finding.pointer, finding.message].compact.join(" ")
      end
      raise Operator::Failure.new("lint_failed", "#{shown} does not lint: #{first.code} #{first.message}", "path" => path, "problems" => problems)
    rescue Operator::Failure
      raise
    rescue StandardError
      text
    end

    def run(roots: [], files: [], host: false, shipped: false, only: RULES, for_doctor: false)
      require_relative "lint/sweep"
      Sweep.call(roots: roots, files: files, host: host, shipped: shipped, only: only, for_doctor: for_doctor)
    end
  end
end

require_relative "lint/hygiene"
require_relative "lint/documents"
