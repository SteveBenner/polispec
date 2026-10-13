#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "authority"
require_relative "../operator/tty"

module Polispec
  module HarnessControls
    module Plane
      ACTIVE_PATH = "/etc/polispec/active.json"
      GENERATIONS_PATH = "/etc/polispec/generations"
      RECORDS_PATH = "/var/lib/polispec"
      SCHEMA = "polispec.plane.active/v1"
      PLANE_SCHEMA = "polispec.plane.generation/v1"
      EDITIONS = %w[standard lock].freeze

      module_function

      def resolve
        resolve_root(Authority::ROOT_PATH, require_protected: true, development: false)
      end

      def development_resolve(root)
        resolve_root(File.expand_path(root.to_s), require_protected: false, development: true)
      end

      def resolve_root(root, require_protected:, development:)
        active_path = File.join(root, "active.json")
        ignored = ignored_overrides
        return base_result("unsealed", [], [], development) unless File.exist?(active_path) || File.symlink?(active_path)

        findings = []
        active = read_regular_json(active_path, "active sentinel", findings)
        return base_result("broken", findings, ignored, development) unless active
        unless active["schema"] == SCHEMA && valid_generation?(active["generation"])
          findings << finding("active_record_invalid", "Active sentinel has an invalid schema or generation.")
          return base_result("broken", findings, ignored, development)
        end
        findings.concat(Authority.protection_findings(active_path, "active_sentinel")) if require_protected
        generation = active["generation"]
        generation_root = File.join(root, "generations", generation)
        unless File.directory?(generation_root) && !File.symlink?(generation_root)
          findings << finding("generation_missing", "Active generation #{generation} is missing or unsafe.")
          return base_result("broken", findings, ignored, development)
        end
        findings.concat(Authority.protection_findings(generation_root, "generation")) if require_protected
        plane_path = File.join(generation_root, "plane.json")
        record = read_regular_json(plane_path, "generation record", findings)
        return base_result("broken", findings, ignored, development) unless record
        unless record["schema"] == PLANE_SCHEMA && record["generation"] == generation && EDITIONS.include?(record["edition"])
          findings << finding("generation_record_invalid", "Generation record does not match the active generation.")
          return base_result("broken", findings, ignored, development)
        end
        verify_generation_files(generation_root, record, findings, require_protected)
        verify_runtime_record(record, findings, require_protected)
        return base_result("broken", findings, ignored, development) unless findings.empty?

        paths = absolute_paths(generation_root, record["paths"])
        settings = stringify_hash(record["settings"])
        settings["polispec.enforce"] = "enforce"
        settings["polispec.ledger"] = paths["ledger"]
        settings["polispec.code.specs_repo"] = paths["code_specs_repo"] if paths["code_specs_repo"]
        controls = stringify_hash(record["controls"]).each_with_object({}) do |(name, relative), result|
          result[name] = safe_generation_path(generation_root, relative)
        end
        {
          "status" => "active",
          "findings" => development ? [finding("development_evidence_only", "This plane was resolved beneath an isolated development root and is not certified authority.")] : [],
          "ignored_overrides" => ignored,
          "edition" => record["edition"],
          "generation" => generation,
          "runtime_argv" => Array(record.dig("runtime", "argv")).map(&:to_s),
          "provenance" => {
            "source" => record["source"],
            "runtime" => record.dig("runtime", "provenance"),
            "source_digest" => record.dig("source", "digest"),
            "runtime_digest" => record.dig("runtime", "digest")
          },
          "authority_files" => Array(record["authority_files"]).map { |relative| safe_generation_path(generation_root, relative) },
          "operator_records" => RECORDS_PATH,
          "settings" => settings,
          "paths" => paths,
          "controls" => controls,
          "certification" => stringify_hash(record["certification"]),
          "development" => development
        }
      rescue Authority::Failure => error
        base_result("broken", [finding(error.code, error.message)], ignored_overrides, development)
      rescue StandardError => error
        base_result("broken", [finding("plane_resolution_failed", error.message)], ignored_overrides, development)
      end

      def setting(key, default = nil)
        plane = resolve
        raise Authority::Failure.new("broken_plane", "sealed plane is broken", plane["findings"]) if plane["status"] == "broken"
        return nil if plane["status"] == "unsealed"
        plane["settings"].fetch(key.to_s, default)
      end

      def path(name)
        plane = resolve
        raise Authority::Failure.new("broken_plane", "sealed plane is broken", plane["findings"]) if plane["status"] == "broken"
        return nil if plane["status"] == "unsealed"
        plane["paths"][name.to_s]
      end

      def requested_edition
        plane = resolve
        raise Authority::Failure.new("broken_plane", "sealed plane is broken", plane["findings"]) if plane["status"] == "broken"
        return plane["edition"] if plane["status"] == "active"

        floor = build_edition
        configured = if defined?(Engine::Settings)
                       Engine::Settings.text("polispec.edition", "standard").to_s
                     else
                       "standard"
                     end
        raise Authority::Failure.new("invalid_edition", "polispec.edition must be standard or lock") unless EDITIONS.include?(configured)
        floor == "lock" ? "lock" : configured
      end

      def operator!(operation)
        Authority.operator!(operation, plane: resolve)
      end

      def activation_overrides
        plane = resolve
        raise Authority::Failure.new("broken_plane", "sealed plane is broken", plane["findings"]) if plane["status"] == "broken"
        return {} unless plane["status"] == "active"
        require_relative "operator_records"
        OperatorRecords.read("activations").each_with_object({}) do |record, result|
          next unless record["generation"] == plane["generation"]
          project = record["project_id"].to_s
          status = record["status"].to_s
          result[project] = status if !project.empty? && %w[live paused].include?(status)
        end
      end

      def verify
        plane = resolve
        prerequisites = []
        if plane["status"] == "active"
          certification = plane["certification"]
          prerequisites << "protected runtime launch provenance" unless certification["runtime_provenance"] == "verified"
          prerequisites << "required native harness evidence" unless certification["native_evidence"] == "verified"
          prerequisites << "OS containment evidence" unless certification["os_containment"] == "verified"
          prerequisites << "lock-capable harness set" if plane["edition"] == "lock" && certification["lock_eligible"] != true
        else
          prerequisites << "active sealed generation"
        end
        plane.merge("green" => plane["status"] == "active" && prerequisites.empty?, "prerequisites" => prerequisites)
      end

      def activate(project_ids, dry_run: false)
        plane = verify
        raise Authority::Failure.new("broken_plane", "sealed plane is broken", plane["findings"]) if plane["status"] == "broken"
        raise Authority::Failure.new("prerequisite_missing", "project activation requires an active plane") unless plane["status"] == "active"
        raise Authority::Failure.new("prerequisite_missing", "project activation is blocked: #{plane['prerequisites'].join(', ')}") unless plane["green"]
        identity = operator!("plane.activate")
        ledger = Ledger.load(plane.dig("paths", "ledger"))
        ids = Array(project_ids).map(&:to_s).uniq
        raise Authority::Failure.new("invalid_project", "at least one project ID is required") if ids.empty?
        projects = ids.map do |id|
          project = ledger.project(id)
          raise Authority::Failure.new("invalid_project", "unknown project #{id}") unless project
          raise Authority::Failure.new("invalid_project", "project #{id} is retired") if project.status == "retired"
          raise Authority::Failure.new("project_validation_failed", "project #{id} repository is unavailable") unless File.directory?(File.expand_path(project.repo))
          project
        end
        records = projects.map do |project|
          {
            "schema" => "polispec.plane.activation/v1",
            "generation" => plane["generation"],
            "project_id" => project.id,
            "prior_status" => activation_overrides.fetch(project.id, project.status),
            "status" => "live",
            "recorded_at" => Time.now.utc.iso8601
          }
        end
        unless dry_run
          Operator::Tty.confirm!("activate #{ids.sort.join(',')} on #{plane['generation']}", prompt: "Project activation changes protected effective status.")
          require_relative "operator_records"
          records.each { |record| OperatorRecords.append("activations", record, identity: identity) }
        end
        { "dry_run" => dry_run == true, "generation" => plane["generation"], "projects" => records, "identity" => identity }
      end

      def build_generation(plan)
        raise Authority::Failure.new("prerequisite_missing", "authority source has blocking prerequisites", plan["source"]["findings"]) unless plan["preparation_ready"]
        Authority.bootstrap_identity!("seal.prepare")
        generation = plan["generation"]
        destination = File.join(GENERATIONS_PATH, generation)
        return destination if File.directory?(destination) && resolve_generation(destination, generation)

        temp = File.join(GENERATIONS_PATH, ".#{generation}.tmp-#{Process.pid}")
        raise Authority::Failure.new("generation_conflict", "temporary generation path already exists") if File.exist?(temp)
        FileUtils.mkdir_p(File.join(temp, "source"), mode: 0o700)
        materialize_source(plan["source"], File.join(temp, "source"))
        source_manifest = Authority.canonical_value(plan.dig("source", "manifest"))
        runtime_manifest = Authority.canonical_value(plan["runtime"])
        write_json(File.join(temp, "source-manifest.json"), source_manifest)
        write_json(File.join(temp, "runtime-manifest.json"), runtime_manifest)
        record = generation_record(plan, temp)
        write_json(File.join(temp, "plane.json"), record)
        FileUtils.mkdir_p(GENERATIONS_PATH, mode: 0o700)
        File.rename(temp, destination)
        destination
      end

      def switch_generation(plan)
        raise Authority::Failure.new("prerequisite_missing", "seal activation has blocking runtime prerequisites", plan["findings"]) unless plan["ready"]
        current = resolve
        raise Authority::Failure.new("broken_plane", "existing fixed-root plane is broken and requires operator recovery", current["findings"]) if current["status"] == "broken"
        destination = File.join(GENERATIONS_PATH, plan["generation"])
        raise Authority::Failure.new("prerequisite_missing", "prepared generation is missing") unless File.directory?(destination)
        prepared_record = JSON.parse(File.read(File.join(destination, "plane.json")))
        candidate = {
          "status" => "active",
          "generation" => plan["generation"],
          "provenance" => { "runtime" => prepared_record.dig("runtime", "provenance") }
        }
        identity = Authority.operator!("seal.activate", plane: candidate)
        active = { "schema" => SCHEMA, "generation" => plan["generation"] }
        prior = File.binread(ACTIVE_PATH) if File.file?(ACTIVE_PATH) && !File.symlink?(ACTIVE_PATH)
        Authority.write_atomic(ACTIVE_PATH, JSON.pretty_generate(Authority.canonical_value(active)) + "\n", mode: 0o600)
        resolved = resolve
        unless resolved["status"] == "active"
          if prior
            Authority.write_atomic(ACTIVE_PATH, prior, mode: 0o600)
          else
            backup = "#{ACTIVE_PATH}.failed-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}"
            File.rename(ACTIVE_PATH, backup) if File.exist?(ACTIVE_PATH)
          end
          raise Authority::Failure.new("activation_failed", "post-switch plane verification failed", resolved["findings"])
        end
        { "generation" => plan["generation"], "identity" => identity, "plane" => resolved }
      end

      def base_result(status, findings, ignored, development)
        {
          "status" => status,
          "findings" => findings,
          "ignored_overrides" => ignored,
          "development" => development == true
        }
      end
      private_class_method :base_result

      def ignored_overrides
        ENV.keys.select do |name|
          name.start_with?("POLISPEC_", "RPLUGIN_POLISPEC_") || Authority::IGNORED_ENV.include?(name)
        end.sort
      end
      private_class_method :ignored_overrides

      def read_regular_json(path, label, findings)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink?
          findings << finding("#{label.tr(' ', '_')}_unsafe", "#{label} is not a regular non-symlink file.")
          return nil
        end
        raise Authority::Failure.new("oversized_record", "#{label} exceeds #{Authority::MAX_FILE} bytes") if stat.size > Authority::MAX_FILE
        data = JSON.parse(File.binread(path))
        unless data.is_a?(Hash)
          findings << finding("#{label.tr(' ', '_')}_invalid", "#{label} must contain an object.")
          return nil
        end
        data
      rescue JSON::ParserError => error
        findings << finding("#{label.tr(' ', '_')}_invalid", "#{label} is malformed JSON: #{error.message}")
        nil
      rescue SystemCallError => error
        findings << finding("#{label.tr(' ', '_')}_unreadable", "Cannot read #{label}: #{error.message}")
        nil
      end
      private_class_method :read_regular_json

      def verify_generation_files(root, record, findings, require_protected)
        files = stringify_hash(record["files"])
        files.each do |relative, expected|
          path = safe_generation_path(root, relative)
          unless File.file?(path) && !File.symlink?(path)
            findings << finding("authority_file_missing", "Generation file #{relative} is missing or unsafe.")
            next
          end
          actual = Digest::SHA256.file(path).hexdigest
          findings << finding("authority_digest_mismatch", "Generation file #{relative} failed its digest.") unless actual == expected
          if require_protected
            findings.concat(Authority.protection_findings(path, "authority_file").map { |item| finding(item["code"], item["detail"]) })
          end
        end
        findings << finding("authority_manifest_empty", "Generation record contains no authority file digests.") if files.empty?
        source_manifest = JSON.parse(File.read(safe_generation_path(root, "source-manifest.json")))
        source_digest = Digest::SHA256.hexdigest(Authority.canonical_json(source_manifest))
        findings << finding("source_manifest_digest", "Source manifest does not match recorded source provenance.") unless source_digest == record.dig("source", "digest")
        runtime_manifest = JSON.parse(File.read(safe_generation_path(root, "runtime-manifest.json")))
        findings << finding("runtime_manifest_digest", "Runtime manifest does not match recorded runtime provenance.") unless runtime_manifest["digest"] == record.dig("runtime", "digest")
      rescue JSON::ParserError => error
        findings << finding("authority_manifest_invalid", "Generation manifest is malformed: #{error.message}")
      rescue Authority::Failure => error
        findings << finding(error.code, error.message)
      end
      private_class_method :verify_generation_files

      def verify_runtime_record(record, findings, require_protected)
        runtime = stringify_hash(record["runtime"])
        argv = Array(runtime["argv"])
        findings << finding("runtime_argv_invalid", "Generation runtime argv is invalid.") unless !argv.empty? && argv.all? { |item| item.is_a?(String) && !item.empty? && !item.include?("\0") } && argv.first.start_with?("/")
        provenance = stringify_hash(runtime["provenance"])
        %w[launcher interpreter sdk].each do |key|
          path = provenance.dig(key, "realpath")
          findings << finding("runtime_#{key}_missing", "Runtime #{key} provenance is missing.") unless path
          findings.concat(Authority.protection_findings(path, "runtime_#{key}").map { |item| finding(item["code"], item["detail"]) }) if require_protected && path
        end
      end
      private_class_method :verify_runtime_record

      def absolute_paths(root, paths)
        stringify_hash(paths).each_with_object({}) do |(name, relative), result|
          result[name] = safe_generation_path(root, relative)
        end
      end
      private_class_method :absolute_paths

      def safe_generation_path(root, relative)
        value = relative.to_s
        invalid = value.empty? || value.start_with?("/") || value.include?("\0") || value.split("/").include?("..")
        raise Authority::Failure.new("invalid_generation_path", "invalid generation-relative path #{value.inspect}") if invalid
        path = File.expand_path(value, root)
        raise Authority::Failure.new("invalid_generation_path", "generation path escapes its root") unless path.start_with?("#{root}/")
        path
      end
      private_class_method :safe_generation_path

      def valid_generation?(value)
        value.is_a?(String) && value.match?(/\A[a-f0-9]{32}\z/)
      end
      private_class_method :valid_generation?

      def build_edition
        path = File.join(ROOT, "EDITION")
        value = File.file?(path) ? File.read(path).strip : "standard"
        EDITIONS.include?(value) ? value : "standard"
      rescue SystemCallError
        "standard"
      end
      private_class_method :build_edition

      def finding(code, detail)
        { "code" => code, "detail" => detail }
      end
      private_class_method :finding

      def stringify_hash(value)
        return {} unless value.is_a?(Hash)
        value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
      end
      private_class_method :stringify_hash

      def materialize_source(source, destination)
        source.fetch("manifest").fetch("files").each do |entry|
          relative = entry.fetch("path")
          target = File.join(destination, relative)
          FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
          bytes = if source["kind"] == "git"
                    output, error, status = Open3.capture3("git", "-C", source["root"], "show", "#{source['ref']}:#{relative}")
                    raise Authority::Failure.new("git_failed", error) unless status.success?
                    output
                  else
                    File.binread(File.join(source["root"], relative))
                  end
          File.open(target, "wb", entry["mode"] & 0o777) { |file| file.write(bytes) }
        end
      end
      private_class_method :materialize_source

      def generation_record(plan, root)
        source_root = File.join(root, "source")
        controls = plan.dig("source", "bundle", "controls").keys.each_with_object({}) do |name, result|
          result[name] = "source/controls/#{name}.json"
        end
        paths = { "ledger" => "source/ledger.yml" }
        paths["global"] = "source/global" if plan.dig("source", "bundle", "has_global")
        paths["code_specs_repo"] = "source/code_specs" if plan.dig("source", "bundle", "has_code_specs")
        %w[home envs code_state].each { |name| FileUtils.mkdir_p(File.join(root, name), mode: 0o700) }
        paths["home"] = "home"
        paths["envs_root"] = "envs"
        paths["code_state"] = "code_state"
        files = {}
        Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
          next unless File.file?(path) && !File.symlink?(path)
          relative = path.delete_prefix("#{root}/")
          files[relative] = Digest::SHA256.file(path).hexdigest
        end
        {
          "schema" => PLANE_SCHEMA,
          "edition" => plan["edition"],
          "generation" => plan["generation"],
          "source" => { "kind" => plan.dig("source", "kind"), "ref" => plan.dig("source", "ref"), "digest" => plan.dig("source", "digest") },
          "runtime" => { "digest" => plan.dig("runtime", "digest"), "argv" => plan.dig("runtime", "runtime_argv"), "provenance" => plan.dig("runtime", "provenance") },
          "settings" => plan.dig("source", "bundle", "settings"),
          "paths" => paths,
          "controls" => controls,
          "files" => files,
          "authority_files" => files.keys.sort,
          "certification" => { "runtime_provenance" => "unverified", "native_evidence" => "unverified", "os_containment" => "unverified", "lock_eligible" => false }
        }
      end
      private_class_method :generation_record

      def write_json(path, value)
        Authority.write_atomic(path, JSON.pretty_generate(Authority.canonical_value(value)) + "\n", mode: 0o600)
      end
      private_class_method :write_json

      def resolve_generation(destination, generation)
        record = JSON.parse(File.read(File.join(destination, "plane.json")))
        record["generation"] == generation
      rescue StandardError
        false
      end
      private_class_method :resolve_generation
    end
  end
end
