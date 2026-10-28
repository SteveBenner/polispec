#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "json"
require "yaml"
require "date"
require "time"
require "fileutils"
require "securerandom"
require "tmpdir"
require_relative "../proof"
require_relative "../operator/gates"
require_relative "../operator/git"
require_relative "../lint"

module Polispec
  class ProofCommand
    USAGE = <<~TEXT.chomp.freeze
      usage: polispec proof run [FEATURE...] [--target T] [--out FILE]
             polispec proof import FILE...
             polispec proof status [--ref REF] [--json]
             polispec proof verify [--ref REF]
             polispec proof except FEATURE [--target T]... --reason TEXT --owner NAME --expires DATE
             polispec proof keygen [--json]
    TEXT
    VALUE_FLAGS = {
      "run" => %w[--target --out],
      "import" => [],
      "status" => %w[--ref],
      "verify" => %w[--ref],
      "except" => %w[--target --reason --owner --expires],
      "keygen" => []
    }.freeze
    SWITCHES = {
      "run" => [],
      "import" => [],
      "status" => %w[--json],
      "verify" => [],
      "except" => [],
      "keygen" => %w[--json]
    }.freeze
    REPEATABLE = %w[--target].freeze
    EXCEPTION_FLAGS = %w[--reason --owner --expires].freeze
    COMMENT_OR_ANCHOR = /(?:^|[\s\[{,])#|(?:^|[\s\[{,:-])[&*][A-Za-z0-9_-]/.freeze

    def self.run(args)
      new.run(args)
    end

    def run(args)
      verb, *rest = args
      return usage unless VALUE_FLAGS.key?(verb)

      opts = parse(verb, rest)
      return usage unless opts

      send("run_#{verb}", opts)
    rescue Operator::Failure => e
      e.report(json: false)
      1
    rescue Polispec::Error => e
      warn "polispec: #{e.message.sub(/\Apolispec: /, '')}"
      1
    end

    private

    def usage
      warn USAGE
      2
    end

    def parse(verb, args)
      opts = { switches: [], values: {}, rest: [] }
      queue = args.dup
      until queue.empty?
        arg = queue.shift
        name, inline = arg.start_with?("--") ? arg.split("=", 2) : [arg, nil]
        if SWITCHES.fetch(verb).include?(name)
          return nil unless inline.nil?

          opts[:switches] << name
        elsif VALUE_FLAGS.fetch(verb).include?(name)
          value = inline || queue.shift
          return nil if value.nil?

          if REPEATABLE.include?(name)
            (opts[:values][name] ||= []) << value
          else
            return nil if opts[:values].key?(name)

            opts[:values][name] = value
          end
        elsif arg.start_with?("--")
          return nil
        else
          opts[:rest] << arg
        end
      end
      opts
    end

    def git(root, *argv)
      Trace.capture3("git", "-C", root, *argv, trace: :silent)
    end

    def toplevel
      out, _err, status = git(Dir.pwd, "rev-parse", "--show-toplevel")
      raise Polispec::Error, "not_a_repository: #{Dir.pwd} is not inside a git work tree" unless status.success?

      out.strip
    rescue SystemCallError => e
      raise Polispec::Error, "not_a_repository: git could not run: #{e.message}"
    end

    def head_commit(root)
      out, err, status = git(root, "rev-parse", "--verify", "HEAD^{commit}")
      raise Polispec::Error, "no_commits: #{err.to_s.strip}" unless status.success?

      out.strip
    end

    def commit_of(root, ref)
      out, _err, status = git(root, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
      raise Polispec::Error, "ref_unknown: #{ref} is not a commit in #{root}" unless status.success?

      out.strip
    end

    def project_id(root)
      found = Ledger.load.project_for(root)
      return File.basename(root) unless found

      found.respond_to?(:id) ? found.id : found.to_s
    rescue Polispec::Error
      File.basename(root)
    end

    def manifest_at(root, ref)
      manifest = ref ? Proof::Manifest.at(root, ref) : Proof::Manifest.load(root: root)
      raise Polispec::Error, "manifest_missing: #{Proof::MANIFEST_PATH} not found#{ref ? " at #{ref}" : " in #{root}"}" unless manifest

      manifest
    end

    def records_for(root, ref, feature)
      ref ? Proof::Records.at(root, ref, feature) : Proof::Records.read(root, feature)
    end

    def host_target(manifest, explicit)
      manifest.host_target(Proof::Manifest.host_facts, explicit)
    end

    def run_run(opts)
      root = toplevel
      adapter = Proof::Runner.adapter
      manifest = manifest_at(root, nil)
      targets = Array(opts[:values]["--target"])
      return usage if targets.length > 1

      target = host_target(manifest, targets.first)
      head_commit(root)
      selected = select_features(root, manifest, target, opts[:rest])
      ensure_clean(root, manifest, selected)
      if selected.empty?
        puts "nothing to run: every feature on #{target['id']} has a passing record at its current digest"
        return 0
      end

      out_dir = File.join(Dir.tmpdir, "polispec-proof", "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(3)}")
      id = adapter.submit(root: root, features: selected, target: target["id"], out_dir: out_dir)
      raise Polispec::Error, "run_failed: runner #{id} ended #{adapter.status(id)}" unless adapter.status(id) == "done"

      records = adapter.fetch(id)
      stored = opts[:values]["--out"] ? write_out(opts[:values]["--out"], records) : append_all(root, records)
      print_runs(stored, out_dir)
      project = project_id(root)
      stored.each { |record| Events.emit("polispec.proof", project: project, feature: record["feature"], target: record["target"], verdict: record["verdict"], id: record["id"]) }
      stored.all? { |record| record["verdict"] == "pass" } ? 0 : 1
    end

    def select_features(root, manifest, target, named)
      if named.empty?
        return manifest.features.select do |feature|
          manifest.target_ids_for(feature).include?(target["id"]) && !current_pass?(root, manifest, feature, target)
        end.map { |feature| feature["id"] }
      end

      named.uniq.each do |id|
        feature = manifest.feature(id)
        raise Polispec::Error, "feature_unknown: no feature #{id} in #{Proof::MANIFEST_PATH}" unless feature
        raise Polispec::Error, "feature_not_on_target: #{id} does not run on #{target['id']}" unless manifest.target_ids_for(feature).include?(target["id"])
      end
      named.uniq
    end

    def current_pass?(root, manifest, feature, target)
      digest = Proof::Digest.cell(root, "HEAD", manifest, feature, target)
      Proof::Records.read(root, feature["id"])["records"].any? { |record| record["target"] == target["id"] && record["digest"] == digest && record["verdict"] == "pass" }
    end

    def ensure_clean(root, manifest, selected)
      return if selected.empty?

      globs = [Proof::MANIFEST_PATH] + selected.flat_map { |id| manifest.covered_globs(manifest.feature(id)) }
      out, err, status = git(root, "status", "--porcelain", "-z", "--untracked-files=normal")
      raise Polispec::Error, "git_failed: #{err.to_s.strip}" unless status.success?

      dirty = changed_paths(out).select { |path| Proof::Manifest.any_match?(globs, path) }
      return if dirty.empty?

      raise Polispec::Error, "dirty_tree: the working tree differs from HEAD in #{dirty.first(5).join(', ')}#{dirty.length > 5 ? ", and #{dirty.length - 5} more" : ''}"
    end

    def changed_paths(porcelain)
      paths = []
      entries = porcelain.split("\0")
      until entries.empty?
        entry = entries.shift
        code = entry[0, 2]
        paths << entry[3..]
        paths << entries.shift if code.include?("R") || code.include?("C")
      end
      paths.compact
    end

    def write_out(file, records)
      previous = nil
      linked = records.map do |record|
        entry = Chain.link(record.reject { |key, _| %w[prev hash].include?(key) }, previous)
        previous = entry["hash"]
        entry
      end
      File.write(file, linked.map { |entry| "#{JSON.generate(entry)}\n" }.join)
      linked
    end

    def append_all(root, records)
      records.map { |record| Proof::Records.append(root, record) }
    end

    def print_runs(records, out_dir)
      records.each do |record|
        log = File.join(out_dir, "#{record['feature']}.#{record['target']}.log")
        puts "#{record['feature']} #{record['target']} #{record['verdict']} rung #{record['rung']} #{format('%.1fs', record['duration_ms'] / 1000.0)} #{log}"
      end
    end

    def run_import(opts)
      return usage if opts[:rest].empty?

      root = toplevel
      manifest = Proof::Manifest.at(root, "HEAD")
      raise Polispec::Error, "manifest_missing: #{Proof::MANIFEST_PATH} is not committed at HEAD" unless manifest

      accepted = opts[:rest].flat_map { |file| check_import_file(root, manifest, file) }
      fresh = accepted.reject { |record| Proof::Records.read(root, record["feature"])["records"].any? { |known| known["id"] == record["id"] } }
      fresh.each { |record| Proof::Records.append(root, record) }
      project = project_id(root)
      fresh.each { |record| Events.emit("polispec.proof", project: project, feature: record["feature"], target: record["target"], verdict: record["verdict"], id: record["id"]) }
      puts "imported #{fresh.length} record#{fresh.length == 1 ? '' : 's'}#{accepted.length == fresh.length ? '' : " (#{accepted.length - fresh.length} already present)"}"
      0
    end

    def check_import_file(root, manifest, file)
      raise Polispec::Error, "import_unreadable: #{file} is not a readable file" unless File.file?(file)

      definition = Schema.definition("proof")
      File.read(file).each_line.with_index(1).reject { |line, _| line.strip.empty? }.map do |line, number|
        where = "#{file}:#{number}"
        record = parse_import_line(line, where)
        errors = Schema::Validator.new(definition).call(record)
        raise Polispec::Error, "schema_invalid: #{where} #{errors.first.pointer} #{errors.first.message}" unless errors.empty?

        ok, reason = Proof::Signer.verify(record, manifest)
        raise Polispec::Error, "#{reason}: #{where} record #{record['id']} producer #{record['producer']}" unless ok

        feature = manifest.feature(record["feature"])
        target = manifest.target(record["target"])
        raise Polispec::Error, "digest_stale: #{where} record #{record['id']} names a cell #{record['feature']} on #{record['target']} the manifest does not have" unless feature && target
        raise Polispec::Error, "digest_stale: #{where} record #{record['id']} does not match the current digest of #{record['feature']} on #{record['target']}" unless Proof::Digest.cell(root, "HEAD", manifest, feature, target) == record["digest"]

        record
      end
    end

    def parse_import_line(line, where)
      parsed = JSON.parse(line)
      raise Polispec::Error, "schema_invalid: #{where} is not a JSON object" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError => e
      raise Polispec::Error, "schema_invalid: #{where} is not JSON: #{e.message.lines.first.to_s.strip}"
    end

    def run_status(opts)
      root = toplevel
      ref = opts[:values]["--ref"]
      manifest = manifest_at(root, ref)
      rev = ref ? commit_of(root, ref) : head_commit(root)
      cells = status_cells(root, ref, rev, manifest)
      unmapped = unmapped_files(root, rev, manifest)
      if opts[:switches].include?("--json")
        puts JSON.generate("cells" => cells, "unmapped" => unmapped)
      else
        print_status(cells, unmapped)
      end
      0
    end

    def status_cells(root, ref, rev, manifest)
      manifest.features.flat_map do |feature|
        records = records_for(root, ref, feature["id"])["records"]
        manifest.targets.map do |target|
          next cell_row(feature, target, "not_applicable", nil, nil) unless manifest.target_ids_for(feature).include?(target["id"])

          cell_status(root, rev, manifest, feature, target, records)
        end
      end
    end

    def cell_status(root, rev, manifest, feature, target, records)
      digest = Proof::Digest.cell(root, rev, manifest, feature, target)
      mine = records.select { |record| record["target"] == target["id"] }
      current = mine.select { |record| record["digest"] == digest }
      proven = current.reverse.find { |record| record["verdict"] == "pass" && record["rung"] >= manifest.min_rung(feature) && Proof::Signer.verify(record, manifest).first }
      return cell_row(feature, target, "proven", proven["id"], nil) if proven

      excepted = manifest.exception_for(feature["id"], target["id"])
      return cell_row(feature, target, "excepted", nil, excepted["expires"]) if excepted
      return cell_row(feature, target, "failing", current.last["id"], nil) unless current.empty?

      stale = mine.reverse.find { |record| record["verdict"] == "pass" }
      return cell_row(feature, target, "stale", stale["id"], nil) if stale

      cell_row(feature, target, "missing", nil, nil)
    end

    def cell_row(feature, target, status, record, expires)
      { "feature" => feature["id"], "target" => target["id"], "status" => status, "record" => record, "expires" => expires }
    end

    def unmapped_files(root, rev, manifest)
      base = stable_base(root)
      out, err, status = if base
                           git(root, "diff", "--name-only", "-z", "--diff-filter=d", "#{base}..#{rev}")
                         else
                           git(root, "ls-tree", "-r", "--name-only", "-z", rev)
                         end
      raise Polispec::Error, "git_failed: #{err.to_s.strip}" unless status.success?

      out.split("\0").reject(&:empty?).reject { |path| manifest.owned?(path) || manifest.ignored?(path) }.sort
    end

    def stable_base(root)
      entry = Ledger.load.project_for(root)
      return nil unless entry

      project = Operator::Gates.load_project(entry.respond_to?(:id) ? entry.id : entry.to_s)
      Operator::Gates.stable_tag(project, Operator::Git.new(project.repo))
    rescue Polispec::Error
      nil
    end

    def print_status(cells, unmapped)
      rows = [%w[feature target status record expires]] + cells.map { |cell| [cell["feature"], cell["target"], cell["status"], cell["record"].to_s, cell["expires"].to_s] }
      widths = rows.first.each_index.map { |index| rows.map { |row| row[index].length }.max }
      rows.each { |row| puts row.each_index.map { |index| row[index].ljust(widths[index]) }.join("  ").rstrip }
      puts
      if unmapped.empty?
        puts "unmapped: none"
      else
        puts "unmapped:"
        unmapped.each { |path| puts "  #{path}" }
      end
    end

    def run_verify(opts)
      root = toplevel
      ref = opts[:values]["--ref"]
      findings = []
      manifest = verify_manifest(root, ref, findings)
      verify_records(root, ref, manifest, findings) if manifest
      if findings.empty?
        puts "ok"
        return 0
      end

      findings.each { |item| puts [item["kind"], item["file"], item["line"] && "line #{item['line']}", item["detail"]].compact.join("  ") }
      1
    end

    def verify_manifest(root, ref, findings)
      manifest = manifest_at(root, ref)
      today = Date.today
      manifest.exceptions.each do |entry|
        next unless Date.iso8601(entry["expires"]) < today

        findings << { "kind" => "exception_expired", "file" => Proof::MANIFEST_PATH, "detail" => "exception for #{entry['feature']} expired #{entry['expires']}" }
      end
      manifest
    rescue Polispec::Error => e
      raise unless e.message.start_with?("manifest_invalid")

      findings << { "kind" => "manifest_invalid", "file" => Proof::MANIFEST_PATH, "detail" => e.message.sub(/\Amanifest_invalid: /, "") }
      nil
    end

    def verify_records(root, ref, manifest, findings)
      sets = if ref
               manifest.features.to_h { |feature| [feature["id"], Proof::Records.at(root, ref, feature["id"])] }
             else
               Proof::Records.read_all(root)
             end
      sets.each do |feature, parsed|
        parsed["findings"].each { |item| findings << item }
        parsed["records"].each_with_index do |record, index|
          label = "#{Proof::PROOFS_DIR}/#{feature}.jsonl"
          findings << { "kind" => "record_misfiled", "file" => label, "line" => index + 1, "detail" => "record #{record['id']} names feature #{record['feature']}" } unless record["feature"] == feature
          ok, reason = Proof::Signer.verify(record, manifest)
          findings << { "kind" => reason, "file" => label, "line" => index + 1, "detail" => "record #{record['id']} producer #{record['producer']}" } unless ok
        end
      end
    end

    def run_except(opts)
      return usage unless opts[:rest].length == 1 && EXCEPTION_FLAGS.all? { |flag| opts[:values].key?(flag) }

      root = toplevel
      path = File.join(root, Proof::MANIFEST_PATH)
      raise Polispec::Error, "manifest_missing: #{Proof::MANIFEST_PATH} not found in #{root}" unless File.file?(path)

      today = Date.today
      entry = exception_entry(opts, today)
      text = File.read(path)
      data = YAML.safe_load(text, permitted_classes: [Date, Time], aliases: false)
      updated = data.merge("exceptions" => Array(data["exceptions"]) + [entry])
      errors = Schema.validate("features", updated)
      raise Polispec::Error, "exception_invalid: #{errors.first(3).map { |error| error.pointer.empty? ? error.message : "#{error.pointer} #{error.message}" }.join('; ')}" unless errors.empty?
      raise Polispec::Error, "manual_edit_required: #{Proof::MANIFEST_PATH} has comments or anchors this command would drop; add this under exceptions: #{JSON.generate(entry)}" if text.match?(COMMENT_OR_ANCHOR)

      rendered = YAML.dump(updated)
      Lint.guard_write!(rendered, path: path, kind: "features")
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, rendered)
      File.rename(tmp, path)
      puts "added exception for #{entry['feature']} (expires #{entry['expires']}); the operator confirms it at promote --to stable"
      0
    end

    def exception_entry(opts, today)
      expires = begin
        Date.iso8601(opts[:values]["--expires"])
      rescue Date::Error
        raise Polispec::Error, "expires_invalid: #{opts[:values]['--expires']} is not an ISO date"
      end
      raise Polispec::Error, "expires_past: #{expires} is before today" if expires < today

      limit = today + Proof::Manifest::MAX_EXCEPTION_DAYS
      raise Polispec::Error, "expires_too_long: #{expires} is more than #{Proof::Manifest::MAX_EXCEPTION_DAYS} days after today (latest #{limit})" if expires > limit

      entry = { "feature" => opts[:rest].first }
      entry["targets"] = opts[:values]["--target"] if opts[:values]["--target"]
      entry.merge("reason" => opts[:values]["--reason"], "owner" => opts[:values]["--owner"], "added" => today.iso8601, "expires" => expires.iso8601)
    end

    def run_keygen(opts)
      return usage unless opts[:rest].empty?

      Operator::Gates.require_terminal!("proof keygen")
      Operator::Gates.confirm!("create proof key")
      entry = Proof::Signer.generate
      if opts[:switches].include?("--json")
        puts JSON.generate(entry)
      else
        puts "created #{Proof::Signer.key_path}"
        puts "add this to trusted_producers in #{Proof::MANIFEST_PATH}:"
        puts YAML.dump([entry]).sub(/\A---\n/, "")
      end
      0
    end
  end

  CLI.register("proof", ProofCommand, summary: "run, import, check and except signed per-feature smoke proofs; keygen creates the host producer key")
end
