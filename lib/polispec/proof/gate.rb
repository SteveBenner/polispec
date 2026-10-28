#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require_relative "../operator/git"

module Polispec
  module Proof
    module Gate
      MODES = %w[off report enforce].freeze

      module_function

      def effective_mode(mode, edition)
        chosen = MODES.include?(mode.to_s) ? mode.to_s : "report"
        return chosen unless chosen == "report"

        Polispec::Editions.allowed?("proof.report_mode", edition) ? chosen : "enforce"
      end

      def check(repo:, sha:, base:, mode:, edition: Polispec::Editions.current)
        effective = effective_mode(mode, edition)
        return { "mode" => "off", "findings" => [], "cells" => 0, "proven" => 0, "excepted" => 0 } if effective == "off"

        Digest.reset!
        manifest = load_manifest(repo, sha)
        return result(effective, [manifest], 0, 0, 0) if manifest.is_a?(Hash)

        findings = []
        counts = cell_findings(repo, sha, manifest, findings)
        findings.concat(unmapped_findings(repo, sha, base, manifest))
        result(effective, findings, counts[:cells], counts[:proven], counts[:excepted])
      end

      def result(mode, findings, cells, proven, excepted)
        { "mode" => mode, "findings" => findings, "cells" => cells, "proven" => proven, "excepted" => excepted }
      end

      def load_manifest(repo, sha)
        manifest = Manifest.at(repo, sha)
        manifest || { "kind" => "manifest_missing", "detail" => "#{MANIFEST_PATH} is absent at #{sha.to_s[0, 12]}" }
      rescue Polispec::Error => e
        { "kind" => "manifest_invalid", "detail" => e.message.sub(/\Amanifest_invalid: /, "") }
      end

      def cell_findings(repo, sha, manifest, findings)
        counts = { cells: 0, proven: 0, excepted: 0 }
        today = Date.today
        manifest.features.each do |feature|
          stored = Records.at(repo, sha, feature["id"])
          stored["findings"].each { |item| findings << item.merge("feature" => feature["id"]) }
          manifest.target_ids_for(feature).each do |target_id|
            counts[:cells] += 1
            reason = cell_problem(repo, sha, manifest, feature, target_id, stored["records"])
            if reason.nil?
              counts[:proven] += 1
            elsif excepted?(manifest, feature, target_id, today)
              counts[:excepted] += 1
            else
              findings << { "kind" => "unproven_cell", "feature" => feature["id"], "target" => target_id, "detail" => reason }
            end
          end
        end
        counts
      end

      def cell_problem(repo, sha, manifest, feature, target_id, records)
        mine = records.select { |record| record["target"] == target_id }
        return "no record" if mine.empty?

        digest = Digest.cell(repo, sha, manifest, feature, target_id)
        current = mine.select { |record| record["digest"] == digest }
        return "stale: the feature changed since its last record" if current.empty?

        passing = current.select { |record| record["verdict"] == "pass" }
        return "last record at the current digest is #{current.last['verdict']}" if passing.empty?

        floor = manifest.min_rung(feature)
        ranked = passing.select { |record| record["rung"].to_i >= floor }
        return "rung #{passing.map { |record| record['rung'] }.max} is below min_rung #{floor}" if ranked.empty?

        reasons = []
        ranked.reverse_each do |record|
          ok, reason = Signer.verify(record, manifest)
          return nil if ok

          reasons << reason
        end
        reasons.first
      end

      def excepted?(manifest, feature, target_id, today)
        manifest.exceptions.any? do |entry|
          next false unless entry["feature"] == feature["id"]

          scope = entry["targets"] || manifest.target_ids_for(feature)
          scope.include?(target_id) && Date.parse(entry["expires"].to_s) >= today
        rescue Date::Error
          false
        end
      end

      def unmapped_findings(repo, sha, base, manifest)
        changed_paths(repo, sha, base).reject { |path| manifest.owned?(path) || manifest.ignored?(path) }.map do |path|
          { "kind" => "unmapped_file", "path" => path, "detail" => "matches no feature, shared or ignore glob" }
        end
      end

      def changed_paths(repo, sha, base)
        git = Operator::Git.new(repo)
        listing = if base.to_s.empty?
                    git.run!("ls-tree", "-r", "--name-only", "-z", sha)
                  else
                    git.run!("diff", "--name-only", "-z", "#{base}..#{sha}")
                  end
        listing.out.split("\0").reject(&:empty?)
      end

      def describe(finding)
        subject = [finding["feature"], finding["target"], finding["path"], finding["file"]].compact.join(" ")
        head = [finding["kind"], subject.empty? ? nil : subject].compact.join(" ")
        finding["detail"] ? "#{head} (#{finding['detail']})" : head
      end

      def summary(findings)
        cells = findings.count { |item| item["kind"] == "unproven_cell" }
        files = findings.count { |item| item["kind"] == "unmapped_file" }
        other = findings.length - cells - files
        text = "#{cells} unproven cells, #{files} unmapped files"
        other.positive? ? "#{text}, #{other} other findings" : text
      end

      def stable_gate(policy)
        return nil unless policy.is_a?(Hash) && policy["promotion"].is_a?(Hash) && policy["promotion"]["to_stable"].is_a?(Hash)

        Array(policy["promotion"]["to_stable"]["gates"]).find { |gate| gate.is_a?(Hash) && gate["builtin"] == "features_proven" }
      end

      def upkeep(policy:, repo:)
        gate = stable_gate(policy)
        return nil unless gate && gate["mode"].to_s != "off"

        root = File.expand_path(repo)
        git = Operator::Git.new(root)
        project = Operator::Gates::Project.new(policy: policy, repo: root)
        tag = Operator::Gates.stable_tag(project, git)
        return nil unless tag

        found = check(repo: root, sha: tag, base: nil, mode: "report", edition: "standard")
        return nil if found["findings"].empty?

        { "kind" => "proof_gap", "detail" => "#{summary(found['findings'])} at #{tag}: #{found['findings'].first(3).map { |item| describe(item) }.join('; ')}" }
      rescue StandardError => e
        { "kind" => "proof_gap", "detail" => "proof check failed: #{e.class}: #{e.message}" }
      end
    end
  end
end
