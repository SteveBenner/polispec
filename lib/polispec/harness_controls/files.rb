require "fileutils"

module Polispec
  module HarnessControls
    module Files
      LIMIT = 1_048_576

      module_function

      def existing(paths)
        Array(paths).each_with_object({}) do |path, result|
          safe_target!(path)
          next unless File.file?(path)

          result[path] = read(path)
        end
      end

      def prepare(artifacts, operation_id, access: nil)
        Array(artifacts).map { |artifact| prepare_artifact(artifact, operation_id, access) }
      end

      def with_target_locks(targets, access: nil, &block)
        with_locks(targets, access: access, &block)
      end

      def apply(prepared, lock: true)
        operation = proc do
          verify_priors!(prepared)
          create_backups!(prepared)
          prepared.each { |row| write_atomic(row["target"], row["merged_content"], row["mode"], row["uid"], row["gid"], row["access"]) }
          verify_installed!(prepared)
        end
        lock ? with_locks(prepared.map { |row| row["target"] }, access: shared_access(prepared), &operation) : operation.call
        prepared
      end

      def rollback(prepared, lock: true)
        failures = []
        operation = proc do
          prepared.reverse_each do |row|
            begin
              current_digest = File.file?(row["target"]) ? digest(read(row["target"])) : nil
              next if current_digest == row["expected_prior_digest"]
              unless current_digest == row["installed_digest"]
                raise Polispec::Error, "rollback refused unexpected bytes at #{row['target']}"
              end
              prior_exists = row.key?("rollback_prior_exists") ? row["rollback_prior_exists"] : row["prior_exists"]
              backup_path = row["rollback_backup_path"] || row["backup_path"]
              backup_digest = row["rollback_backup_digest"] || row["backup_digest"]
              if prior_exists
                backup = read(backup_path)
                raise Polispec::Error, "backup digest mismatch for #{row['target']}" unless digest(backup) == backup_digest
                write_atomic(row["target"], backup, row["rollback_mode"] || row["mode"], row.key?("rollback_uid") ? row["rollback_uid"] : row["uid"], row.key?("rollback_gid") ? row["rollback_gid"] : row["gid"], row["access"])
              elsif File.exist?(row["target"])
                failed = "#{row['target']}.polispec-failed-#{row['operation_suffix']}"
                safe_target!(failed)
                File.rename(row["target"], failed)
              end
            rescue StandardError => error
              failures << { "target" => row["target"], "error" => "#{error.class}: #{error.message}" }
            end
          end
        end
        lock ? with_locks(prepared.map { |row| row["target"] }, access: shared_access(prepared), &operation) : operation.call
        failures
      rescue StandardError => error
        [{ "target" => nil, "error" => "#{error.class}: #{error.message}" }]
      end

      def verify_receipt(receipt)
        receipt = stringify(receipt)
        rows = Array(receipt["owned_entries"])
        findings = []
        access = normalize_access(receipt["file_access"])
        integrity = receipt.fetch("artifact_digests", {}).all? do |path, expected|
          actual = File.file?(path) ? digest(read(path)) : nil
          if actual != expected
            findings << finding("artifact_digest_mismatch", "Installed bytes at #{path} do not match the committed receipt.")
            false
          else
            true
          end
        end
        access_integrity = receipt.fetch("artifact_digests", {}).keys.all? do |path|
          next true unless access
          begin
            safe_target!(path)
            validate_existing_parent!(path, access)
            validate_access_target!(path, access)
            true
          rescue StandardError => error
            findings << finding("artifact_access_invalid", "Installed access at #{path} is invalid: #{error.class}: #{error.message}")
            false
          end
        end
        ownership = rows.all? do |row|
          owned_entry_present?(row, findings)
        end
        { "integrity" => integrity && access_integrity, "ownership" => ownership, "findings" => findings }
      rescue StandardError => error
        { "integrity" => false, "ownership" => false, "findings" => [finding("ownership_check_failed", "#{error.class}: #{error.message}")] }
      end

      def validate_mutable_receipt!(receipt, planned_artifacts, owner_uid:, boundary:, home:, protected_paths:)
        receipt = stringify(receipt)
        planned = Array(planned_artifacts).map { |artifact| stringify(artifact) }
        stored = Array(receipt["artifacts"]).map { |artifact| stringify(artifact) }
        stored.each { |artifact| validate_artifact!(artifact) }
        planned_signatures = planned.map { |artifact| artifact_signature(artifact) }.sort_by { |row| row["path"] }
        stored_signatures = stored.map { |artifact| artifact_signature(artifact) }.sort_by { |row| row["path"] }
        raise Polispec::Error, "mutable receipt artifact targets or ownership differ from canonical planning" unless stored_signatures == planned_signatures
        targets = receipt.fetch("artifact_digests", {}).keys.sort
        expected_targets = planned_signatures.map { |row| row["path"] }.sort
        planned_by_path = planned_signatures.each_with_object({}) { |row, result| result[row["path"]] = row }
        raise Polispec::Error, "mutable receipt artifact digest targets are incomplete" unless targets == expected_targets
        valid_digests = receipt.fetch("artifact_digests", {}).values.all? { |value| value.to_s.match?(/\A[0-9a-f]{64}\z/) }
        raise Polispec::Error, "mutable receipt artifact digests are invalid" unless valid_digests
        boundary = File.realpath(boundary)
        home = File.realpath(home)
        targets.each do |target|
          safe_target!(target)
          real = File.realpath(target)
          canonical_planned = expected_targets.include?(target) && File.realpath(target) == real
          control_document = planned_by_path.dig(target, "kind") == "control_document"
          allowed_home_target = boundary != home && canonical_planned && !control_document && path_within?(real, home)
          raise Polispec::Error, "mutable target escapes selected scope: #{target}" unless path_within?(real, boundary) || allowed_home_target
          protected = Array(protected_paths).any? do |path|
            protected_real = canonical_existing(path)
            protected_real && (path_within?(real, protected_real) || path_within?(protected_real, real))
          end
          raise Polispec::Error, "mutable target intersects protected authority: #{target}" if protected
          stat = File.lstat(target)
          raise Polispec::Error, "mutable target is not a selected-owner regular file: #{target}" unless stat.file? && !stat.symlink? && stat.uid == owner_uid
        end
        allowed = stored.each_with_object({}) do |artifact, result|
          result[artifact["path"]] = expected_ownership(artifact)
        end
        rows = Array(receipt["owned_entries"])
        raise Polispec::Error, "mutable receipt has no ownership entries" if rows.empty?
        backups = validated_receipt_backups(receipt, targets, owner_uid)
        normalized_rows = rows.map { |row| stringify(row) }
        grouped_rows = normalized_rows.group_by { |row| [row["target"], row["pointer"].to_s] }
        allowed.each do |target, selectors|
          actual = grouped_rows.keys.select { |entry| entry.first == target }.map(&:last).sort
          raise Polispec::Error, "mutable receipt ownership selectors are incomplete" unless actual == selectors.keys.sort
        end
        grouped_rows.each do |(target, pointer), group|
          expected = allowed.dig(target, pointer)
          raise Polispec::Error, "mutable receipt owns an unplanned selector" unless expected
          modes = group.map { |row| row["merge_mode"] }.uniq
          raise Polispec::Error, "mutable receipt ownership mode differs from stored artifact" unless modes == [expected["mode"]]
          if expected["mode"] == "array"
            contributions = group.flat_map { |row| Array(row["contributed_values"]).map { |value| canonical(value) } }
            valid = contributions.length == contributions.uniq.length && contributions.all? { |value| expected["value"].include?(value) }
            raise Polispec::Error, "mutable receipt array contributions differ from stored artifact" unless valid
          elsif expected["mode"] == "scalar"
            valid = group.length == 1 && canonical(group.first["contributed_value"]) == expected["value"]
            raise Polispec::Error, "mutable receipt scalar contribution differs from stored artifact" unless valid
          else
            valid = group.length == 1 && group.first["contributed_digest"] == expected["digest"]
            raise Polispec::Error, "mutable receipt root contribution differs from stored artifact" unless valid
          end
          normalize_restoration_group!(group, expected, backups.fetch(target), owner_uid)
        end
        Array(receipt["schedules"]).each do |job|
          id = stringify(job)["job_id"].to_s
          raise Polispec::Error, "mutable receipt contains an invalid schedule job" unless id.match?(/\Apolispec-[0-9a-f]{24}\z/)
        end
        normalized_rows
      end

      def uninstall(receipt, lock: true)
        prepared = prepare_uninstall(receipt)
        apply_uninstall(prepared, lock: lock)
        prepared.map { |row| { "target" => row["target"], "backup_path" => row["uninstall_backup"] } }
      end

      def prepare_uninstall(receipt)
        receipt = stringify(receipt)
        access = normalize_access(receipt["file_access"])
        grouped = Array(receipt["owned_entries"]).group_by { |row| row["target"] }
        grouped.map do |target, rows|
          safe_target!(target)
          ensure_parent!(target, access)
          validate_access_target!(target, access) if File.exist?(target)
          raise Polispec::Error, "owned target is missing: #{target}" unless File.file?(target)
          current = read(target)
          content = remove_rows(current, rows)
          stat = File.stat(target)
          { "target" => target, "prior" => current, "prior_digest" => digest(current), "content" => content, "post_digest" => content && digest(content), "mode" => stat.mode & 0o7777, "uid" => stat.uid, "gid" => stat.gid, "access" => access }
        end
      end

      def apply_uninstall(prepared, lock: true)
        operation = proc do
          prepared.each do |row|
            current = File.file?(row["target"]) ? digest(read(row["target"])) : nil
            raise Polispec::Error, "owned target changed during uninstall: #{row['target']}" unless current == row["prior_digest"]
          end
          prepared.each do |row|
            backup = backup_current(row["target"], "uninstall-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}", row["access"])
            if row["content"].nil?
              File.delete(row["target"])
            else
              write_atomic(row["target"], row["content"], row["mode"], row["uid"], row["gid"], row["access"])
            end
            row["uninstall_backup"] = backup
            row["uninstall_backup_digest"] = digest(read(backup))
          end
        end
        lock ? with_locks(prepared.map { |row| row["target"] }, access: shared_access(prepared), &operation) : operation.call
        prepared
      end

      def rollback_uninstall(prepared, lock: true)
        failures = []
        operation = proc do
          prepared.reverse_each do |row|
            begin
              current = File.file?(row["target"]) ? digest(read(row["target"])) : nil
              next if current == row["prior_digest"]
              raise Polispec::Error, "uninstall rollback refused unexpected bytes at #{row['target']}" unless current == row["post_digest"]
              backup = read(row["uninstall_backup"])
              raise Polispec::Error, "uninstall backup digest mismatch at #{row['target']}" unless digest(backup) == row["uninstall_backup_digest"]
              write_atomic(row["target"], backup, row["mode"], row["uid"], row["gid"], row["access"])
            rescue StandardError => error
              failures << { "target" => row["target"], "error" => "#{error.class}: #{error.message}" }
            end
          end
        end
        lock ? with_locks(prepared.map { |row| row["target"] }, access: shared_access(prepared), &operation) : operation.call
        failures
      end

      def prepare_artifact(artifact, operation_id, access)
        artifact = stringify(artifact)
        validate_artifact!(artifact)
        target = artifact["path"]
        access = normalize_access(access)
        safe_target!(target)
        ensure_parent!(target, access)
        validate_access_target!(target, access) if File.exist?(target)
        prior_exists = File.file?(target)
        prior = prior_exists ? read(target) : nil
        merged, owned = merge(prior, artifact)
        stat = prior_exists ? File.stat(target) : nil
        suffix = operation_id.to_s.gsub(/[^A-Za-z0-9]/, "")[0, 24]
        backup_path = prior_exists ? "#{target}.polispec-backup-#{suffix}" : nil
        {
          "target" => target,
          "format" => artifact["format"],
          "kind" => artifact.dig("ownership", "kind"),
          "prior_exists" => prior_exists,
          "prior_digest" => prior && digest(prior),
          "backup_path" => backup_path,
          "backup_digest" => prior && digest(prior),
          "mode" => stat ? stat.mode & 0o7777 : access ? access["file_mode"] : 0o600,
          "uid" => stat ? stat.uid : access && access["owner_uid"],
          "gid" => stat ? stat.gid : access && access["owner_gid"],
          "expected_prior_digest" => prior && digest(prior),
          "merged_content" => merged,
          "installed_digest" => digest(merged),
          "owned_entries" => owned,
          "operation_suffix" => suffix,
          "access" => access
        }
      end
      private_class_method :prepare_artifact

      def artifact_signature(artifact)
        ownership = stringify(artifact["ownership"])
        entries = Array(ownership["entries"]).map(&:to_s)
        { "path" => artifact["path"].to_s, "format" => artifact["format"].to_s, "kind" => ownership["kind"].to_s, "entries" => entries.sort }
      end
      private_class_method :artifact_signature

      def expected_ownership(artifact)
        ownership = stringify(artifact["ownership"])
        kind = ownership["kind"]
        entries = Array(ownership["entries"])
        return { "" => { "mode" => "root", "digest" => artifact["digest"] } } if %w[control_document exclusive].include?(kind)
        return { entries.first => { "mode" => "toml_block", "digest" => artifact["digest"] } } if kind == "toml_block"
        type = kind == "json_entries" ? :json : :yaml
        fragment = parse_document(artifact["content"], type)
        entries.each_with_object({}) do |pointer, result|
          value = pointer_get(fragment, pointer)
          raise Polispec::Error, "planned ownership selector is absent" if value.equal?(MISSING)
          result[pointer] = { "mode" => value.is_a?(Array) ? "array" : "scalar", "value" => canonical(value) }
        end
      end
      private_class_method :expected_ownership

      def validated_receipt_backups(receipt, targets, owner_uid)
        rows = Array(receipt["backups"]).map { |row| stringify(row) }
        raise Polispec::Error, "mutable receipt backup rows are incomplete" unless rows.map { |row| row["target"] }.sort == targets
        rows.each_with_object({}) do |row, result|
          target = row["target"]
          raise Polispec::Error, "mutable receipt backup names an unplanned target" unless targets.include?(target)
          raise Polispec::Error, "mutable receipt backup prior_exists must be boolean" unless [true, false].include?(row["prior_exists"])
          if row["prior_exists"]
            raise Polispec::Error, "mutable receipt prior backup is required" if row["backup_path"].nil?
            validate_backup_reference!(target, row["backup_path"], row["backup_digest"], owner_uid)
            raise Polispec::Error, "mutable receipt prior digest differs from backup" unless row["prior_digest"] == row["backup_digest"]
          elsif row["backup_path"] || row["backup_digest"]
            raise Polispec::Error, "mutable receipt absent prior cannot name a backup"
          elsif row["prior_digest"]
            raise Polispec::Error, "mutable receipt absent prior cannot name a digest"
          end
          if row["transaction_backup_path"]
            validate_backup_reference!(target, row["transaction_backup_path"], row["transaction_backup_digest"], owner_uid)
          elsif row["transaction_backup_digest"]
            raise Polispec::Error, "mutable receipt transaction backup digest lacks a path"
          end
          result[target] = row
        end
      end
      private_class_method :validated_receipt_backups

      def normalize_restoration_group!(group, expected, target_backup, owner_uid)
        mode = expected["mode"]
        if %w[root toml_block].include?(mode)
          row = group.first
          same_backup = row["backup_path"] == target_backup["backup_path"] && row["backup_digest"] == target_backup["backup_digest"]
          raise Polispec::Error, "mutable root ownership backup differs from receipt backup" unless same_backup
          expected_present = target_backup["prior_exists"] == true
          raise Polispec::Error, "mutable root prior_present differs from receipt backup" unless row["prior_present"] == expected_present
          raise Polispec::Error, "mutable root restoration fields are invalid" unless row["prior_value"].nil? && Array(row["prior_ancestors"]).empty?
          row["prior_present"] = expected_present
          row["prior_value"] = nil
          row["prior_ancestors"] = []
          return
        end

        expected_prior = MISSING
        group.each_with_index do |row, index|
          prior, ancestors = restoration_from_backup(row, owner_uid)
          if index.positive? && !same_value?(prior, expected_prior)
            raise Polispec::Error, "mutable receipt ownership backup chain is inconsistent"
          end
          present = !prior.equal?(MISSING)
          supplied_ancestors = Array(row["prior_ancestors"])
          valid = row["prior_present"] == present && canonical(row["prior_value"]) == canonical(present ? prior : nil) && supplied_ancestors == ancestors
          raise Polispec::Error, "mutable receipt restoration fields differ from owned backup" unless valid
          row["prior_present"] = present
          row["prior_value"] = present ? canonical(prior) : nil
          row["prior_ancestors"] = ancestors
          expected_prior = contribution_result(prior, row, mode)
        end
      end
      private_class_method :normalize_restoration_group!

      def restoration_from_backup(row, owner_uid)
        path = row["backup_path"]
        if path.nil?
          raise Polispec::Error, "mutable receipt backup digest lacks a path" if row["backup_digest"]
          return [MISSING, []]
        end
        validate_backup_reference!(row["target"], path, row["backup_digest"], owner_uid)
        type = row["format"] == "json" ? :json : :yaml
        document = parse_document(read(path), type)
        prior = pointer_get(document, row["pointer"])
        ancestors = pointer_ancestors(row["pointer"]).select { |pointer| !pointer_get(document, pointer).equal?(MISSING) }
        [prior, ancestors]
      end
      private_class_method :restoration_from_backup

      def contribution_result(prior, row, mode)
        return canonical(row["contributed_value"]) if mode == "scalar"
        base = prior.equal?(MISSING) ? [] : canonical(prior)
        raise Polispec::Error, "mutable receipt array backup contains a scalar" unless base.is_a?(Array)
        contribution = Array(row["contributed_values"]).map { |value| canonical(value) }
        raise Polispec::Error, "mutable receipt array contribution was already present in its backup" unless (base & contribution).empty?
        base + contribution
      end
      private_class_method :contribution_result

      def same_value?(left, right)
        return true if left.equal?(MISSING) && right.equal?(MISSING)
        return false if left.equal?(MISSING) || right.equal?(MISSING)
        canonical(left) == canonical(right)
      end
      private_class_method :same_value?

      def validate_backup_reference!(target, backup_path, backup_digest, owner_uid)
        return if backup_path.nil?
        path = backup_path.to_s
        expected = "#{target}.polispec-backup-"
        raise Polispec::Error, "mutable receipt backup path is invalid" unless path.start_with?(expected) && File.dirname(path) == File.dirname(target)
        safe_target!(path)
        raise Polispec::Error, "mutable receipt backup is missing" unless File.exist?(path)
        stat = File.lstat(path)
        raise Polispec::Error, "mutable receipt backup is not selected-owner regular data" unless stat.file? && !stat.symlink? && stat.uid == owner_uid
        raise Polispec::Error, "mutable receipt backup digest is invalid" unless backup_digest.to_s.match?(/\A[0-9a-f]{64}\z/) && digest(read(path)) == backup_digest
      end
      private_class_method :validate_backup_reference!

      def canonical_existing(path)
        value = path.to_s
        return nil unless value.start_with?("/")
        current = value
        current = File.dirname(current) until File.exist?(current) || File.symlink?(current) || File.dirname(current) == current
        return nil if File.symlink?(current)
        File.join(File.realpath(current), value.delete_prefix(current).delete_prefix("/"))
      rescue SystemCallError
        nil
      end
      private_class_method :canonical_existing

      def path_within?(path, boundary)
        path == boundary || path.start_with?(boundary.end_with?("/") ? boundary : "#{boundary}/")
      end
      private_class_method :path_within?

      def validate_artifact!(artifact)
        path = artifact["path"]
        content = artifact["content"]
        raise Polispec::Error, "artifact path must be absolute" unless path.is_a?(String) && path.start_with?("/") && !path.include?("\0")
        raise Polispec::Error, "artifact content must be bounded UTF-8" unless content.is_a?(String) && content.valid_encoding? && content.bytesize <= LIMIT
        raise Polispec::Error, "artifact digest mismatch for #{path}" unless artifact["digest"] == digest(content)
        ownership = stringify(artifact["ownership"])
        entries = ownership["entries"]
        raise Polispec::Error, "artifact ownership entries are invalid for #{path}" unless entries.is_a?(Array) && !entries.empty? && entries.all? { |entry| entry.is_a?(String) }
        kind = ownership["kind"]
        allowed = %w[control_document json_entries yaml_entries toml_block exclusive]
        raise Polispec::Error, "unsupported artifact ownership #{kind.inspect}" unless allowed.include?(kind)
        if %w[control_document exclusive].include?(kind) && entries != [""]
          raise Polispec::Error, "root ownership must use the RFC 6901 empty pointer"
        end
      end
      private_class_method :validate_artifact!

      def merge(prior, artifact)
        ownership = stringify(artifact["ownership"])
        kind = ownership["kind"]
        case kind
        when "control_document", "exclusive"
          if prior && prior != artifact["content"]
            raise Polispec::Error, "exclusive artifact conflicts with existing bytes at #{artifact['path']}" if kind == "exclusive"
          end
          row = root_row(artifact, prior)
          [artifact["content"], [row]]
        when "json_entries", "yaml_entries"
          merge_structured(prior, artifact, kind == "json_entries" ? :json : :yaml)
        when "toml_block"
          merge_toml(prior, artifact)
        end
      end
      private_class_method :merge

      def merge_structured(prior, artifact, type)
        fragment = parse_document(artifact["content"], type)
        current = prior ? parse_document(prior, type) : {}
        raise Polispec::Error, "shared artifact root must be an object" unless fragment.is_a?(Hash) && current.is_a?(Hash)
        original = canonical(current)
        rows = artifact.dig("ownership", "entries").map do |pointer|
          value = pointer_get(fragment, pointer)
          raise Polispec::Error, "owned pointer #{pointer} is absent from generated fragment" if value.equal?(MISSING)
          previous = pointer_get(original, pointer)
          prior_ancestors = pointer_ancestors(pointer).select { |ancestor| !pointer_get(original, ancestor).equal?(MISSING) }
          merged, mode, contribution = merge_value(previous, value, pointer)
          pointer_set(current, pointer, merged)
          {
            "target" => artifact["path"], "format" => artifact["format"], "pointer" => pointer,
            "merge_mode" => mode, "contributed_values" => mode == "array" ? canonical(contribution) : nil,
            "contributed_value" => mode == "scalar" ? canonical(value) : nil,
            "contributed_digest" => digest(JSON.generate(canonical(value))),
            "prior_present" => !previous.equal?(MISSING), "prior_value" => previous.equal?(MISSING) ? nil : canonical(previous),
            "prior_ancestors" => prior_ancestors,
            "control_ids" => Array(artifact.dig("ownership", "control_ids"))
          }
        end
        content = type == :json ? JSON.pretty_generate(canonical(current)) + "\n" : YAML.dump(canonical(current))
        [content, rows]
      end
      private_class_method :merge_structured

      def merge_value(previous, value, pointer)
        return [canonical(value), value.is_a?(Array) ? "array" : "scalar", canonical(value)] if previous.equal?(MISSING)
        if value.is_a?(Array)
          raise Polispec::Error, "owned array conflicts with scalar at #{pointer}" unless previous.is_a?(Array)
          if pointer.downcase.match?(/allow|domain/) && canonical(previous) != canonical(value)
            raise Polispec::Error, "allowlist widening or uncertain merge refused at #{pointer}"
          end
          merged = canonical(previous)
          contribution = canonical(value).reject { |item| merged.include?(item) }
          contribution.each { |item| merged << item }
          return [merged, "array", contribution]
        end
        raise Polispec::Error, "owned scalar conflicts at #{pointer}" unless canonical(previous) == canonical(value)
        [canonical(value), "scalar", canonical(value)]
      end
      private_class_method :merge_value

      def merge_toml(prior, artifact)
        names = artifact.dig("ownership", "entries")
        raise Polispec::Error, "TOML artifact must own one named block" unless names.length == 1
        name = names.first
        content = artifact["content"]
        begin_line = "# polispec:begin #{name}"
        end_line = "# polispec:end #{name}"
        raise Polispec::Error, "TOML ownership markers are missing" unless content.lines.map(&:chomp).include?(begin_line) && content.lines.map(&:chomp).include?(end_line)
        raise Polispec::Error, "unmanaged TOML merge is unsupported at #{artifact['path']}" if prior && prior != content
        row = root_row(artifact, prior).merge("pointer" => name, "merge_mode" => "toml_block")
        [content, [row]]
      end
      private_class_method :merge_toml

      def root_row(artifact, prior)
        {
          "target" => artifact["path"], "format" => artifact["format"], "pointer" => "",
          "merge_mode" => "root", "contributed_values" => nil, "contributed_value" => nil,
          "contributed_digest" => artifact["digest"], "prior_present" => !prior.nil?,
          "prior_value" => nil, "control_ids" => Array(artifact.dig("ownership", "control_ids"))
        }
      end
      private_class_method :root_row

      def verify_priors!(prepared)
        prepared.each do |row|
          current = File.file?(row["target"]) ? digest(read(row["target"])) : nil
          raise Polispec::Error, "target changed after planning: #{row['target']}" unless current == row["expected_prior_digest"]
        end
      end
      private_class_method :verify_priors!

      def create_backups!(prepared)
        prepared.each do |row|
          if row["backup_inherited"]
            rollback_path = row["rollback_backup_path"]
            raise Polispec::Error, "transaction rollback path is missing for #{row['target']}" unless rollback_path
            if File.file?(rollback_path)
              raise Polispec::Error, "transaction rollback backup differs for #{row['target']}" unless digest(read(rollback_path)) == row["rollback_backup_digest"]
            else
              write_atomic(rollback_path, read(row["target"]), 0o600, row["rollback_uid"], row["rollback_gid"], row["access"])
            end
            if row["prior_exists"]
              raise Polispec::Error, "inherited backup is missing for #{row['target']}" unless row["backup_path"] && File.file?(row["backup_path"])
              raise Polispec::Error, "inherited backup digest mismatch for #{row['target']}" unless digest(read(row["backup_path"])) == row["backup_digest"]
            end
            next
          end
          next unless row["prior_exists"]
          if File.file?(row["backup_path"])
            raise Polispec::Error, "existing backup differs for #{row['target']}" unless read(row["backup_path"]) == read(row["target"])
          else
            write_atomic(row["backup_path"], read(row["target"]), 0o600, row["uid"], row["gid"], row["access"])
          end
        end
      end
      private_class_method :create_backups!

      def verify_installed!(prepared)
        prepared.each do |row|
          raise Polispec::Error, "installed artifact verification failed: #{row['target']}" unless File.file?(row["target"]) && digest(read(row["target"])) == row["installed_digest"]
        end
      end
      private_class_method :verify_installed!

      def owned_entry_present?(row, findings)
        row = stringify(row)
        target = row["target"]
        unless File.file?(target)
          findings << finding("owned_target_missing", "Owned target #{target} is missing.")
          return false
        end
        return true if row["merge_mode"] == "root" || row["merge_mode"] == "toml_block"
        type = row["format"] == "json" ? :json : :yaml
        value = pointer_get(parse_document(read(target), type), row["pointer"])
        expected = row["merge_mode"] == "array" ? Array(row["contributed_values"]) : row["contributed_value"]
        present = row["merge_mode"] == "array" ? expected.all? { |item| value.is_a?(Array) && value.include?(item) } : canonical(value) == canonical(expected)
        findings << finding("owned_entry_changed", "Owned entry #{row['pointer']} changed at #{target}.") unless present
        present
      end
      private_class_method :owned_entry_present?

      def remove_rows(content, rows)
        root = rows.any? { |row| %w[root toml_block].include?(row["merge_mode"]) }
        if root
          raise Polispec::Error, "root-owned artifact changed" unless digest(content) == rows.first["contributed_digest"]
          backup_path = rows.first["backup_path"]
          if backup_path && File.file?(backup_path)
            backup = read(backup_path)
            raise Polispec::Error, "root backup digest mismatch" unless digest(backup) == rows.first["backup_digest"]
            return backup
          end
          return nil
        end
        type = rows.first["format"] == "json" ? :json : :yaml
        data = parse_document(content, type)
        rows.each do |row|
          current = pointer_get(data, row["pointer"])
          if row["merge_mode"] == "array"
            values = Array(row["contributed_values"])
            raise Polispec::Error, "owned array contribution changed at #{row['pointer']}" unless current.is_a?(Array) && values.all? { |item| current.include?(item) }
            remaining = current.reject { |item| values.include?(item) }
            if row["prior_present"] || !remaining.empty?
              pointer_set(data, row["pointer"], remaining)
            else
              pointer_delete(data, row["pointer"], row["prior_ancestors"])
            end
          else
            raise Polispec::Error, "owned scalar contribution changed at #{row['pointer']}" unless canonical(current) == canonical(row["contributed_value"])
            row["prior_present"] ? pointer_set(data, row["pointer"], row["prior_value"]) : pointer_delete(data, row["pointer"], row["prior_ancestors"])
          end
        end
        type == :json ? JSON.pretty_generate(canonical(data)) + "\n" : YAML.dump(canonical(data))
      end
      private_class_method :remove_rows

      MISSING = Object.new.freeze

      def pointer_get(data, pointer)
        return data if pointer == ""
        pointer_tokens(pointer).reduce(data) do |value, token|
          return MISSING unless value.is_a?(Hash) && value.key?(token)
          value[token]
        end
      end
      private_class_method :pointer_get

      def pointer_set(data, pointer, value)
        tokens = pointer_tokens(pointer)
        raise Polispec::Error, "cannot replace shared document root" if tokens.empty?
        parent = tokens[0...-1].reduce(data) do |memo, token|
          existing = memo[token]
          memo[token] = {} if existing.nil?
          raise Polispec::Error, "pointer container conflicts at #{pointer}" unless memo[token].is_a?(Hash)
          memo[token]
        end
        parent[tokens.last] = value
      end
      private_class_method :pointer_set

      def pointer_delete(data, pointer, prior_ancestors = nil)
        tokens = pointer_tokens(pointer)
        parent = tokens[0...-1].reduce(data) { |memo, token| memo.is_a?(Hash) ? memo[token] : nil }
        parent.delete(tokens.last) if parent.is_a?(Hash)
        return if prior_ancestors.nil?
        preserved = Array(prior_ancestors)
        (tokens.length - 1).downto(1) do |length|
          ancestor = "/" + tokens.first(length).map { |token| token.gsub("~", "~0").gsub("/", "~1") }.join("/")
          break if preserved.include?(ancestor)
          container = pointer_get(data, ancestor)
          break unless container.is_a?(Hash) && container.empty?
          parent_tokens = tokens.first(length - 1)
          owner = parent_tokens.reduce(data) { |memo, token| memo.is_a?(Hash) ? memo[token] : nil }
          owner.delete(tokens[length - 1]) if owner.is_a?(Hash)
        end
      end
      private_class_method :pointer_delete

      def pointer_ancestors(pointer)
        tokens = pointer_tokens(pointer)
        (1...tokens.length).map do |length|
          "/" + tokens.first(length).map { |token| token.gsub("~", "~0").gsub("/", "~1") }.join("/")
        end
      end
      private_class_method :pointer_ancestors

      def pointer_tokens(pointer)
        raise Polispec::Error, "invalid RFC 6901 pointer #{pointer.inspect}" unless pointer.start_with?("/")
        pointer.split("/").drop(1).map { |token| token.gsub("~1", "/").gsub("~0", "~") }
      end
      private_class_method :pointer_tokens

      def parse_document(content, type)
        value = type == :json ? JSON.parse(content) : YAML.safe_load(content, aliases: false)
        canonical(value)
      rescue JSON::ParserError, Psych::Exception => error
        raise Polispec::Error, "unsupported existing #{type} document: #{error.message}"
      end
      private_class_method :parse_document

      def with_locks(targets, access: nil)
        access = normalize_access(access)
        handles = []
        targets.uniq.sort.each do |target|
          safe_target!(target)
          ensure_parent!(target, access)
          validate_access_target!(target, access) if access && File.exist?(target)
          lock_path = "#{target}.polispec.lock"
          safe_target!(lock_path)
          handle = File.open(lock_path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600)
          unless handle.flock(File::LOCK_EX | File::LOCK_NB)
            handle.close
            raise Polispec::Error, "target lock unavailable: #{target}"
          end
          handles << handle
        end
        yield
      ensure
        Array(handles).reverse_each do |handle|
          handle.flock(File::LOCK_UN) rescue nil
          handle.close rescue nil
        end
      end
      private_class_method :with_locks

      def backup_current(target, suffix, access = nil)
        path = "#{target}.polispec-backup-#{suffix}"
        safe_target!(path)
        content = read(target)
        stat = File.stat(target)
        write_atomic(path, content, 0o600, stat.uid, stat.gid, access)
        path
      end
      private_class_method :backup_current

      def write_atomic(path, content, mode, uid = nil, gid = nil, access = nil)
        safe_target!(path)
        ensure_parent!(path, access)
        temp = "#{path}.polispec-tmp-#{Process.pid}-#{Thread.current.object_id}"
        File.open(temp, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
          file.binmode
          file.write(content)
          file.flush
          file.fsync
        end
        File.chmod(mode, temp)
        File.chown(uid, gid, temp) unless uid.nil? && gid.nil?
        File.rename(temp, path)
      ensure
        File.delete(temp) if temp && File.exist?(temp)
      end
      private_class_method :write_atomic

      def read(path)
        safe_target!(path)
        content = File.binread(path, LIMIT + 1)
        raise Polispec::Error, "artifact exceeds #{LIMIT} bytes: #{path}" if content.bytesize > LIMIT
        content
      end
      private_class_method :read

      def safe_target!(path)
        raise Polispec::Error, "artifact path must be absolute" unless path.is_a?(String) && path.start_with?("/") && !path.include?("\0")
        current = "/"
        path.split("/").reject(&:empty?).each do |component|
          current = File.join(current, component)
          next unless File.exist?(current) || File.symlink?(current)
          raise Polispec::Error, "symlinked artifact ancestry is refused: #{current}" if File.lstat(current).symlink?
        end
        true
      rescue SystemCallError => error
        raise Polispec::Error, "artifact ancestry inspection failed for #{path}: #{error.message}"
      end
      private_class_method :safe_target!

      def normalize_access(value)
        return nil if value.nil? || value == {}
        access = stringify(value)
        raise Polispec::Error, "file access policy must be protected" unless access["protected"] == true
        raise Polispec::Error, "file access owner uid is invalid" unless access["owner_uid"].is_a?(Integer) && access["owner_uid"] >= 0
        raise Polispec::Error, "file access owner gid is invalid" unless access["owner_gid"].is_a?(Integer) && access["owner_gid"] >= 0
        raise Polispec::Error, "file access directory mode is invalid" unless access["directory_mode"] == 0o755
        raise Polispec::Error, "file access file mode is invalid" unless access["file_mode"] == 0o644
        boundary = access["boundary"].to_s
        raise Polispec::Error, "file access boundary must be absolute" unless boundary.start_with?("/") && !boundary.include?("\0")
        access.merge("boundary" => File.expand_path(boundary))
      end
      private_class_method :normalize_access

      def ensure_parent!(path, access)
        parent = File.dirname(path)
        unless access
          FileUtils.mkdir_p(parent, mode: 0o700)
          return
        end
        access_chain(path, access).reverse_each do |directory|
          if File.exist?(directory) || File.symlink?(directory)
            validate_access_directory!(directory, access)
          else
            Dir.mkdir(directory, access["directory_mode"])
            File.chmod(access["directory_mode"], directory)
            File.chown(access["owner_uid"], access["owner_gid"], directory)
            validate_access_directory!(directory, access)
          end
        end
      end
      private_class_method :ensure_parent!

      def validate_existing_parent!(path, access)
        access_chain(path, access).reverse_each { |directory| validate_access_directory!(directory, access) }
      end
      private_class_method :validate_existing_parent!

      def access_chain(path, access)
        parent = File.dirname(path)
        boundary = access["boundary"]
        unless parent == boundary || parent.start_with?("#{boundary == '/' ? '' : boundary}/")
          raise Polispec::Error, "managed target escapes its access boundary: #{path}"
        end
        chain = []
        current = parent
        loop do
          chain << current
          break if current == boundary
          ancestor = File.dirname(current)
          raise Polispec::Error, "managed access boundary is not an ancestor of #{path}" if ancestor == current
          current = ancestor
        end
        chain
      end
      private_class_method :access_chain

      def validate_access_directory!(path, access)
        stat = File.lstat(path)
        mode = stat.mode & 0o7777
        valid = stat.directory? && !stat.symlink? && stat.uid == access["owner_uid"] && (mode & 0o022).zero? && (mode & 0o005) == 0o005
        raise Polispec::Error, "managed directory is not protected and guard-readable: #{path}" unless valid
      end
      private_class_method :validate_access_directory!

      def validate_access_target!(path, access)
        return unless access
        stat = File.lstat(path)
        mode = stat.mode & 0o7777
        valid = stat.file? && !stat.symlink? && stat.uid == access["owner_uid"] && (mode & 0o022).zero? && (mode & 0o004) == 0o004
        raise Polispec::Error, "managed target is not protected and guard-readable: #{path}" unless valid
      end
      private_class_method :validate_access_target!

      def shared_access(prepared)
        values = Array(prepared).map { |row| row["access"] }.compact.uniq
        raise Polispec::Error, "mixed file access policies are unsupported" if values.length > 1
        values.first
      end
      private_class_method :shared_access

      def digest(content)
        Digest::SHA256.hexdigest(content)
      end
      private_class_method :digest

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

      def finding(code, detail)
        { "code" => code, "detail" => detail, "control_id" => nil, "harness" => nil, "capability" => "ownership", "next_step" => "Inspect the installed artifact and its receipt before retrying." }
      end
      private_class_method :finding
    end
  end
end
