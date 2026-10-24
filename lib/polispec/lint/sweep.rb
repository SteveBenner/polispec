#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../lint"
require_relative "targets"
require_relative "drift"
require_relative "refs"

module Polispec
  module Lint
    module Sweep
      MAX_BYTES = 5 * 1024 * 1024
      HYGIENE_ONLY = %w[schema_doc template hygiene deployments].freeze

      module_function

      def call(roots: [], files: [], host: false, shipped: false, only: RULES, for_doctor: false)
        only = Array(only).map(&:to_s)
        notes = []
        host_roots = []
        labels = {}
        scratch = []
        targets = []
        roots.each { |root| targets.concat(Targets.project(root, notes: notes)) }
        files.each do |file|
          path = File.expand_path(file)
          targets << Targets.target(path: path, kind: "auto", format: Lint.format_for(path), descriptions: true)
        end
        targets.concat(Targets.host(for_doctor: for_doctor, notes: notes, roots: host_roots, labels: labels, scratch: scratch)) if host
        targets.concat(Targets.shipped(notes: notes)) if shipped
        targets = targets.uniq { |target| [target.path, target.kind] }
        findings = notes.select { |note| only.include?(note.rule) }
        description_error = Engine::Settings.description_strict?
        targets.each do |target|
          check_target(target, only, description_error).each do |item|
            item.path = labels[item.path] if labels.key?(item.path)
            findings << item
          end
        end
        scope = { roots: (roots.map { |root| File.expand_path(root) } + host_roots).uniq, host: host, shipped: shipped, targets: targets }
        findings.concat(Drift.check(scope, only: only, for_doctor: for_doctor))
        findings.concat(Refs.check(scope, only: only, for_doctor: for_doctor))
        Report.new(Lint.finalize(findings), targets.length)
      ensure
        scratch.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) } if scratch
      end

      def check_target(target, only, description_error)
        text = target.text
        if text.nil?
          size = File.size(target.path)
          return [Finding.new("info", "hygiene", "file_too_large", target.path, nil, nil, "larger than #{MAX_BYTES} bytes; not checked", target.project)] if size > MAX_BYTES

          text = File.binread(target.path).force_encoding("UTF-8")
        elsif text.bytesize > MAX_BYTES
          return [Finding.new("info", "hygiene", "file_too_large", target.path, nil, nil, "larger than #{MAX_BYTES} bytes; not checked", target.project)]
        end
        custom = %w[schema_doc deployments].include?(target.kind)
        effective = HYGIENE_ONLY.include?(target.kind) ? retarget(target) : target
        out = Documents.check(effective, text, only: only, description_error: description_error)
        out.concat(custom_findings(target, text)) if custom && only.include?("schema") && out.none? { |item| item.error? && Documents::STOPPING.include?(item.code) }
        out
      rescue SystemCallError => e
        [Finding.new("warn", "hygiene", "target_unreadable", target.path, nil, nil, e.message, target.project)]
      end

      def retarget(target)
        copy = target.dup
        copy.kind = nil
        copy
      end

      def custom_findings(target, text)
        body = text.sub(Hygiene::BOM, "")
        data = Schema::Document.parse(body, target.path)
        unless data.is_a?(Hash)
          return [Finding.new("error", "schema", "schema_invalid", target.path, nil, "", "the document must be a mapping", target.project)]
        end

        return Schema::Validator.new(Schema::Document.load(File.join(Schema::DIR, "deployments.v1.yml"))).call(data).map { |error| Finding.new("error", "schema", "schema_invalid", target.path, nil, error.pointer, error.message, target.project) } if target.kind == "deployments"

        Schema::Validator.new(data).call(nil)
        []
      rescue Schema::Document::ParseError
        []
      rescue StandardError => e
        [Finding.new("error", "schema", "schema_invalid", target.path, nil, "", "the schema cannot be evaluated: #{e.message}", target.project)]
      end
    end
  end
end
