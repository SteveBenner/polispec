#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "digest"
require_relative "../validate_profiles"
require_relative "../packages"
require_relative "../native_pin"
require_relative "../exceptions"
require_relative "../editions"
require_relative "../personal_defaults"
require_relative "../lint"
require_relative "../catalog"
require_relative "../web"
require_relative "../plugin_store"

module Polispec
  class DoctorCommand
    USAGE = "usage: polispec doctor [--json]"
    FILE_LIMIT = 1_048_576
    GIT_LIMIT = 65_536
    GIT_TIMEOUT = 5
    NONBLOCKING = %w[info warn].freeze
    OID = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
    GitResult = Struct.new(:stdout, :stderr, :status)

    class GitFailure < StandardError; end

    def self.run(args)
      new.run(args)
    end

    def run(args)
      args = args.dup
      json = args.delete("--json")
      return usage unless args.empty?

      findings = []
      ledger = traced_check("load ledger", findings) { load_ledger(findings) }
      traced_check("check ledger", findings) { check_ledger(ledger, findings) } if ledger
      traced_check("check ledger runtime", findings) { check_ledger_runtime(ledger, findings) } if ledger
      traced_check("check descriptions", findings) { check_descriptions(ledger, findings) } if ledger
      traced_check("check drain resume", findings) { check_drain_resume(findings) }
      traced_check("check runtime", findings) { check_runtime(findings) }
      traced_check("check release", findings) { check_release(findings) }
      traced_check("check plane", findings) { check_plane(findings) }
      traced_check("check judgments", findings) { check_judgments(findings) }
      traced_check("check guard health", findings) { check_guard_health(findings) }
      traced_check("check exceptions", findings) { check_exceptions(findings) }
      traced_check("check editions", findings) { check_editions(findings) }
      traced_check("check effect", findings) { check_effect(findings) }
      if Engine::Settings.lint_doctor?
        traced_check("check lint", findings) { check_lint(findings) }
      else
        Polispec::Trace.info("skipped check lint", reason: "polispec.lint.doctor is off")
      end
      traced_check("check contracts", findings) { check_contracts(ledger, findings) } if ledger
      traced_check("check personal defaults", findings) { check_personal_defaults(ledger, findings) }
      traced_check("check catalog", findings) { check_catalog(findings) }
      traced_check("check web", findings) { check_web(findings) }
      traced_check("check code enforcers", findings) { check_code_enforcers(findings) }
      blocking = findings.reject { |item| NONBLOCKING.include?(item["severity"]) }
      json ? puts(JSON.generate("ok" => blocking.empty?, "runtime" => runtime_info, "findings" => findings)) : print_text(findings)
      blocking.empty? ? 0 : 1
    end

    private

    def traced_check(label, findings, **fields)
      return yield unless Polispec::Trace.on?

      Polispec::Trace.step(label, **fields) do
        before = findings.length
        result = yield
        Polispec::Trace.info("findings", count: findings.length - before)
        result
      end
    end

    def load_ledger(findings)
      path = Ledger.default_path
      unless File.file?(path)
        detail = Ledger.sealed_ledger? ? "no ledger at #{path}; the sealed plane names it; ask the operator" : "no ledger at #{path}; create one with polispec ledger init"
        findings << finding(nil, "ledger_missing", detail)
        return nil
      end
      result = Schema.validate_file("ledger", path)
      result.errors.each { |error| findings << finding(nil, "ledger_invalid", "#{error.pointer} #{error.message}".strip) }
      Ledger.load(path)
    rescue Polispec::Error => e
      findings << finding(nil, "ledger_unreadable", e.message)
      nil
    end

    def check_ledger(ledger, findings)
      ledger.projects.reject { |project| project.status == "retired" }.each do |project|
        traced_check("check project", findings, project: project.id) { check_project(ledger, project, findings) }
      end
    end

    def check_project(ledger, project, findings)
      unless File.directory?(File.expand_path(project.repo))
        findings << finding(project.id, "repo_missing", "#{project.repo} is not a directory")
        return
      end
      loaded = PolicySource.resolve(project, ledger: ledger)
      findings << finding(project.id, loaded.finding["kind"], loaded.finding["detail"]) if loaded.finding
      defaults = loaded.source == "defaults"
      Polispec::Trace.info("policy source", project: project.id, source: loaded.source, status: project.status)
      Operator::Gates.health_required_errors(loaded.policy).each { |message| findings << finding(project.id, "health_required", message) } unless defaults
      Operator::Gates.unreachable_errors(loaded.policy).each { |message| findings << finding(project.id, "gate_unreachable", message) } unless defaults
      Layers.policy_errors(loaded.policy, project: project, ledger: ledger).each { |message| findings << finding(project.id, "layers_invalid", message) }
      check_proof(project, loaded, findings) if project.status == "live" && !defaults
      roster = PolicySource.roster_digest(project)
      Polispec::ValidateProfiles.errors(loaded.policy, project, ledger: ledger).each { |detail| findings << finding(project.id, "profile_check", detail) } unless defaults
      findings << finding(project.id, "roster_missing", "#{project.trust_ref}:#{project.roster} not found") if roster.nil? && !defaults
      AgentsRender.drift(project.repo, project.trust_ref, project).each { |detail| findings << finding(project.id, "agents_drift", detail) } unless defaults
      findings << finding(project.id, "not_live", "status #{project.status}: the guard does not enforce this project") unless project.status == "live"
      check_packages(project, findings)
    end

    def check_proof(project, loaded, findings)
      gap = Proof::Gate.upkeep(policy: loaded.policy, repo: project.repo)
      findings << finding(project.id, gap["kind"], gap["detail"]).merge("severity" => "warn") if gap
    end

    def check_packages(project, findings)
      project.packages.each do |record|
        offered = Packages.latest_version(record["name"])
        if offered && Packages.newer?(offered, record["version"])
          findings << info(project.id, "package_upgrade_available", "#{record['name']} #{offered} is available; #{record['version']} is applied")
        end
        root = File.expand_path(project.repo)
        record["files"].to_h.each do |path, digest|
          file = File.join(root, path)
          next unless File.file?(file)

          findings << info(project.id, "package_file_drift", "#{path} differs from the #{record['name']} #{record['version']} record") unless Packages.sha(File.read(file)) == digest
        end
      end
    rescue Polispec::Error, SystemCallError
      nil
    end

    def check_drain_resume(findings)
      last = {}
      State.read_jsonl("deploys").each do |row|
        resumes = Array(row["drain"]).select { |entry| entry.is_a?(Hash) && entry["phase"] == "resume" }
        last[[row["project"], row["env"]]] = [row, resumes.last] unless resumes.empty?
      end
      last.each do |(project, env), (row, resume)|
        next if resume["exit"].to_i.zero?

        findings << finding(project, "drain_resume_failed", "#{env} queues still paused since deploy #{row['id']} at #{row['at']}: resume exited #{resume['exit']} after #{resume['attempt'] || 1} attempts; run `#{resume['command']}` in #{resume['dir'] || 'the active checkout'}; the next deploy whose resume succeeds clears this").merge("severity" => "warn")
      end
    end

    def info(project, kind, detail)
      finding(project, kind, detail).merge("severity" => "info")
    end

    def check_runtime(findings)
      old = ruby_older_than_floor?(findings)
      findings << finding(nil, "ruby_old", "ruby #{RUBY_VERSION} is older than 2.6") if old
      findings << finding(nil, "state_unwritable", "#{State.home} is not writable") unless writable?(State.home)
      Classify::Registry.families
      Classify::Registry.load_errors.each { |file, message| findings << finding(nil, "classifier_load", "#{file}: #{message}") }
      findings << finding(nil, "classifier_absent", "no classifier family is installed; every call classifies to no action") if Classify::Registry.families.empty?
      CLI.load_all
      CLI.load_errors.each { |file, message| findings << finding(nil, "command_load", "#{file}: #{message}") }
    end

    def ruby_older_than_floor?(findings)
      version = RUBY_VERSION.split(".").first(2).map { |part| Integer(part, 10) }
      version[0] < 2 || (version[0] == 2 && version[1] < 6)
    rescue ArgumentError, TypeError
      findings << finding(nil, "ruby_version_invalid", "ruby version #{RUBY_VERSION.inspect} is not numeric")
      false
    end

    def check_release(findings)
      edition = edition_value(findings)
      version = version_value(findings)
      manifest = manifest_version(findings)
      if version && manifest && version != manifest
        findings << finding(nil, "version_mismatch", "VERSION #{version} differs from manifest version #{manifest}")
      end
      check_edition_provenance(edition, version, manifest, findings) if edition
    end

    def edition_value(findings)
      path = File.join(ROOT, "EDITION")
      stat = File.lstat(path)
      unless stat.file? && !stat.symlink? && stat.size <= 16
        findings << finding(nil, "edition_invalid", "EDITION must be a small regular nonsymlink file")
        return nil
      end
      bytes = File.binread(path, 17)
      return "standard" if bytes == "standard\n"
      return "lock" if bytes == "lock\n"
      findings << finding(nil, "edition_invalid", "EDITION must contain exactly standard or lock followed by one newline")
      nil
    rescue Errno::ENOENT
      findings << finding(nil, "edition_missing", "EDITION is absent")
      nil
    rescue SystemCallError => error
      findings << finding(nil, "edition_invalid", "EDITION cannot be read: #{error.class}: #{error.message}")
      nil
    end

    def version_value(findings)
      path = File.join(ROOT, "VERSION")
      bytes = read_regular(path, "VERSION", findings)
      return nil unless bytes
      unless bytes.match?(/\A\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\n?\z/)
        findings << finding(nil, "version_invalid", "VERSION is not a valid bounded release version")
        return nil
      end
      bytes.chomp
    end

    def manifest_version(findings)
      path = File.join(ROOT, "polispec.rplugin.yml")
      bytes = read_regular(path, "plugin manifest", findings)
      return nil unless bytes
      document = YAML.safe_load(bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
      value = document.is_a?(Hash) ? document["version"] : nil
      unless value.is_a?(String) && value.match?(/\A\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/)
        findings << finding(nil, "manifest_version_invalid", "plugin manifest version is missing or invalid")
        return nil
      end
      value
    rescue Psych::Exception => error
      findings << finding(nil, "manifest_version_invalid", "plugin manifest cannot be parsed: #{error.class}: #{error.message}")
      nil
    end

    def read_regular(path, label, findings)
      stat = File.lstat(path)
      unless stat.file? && !stat.symlink? && stat.size <= FILE_LIMIT
        findings << finding(nil, "release_metadata_invalid", "#{label} must be a bounded regular nonsymlink file")
        return nil
      end
      File.binread(path, FILE_LIMIT + 1)
    rescue SystemCallError => error
      findings << finding(nil, "release_metadata_invalid", "#{label} cannot be read: #{error.class}: #{error.message}")
      nil
    end

    def git_dir
      return ROOT unless Runtime.pinned?

      source = Runtime.release["source"].to_s
      return source if File.directory?(source)

      cache = File.join(NativePin.data_home, "source.git")
      Runtime.release_kind == "native" && File.directory?(cache) ? cache : source
    end

    def check_pinned_digest(findings)
      return true unless Runtime.pinned?
      return true if Runtime.tree_digest(Runtime.root) == Runtime.release["tree_digest"]

      findings << finding(nil, "edition_provenance_invalid", "pinned release differs from its record")
      false
    end

    def check_edition_provenance(edition, version, manifest, findings)
      return unless check_pinned_digest(findings)
      if Runtime.pinned?
        raise GitFailure, "source repository #{git_dir} is unavailable" unless File.directory?(git_dir) && git("rev-parse", "--git-dir", allowed: [0, 128]).status.zero?
        head = git_oid("#{Runtime.release['commit']}^{commit}")
      else
        root = git!("rev-parse", "--show-toplevel").stdout.chomp
        raise GitFailure, "Git top level differs from the plugin root" unless File.realpath(root) == File.realpath(ROOT)
        head = git_oid("HEAD^{commit}")
      end
      committed_edition!(head, edition)
      if version && manifest
        committed_file!(head, "VERSION", File.binread(File.join(ROOT, "VERSION"), FILE_LIMIT + 1))
        committed_file!(head, "polispec.rplugin.yml", File.binread(File.join(ROOT, "polispec.rplugin.yml"), FILE_LIMIT + 1))
      end
      Editions.lock?(edition) ? check_lock_provenance(head) : check_standard_provenance(head)
    rescue GitFailure, SystemCallError => error
      kind = error.message.start_with?("invalid:") ? "edition_provenance_invalid" : "edition_provenance_unavailable"
      findings << finding(nil, kind, error.message.sub(/\Ainvalid:\s*/, ""))
    end

    def check_standard_provenance(head)
      main = required_ref("refs/heads/main")
      return check_on_branch(head, "main") if Runtime.pinned?
      raise GitFailure, "invalid: standard HEAD differs from local main" unless main == head
    end

    def check_on_branch(head, branch)
      result = git("merge-base", "--is-ancestor", head, "refs/heads/#{branch}", allowed: [0, 1])
      return if result.status.zero?
      raise GitFailure, "invalid: pinned release #{head[0, 12]} is not on #{branch} of #{git_dir}"
    end

    def check_lock_provenance(head)
      lock = required_ref("refs/heads/polispec-lock")
      if Runtime.pinned?
        check_on_branch(head, "polispec-lock")
      else
        raise GitFailure, "invalid: lock HEAD differs from local polispec-lock" unless lock == head
      end
      fields = git!("rev-list", "--parents", "-n", "1", head).stdout.split
      valid_parent = fields.length == 2 && fields.all? { |oid| oid.match?(OID) } && fields[0] == head
      raise GitFailure, "invalid: lock commit must have exactly one parent" unless valid_parent
      parent = fields[1]
      committed_edition!(parent, "standard")
      changed = git!("diff-tree", "--no-commit-id", "--name-only", "-r", "-z", parent, head).stdout.split("\0").reject(&:empty?)
      raise GitFailure, "invalid: lock commit tree differs from its parent by more than EDITION" unless changed == ["EDITION"]
    end

    def committed_edition!(commit, expected)
      row = git!("ls-tree", "-z", commit, "--", "EDITION").stdout
      match = row.match(/\A100644 blob ((?:[0-9a-f]{40}|[0-9a-f]{64}))\tEDITION\0\z/)
      raise GitFailure, "invalid: committed EDITION is missing or is not regular mode 100644" unless match
      bytes = git!("show", "#{commit}:EDITION").stdout
      raise GitFailure, "invalid: committed EDITION does not match #{expected}" unless bytes == "#{expected}\n"
    end

    def committed_file!(commit, path, current)
      row = git!("ls-tree", "-z", commit, "--", path).stdout
      pattern = /\A100644 blob ((?:[0-9a-f]{40}|[0-9a-f]{64}))\t#{Regexp.escape(path)}\0\z/
      raise GitFailure, "invalid: committed #{path} is missing or is not regular mode 100644" unless row.match?(pattern)
      bytes = git!("show", "#{commit}:#{path}").stdout
      raise GitFailure, "invalid: working #{path} differs from the checked-out commit" unless bytes == current
    end

    def required_ref(name)
      result = git("show-ref", "--verify", "--hash", name, allowed: [0, 1])
      raise GitFailure, "required local ref #{name} is absent" unless result.status.zero?
      oid = result.stdout.chomp
      raise GitFailure, "invalid: local ref #{name} is malformed" unless oid.match?(OID)
      oid
    end

    def git_oid(expression)
      value = git!("rev-parse", "--verify", expression).stdout.chomp
      raise GitFailure, "invalid: Git object identity is malformed" unless value.match?(OID)
      value
    end

    def git!(*args)
      git(*args, allowed: [0])
    end

    def git(*args, allowed:)
      command = ["git", "--no-optional-locks", "-C", git_dir, *args]
      stdout = +""
      stderr = +""
      status = nil
      git_env = {
        "LC_ALL" => "C", "GIT_TERMINAL_PROMPT" => "0", "GIT_NO_REPLACE_OBJECTS" => "1",
        "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil, "GIT_COMMON_DIR" => nil,
        "GIT_OBJECT_DIRECTORY" => nil, "GIT_ALTERNATE_OBJECT_DIRECTORIES" => nil, "GIT_REPLACE_REF_BASE" => nil,
        "GIT_SHALLOW_FILE" => nil, "GIT_GRAFT_FILE" => nil, "GIT_NAMESPACE" => nil,
        "GIT_CONFIG_PARAMETERS" => nil, "GIT_CONFIG_COUNT" => nil
      }
      started = monotonic
      Polispec::Trace.command(command)
      Open3.popen3(git_env, *command, pgroup: true) do |input, output, error, waiter|
        input.close
        output.binmode
        error.binmode
        streams = { output => stdout, error => stderr }
        deadline = monotonic + GIT_TIMEOUT
        begin
          loop do
            break if !waiter.alive? && streams.empty?
            remaining = deadline - monotonic
            raise GitFailure, "Git provenance command timed out" unless remaining.positive?
            readable = IO.select(streams.keys, nil, nil, [remaining, 0.05].min)&.first
            Array(readable).each do |io|
              loop do
                chunk = io.read_nonblock(4096, exception: false)
                break if chunk == :wait_readable
                if chunk.nil?
                  streams.delete(io)
                  io.close unless io.closed?
                  break
                end
                target = streams.fetch(io)
                raise GitFailure, "Git provenance output exceeded #{GIT_LIMIT} bytes" if target.bytesize + chunk.bytesize > GIT_LIMIT
                target << chunk
              end
            end
          end
        rescue StandardError
          terminate_git(waiter)
          raise
        end
        waiter.join(0)
        status = waiter.value.exitstatus
        Polispec::Trace.exit_line(status, (monotonic - started) * 1000)
      ensure
        [input, output, error].compact.each { |io| io.close unless io.closed? }
      end
      raise GitFailure, "Git provenance command failed" unless allowed.include?(status)
      GitResult.new(stdout, stderr, status)
    rescue SystemCallError => error
      raise GitFailure, "Git provenance is unavailable: #{error.class}: #{error.message}"
    end

    def terminate_git(waiter)
      Process.kill("TERM", -waiter.pid)
      cutoff = monotonic + 0.2
      while monotonic < cutoff && process_group_alive?(waiter.pid)
        IO.select(nil, nil, nil, 0.01)
      end
      Process.kill("KILL", -waiter.pid) if process_group_alive?(waiter.pid)
      waiter.join(0.2)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def process_group_alive?(pid)
      Process.kill(0, -pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def check_plane(findings)
      path = File.join(LIB, "harness_controls", "plane.rb")
      return unless File.file?(path)
      require path
      unless defined?(HarnessControls::Plane) && HarnessControls::Plane.respond_to?(:verify)
        findings << finding(nil, "plane_unavailable", "sealed plane verification API is unavailable")
        return
      end
      plane = HarnessControls::Plane.verify
      case plane["status"]
      when "unsealed"
        nil
      when "broken"
        detail = Array(plane["findings"]).map { |item| item["detail"] || item["code"] }.compact.join("; ")
        findings << finding(nil, "plane_broken", detail.empty? ? "sealed plane is broken" : detail)
      when "active"
        unless plane["green"] == true
          findings << finding(nil, "plane_unverified", "active sealed plane prerequisites are incomplete: #{Array(plane['prerequisites']).join(', ')}")
        end
      else
        findings << finding(nil, "plane_broken", "sealed plane returned an invalid status")
      end
    rescue StandardError => error
      findings << finding(nil, "plane_broken", "sealed plane verification failed: #{error.class}: #{error.message}")
    end

    def writable?(dir)
      FileUtils.mkdir_p(dir, mode: 0o700)
      File.writable?(dir)
    rescue SystemCallError
      false
    end

    def check_judgments(findings)
      Judgments.verify(schema: false)["findings"].each do |item|
        kind = item["kind"] == "truncated" ? "judgments_truncated" : "judgments_chain_broken"
        findings << finding(nil, kind, "#{item['kind']} #{item['id'] || '-'}: #{item['detail']}")
      end
    rescue StandardError => error
      findings << finding(nil, "judgments_unreadable", "#{error.class}: #{error.message}")
    end

    def check_guard_health(findings)
      current = GuardHealth.line
      findings << finding(nil, "guard_failing", current) if current
    end

    def check_exceptions(findings)
      problem = Exceptions.load.problems.first
      findings << finding(nil, "exceptions_invalid", problem) if problem
    rescue StandardError => error
      findings << finding(nil, "exceptions_invalid", "#{error.class}: #{error.message}")
    end

    def check_editions(findings)
      Editions.check.each do |item|
        where = item.line ? "#{item.file}:#{item.line}" : item.file
        findings << finding(nil, "editions_drift", "#{item.kind} #{where} #{item.detail}").merge("severity" => "warn")
      end
    rescue StandardError => error
      findings << finding(nil, "editions_drift", "#{error.class}: #{error.message}").merge("severity" => "warn")
    end

    def check_contracts(ledger, findings)
      require_relative "../contract"
      release = Description.installed_release
      return unless release && (release <=> Contract::FLOOR) == -1

      ledger.projects.reject { |project| project.status == "retired" }.each do |project|
        repo = File.expand_path(project.repo)
        worktree = Dir.glob(File.join(repo, Contract::DIR, "*.yml")).any?
        committed = !Environments.git(repo, "ls-tree", "--name-only", "#{project.trust_ref}:#{Contract::DIR}").to_s.strip.empty?
        next unless worktree || committed

        findings << finding(project.id, "contract_ahead_of_runtime", "the working tree or #{project.trust_ref} holds contract files but the installed release is #{release.join('.')}, older than #{Contract::FLOOR.join('.')}; that runtime reports them as unknown").merge("severity" => "warn")
      end
    rescue StandardError => error
      findings << finding(nil, "contract_ahead_of_runtime", "#{error.class}: #{error.message}").merge("severity" => "info")
    end

    def check_catalog(findings)
      state = Catalog.state
      if state["invalid"]
        findings << finding(nil, "catalog_state_invalid", "#{state['invalid']}; every gate counts on until it is fixed")
        return
      end
      findings << info(nil, "catalog_none_active", "no catalog spec is active on this host; polispec catalog list") if Array(state["active"]).empty?
      Array(state["active"]).each do |entry|
        sub = Catalog.spec(entry["spec"])&.subspecs&.find { |item| item.id == entry["subspec"] }
        next unless sub&.provision

        record = Array(state["provisioned"]).find { |item| item["spec"] == entry["spec"] && item["subspec"] == entry["subspec"] }
        path = record && File.join(Catalog.state_dir, record["file"].to_s)
        next if path && File.file?(path) && Digest::SHA256.file(path).hexdigest == record["sha256"]

        findings << finding(nil, "catalog_provision_missing", "#{entry['spec']}/#{entry['subspec']} is active but its provisioned file is missing or changed").merge("severity" => "warn")
      end
    rescue StandardError => e
      findings << finding(nil, "catalog_state_invalid", "#{e.class}: #{e.message}")
    end

    def check_web(findings)
      detail = Web::Server.stale
      findings << finding(nil, "web_stale", "#{detail}; restart polispec web so it serves the installed release").merge("severity" => "warn") if detail
    end

    def check_personal_defaults(ledger, findings)
      PersonalDefaults.findings(ledger: ledger).each do |hit|
        findings << finding(nil, "personal_default", "#{hit['file']}:#{hit['line']} names #{hit['token']} (#{hit['source']})").merge("severity" => "warn")
      end
    rescue StandardError => error
      findings << finding(nil, "personal_default", "#{error.class}: #{error.message}").merge("severity" => "info")
    end

    def check_descriptions(ledger, findings)
      findings.concat(Description.doctor_findings(ledger))
    end

    def check_effect(findings)
      findings.concat(Effect.doctor_findings)
    end

    def check_lint(findings)
      report = Lint.run(host: true, for_doctor: true, ref: :trust, only: %w[schema hygiene drift refs])
      reported = findings.select { |item| %w[layers_invalid gate_unreachable].include?(item["kind"]) }.map { |item| [item["project"], item["detail"]] }
      report.findings.each do |item|
        next if item.code == "schema_invalid" && reported.include?([item.project, item.message])

        detail = "#{item.path}#{item.line ? ":#{item.line}" : ''} #{item.message}"
        entry = finding(item.project, "lint_#{item.code}", detail)
        entry = entry.merge("severity" => item.severity) unless item.severity == "error"
        findings << entry
      end
    rescue StandardError => error
      findings << finding(nil, "lint_unavailable", "#{error.class}: #{error.message}").merge("severity" => "info")
    end

    def check_code_enforcers(findings)
      pack = code_pack
      return unless pack

      pack.rules.select(&:active?).each do |rule|
        rule.requires.each do |entry|
          id = entry["plugin"].to_s
          root = PluginStore.root(id)
          unless root
            findings << finding(nil, "code_enforcer_unresolved", "#{rule.id} enforcer #{rule.enforcer['ref']} requires plugin #{id}, not installed at #{PluginStore.path(id)}")
            next
          end

          requirement = entry["version"].to_s
          installed = PluginStore.version(root)
          next if PluginStore.satisfies?(installed, requirement)

          findings << finding(nil, "code_enforcer_version_skew", "#{rule.id} requires #{id} #{requirement}, installed #{installed || 'no VERSION file'}")
        end
      end
    rescue StandardError => error
      findings << finding(nil, "code_enforcer_unavailable", "#{error.class}: #{error.message}").merge("severity" => "info")
    end

    def code_pack
      require_relative "../code/core"
      require_relative "../harness_controls/plane"
      plane = HarnessControls::Plane.respond_to?(:resolve) ? HarnessControls::Plane.resolve : { "status" => "unsealed" }
      ref = plane["status"] == "active" ? nil : ENV["POLISPEC_CODE_REF"]
      pack = Code::Pack.load(ref: ref)
      pack.specs.empty? ? nil : pack
    rescue Code::Error, SystemCallError
      nil
    end

    def check_ledger_runtime(ledger, findings)
      keys = []
      keys << "paths" unless Array(ledger.paths).empty?
      keys << "owner" if Array(ledger.projects).any?(&:owner) || Array(ledger.paths).any?(&:owner)
      keys << "registered_by" if Array(ledger.projects).any?(&:registered_by) || Array(ledger.paths).any?(&:registered_by)
      return if keys.empty?

      release = Description.installed_release
      return unless Description.ahead_of_runtime?(release)

      findings << finding(nil, "ledger_ahead_of_runtime", "the ledger uses #{keys.join(', ')} but the installed release is #{release.join('.')}, older than 0.35.0; that runtime rejects the ledger (additionalProperties false); install 0.35.0 first").merge("severity" => "warn")
    rescue StandardError => error
      findings << finding(nil, "ledger_ahead_of_runtime", "#{error.class}: #{error.message}").merge("severity" => "info")
    end

    def finding(project, kind, detail)
      { "project" => project, "kind" => kind, "detail" => detail }
    end

    def runtime_info
      { "kind" => Runtime.kind, "commit" => Runtime.commit, "root" => Runtime.root, "release_ref" => Runtime.release && Runtime.release["ref"] }
    end

    def print_text(findings)
      puts "runtime: #{Runtime.kind}#{Runtime.release_kind == 'native' ? ' (native)' : ''} #{Runtime.commit ? Runtime.commit[0, 12] : '-'} #{Runtime.root}"
      blocking = findings.reject { |item| NONBLOCKING.include?(item["severity"]) }
      if findings.empty?
        puts "polispec doctor: 0 findings"
      else
        notes = findings.length - blocking.length
        puts "polispec doctor: #{findings.length} finding#{'s' unless findings.length == 1}#{" (#{blocking.length} blocking, #{notes} info)" if notes.positive?}"
        findings.each { |item| puts "  #{item['project'] || '-'}  #{item['kind']}#{NONBLOCKING.include?(item['severity']) ? " (#{item['severity']})" : ''}  #{item['detail']}" }
      end
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("doctor", Polispec::DoctorCommand, summary: "check the ledger, trust-ref policies, state and classifier")
