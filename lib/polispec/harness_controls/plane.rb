#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "authority"
require_relative "../operator/tty"
require_relative "../operator/gates"

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
        unless active["schema"] == SCHEMA && valid_generation?(active["generation"]) && active["plane_digest"].to_s.match?(/\A[a-f0-9]{64}\z/)
          findings << finding("active_record_invalid", "Active sentinel has an invalid schema or generation.")
          return base_result("broken", findings, ignored, development)
        end
        findings.concat(Authority.protection_findings(active_path, "active_sentinel")) if require_protected
        findings.concat(Authority.consumer_read_findings(active_path, "active_sentinel")) if require_protected
        generation = active["generation"]
        generation_root = File.join(root, "generations", generation)
        unless File.directory?(generation_root) && !File.symlink?(generation_root)
          findings << finding("generation_missing", "Active generation #{generation} is missing or unsafe.")
          return base_result("broken", findings, ignored, development)
        end
        findings.concat(Authority.protection_findings(generation_root, "generation")) if require_protected
        findings.concat(Authority.consumer_read_findings(generation_root, "generation")) if require_protected
        plane_path = File.join(generation_root, "plane.json")
        record = read_regular_json(plane_path, "generation record", findings)
        return base_result("broken", findings, ignored, development) unless record
        findings << finding("generation_record_digest", "Generation record does not match the active sentinel digest.") unless Digest::SHA256.file(plane_path).hexdigest == active["plane_digest"]
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
        floor = build_edition
        if plane["status"] == "active"
          raise Authority::Failure.new("edition_mismatch", "lock build cannot use a standard plane") if floor == "lock" && plane["edition"] != "lock"
          return plane["edition"]
        end

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
        validated_activation_overrides(plane, OperatorRecords.read("activation_transactions"))
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
        if !dry_run && !Features.enabled?("sealed_plane")
          raise Authority::Failure.new("prerequisite_missing", "sealed_plane mutation is disabled")
        end
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
          validate_project!(project, ledger)
          project
        end
        payload = activation_payload(projects, plane, identity, dry_run)
        return payload if dry_run
        Operator::Tty.confirm!("activate #{ids.sort.join(',')} on #{plane['generation']}", prompt: "Project activation changes protected effective status.")
        require_relative "operator_records"
        OperatorRecords.synchronize("activation_transactions", identity: identity) do
          activation_payload(projects, plane, identity, false)
        end
      end

      def rollback_activation(operation_id, dry_run: false)
        if !dry_run && !Features.enabled?("sealed_plane")
          raise Authority::Failure.new("prerequisite_missing", "sealed_plane mutation is disabled")
        end
        plane = verify
        raise Authority::Failure.new("prerequisite_missing", "rollback requires an active plane") unless plane["status"] == "active"
        identity = operator!("plane.rollback")
        require_relative "operator_records"
        Operator::Tty.confirm!("rollback activation #{operation_id}", prompt: "Rollback restores exact prior protected project statuses.") unless dry_run
        return rollback_activation_locked(operation_id, plane, identity, true) if dry_run
        OperatorRecords.synchronize("activation_transactions", identity: identity) do
          rollback_activation_locked(operation_id, plane, identity, false)
        end
      end

      def rollback_activation_locked(operation_id, plane, identity, dry_run)
        transactions = OperatorRecords.read("activation_transactions")
        validated_activation_overrides(plane, transactions)
        committed_index = transactions.rindex { |record| record["operation_id"] == operation_id.to_s && record["state"] == "committed" && record["generation"] == plane["generation"] }
        committed = committed_index && transactions[committed_index]
        raise Authority::Failure.new("invalid_activation", "no committed activation #{operation_id}") unless committed
        duplicate = transactions.any? { |record| record["rollback_of"] == operation_id.to_s && record["state"] == "committed" && record["generation"] == plane["generation"] }
        raise Authority::Failure.new("stale_activation", "activation #{operation_id} has already been rolled back") if duplicate
        project_ids = Array(committed["changes"]).map { |change| change["project_id"].to_s }
        superseded = transactions[(committed_index + 1)..].to_a.any? do |record|
          record["state"] == "committed" && record["generation"] == plane["generation"] && Array(record["changes"]).any? { |change| project_ids.include?(change["project_id"].to_s) }
        end
        raise Authority::Failure.new("stale_activation", "activation #{operation_id} has been superseded by a later committed status") if superseded
        effective = activation_overrides
        stale = Array(committed["changes"]).any? { |change| effective[change["project_id"].to_s] != change["status"].to_s }
        raise Authority::Failure.new("stale_activation", "activation #{operation_id} no longer matches effective project status") if stale
        changes = Array(committed["changes"]).map { |change| { "project_id" => change["project_id"], "prior_status" => change["status"], "status" => change["prior_status"] } }
        recorded_at = Time.now.utc.iso8601
        rollback_id = Digest::SHA256.hexdigest(Authority.canonical_json({ "generation" => plane["generation"], "rollback_of" => operation_id.to_s, "changes" => changes, "recorded_at" => recorded_at }))
        records = %w[prepared committed].map do |state|
          { "schema" => "polispec.plane.activation/v1", "operation_id" => rollback_id, "rollback_of" => operation_id.to_s, "generation" => plane["generation"], "state" => state, "changes" => changes, "recorded_at" => recorded_at }
        end
        records = records.map { |record| append_operator_record("activation_transactions", record, identity) } unless dry_run
        { "dry_run" => dry_run == true, "record" => records.last, "records" => records }
      end
      private_class_method :rollback_activation_locked

      def activation_payload(projects, plane, identity, dry_run)
        overrides = activation_overrides
        changes = projects.map do |project|
          { "project_id" => project.id, "prior_status" => overrides.fetch(project.id, project.status), "status" => "live" }
        end
        recorded_at = Time.now.utc.iso8601
        operation_id = Digest::SHA256.hexdigest(Authority.canonical_json({ "generation" => plane["generation"], "changes" => changes, "recorded_at" => recorded_at }))
        records = %w[prepared committed].map do |state|
          { "schema" => "polispec.plane.activation/v1", "operation_id" => operation_id, "generation" => plane["generation"], "state" => state, "changes" => changes, "recorded_at" => recorded_at }
        end
        records = records.map { |record| append_operator_record("activation_transactions", record, identity) } unless dry_run
        { "dry_run" => dry_run == true, "generation" => plane["generation"], "operation_id" => operation_id, "changes" => changes, "records" => records, "identity" => identity }
      end
      private_class_method :activation_payload

      def append_operator_record(stream, record, identity)
        authenticated = OperatorRecords.append(stream, record, identity: identity)
        found = OperatorRecords.read(stream).any? { |stored| Authority.canonical_json(stored) == Authority.canonical_json(authenticated) }
        raise Authority::Failure.new("operator_record_unconfirmed", "authenticated operator record was not confirmed by readback") unless found
        authenticated
      end
      private_class_method :append_operator_record

      def validated_activation_overrides(plane, records)
        result = {}
        prepared = {}
        committed = {}
        rolled_back = {}
        expected_digest = Authority.operator_provenance_digest(plane)
        Array(records).each do |record|
          raise Authority::Failure.new("operator_records_invalid", "activation transaction must be an object") unless record.is_a?(Hash)
          invalid = record["schema"] != "polispec.plane.activation/v1" || !record["generation"].to_s.match?(/\A[a-f0-9]{32}\z/) || !%w[prepared committed].include?(record["state"]) || !record["operation_id"].to_s.match?(/\A[a-f0-9]{64}\z/)
          raise Authority::Failure.new("operator_records_invalid", "activation transaction has invalid identity fields") if invalid
          changes = validated_activation_changes(record["changes"])
          next unless record["generation"] == plane["generation"]
          authorization = record["authorization"]
          launch = authorization.is_a?(Hash) ? authorization["launch_evidence"] : nil
          expected_launcher = plane.dig("provenance", "runtime", "launcher", "realpath")
          authorized = authorization.is_a?(Hash) && authorization["generation"] == plane["generation"] && authorization["euid"] == 0 && authorization["provenance_digest"] == expected_digest && authorization["append_operation"] == "operator_records.append.activation_transactions" && launch.is_a?(Hash) && launch["verified"] == true && launch["launcher"] == expected_launcher
          raise Authority::Failure.new("operator_records_invalid", "activation transaction lacks current authenticated provenance") unless authorized
          rollback_of = record["rollback_of"]
          caller = rollback_of ? "plane.rollback" : "plane.activate"
          raise Authority::Failure.new("operator_records_invalid", "activation transaction has the wrong authorized operation") unless authorization["caller_operation"] == caller
          operation_id = record["operation_id"]
          signature = Authority.canonical_json({ "rollback_of" => rollback_of, "changes" => changes })
          if record["state"] == "prepared"
            raise Authority::Failure.new("operator_records_invalid", "activation transaction has duplicate preparation") if prepared.key?(operation_id) || committed.key?(operation_id)
            prepared[operation_id] = signature
            next
          end
          raise Authority::Failure.new("operator_records_invalid", "activation commit lacks an exact prepared record") unless prepared[operation_id] == signature
          raise Authority::Failure.new("operator_records_invalid", "activation transaction has duplicate commit") if committed.key?(operation_id)
          if rollback_of
            target = committed[rollback_of]
            raise Authority::Failure.new("operator_records_invalid", "activation rollback has no prior committed target") unless target && !rolled_back[rollback_of]
            expected = target["changes"].map { |change| { "project_id" => change["project_id"], "prior_status" => change["status"], "status" => change["prior_status"] } }
            raise Authority::Failure.new("operator_records_invalid", "activation rollback does not restore exact prior statuses") unless Authority.canonical_json(changes) == Authority.canonical_json(expected)
            rolled_back[rollback_of] = true
          end
          committed[operation_id] = { "changes" => changes, "rollback_of" => rollback_of }
          changes.each { |change| result[change["project_id"]] = change["status"] }
        end
        result
      end
      private_class_method :validated_activation_overrides

      def validated_activation_changes(value)
        raise Authority::Failure.new("operator_records_invalid", "activation changes must be a nonempty array") unless value.is_a?(Array) && !value.empty? && value.length <= 256
        statuses = %w[live paused onboarding retired]
        seen = {}
        value.map do |change|
          raise Authority::Failure.new("operator_records_invalid", "activation change must be an object") unless change.is_a?(Hash)
          project = change["project_id"]
          prior = change["prior_status"]
          status = change["status"]
          valid = project.is_a?(String) && !project.empty? && project.bytesize <= 256 && statuses.include?(prior) && statuses.include?(status) && !seen[project]
          raise Authority::Failure.new("operator_records_invalid", "activation change is invalid or duplicated") unless valid
          seen[project] = true
          { "project_id" => project, "prior_status" => prior, "status" => status }
        end
      end
      private_class_method :validated_activation_changes

      def build_generation(plan)
        raise Authority::Failure.new("prerequisite_missing", "authority source has blocking prerequisites", plan["source"]["findings"]) unless plan["preparation_ready"]
        Authority.bootstrap_identity!("seal.prepare")
        generation = plan["generation"]
        destination = File.join(GENERATIONS_PATH, generation)
        if File.exist?(destination)
          findings = candidate_findings(destination, plan, require_protected: true)
          raise Authority::Failure.new("generation_conflict", "existing prepared generation does not exactly match the requested plan", findings) unless findings.empty?
          return destination
        end

        temp = File.join(GENERATIONS_PATH, ".#{generation}.tmp-#{Process.pid}")
        raise Authority::Failure.new("generation_conflict", "temporary generation path already exists") if File.exist?(temp)
        FileUtils.mkdir_p(File.join(temp, "source"), mode: 0o755)
        File.chmod(0o755, temp)
        File.chmod(0o755, File.join(temp, "source"))
        materialize_source(plan["source"], File.join(temp, "source"))
        source_manifest = Authority.canonical_value(plan.dig("source", "manifest"))
        source_findings = Authority.verify_materialized_source(File.join(temp, "source"), source_manifest)
        raise Authority::Failure.new("source_changed", "materialized source differs from the planned authority manifest", source_findings) unless source_findings.empty?
        runtime_manifest = Authority.canonical_value(plan["runtime"])
        write_json(File.join(temp, "source-manifest.json"), source_manifest, mode: 0o644)
        write_json(File.join(temp, "runtime-manifest.json"), runtime_manifest, mode: 0o644)
        record = generation_record(plan, temp)
        write_json(File.join(temp, "plane.json"), record, mode: 0o644)
        FileUtils.mkdir_p(GENERATIONS_PATH, mode: 0o755)
        File.chmod(0o755, GENERATIONS_PATH)
        File.rename(temp, destination)
        File.open(GENERATIONS_PATH, File::RDONLY) { |file| file.fsync }
        findings = candidate_findings(destination, plan, require_protected: true)
        raise Authority::Failure.new("generation_verification_failed", "prepared generation failed verification", findings) unless findings.empty?
        destination
      end

      def switch_generation(plan)
        raise Authority::Failure.new("prerequisite_missing", "seal activation has blocking runtime prerequisites", plan["findings"]) unless plan["ready"]
        current = resolve
        raise Authority::Failure.new("broken_plane", "existing fixed-root plane is broken and requires operator recovery", current["findings"]) if current["status"] == "broken"
        destination = File.join(GENERATIONS_PATH, plan["generation"])
        raise Authority::Failure.new("prerequisite_missing", "prepared generation is missing") unless File.directory?(destination)
        candidate_errors = candidate_findings(destination, plan, require_protected: true)
        raise Authority::Failure.new("generation_verification_failed", "prepared generation is not safe to activate", candidate_errors) unless candidate_errors.empty?
        prepared_record = JSON.parse(File.read(File.join(destination, "plane.json")))
        candidate = {
          "status" => "active",
          "generation" => plan["generation"],
          "provenance" => { "runtime" => prepared_record.dig("runtime", "provenance") }
        }
        identity = Authority.operator!("seal.activate", plane: candidate)
        active = { "schema" => SCHEMA, "generation" => plan["generation"], "plane_digest" => Digest::SHA256.file(File.join(destination, "plane.json")).hexdigest }
        prior = File.binread(ACTIVE_PATH) if File.file?(ACTIVE_PATH) && !File.symlink?(ACTIVE_PATH)
        backup_path = "#{ACTIVE_PATH}.backup-#{plan['generation']}"
        backup_record = { "schema" => "polispec.plane.active-backup/v1", "generation" => plan["generation"], "prior_present" => !prior.nil?, "prior_digest" => prior && Digest::SHA256.hexdigest(prior), "recorded_at" => Time.now.utc.iso8601 }
        Authority.write_atomic(backup_path, prior || JSON.pretty_generate(Authority.canonical_value(backup_record)) + "\n", mode: 0o600)
        Authority.write_atomic(ACTIVE_PATH, JSON.pretty_generate(Authority.canonical_value(active)) + "\n", mode: 0o644)
        resolved = resolve
        unless resolved["status"] == "active"
          if prior
            Authority.write_atomic(ACTIVE_PATH, prior, mode: 0o644)
            restored = resolve
            raise Authority::Failure.new("recovery_failed", "previous active sentinel could not be restored", restored["findings"]) if restored["status"] == "broken"
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
            findings.concat(Authority.consumer_read_findings(path, "authority_file").map { |item| finding(item["code"], item["detail"]) })
          end
        end
        findings << finding("authority_manifest_empty", "Generation record contains no authority file digests.") if files.empty?
        source_manifest = JSON.parse(File.read(safe_generation_path(root, "source-manifest.json")))
        source_digest = Digest::SHA256.hexdigest(Authority.canonical_json(source_manifest))
        findings << finding("source_manifest_digest", "Source manifest does not match recorded source provenance.") unless source_digest == record.dig("source", "digest")
        findings.concat(Authority.verify_materialized_source(File.join(root, "source"), source_manifest).map { |item| finding(item["code"], item["detail"]) })
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
        %w[launcher entrypoint interpreter sdk runtime_metadata runtime_manifest].each do |key|
          path = provenance.dig(key, "realpath")
          findings << finding("runtime_#{key}_missing", "Runtime #{key} provenance is missing.") unless path
          findings.concat(Authority.protection_findings(path, "runtime_#{key}").map { |item| finding(item["code"], item["detail"]) }) if require_protected && path
          if path
            recorded = stringify_hash(provenance[key])
            findings << finding("runtime_#{key}_unverified", "Runtime #{key} provenance was not completely verified.") unless recorded["present"] == true && recorded["digest"] && !recorded["error"]
            current = Authority.current_metadata(path)
            %w[realpath uid mode digest].each do |field|
              findings << finding("runtime_#{key}_changed", "Runtime #{key} #{field} differs from recorded provenance.") unless current[field] == recorded[field]
            end
          end
        end
        release = stringify_hash(provenance["release"])
        if release["realpath"]
          current = Authority.current_metadata(release["realpath"])
          %w[realpath uid mode digest].each do |field|
            findings << finding("runtime_release_changed", "Runtime release #{field} differs from recorded provenance.") unless current[field] == release[field]
          end
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
          FileUtils.mkdir_p(File.dirname(target), mode: 0o755)
          bytes = if source["kind"] == "git"
                    Authority.committed_blob(source["root"], source["ref"], relative)
                  else
                    File.binread(File.join(source["root"], relative))
                  end
          File.open(target, "wb", entry["mode"] & 0o777) do |file|
            file.chmod(entry["mode"] & 0o777)
            file.write(bytes)
          end
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
        %w[home envs code_state].each do |name|
          path = File.join(root, name)
          FileUtils.mkdir_p(path, mode: 0o755)
          File.chmod(0o755, path)
        end
        paths["home"] = "home"
        paths["envs_root"] = "envs"
        paths["code_state"] = "code_state"
        files = {}
        Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
          next unless File.file?(path) && !File.symlink?(path)
          relative = path.delete_prefix("#{root}/")
          next if relative == "plane.json"
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

      def validate_project!(project, ledger)
        repo = File.expand_path(project.repo)
        raise Authority::Failure.new("project_validation_failed", "project #{project.id} repository is not a Git checkout") unless File.exist?(File.join(repo, ".git"))
        loaded = PolicySource.resolve(project, ledger: ledger)
        raise Authority::Failure.new("project_validation_failed", "project #{project.id} has no committed policy authority") if loaded.source == "defaults" || loaded.finding
        policy = loaded.policy
        problems = Operator::Gates.health_required_errors(policy)
        problems.concat(Layers.policy_errors(policy, project: project, ledger: ledger))
        problems.concat(ValidateProfiles.errors(policy, project, ledger: ledger))
        raise Authority::Failure.new("project_validation_failed", "project #{project.id}: #{problems.join('; ')}") unless problems.empty?
        raise Authority::Failure.new("project_validation_failed", "project #{project.id} roster is unavailable") unless PolicySource.roster_digest(project)
        true
      end
      private_class_method :validate_project!

      def write_json(path, value, mode: 0o644)
        Authority.write_atomic(path, JSON.pretty_generate(Authority.canonical_value(value)) + "\n", mode: mode)
      end
      private_class_method :write_json

      def candidate_findings(destination, plan, require_protected:)
        findings = []
        findings.concat(Authority.protection_findings(destination, "generation").map { |item| finding(item["code"], item["detail"]) }) if require_protected
        record = JSON.parse(File.read(File.join(destination, "plane.json")))
        expected_record = generation_record(plan, destination)
        findings << finding("generation_record_conflict", "Prepared generation record differs from the deterministic requested plan.") unless Authority.canonical_json(record) == Authority.canonical_json(expected_record)
        findings << finding("generation_mismatch", "Prepared generation identifier differs from the plan.") unless record["generation"] == plan["generation"]
        findings << finding("source_provenance_mismatch", "Prepared source provenance differs from the plan.") unless record.dig("source", "digest") == plan.dig("source", "digest") && record.dig("source", "ref") == plan.dig("source", "ref")
        findings << finding("runtime_provenance_mismatch", "Prepared runtime provenance differs from the plan.") unless record.dig("runtime", "digest") == plan.dig("runtime", "digest")
        verify_generation_files(destination, record, findings, require_protected)
        verify_runtime_record(record, findings, require_protected)
        findings
      rescue StandardError => error
        [finding("generation_invalid", error.message)]
      end
      private_class_method :candidate_findings
    end
  end
end
