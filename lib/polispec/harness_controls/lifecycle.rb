require "timeout"
require_relative "contracts"
require_relative "backends"
require_relative "files"
require_relative "schedule"
require_relative "verification"
require_relative "environment"
require_relative "owner_handoff"

module Polispec
  module HarnessControls
    module Lifecycle
      STREAM = "harness_installations"
      VERSION_TIMEOUT = 5
      OUTPUT_LIMIT = 65_536
      TRANSACTION_LIMIT = 4096
      TRANSACTION_SCAN_LIMIT = 65_536
      TRANSACTION_SCAN_BYTES = 16 * 1_048_576
      TRANSACTION_STATUSES = %w[prepared committed rollback_complete recovery_required uninstalled].freeze

      class Failure < Polispec::Error
        attr_reader :code, :exit_status, :data, :findings

        def initialize(code, message, exit_status: 1, data: nil, findings: [])
          @code = code.to_s
          @exit_status = exit_status
          @data = data
          @findings = findings
          super(message)
        end
      end

      module_function

      def plan(document, harness, context = {}, port_set: nil)
        validate_document!(document)
        values = stringify(context)
        values["edition"] ||= requested_edition.first
        values["version"] ||= native_version(harness)
        backend = Backends.fetch(harness)
        draft = stringify(backend.plan(canonical(document), values))
        paths = Array(draft["artifacts"]).map { |artifact| artifact["path"] }
        inspected = Files.existing(paths)
        inspected = safe_existing(inspected, draft)
        values["existing"] = inspected
        planned = stringify(backend.plan(canonical(document), values))
        validate_plan!(planned, document, harness, values)
        edition, edition_findings = requested_edition
        if planned["edition"] != edition
          planned["findings"] = Array(planned["findings"]) + [finding("edition_mismatch", "The backend planned #{planned['edition']} while the requested edition is #{edition}.", harness, "edition", "Resolve the protected edition source and plan again.")]
        end
        planned["findings"] = Array(planned["findings"]) + edition_findings
        planned
      end

      def install(plan, actor, port_set: nil, schedule_port_set: nil)
        proposed = stringify(plan.respond_to?(:to_h) ? plan.to_h : plan)
        actor = stringify(actor)
        document = controls_from_plan(proposed)
        context = context_from_plan(proposed)
        trusted = self.plan(document, proposed["harness"], context, port_set: port_set)
        assert_same_plan!(proposed, trusted)
        blockers = ineffective_controls(trusted, document)
        unless blockers.empty?
          raise Failure.new("unsupported_controls", "one or more requested controls have no effective native implementation", data: { "controls" => blockers }, findings: Array(trusted["findings"]))
        end

        plane = resolve_plane
        targets = Array(proposed["artifacts"]).map { |artifact| artifact["path"] }
        protected_paths = Array(plane["authority_files"]) + (plane["controls"].is_a?(Hash) ? plane["controls"].values : [])
        protected_collision = !(targets & protected_paths.map(&:to_s)).empty?
        privileged = proposed["scope"] == "managed" || protected_collision
        identity = privileged ? operator_identity!("harness.install") : nil
        state = state_adapter(privileged, identity, port_set)
        installation_id = installation_id_for(proposed)
        access = file_access(privileged)
        result = nil
        Files.with_target_locks(targets, access: access) do
          records = read_records(state, identity)
          block_unresolved!(records, targets)
          latest = active_installation(records, installation_id)
          if latest && latest["status"] == "committed"
            receipt = stringify(latest["receipt"])
            checked = Files.verify_receipt(receipt)
            raise Failure.new("idempotent_install_drift", "the existing identical installation has drifted", data: checked, findings: checked["findings"]) unless checked["integrity"] && checked["ownership"]
            unless idempotent_match?(receipt, trusted, context)
              raise Failure.new("idempotent_install_conflict", "the installation identity matches but its planned artifacts or runtime provenance changed", exit_status: 3)
            end
            result = receipt.merge("idempotent" => true)
            next
          end
          monotonic = Controls.monotonic(current_controls(proposed), document, actor)
          if monotonic["disposition"] == "operator_required" && !privileged
            raise Failure.new("operator_required", monotonic["reasons"].join("; "), exit_status: 3, data: monotonic)
          end
          operator_identity!("harness.install.loosen") if monotonic["disposition"] == "operator_required" && privileged
          prepared = Files.prepare(proposed["artifacts"], proposed["operation_id"], access: access)
          supersedes = inherit_ownership!(prepared, records, installation_id)
          receipt = build_receipt(proposed, document, installation_id, prepared, plane, context, privileged)
          receipt["supersedes"] = supersedes unless supersedes.empty?
          schedule_plan = Schedule.plan(document, receipt, context)
          receipt["schedules"] = schedule_plan["jobs"]
          sequence = next_sequence(records)
          transaction = transaction_record(proposed, receipt, "prepared", sequence, targets)
          append_confirm!(state, transaction, identity)
          schedules = nil
          begin
            Files.apply(prepared, lock: false)
            schedules = Schedule.install(document, receipt, context, port_set: schedule_port_set) unless schedule_plan["jobs"].empty?
            ensure_schedules_verified!(schedules)
            receipt["schedule_results"] = schedules ? schedules["installed"] : []
            receipt["artifact_digests"] = prepared.each_with_object({}) { |row, memo| memo[row["target"]] = row["installed_digest"] }
            receipt["owned_entries"] = receipt_owned_entries(prepared)
            committed = transaction_record(proposed, receipt, "committed", sequence + 1, targets)
            append_confirm!(state, committed, identity)
            emit_committed(port_set, proposed, receipt)
            result = receipt
          rescue StandardError => error
            recovery_ids = schedules ? Array(schedules["installed"]).select { |row| row["port_accepted"] }.map { |row| row["job_id"] } : []
            schedule_recovery = recovery_ids.empty? ? nil : Schedule.uninstall(recovery_ids, port_set: schedule_port_set)
            rollback_failures = Files.rollback(prepared, lock: false)
            schedule_failed = schedule_recovery && Array(schedule_recovery["uninstalled"]).any? { |row| row["absence_verified"] != true }
            status = rollback_failures.empty? && !schedule_failed ? "rollback_complete" : "recovery_required"
            recovery = transaction_record(proposed, receipt.merge("recovery_job_ids" => recovery_ids, "rollback_failures" => rollback_failures, "schedule_recovery" => schedule_recovery), status, sequence + 1, targets)
            begin
              append_confirm!(state, recovery, identity)
            rescue StandardError => state_error
              raise Failure.new("recovery_state_failed", "#{error.class}: #{error.message}; recovery journal failed: #{state_error.class}: #{state_error.message}", data: recovery)
            end
            raise Failure.new(status, "installation failed and #{status.tr('_', ' ')}: #{error.class}: #{error.message}", data: recovery, exit_status: status == "recovery_required" ? 3 : 1)
          end
        end
        result
      end

      def verify(installation_id, port_set: nil, runner: nil)
        Verifier.verify(installation_id, port_set: port_set, runner: runner)
      end

      def uninstall(installation_id, port_set: nil, schedule_port_set: nil, owner: nil, scope: nil, project: nil, state_home: nil, dry_run: false)
        selectors = [scope, project, state_home]
        if owner
          raise Failure.new("owner_port_conflict", "owner selection cannot use injected development ports", exit_status: 3) if port_set || schedule_port_set
          identity = operator_identity!("harness.uninstall.overlay")
          plane = resolve_plane
          bind_operator_plane!(identity, plane)
          profile = OwnerHandoff.profile(owner: owner, scope: scope, project: project, state_home: state_home, plane: plane)
          return OwnerHandoff.run(profile) do |selected, ports|
            state = state_adapter(false, nil, ports, read_only: dry_run)
            uninstall_from_state(installation_id, state, ports, nil, dry_run, selected, plane)
          end
        end
        raise Failure.new("owner_required", "scope, project, and state_home require an explicit owner", exit_status: 3) if selectors.any?
        identity = operator_identity!("harness.uninstall")
        state = state_adapter(true, identity, nil, read_only: dry_run)
        uninstall_from_state(installation_id, state, schedule_port_set, identity, dry_run, nil, {})
      end

      def uninstall_from_state(installation_id, state, schedule_port_set, identity, dry_run, owner_profile, plane)
        records = read_records(state, identity)
        committed = active_installation(records, installation_id)
        raise Failure.new("installation_not_found", "installation #{installation_id} was not found") unless committed
        receipt = stringify(committed["receipt"])
        if owner_profile
          validate_mutable_receipt!(committed, receipt, owner_profile, plane)
        elsif receipt["protected"] != true
          raise Failure.new("protected_receipt_required", "uninstall without an owner accepts protected receipts only", exit_status: 3)
        end
        targets = receipt.fetch("artifact_digests", {}).keys
        access = receipt["file_access"] || file_access(receipt["protected"] == true)
        receipt["file_access"] = access if access
        if dry_run
          return {
            "installation_id" => installation_id, "dry_run" => true, "operator_required" => true,
            "owner" => owner_profile && owner_profile["owner"], "scope" => receipt["scope"],
            "targets" => targets.sort, "schedule_job_ids" => Array(receipt["schedules"]).map { |job| job["job_id"] }
          }
        end
        result = nil
        Files.with_target_locks(targets, access: access) do
          records = read_records(state, identity)
          current = active_installation(records, installation_id)
          unless current && current["record_id"] == committed["record_id"]
            raise Failure.new("installation_state_changed", "installation state changed before uninstall acquired its target locks", exit_status: 3)
          end
          block_unresolved!(records, targets, except_operation: committed["operation_id"])
          sequence = next_sequence(records)
          operation_id = "uninstall_#{Digest::SHA256.hexdigest("#{installation_id}\0#{sequence}")[0, 24]}"
          plan = { "operation_id" => operation_id, "control_digest" => receipt["control_digest"], "harness" => receipt["harness"], "scope" => receipt["scope"], "edition" => receipt["edition"] }
          file_plan = Files.prepare_uninstall(receipt)
          prepared = transaction_record(plan, receipt, "prepared", sequence, targets).merge("operation" => "uninstall")
          append_confirm!(state, prepared, identity)
          schedule_result = nil
          begin
            Files.apply_uninstall(file_plan, lock: false)
            job_ids = Array(receipt["schedules"]).map { |job| job["job_id"] }
            schedule_result = Schedule.uninstall(job_ids, port_set: schedule_port_set)
            if Array(schedule_result["uninstalled"]).any? { |row| row["absence_verified"] != true }
              raise Failure.new("schedule_uninstall_unverified", "scheduled jobs were not verified absent", exit_status: 3, data: schedule_result)
            end
            removed = file_plan.map { |row| { "target" => row["target"], "backup_path" => row["uninstall_backup"] } }
            record = transaction_record(plan, receipt.merge("uninstalled_artifacts" => removed, "schedule_results" => schedule_result["uninstalled"]), "uninstalled", sequence + 1, targets)
            append_confirm!(state, record, identity)
            result = record
          rescue StandardError => error
            rollback_failures = Files.rollback_uninstall(file_plan, lock: false)
            schedules_touched = schedule_result && !Array(receipt["schedules"]).empty?
            status = rollback_failures.empty? && !schedules_touched ? "rollback_complete" : "recovery_required"
            recovery = transaction_record(plan, receipt.merge("rollback_failures" => rollback_failures, "schedule_recovery" => schedule_result), status, sequence + 1, targets)
            begin
              append_confirm!(state, recovery, identity)
            rescue StandardError => state_error
              raise Failure.new("recovery_state_failed", "#{error.class}: #{error.message}; recovery journal failed: #{state_error.class}: #{state_error.message}", data: recovery, exit_status: 3)
            end
            raise Failure.new(status, "uninstall failed and #{status.tr('_', ' ')}: #{error.class}: #{error.message}", data: recovery, exit_status: status == "recovery_required" ? 3 : 1)
          end
        end
        result
      end
      private_class_method :uninstall_from_state

      def scan(context = {})
        values = stringify(context)
        values["requested_edition"] ||= requested_edition.first
        Environment.scan(values)
      end

      def edition
        requested_edition.first
      end

      def receipt(installation_id, port_set: nil, owner: nil, scope: nil, project: nil, state_home: nil)
        selectors = [scope, project, state_home]
        if owner
          raise Failure.new("owner_port_conflict", "owner selection cannot use an injected development port", exit_status: 3) if port_set
          identity = operator_identity!("harness.receipt.overlay")
          plane = resolve_plane
          bind_operator_plane!(identity, plane)
          profile = OwnerHandoff.profile(owner: owner, scope: scope, project: project, state_home: state_home, plane: plane)
          return OwnerHandoff.run(profile) do |selected, ports|
            state = state_adapter(false, nil, ports, read_only: true)
            records = read_records(state, nil)
            record = active_installation(records, installation_id)
            raise Failure.new("installation_not_found", "installation #{installation_id} was not found") unless record
            selected_receipt = stringify(record["receipt"])
            validate_mutable_receipt!(record, selected_receipt, selected, plane)
            selected_receipt
          end
        end
        raise Failure.new("owner_required", "scope, project, and state_home require an explicit owner", exit_status: 3) if selectors.any?
        _state, _records, record = installation_source(installation_id, port_set, identity: nil, include_privileged: true)
        record && stringify(record["receipt"])
      end

      def validate_mutable_receipt!(record, receipt, profile, plane)
        raise Failure.new("mutable_receipt_invalid", "mutable overlay record exceeds #{Files::LIMIT} bytes", exit_status: 3) if JSON.generate(record).bytesize > Files::LIMIT
        valid = record["schema"] == "polispec.harness.transaction/v1" && receipt["schema"] == "polispec.harness.receipt/v1"
        valid &&= record["installation_id"] == receipt["installation_id"]
        valid &&= record["operation_id"] == receipt["operation_id"]
        valid &&= record["control_digest"] == receipt["control_digest"]
        valid &&= record["harness"] == receipt["harness"] && record["scope"] == receipt["scope"]
        valid &&= receipt["protected"] == false && receipt["file_access"].nil?
        valid &&= receipt["scope"] == profile["scope"]
        raise Failure.new("mutable_receipt_invalid", "mutable overlay receipt identity or authority fields are invalid", exit_status: 3) unless valid
        controls = receipt["controls"]
        validate_document!(controls)
        digest = Digest::SHA256.hexdigest(JSON.generate(canonical(controls)))
        raise Failure.new("mutable_receipt_invalid", "mutable overlay control digest does not match its document", exit_status: 3) unless digest == receipt["control_digest"]
        receipt_targets = receipt.fetch("artifact_digests", {}).keys.sort
        raise Failure.new("mutable_receipt_invalid", "mutable overlay transaction targets do not match its receipt", exit_status: 3) unless Array(record["targets"]).sort == receipt_targets
        context = { "scope" => profile["scope"], "edition" => receipt["edition"], "home" => profile["home"] }
        context["project"] = profile["project"] if profile["scope"] == "project"
        trusted = plan(controls, receipt["harness"], context)
        historical_schedule_context = context.merge("runtime_argv" => receipt["runtime_argv"])
        expected_schedules = Schedule.plan(controls, receipt, historical_schedule_context)["jobs"]
        raise Failure.new("mutable_receipt_invalid", "mutable overlay schedules differ from canonical planning", exit_status: 3) unless canonical(receipt["schedules"]) == canonical(expected_schedules)
        receipt["owned_entries"] = Files.validate_mutable_receipt!(receipt, trusted["artifacts"], owner_uid: profile["uid"], boundary: profile["scope"] == "project" ? profile["project"] : profile["home"], home: profile["home"], protected_paths: profile["protected_paths"])
        true
      rescue Failure
        raise
      rescue StandardError => error
        raise Failure.new("mutable_receipt_invalid", "mutable overlay receipt validation failed: #{error.class}: #{error.message}", exit_status: 3)
      end
      private_class_method :validate_mutable_receipt!

      def validate_document!(document)
        errors = Controls.validate(document)
        return if errors.empty?
        first = errors.first
        raise Failure.new("invalid_control", "invalid control document at #{first['pointer']}: #{first['message']}")
      end
      private_class_method :validate_document!

      def validate_plan!(plan, document, harness, context)
        raise Failure.new("invalid_plan", "backend returned an invalid plan schema") unless plan["schema"] == "polispec.harness.plan/v1"
        raise Failure.new("invalid_plan", "backend returned the wrong harness") unless plan["harness"] == harness.to_s
        expected = Digest::SHA256.hexdigest(JSON.generate(canonical(document)))
        raise Failure.new("invalid_plan", "backend control digest mismatch") unless plan["control_digest"] == expected
        raise Failure.new("invalid_plan", "backend scope mismatch") unless plan["scope"] == context["scope"]
        Array(plan["artifacts"]).each do |artifact|
          raise Failure.new("invalid_plan", "artifact digest mismatch at #{artifact['path']}") unless artifact["digest"] == Digest::SHA256.hexdigest(artifact["content"].to_s)
        end
      end
      private_class_method :validate_plan!

      def safe_existing(existing, draft)
        artifacts = Array(draft["artifacts"])
        existing.reject do |path, content|
          artifact = artifacts.find { |item| item["path"] == path }
          next false unless artifact && artifact.dig("ownership", "kind") == "toml_block" && artifact["content"] == content
          names = Array(artifact.dig("ownership", "entries"))
          names.length == 1 && content.include?("# polispec:begin #{names.first}\n") && content.include?("# polispec:end #{names.first}\n")
        end
      end
      private_class_method :safe_existing

      def controls_from_plan(plan)
        artifacts = Array(plan["artifacts"])
        artifact = artifacts.find { |item| item.dig("ownership", "kind") == "control_document" }
        raise Failure.new("invalid_plan", "plan has no canonical control document") unless artifact
        document = JSON.parse(artifact["content"])
        validate_document!(document)
        expected = Digest::SHA256.hexdigest(JSON.generate(canonical(document)))
        raise Failure.new("invalid_plan", "control document does not match plan digest") unless expected == plan["control_digest"]
        document
      rescue JSON::ParserError => error
        raise Failure.new("invalid_plan", "control artifact is invalid JSON: #{error.message}")
      end
      private_class_method :controls_from_plan

      def context_from_plan(plan)
        scope = plan["scope"]
        control = Array(plan["artifacts"]).find { |item| item.dig("ownership", "kind") == "control_document" }
        path = control && control["path"].to_s
        context = { "scope" => scope, "edition" => plan["edition"] }
        if scope == "project"
          marker = "/.polispec/harness/"
          raise Failure.new("invalid_plan", "project control path is invalid") unless path.include?(marker)
          context["project"] = path.split(marker, 2).first
        elsif scope == "user"
          marker = "/.config/polispec/harness/"
          raise Failure.new("invalid_plan", "user control path is invalid") unless path.include?(marker)
          context["home"] = path.split(marker, 2).first
        elsif scope == "managed"
          plane = resolve_plane
          raise Failure.new("operator_required", "managed planning requires an active protected plane", exit_status: 3, data: plane) unless plane["status"] == "active"
          context["runtime_argv"] = plane["runtime_argv"]
        end
        context["version"] = native_version(plan["harness"])
        context
      end
      private_class_method :context_from_plan

      def assert_same_plan!(supplied, trusted)
        keys = %w[schema operation_id control_digest edition harness scope artifacts capabilities authority]
        keys.each do |key|
          raise Failure.new("untrusted_plan", "supplied plan differs from trusted planning at #{key}") unless canonical(supplied[key]) == canonical(trusted[key])
        end
      end
      private_class_method :assert_same_plan!

      def ineffective_controls(plan, document)
        Array(document["controls"]).each_with_object([]) do |control, result|
          next if control["trigger"] == "schedule" && control["effect"] == "verify"
          rows = Array(plan["capabilities"]).select { |row| row["control_id"] == control["id"] }
          effective = rows.any? { |row| %w[generated supported].include?(row["disposition"]) }
          effective = false if plan["harness"] == "antigravity" && plan["scope"] == "managed"
          next if effective
          result << { "control_id" => control["id"], "trigger" => control["trigger"], "effect" => control["effect"], "capabilities" => rows }
        end
      end
      private_class_method :ineffective_controls

      def current_controls(plan)
        artifact = Array(plan["artifacts"]).find { |item| item.dig("ownership", "kind") == "control_document" }
        return nil unless artifact && File.exist?(artifact["path"])
        JSON.parse(File.read(artifact["path"], 1_048_577))
      rescue JSON::ParserError, SystemCallError => error
        raise Failure.new("current_controls_corrupt", "installed control document cannot be trusted: #{error.class}: #{error.message}", exit_status: 3)
      end
      private_class_method :current_controls

      def build_receipt(plan, document, installation_id, prepared, plane, context, privileged)
        backups = prepared.map do |row|
          { "target" => row["target"], "prior_exists" => row["prior_exists"], "backup_path" => row["backup_path"], "prior_digest" => row["prior_digest"], "backup_digest" => row["backup_digest"], "mode" => row["mode"], "uid" => row["uid"], "gid" => row["gid"], "transaction_backup_path" => row["rollback_backup_path"], "transaction_backup_digest" => row["rollback_backup_digest"] }
        end
        runtime = runtime_argv(context)
        provenance = runtime_provenance(runtime)
        {
          "schema" => "polispec.harness.receipt/v1", "installation_id" => installation_id,
          "operation_id" => plan["operation_id"], "control_digest" => plan["control_digest"],
          "edition" => plan["edition"], "harness" => plan["harness"], "scope" => plan["scope"],
          "owned_entries" => receipt_owned_entries(prepared),
          "artifact_digests" => prepared.each_with_object({}) { |row, memo| memo[row["target"]] = row["installed_digest"] },
          "backups" => backups, "runtime_argv" => runtime, "runtime_provenance" => provenance,
          "runtime_digest" => Digest::SHA256.hexdigest(JSON.generate(canonical(provenance))), "installed_at" => Time.now.utc.iso8601,
          "controls" => canonical(document), "artifacts" => canonical(plan["artifacts"]),
          "capabilities" => canonical(plan["capabilities"]), "plan_findings" => canonical(plan["findings"]),
          "plane" => { "status" => plane["status"], "generation" => plane["generation"] },
          "file_access" => prepared.first && prepared.first["access"],
          "protected" => privileged == true,
          "certified" => false
        }
      end
      private_class_method :build_receipt

      def receipt_owned_entries(prepared)
        prepared.flat_map do |row|
          row["owned_entries"].map do |entry|
            value = stringify(entry)
            value["backup_path"] = row["backup_path"] unless value.key?("backup_path")
            value["backup_digest"] = row["backup_digest"] unless value.key?("backup_digest")
            value
          end
        end
      end
      private_class_method :receipt_owned_entries

      def idempotent_match?(receipt, plan, context)
        canonical(receipt["artifacts"]) == canonical(plan["artifacts"]) &&
          canonical(receipt["runtime_argv"]) == canonical(runtime_argv(context)) &&
          canonical(receipt["runtime_provenance"]) == canonical(runtime_provenance(runtime_argv(context)))
      end
      private_class_method :idempotent_match?

      def inherit_ownership!(prepared, records, installation_id)
        active = records.group_by { |row| row["installation_id"] }.values.map do |rows|
          rows.max_by { |row| row["sequence"].to_i }
        end.select { |row| row["status"] == "committed" && row["installation_id"] != installation_id }
        supersedes = []
        prepared.each do |row|
          predecessor = active.select { |record| record.dig("receipt", "artifact_digests", row["target"]) }.max_by { |record| record["sequence"].to_i }
          next unless predecessor
          prior_receipt = stringify(predecessor["receipt"])
          checked = Files.verify_receipt(prior_receipt)
          raise Failure.new("predecessor_ownership_unverified", "prior ownership at #{row['target']} cannot be transferred", exit_status: 3, data: checked, findings: checked["findings"]) unless checked["ownership"]
          prior_entries = Array(prior_receipt["owned_entries"]).select { |entry| entry["target"] == row["target"] }
          if %w[control_document exclusive toml_block].include?(row["kind"])
            expected = prior_receipt.dig("artifact_digests", row["target"])
            raise Failure.new("predecessor_bytes_changed", "root-owned predecessor changed at #{row['target']}", exit_status: 3) unless row["expected_prior_digest"] == expected
            backup = Array(prior_receipt["backups"]).find { |item| item["target"] == row["target"] }
            row["rollback_prior_exists"] = row["prior_exists"]
            row["rollback_backup_path"] = row["backup_path"]
            row["rollback_backup_digest"] = row["backup_digest"]
            row["rollback_mode"] = row["mode"]
            row["rollback_uid"] = row["uid"]
            row["rollback_gid"] = row["gid"]
            row["prior_exists"] = backup ? backup["prior_exists"] == true : false
            row["backup_path"] = backup && backup["backup_path"]
            row["backup_digest"] = backup && backup["backup_digest"]
            row["prior_digest"] = backup && backup["prior_digest"]
            row["mode"] = backup["mode"] if backup && backup["mode"]
            row["uid"] = backup["uid"] if backup && backup.key?("uid")
            row["gid"] = backup["gid"] if backup && backup.key?("gid")
            row["backup_inherited"] = true
            row["owned_entries"].each do |entry|
              entry["prior_present"] = row["prior_exists"] == true
              entry["prior_value"] = nil
              entry["prior_ancestors"] = []
            end
          else
            prior_pointers = prior_entries.map { |entry| entry["pointer"] }.uniq
            current = row["owned_entries"].reject do |entry|
              prior_pointers.include?(entry["pointer"]) && (entry["merge_mode"] == "scalar" || Array(entry["contributed_values"]).empty?)
            end
            row["owned_entries"] = prior_entries.map { |entry| stringify(entry) } + current
          end
          supersedes << prior_receipt["installation_id"]
        end
        supersedes.compact.uniq.sort
      end
      private_class_method :inherit_ownership!

      def transaction_record(plan, receipt, status, sequence, targets)
        {
          "schema" => "polispec.harness.transaction/v1", "record_id" => "tx_#{Digest::SHA256.hexdigest("#{plan['operation_id']}\0#{status}\0#{sequence}")[0, 24]}",
          "installation_id" => receipt["installation_id"], "operation_id" => plan["operation_id"], "status" => status,
          "sequence" => sequence, "targets" => targets.sort, "control_digest" => plan["control_digest"],
          "harness" => plan["harness"], "scope" => plan["scope"], "edition" => plan["edition"],
          "receipt" => receipt, "recorded_at" => Time.now.utc.iso8601
        }
      end
      private_class_method :transaction_record

      def append_confirm!(state, record, identity)
        appended = append_state(state, record, identity)
        authenticated = state.respond_to?(:append) && state.method(:append).parameters.any? { |kind, name| name == :identity && %i[key keyreq].include?(kind) }
        expected = authenticated && appended.is_a?(Hash) ? stringify(appended) : record
        rows = read_records(state, identity)
        observed = rows.reverse.find { |row| row["record_id"] == record["record_id"] }
        raise Failure.new("state_readback_failed", "transaction record was not confirmed by state readback", exit_status: 3) unless canonical(observed) == canonical(expected)
        true
      rescue Failure
        raise
      rescue StandardError => error
        raise Failure.new("state_unavailable", "transaction state append failed: #{error.class}: #{error.message}", exit_status: 3)
      end
      private_class_method :append_confirm!

      def append_state(state, record, identity)
        if state.respond_to?(:append) && state.method(:append).parameters.any? { |kind, name| name == :identity && %i[key keyreq].include?(kind) }
          state.append(STREAM, record, identity: identity)
        else
          state.append(STREAM, record)
        end
      end
      private_class_method :append_state

      def read_records(state, identity)
        rows = if state.respond_to?(:read) && state.method(:read).parameters.any? { |kind, name| name == :identity && %i[key keyreq].include?(kind) }
                 state.read(STREAM, identity: identity)
               else
                 state.read(STREAM)
               end
        raise Failure.new("state_unavailable", "installation state read did not return an array", exit_status: 3) unless rows.is_a?(Array)
        rows.map { |row| stringify(row) }
      rescue Failure
        raise
      rescue StandardError => error
        raise Failure.new("state_unavailable", "installation state is unavailable: #{error.class}: #{error.message}", exit_status: 3)
      end
      private_class_method :read_records

      def state_adapter(privileged, identity, port_set, read_only: false)
        if privileged
          load_plane_implementation
          unless defined?(Polispec::HarnessControls::OperatorRecords) && OperatorRecords.respond_to?(:read) && (read_only || OperatorRecords.respond_to?(:append))
            raise Failure.new("operator_records_unavailable", "protected operator records are unavailable", exit_status: 3)
          end
          return OperatorRecords
        end
        ports = port_set || sdk_ports
        state = ports && ports.state
        usable = state && state.respond_to?(:read) && (read_only || state.respond_to?(:append))
        raise Failure.new("state_unavailable", "the required rplugin state port is unavailable", exit_status: 3) unless usable
        state
      end
      private_class_method :state_adapter

      def installation_source(installation_id, port_set, identity:, include_privileged:)
        sources = []
        begin
          state = state_adapter(false, nil, port_set, read_only: true)
          sources << [state, read_records(state, nil)]
        rescue Failure
          nil
        end
        if include_privileged
          load_plane_implementation
          if defined?(Polispec::HarnessControls::OperatorRecords) && OperatorRecords.respond_to?(:read)
            begin
              sources << [OperatorRecords, read_records(OperatorRecords, identity)]
            rescue Failure
              nil
            end
          end
        end
        raise Failure.new("state_unavailable", "no installation record source is available", exit_status: 3) if sources.empty?
        matches = sources.map do |state, records|
          latest = active_installation(records, installation_id)
          [state, records, latest] if latest && latest["status"] == "committed"
        end.compact
        raise Failure.new("ambiguous_installation", "installation #{installation_id} exists in multiple authority stores", exit_status: 3) if matches.length > 1
        matches.first || [sources.first[0], sources.first[1], nil]
      end
      private_class_method :installation_source

      def sdk_ports
        return Rplugin::Ports.for(ID, root: ROOT) if defined?(Rplugin::Ports)
        home = ENV["RPLUGIN_HOME"]
        home = File.expand_path(home && !home.empty? ? home : "~/.rplugin")
        entry = File.join(home, "lib", "rplugin.rb")
        return nil unless File.file?(entry)
        require entry
        defined?(Rplugin::Ports) ? Rplugin::Ports.for(ID, root: ROOT) : nil
      rescue StandardError, LoadError
        nil
      end
      private_class_method :sdk_ports

      def resolve_plane
        load_plane_implementation
        return stringify(Plane.resolve) if Plane.respond_to?(:resolve)
        { "status" => "unsealed", "findings" => [finding("plane_api_unavailable", "The protected plane implementation is unavailable.", nil, "plane", "Install the plane implementation before privileged lifecycle operations.")] }
      rescue Unavailable, NoMethodError => error
        { "status" => "unsealed", "findings" => [finding("plane_api_unavailable", error.message, nil, "plane", "Install the plane implementation before privileged lifecycle operations.")] }
      end
      private_class_method :resolve_plane

      def requested_edition
        load_plane_implementation
        if Plane.respond_to?(:requested_edition)
          edition = Plane.requested_edition.to_s
          raise Failure.new("edition_unavailable", "Plane.requested_edition returned #{edition.inspect}", exit_status: 3) unless %w[standard lock].include?(edition)
          return [edition, []]
        end
        build = File.join(ROOT, "EDITION")
        edition = File.file?(build) ? File.read(build).strip : "standard"
        raise Failure.new("edition_unavailable", "invalid build edition #{edition.inspect}", exit_status: 3) unless %w[standard lock].include?(edition)
        [edition, [finding("plane_api_unavailable", "Plane.requested_edition is unavailable; planning uses the build floor only.", nil, "plane", "Integrate the protected plane implementation before relying on edition selection.")]]
      rescue Failure
        raise
      rescue StandardError => error
        raise Failure.new("edition_unavailable", "requested edition could not be resolved: #{error.class}: #{error.message}", exit_status: 3)
      end
      private_class_method :requested_edition

      def operator_identity!(operation)
        load_plane_implementation
        raise Failure.new("operator_required", "protected operator authentication is unavailable", exit_status: 3) unless Plane.respond_to?(:operator!)
        stringify(Plane.operator!(operation))
      rescue Failure
        raise
      rescue StandardError => error
        code = error.respond_to?(:code) ? error.code.to_s : "operator_required"
        raise Failure.new(code.empty? ? "operator_required" : code, error.message, exit_status: 3)
      end
      private_class_method :operator_identity!

      def bind_operator_plane!(identity, plane)
        valid = plane["status"] == "active" && identity["generation"].to_s == plane["generation"].to_s && !plane["generation"].to_s.empty?
        raise Failure.new("operator_plane_changed", "protected plane changed during operator authentication", exit_status: 3) unless valid
        true
      end
      private_class_method :bind_operator_plane!

      def load_plane_implementation
        path = File.join(LIB, "harness_controls", "plane.rb")
        require path if File.file?(path)
      end
      private_class_method :load_plane_implementation

      def block_unresolved!(records, targets, except_operation: nil)
        latest = records.group_by { |row| row["operation_id"] }.values.map { |rows| rows.max_by { |row| row["sequence"].to_i } }
        conflict = latest.find do |row|
          next false if row["operation_id"] == except_operation
          %w[prepared recovery_required].include?(row["status"]) && !(Array(row["targets"]) & targets).empty?
        end
        raise Failure.new("recovery_required", "unresolved transaction #{conflict['operation_id']} owns one or more targets", exit_status: 3, data: conflict) if conflict
      end
      private_class_method :block_unresolved!

      def ensure_schedules_verified!(result)
        return unless result
        failed = Array(result["installed"]).reject { |row| row["port_accepted"] == true && row.dig("status", "installed") == true }
        return if failed.empty?
        ids = failed.map { |row| row["job_id"] }
        raise Failure.new("schedule_installation_unverified", "scheduled jobs were not observed installed: #{ids.join(', ')}", exit_status: 3, data: result, findings: Array(result["findings"]))
      end
      private_class_method :ensure_schedules_verified!

      def runtime_argv(context)
        values = stringify(context)
        runtime = values["runtime_argv"]
        return runtime if runtime.is_a?(Array) && !runtime.empty?
        [values["runtime_path"].to_s.empty? ? File.join(ROOT, "bin", "polispec") : values["runtime_path"]]
      end
      private_class_method :runtime_argv

      def runtime_provenance(argv)
        Array(argv).select { |item| item.is_a?(String) && item.start_with?("/") }.map do |path|
          realpath = File.realpath(path)
          stat = File.stat(realpath)
          raise Failure.new("runtime_untrusted", "runtime component is not a regular file: #{path}", exit_status: 3) unless stat.file?
          content = File.binread(realpath, 16 * 1_048_576 + 1)
          raise Failure.new("runtime_untrusted", "runtime component exceeds provenance limit: #{path}", exit_status: 3) if content.bytesize > 16 * 1_048_576
          { "path" => path, "realpath" => realpath, "digest" => Digest::SHA256.hexdigest(content), "mode" => stat.mode & 0o7777, "uid" => stat.uid, "gid" => stat.gid }
        end
      rescue SystemCallError => error
        raise Failure.new("runtime_unavailable", "runtime provenance failed: #{error.class}: #{error.message}", exit_status: 3)
      end
      private_class_method :runtime_provenance

      def file_access(protected_artifacts)
        return nil unless protected_artifacts
        { "protected" => true, "owner_uid" => 0, "owner_gid" => 0, "directory_mode" => 0o755, "file_mode" => 0o644, "boundary" => "/" }
      end
      private_class_method :file_access

      def installation_id_for(plan)
        "install_#{Digest::SHA256.hexdigest([plan['operation_id'], plan['harness'], plan['scope'], plan['edition']].join("\0"))[0, 24]}"
      end
      private_class_method :installation_id_for

      def next_sequence(records)
        records.map { |row| row["sequence"].to_i }.max.to_i + 1
      end
      private_class_method :next_sequence

      def latest_installation(records, installation_id)
        records.select { |row| row["installation_id"] == installation_id }.max_by { |row| row["sequence"].to_i }
      end
      private_class_method :latest_installation

      def active_installation(records, installation_id)
        fold_installation(records, installation_id)["active"]
      end
      private_class_method :active_installation

      def fold_installation(records, installation_id)
        raise Failure.new("installation_history_invalid", "installation state exceeds #{TRANSACTION_SCAN_LIMIT} records", exit_status: 3) if records.length > TRANSACTION_SCAN_LIMIT
        selected = []
        scanned_bytes = 0
        records.each do |row|
          row_bytes = JSON.generate(row).bytesize
          raise Failure.new("installation_history_invalid", "installation transaction record exceeds #{Files::LIMIT} bytes", exit_status: 3) if row_bytes > Files::LIMIT
          raise Failure.new("installation_history_invalid", "installation state exceeds #{TRANSACTION_SCAN_BYTES} bytes", exit_status: 3) if row_bytes > TRANSACTION_SCAN_BYTES - scanned_bytes
          scanned_bytes += row_bytes
          selected << row if row.is_a?(Hash) && row["installation_id"] == installation_id
        end
        raise Failure.new("installation_history_invalid", "installation history exceeds #{TRANSACTION_LIMIT} records", exit_status: 3) if selected.length > TRANSACTION_LIMIT
        previous_sequence = 0
        record_ids = {}
        pending = nil
        active = nil
        selected.each do |row|
          validate_transaction_row!(row, installation_id, previous_sequence, record_ids)
          previous_sequence = row["sequence"]
          if row["status"] == "prepared"
            raise Failure.new("installation_history_invalid", "transaction #{pending['row']['operation_id']} has no terminal record", exit_status: 3, data: pending["row"]) if pending
            operation = row["operation"]
            raise Failure.new("installation_history_invalid", "prepared transaction has an unknown operation", exit_status: 3, data: row) unless operation.nil? || operation == "uninstall"
            pending = { "row" => row, "operation" => operation || "install" }
            next
          end
          raise Failure.new("installation_history_invalid", "terminal transaction lacks a prepared record", exit_status: 3, data: row) unless pending
          prepared = pending["row"]
          unless row["operation_id"] == prepared["operation_id"] && transaction_identity(row) == transaction_identity(prepared)
            raise Failure.new("installation_history_invalid", "terminal transaction does not match its prepared record", exit_status: 3, data: row)
          end
          allowed = pending["operation"] == "uninstall" ? %w[uninstalled rollback_complete recovery_required] : %w[committed rollback_complete recovery_required]
          raise Failure.new("installation_history_invalid", "transaction terminal status is invalid for #{pending['operation']}", exit_status: 3, data: row) unless allowed.include?(row["status"])
          if row["status"] == "recovery_required"
            raise Failure.new("recovery_required", "unresolved transaction #{row['operation_id']} prevents receipt selection", exit_status: 3, data: row)
          elsif row["status"] == "committed"
            active = row
          elsif row["status"] == "uninstalled"
            active = nil
          end
          pending = nil
        end
        raise Failure.new("recovery_required", "unresolved transaction #{pending['row']['operation_id']} prevents receipt selection", exit_status: 3, data: pending["row"]) if pending
        { "active" => active, "records" => selected.length }
      rescue JSON::GeneratorError, SystemStackError
        raise Failure.new("installation_history_invalid", "installation transaction history cannot be serialized", exit_status: 3)
      end
      private_class_method :fold_installation

      def validate_transaction_row!(row, installation_id, previous_sequence, record_ids)
        valid = row.is_a?(Hash) && row["schema"] == "polispec.harness.transaction/v1" && row["installation_id"] == installation_id
        valid &&= row["operation_id"].is_a?(String) && !row["operation_id"].empty? && row["operation_id"].bytesize <= 128 && !row["operation_id"].include?("\0")
        valid &&= TRANSACTION_STATUSES.include?(row["status"])
        valid &&= row["sequence"].is_a?(Integer) && row["sequence"].positive? && row["sequence"] > previous_sequence
        valid &&= row["record_id"] == "tx_#{Digest::SHA256.hexdigest("#{row['operation_id']}\0#{row['status']}\0#{row['sequence']}")[0, 24]}"
        valid &&= row["receipt"].is_a?(Hash) && row["receipt"]["schema"] == "polispec.harness.receipt/v1"
        targets = row["targets"]
        valid &&= targets.is_a?(Array) && !targets.empty? && targets.length <= 64 && targets == targets.uniq.sort
        valid &&= targets.all? { |path| path.is_a?(String) && path.start_with?("/") && !path.include?("\0") }
        valid &&= targets == row["receipt"].fetch("artifact_digests", {}).keys.sort
        valid &&= row["installation_id"] == row["receipt"]["installation_id"]
        valid &&= row["control_digest"] == row["receipt"]["control_digest"] && row["harness"] == row["receipt"]["harness"]
        valid &&= row["scope"] == row["receipt"]["scope"] && row["edition"] == row["receipt"]["edition"]
        valid &&= JSON.generate(row).bytesize <= Files::LIMIT
        raise Failure.new("installation_history_invalid", "installation transaction history is malformed or nonmonotonic", exit_status: 3, data: row) unless valid
        raise Failure.new("installation_history_invalid", "installation transaction record_id is duplicated", exit_status: 3, data: row) if record_ids[row["record_id"]]
        record_ids[row["record_id"]] = true
      rescue KeyError, JSON::GeneratorError
        raise Failure.new("installation_history_invalid", "installation transaction history is malformed", exit_status: 3, data: row)
      end
      private_class_method :validate_transaction_row!

      def transaction_identity(row)
        canonical({
          "installation_id" => row["installation_id"], "operation_id" => row["operation_id"],
          "targets" => row["targets"], "control_digest" => row["control_digest"],
          "harness" => row["harness"], "scope" => row["scope"], "edition" => row["edition"]
        })
      end
      private_class_method :transaction_identity

      def native_version(harness)
        executable = { "claude-code" => "claude", "codex" => "codex", "hermes" => "hermes", "antigravity" => "agy" }[harness.to_s]
        return nil unless executable
        path = executable_path(executable)
        return nil unless path
        result = VerificationRunner.call([path, "--version"], timeout: VERSION_TIMEOUT, max_output: OUTPUT_LIMIT)
        return nil unless result["exit_status"] == 0 && result["timed_out"] == false && result["output_complete"] != false
        output = "#{result['stdout']}\n#{result['stderr']}"
        output.to_s[/\d+(?:\.\d+){1,3}/]
      rescue StandardError
        nil
      end
      private_class_method :native_version

      def executable_path(name)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
          path = File.join(directory, name)
          return File.realpath(path) if File.file?(path) && File.executable?(path)
        end
        nil
      rescue SystemCallError
        nil
      end
      private_class_method :executable_path

      def emit_committed(port_set, plan, receipt)
        ports = port_set || sdk_ports
        return unless ports && ports.respond_to?(:events)
        ports.events.emit("polispec.control", {
          "operation_id" => plan["operation_id"], "control_digest" => plan["control_digest"],
          "edition" => plan["edition"], "harness" => plan["harness"], "scope" => plan["scope"],
          "disposition" => "committed", "duration_ms" => 0, "installation_id" => receipt["installation_id"]
        })
      rescue StandardError
        nil
      end
      private_class_method :emit_committed

      def canonical(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
            source = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
            result[key] = canonical(value[source])
          end
        when Array
          value.map { |item| canonical(item) }
        else
          value
        end
      end
      private_class_method :canonical

      def stringify(value)
        return {} unless value.is_a?(Hash)
        value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
      end
      private_class_method :stringify

      def finding(code, detail, harness, capability, next_step)
        { "code" => code, "detail" => detail, "control_id" => nil, "harness" => harness, "capability" => capability, "next_step" => next_step }
      end
      private_class_method :finding
    end
  end
end
