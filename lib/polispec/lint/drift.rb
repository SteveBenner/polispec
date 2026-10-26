#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Lint
    module Drift
      module_function

      def check(scope, only:, for_doctor:)
        return [] unless only.include?("drift")

        require_relative "../agents_render"
        require_relative "../behavior"
        require_relative "../surfaces"
        require_relative "../manifest"
        roots = Array(scope[:roots]).map { |root| File.expand_path(root) }.uniq
        out = []
        (roots - Array(scope[:ref_roots])).each do |root|
          out.concat(agents_drift(root)) unless for_doctor
          out.concat(manifest_drift(root)) unless for_doctor
        end
        out.concat(behavior_drift(roots, Array(scope[:targets])))
        out.concat(contract_drift(roots, Array(scope[:targets])))
        out.concat(harness_drift) if scope[:host]
        out
      end

      def finding(severity, code, path, message, project = nil)
        Finding.new(severity, "drift", code, path, nil, nil, message, project)
      end

      def ledger_for(root)
        ledger = Ledger.load
        [ledger, ledger.locate(root)&.project]
      rescue StandardError
        [nil, nil]
      end

      def agents_drift(root)
        _ledger, project = ledger_for(root)
        policy_path = project ? project.policy : AgentsRender::POLICY_PATH
        env_file = File.join(root, File.dirname(policy_path), Environments::FILE)
        return [] unless File.file?(env_file)

        source = AgentsRender.source_from_worktree(root, policy_path)
        files = AgentsRender.plan(root, AgentsRender.render(source))
        files.select { |file| file[:changed] }.map do |file|
          finding("error", "agents_drift", file[:path], "differs from what polispec agents render writes", project&.id)
        end
      rescue StandardError => e
        [finding("warn", "agents_drift", File.join(root, policy_path_label(root)), "cannot compare with the render: #{e.message}")]
      end

      def policy_path_label(root)
        _ledger, project = ledger_for(root)
        project ? project.policy : AgentsRender::POLICY_PATH
      end

      def behavior_drift(roots, targets)
        out = []
        targets.each do |target|
          next unless %w[auto behavior].include?(target.kind)
          root = roots.select { |candidate| target.path.start_with?("#{candidate}/") }.max_by(&:length)
          next unless root && File.file?(target.path)

          begin
            data = Schema::Document.parse(File.binread(target.path).force_encoding("UTF-8"), target.path)
            next unless Behavior.v2?(data) && data["surfaces"].is_a?(Hash) && !data["surfaces"].empty?

            compiled = Behavior.compile(Behavior.load(target.path), root: root)
            Surfaces.drift(compiled, root: root).each do |item|
              out << finding("error", "behavior_surface_drift", File.join(root, item["target"]),
                             "surface #{item['surface']} expected sha256 #{item['expected_sha256']} actual #{item['actual_sha256'] || 'missing'}", target.project)
            end
          rescue Schema::Document::ParseError
            next
          rescue StandardError => e
            out << finding("warn", "behavior_surface_drift", target.path, e.message, target.project)
          end
        end
        out
      end

      def contract_drift(roots, targets)
        require_relative "../contract"
        out = []
        targets.each do |target|
          next unless %w[auto contract].include?(target.kind)

          root = roots.select { |candidate| target.path.start_with?("#{candidate}/") }.max_by(&:length)
          next unless root && File.file?(target.path)

          begin
            data = Schema::Document.parse(File.binread(target.path).force_encoding("UTF-8"), target.path)
            next unless Contract.contract?(data) && Schema.validate("contract", data).empty?

            behavior, = Contract.load_behavior(data, root, data["id"])
            next unless behavior

            Contract.drift_items(data, behavior, root).each do |item|
              out << finding("error", "behavior_surface_drift", File.join(root, item["target"]),
                             "surface #{item['surface']} expected sha256 #{item['expected_sha256']} actual #{item['actual_sha256'] || 'missing'}", target.project)
            end
          rescue Schema::Document::ParseError
            next
          rescue StandardError => e
            out << finding("warn", "behavior_surface_drift", target.path, e.message, target.project)
          end
        end
        out
      end

      def manifest_drift(root)
        file = File.join(root, Manifest::MANIFEST_FILE)
        return [] unless File.file?(file)

        ledger, project = ledger_for(root)
        return [] unless ledger && project && File.expand_path(project.repo) == root

        text = File.binread(file).force_encoding("UTF-8")
        committed = JSON.parse(text)
        regenerate = "regenerate with polispec manifest #{project.id} --write"
        out = Schema.validate("manifest", committed).map do |error|
          finding("warn", "manifest_drift", file, "#{error.pointer} #{error.message}".strip, project.id)
        end
        out.concat(manifest_differences(ledger, project, committed, file, regenerate))
        badge = File.join(root, Manifest::BADGE_FILE)
        if File.file?(badge)
          expected = Manifest.badge_svg(committed)
          out << finding("warn", "manifest_drift", badge, "badge differs from the committed manifest; #{regenerate}", project.id) unless File.read(badge) == expected
        end
        out
      rescue StandardError
        []
      end

      def manifest_differences(ledger, project, committed, file, regenerate)
        current = Manifest.for(project.id, ledger: ledger)
        pairs = [
          ["id", committed["id"], current["id"]],
          ["status", committed["status"], current["status"]],
          ["enforce", committed["enforce"], current["enforce"]],
          ["policy.digest", committed.dig("policy", "digest"), current.dig("policy", "digest")]
        ]
        names = (committed["environments"].to_h.keys + current["environments"].to_h.keys).uniq.sort
        names.each do |name|
          pairs << ["environments.#{name}.policy_digest", committed.dig("environments", name, "policy_digest"), current.dig("environments", name, "policy_digest")]
        end
        pairs.reject { |_label, old, new| old == new }.map do |label, old, new|
          finding("warn", "manifest_drift", file, "#{label} is #{old.inspect} in the manifest and #{new.inspect} now; #{regenerate}", project.id)
        end
      rescue StandardError
        []
      end

      def harness_drift
        require_relative "../harness_controls/lifecycle"
        require_relative "../harness_controls/files"
        installs = HarnessControls::Lifecycle.owned_installations
        installs.flat_map do |install|
          receipt = begin
            HarnessControls::Lifecycle.receipt(install["installation_id"])
          rescue StandardError
            nil
          end
          receipt ||= install["receipt"]
          next [] unless receipt

          result = HarnessControls::Files.verify_receipt(receipt)
          Array(result["findings"]).map do |item|
            path = item["detail"].to_s[%r{(/[^\s]+?) (?:do not match|is invalid)}, 1] || Array(install["artifacts"]).first
            finding("error", "harness_artifact_drift", path, item["detail"].to_s)
          end
        end
      rescue StandardError
        []
      end
    end
  end
end
