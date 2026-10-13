#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "yaml"
require "digest"
require "fileutils"
require "open3"
require "timeout"
require "rbconfig"
require "shellwords"

module Polispec
  module HarnessControls
    module Authority
      ROOT_PATH = "/etc/polispec"
      SOURCE_PATH = "/etc/polispec/source"
      RUNTIME_PATH = "/usr/local/lib/polispec"
      RECORDS_PATH = "/var/lib/polispec"
      MAX_FILE = 1_048_576
      MAX_BUNDLE = 16_777_216
      COMMAND_TIMEOUT = 10
      MAX_COMMAND_OUTPUT = 16_777_216
      MAX_FILES = 20_000
      MAX_RUNTIME_BYTES = 67_108_864
      ALLOWED_ROOTS = %w[ledger.yml settings.json controls global code_specs].freeze
      IGNORED_ENV = %w[
        POLISPEC_ROOT POLISPEC_LEDGER POLISPEC_EDITION POLISPEC_RUNTIME POLISPEC_SOURCE
        RPLUGIN_HOME RUBYLIB RUBYOPT GEM_HOME GEM_PATH BUNDLE_GEMFILE BUNDLE_PATH
        LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH
      ].freeze

      class Failure < Polispec::Error
        attr_reader :code, :findings

        def initialize(code, message, findings = [])
          @code = code.to_s
          @findings = findings
          super(message)
        end
      end

      module_function

      def seal_plan(kind:, source:, revision: nil)
        source_plan = kind.to_s == "git" ? git_source_plan(source, revision) : lock_source_plan(source)
        runtime = runtime_plan
        findings = source_plan["findings"] + runtime["findings"]
        lock = kind.to_s != "git"
        findings << finding("lock_launch_proof_unresolved", "Lock requires independently verified pre-interpreter process-loading provenance.", true) if lock
        findings << finding("native_harness_evidence_missing", "Required native harness denial and failure axes are not verified.", lock)
        findings << finding("os_containment_evidence_missing", "Kernel sandbox containment evidence has not been supplied.", lock)
        generation_material = {
          "edition" => kind.to_s == "git" ? "standard" : "lock",
          "runtime_digest" => runtime["digest"],
          "source_digest" => source_plan["digest"],
          "source_ref" => source_plan["ref"]
        }
        {
          "schema" => "polispec.plane.seal-plan/v1",
          "edition" => generation_material["edition"],
          "generation" => Digest::SHA256.hexdigest(canonical_json(generation_material))[0, 32],
          "source" => source_plan,
          "runtime" => runtime,
          "findings" => findings,
          "preparation_ready" => source_plan["findings"].none? { |item| item["blocking"] == true },
          "ready" => findings.none? { |item| item["blocking"] == true },
          "bootstrap_required" => true
        }
      end

      def git_source_plan(repo, revision)
        path = File.expand_path(repo.to_s)
        raise Failure.new("invalid_source", "source repository must be an existing directory") unless File.directory?(path)
        raise Failure.new("invalid_source", "a full committed Git revision is required") unless revision && !revision.to_s.empty?

        commit = git(path, "rev-parse", "--verify", "#{revision}^{commit}").strip
        raise Failure.new("invalid_source", "Git did not resolve a full commit") unless commit.match?(/\A[0-9a-f]{40,64}\z/)
        files = git_entries(path, commit, bundle_only: true)
        bundle = validate_bundle(files) { |relative| git_blob(path, commit, relative) }
        findings = bundle.delete("findings")
        manifest = source_manifest("git", commit, files, bundle)
        {
          "kind" => "git",
          "root" => path,
          "ref" => commit,
          "digest" => digest_manifest(manifest),
          "manifest" => manifest,
          "bundle" => bundle,
          "findings" => findings
        }
      rescue Failure
        raise
      rescue StandardError => error
        raise Failure.new("invalid_source", "cannot inspect committed Git source: #{error.message}")
      end

      def lock_source_plan(source)
        path = File.expand_path(source.to_s)
        findings = []
        findings << finding("lock_source_fixed_path", "Lock source must be authored directly at #{SOURCE_PATH}.", true) unless path == SOURCE_PATH
        findings.concat(protection_findings(path, "lock_source"))
        files = filesystem_entries(path)
        files.each { |entry| findings.concat(protection_findings(File.join(path, entry["path"]), "lock_source_file")) }
        bundle = validate_bundle(files) { |relative| bounded_read(File.join(path, relative)) }
        findings.concat(bundle.delete("findings"))
        manifest = source_manifest("root_authored", path, files, bundle)
        {
          "kind" => "root_authored",
          "root" => path,
          "ref" => path,
          "digest" => digest_manifest(manifest),
          "manifest" => manifest,
          "bundle" => bundle,
          "findings" => findings
        }
      rescue Failure
        raise
      rescue StandardError => error
        raise Failure.new("invalid_source", "cannot inspect lock source: #{error.message}")
      end

      def runtime_plan(root: RUNTIME_PATH, require_protected: true)
        commit = git(ROOT, "rev-parse", "--verify", "HEAD^{commit}").strip
        files = git_entries(ROOT, commit, bundle_only: false)
        manifest = files.map { |entry| entry.slice("path", "mode", "type", "digest", "size") }
        source_digest = digest_manifest(manifest)
        descriptor_path = File.join(root, "runtime.json")
        descriptor = runtime_descriptor(descriptor_path)
        release = descriptor["release"] || File.join(root, "releases", commit)
        launcher = descriptor["launcher"] || File.join(root, "bin", "polispec")
        sdk = descriptor["sdk"] || "/usr/local/lib/rplugin"
        interpreter = descriptor["interpreter"] || launcher_interpreter(launcher)
        findings = []
        findings << finding("runtime_metadata_missing", "Protected runtime metadata is missing at #{descriptor_path}.", true) if descriptor.empty?
        findings.concat(protection_findings(descriptor_path, "runtime_metadata")) if require_protected && File.exist?(descriptor_path)
        findings << finding("runtime_launcher_path", "Runtime metadata must use the fixed launcher #{File.join(root, 'bin', 'polispec')}.", true) unless launcher == File.join(root, "bin", "polispec")
        if descriptor["source_commit"] && descriptor["source_commit"] != commit
          findings << finding("runtime_commit_mismatch", "Protected runtime metadata does not name the exact committed polispec release.", true)
        end
        findings << finding("runtime_release_missing", "Pinned runtime release is missing at #{release}.", true) unless File.directory?(release)
        if File.exist?(release)
          findings.concat(protection_findings(release, "runtime_release")) if require_protected
          findings.concat(verify_release(files, release))
        end
        findings << finding("sealed_launcher_missing", "Sealed launcher is missing at #{launcher}.", true) unless File.file?(launcher)
        findings.concat(protection_findings(launcher, "sealed_launcher")) if require_protected && File.exist?(launcher)
        if interpreter
          findings.concat(protection_findings(interpreter, "interpreter")) if require_protected
        else
          findings << finding("protected_interpreter_unresolved", "The sealed launcher does not select a validated absolute interpreter.", true)
        end
        if File.file?(launcher) && interpreter && descriptor["release"] && descriptor["sdk"]
          expected_launcher = launcher_content(interpreter, File.join(release, "bin", "polispec"), sdk)
          findings << finding("launcher_contract_mismatch", "Sealed launcher does not implement the deterministic sanitized absolute launch contract.", true) unless File.binread(launcher) == expected_launcher
        end
        findings << finding("protected_sdk_missing", "Independent protected rplugin SDK is missing at #{sdk}.", true) unless File.exist?(sdk)
        findings.concat(protection_findings(sdk, "protected_sdk")) if require_protected && File.exist?(sdk)
        sanitized = descriptor["sanitized_before_interpreter"] == true
        loader = "unresolved"
        findings << finding("launcher_sanitization_unverified", "Protected launcher sanitization before interpreter startup is unverified.", true) unless sanitized
        findings << finding("launch_proof_unresolved", "Inherited dynamic-loader behavior before sanitization has not been proven safe; certification remains unavailable.", false) unless loader == "verified"
        record = {
          "source_commit" => commit,
          "source_digest" => source_digest,
          "release" => metadata(release),
          "launcher" => metadata(launcher),
          "entrypoint" => metadata(File.join(release, "bin", "polispec")),
          "interpreter" => metadata(interpreter),
          "sdk" => metadata(sdk),
          "runtime_metadata" => metadata(descriptor_path),
          "sanitized_before_interpreter" => sanitized,
          "inherited_loader_provenance" => loader.empty? ? "unresolved" : loader
        }
        {
          "commit" => commit,
          "digest" => Digest::SHA256.hexdigest(canonical_json(record)),
          "manifest" => manifest,
          "provenance" => record,
          "runtime_argv" => [launcher],
          "findings" => findings
        }
      rescue Failure
        raise
      rescue StandardError => error
        {
          "commit" => nil,
          "digest" => nil,
          "manifest" => [],
          "provenance" => {},
          "runtime_argv" => [],
          "findings" => [finding("runtime_source_unavailable", "Cannot inspect the separately pinned runtime source: #{error.message}", true)]
        }
      end

      def prepare_runtime(destination: RUNTIME_PATH, interpreter: "/usr/bin/ruby", sdk: "/usr/local/lib/rplugin", development: false)
        root = File.expand_path(destination.to_s)
        unless development
          bootstrap_identity!("seal.runtime.prepare")
          raise Failure.new("invalid_destination", "protected runtime destination is fixed at #{RUNTIME_PATH}") unless root == RUNTIME_PATH
          findings = protection_findings(interpreter, "bootstrap_interpreter")
          raise Failure.new("protected_interpreter_required", "runtime preparation requires a protected absolute interpreter", findings) unless findings.empty?
        end
        raise Failure.new("invalid_interpreter", "runtime interpreter must be an absolute regular file") unless interpreter.to_s.start_with?("/") && File.file?(interpreter)
        commit = git(ROOT, "rev-parse", "--verify", "HEAD^{commit}").strip
        entries = git_entries(ROOT, commit, bundle_only: false)
        release = File.join(root, "releases", commit)
        entries.each do |entry|
          target = File.join(release, entry["path"])
          bytes = git_blob(ROOT, commit, entry["path"])
          if entry["type"] == "symlink"
            link_target = bytes.to_s
            invalid = link_target.start_with?("/") || link_target.split("/").include?("..") || link_target.include?("\0")
            raise Failure.new("runtime_symlink_unsafe", "runtime symlink #{entry['path']} has an unsafe target") if invalid
            FileUtils.mkdir_p(File.dirname(target), mode: 0o755)
            if File.symlink?(target)
              raise Failure.new("runtime_conflict", "runtime symlink #{target} has a conflicting target") unless File.readlink(target) == link_target
            elsif File.exist?(target)
              raise Failure.new("runtime_conflict", "runtime symlink target #{target} already exists")
            else
              File.symlink(link_target, target)
            end
          else
            write_exact(target, bytes, entry["mode"] & 0o777)
          end
        end
        launcher = File.join(root, "bin", "polispec")
        launcher_bytes = launcher_content(File.realpath(interpreter), File.join(release, "bin", "polispec"), sdk)
        write_exact(launcher, launcher_bytes, 0o755)
        descriptor = {
          "schema" => "polispec.runtime.bootstrap/v1",
          "source_commit" => commit,
          "release" => release,
          "launcher" => launcher,
          "interpreter" => File.realpath(interpreter),
          "sdk" => File.expand_path(sdk),
          "sanitized_before_interpreter" => true,
          "inherited_loader_provenance" => "unresolved"
        }
        write_exact(File.join(root, "runtime.json"), JSON.pretty_generate(canonical_value(descriptor)) + "\n", 0o600)
        planned = runtime_plan(root: root, require_protected: !development)
        { "development" => development == true, "root" => root, "commit" => commit, "launcher" => launcher, "runtime" => planned }
      end

      def development_prepare_runtime(destination:, interpreter: RbConfig.ruby, sdk: "/tmp/polispec-development-rplugin")
        prepare_runtime(destination: destination, interpreter: interpreter, sdk: sdk, development: true)
      end

      def operator!(operation, plane: nil)
        raise Failure.new("operator_required", "#{operation} requires effective uid 0") unless Process.euid.zero?
        plane ||= defined?(Plane) ? Plane.resolve : nil
        unless plane.is_a?(Hash) && plane["status"] == "active"
          raise Failure.new("operator_required", "#{operation} requires an active protected plane and re-execution through its sealed launcher")
        end
        current_launcher = realpath_or_nil($PROGRAM_NAME)
        current_interpreter = realpath_or_nil(RbConfig.ruby)
        provenance = plane.dig("provenance", "runtime") || {}
        expected_launcher = provenance.dig("entrypoint", "realpath")
        expected_interpreter = provenance.dig("interpreter", "realpath")
        unless current_launcher && current_launcher == expected_launcher && current_interpreter && current_interpreter == expected_interpreter
          raise Failure.new("operator_required", "#{operation} requires verified sealed launcher and interpreter provenance")
        end
        findings = protection_findings(current_launcher, "current_entrypoint") + protection_findings(current_interpreter, "current_interpreter")
        raise Failure.new("operator_required", "#{operation} lacks complete protected executable provenance", findings) if findings.any? { |item| item["blocking"] }

        provenance_material = {
          "euid" => Process.euid,
          "executable" => current_launcher,
          "interpreter" => current_interpreter,
          "generation" => plane["generation"],
          "entrypoint_metadata" => metadata(current_launcher),
          "interpreter_metadata" => metadata(current_interpreter)
        }
        {
          "euid" => Process.euid,
          "executable" => current_launcher,
          "interpreter" => current_interpreter,
          "operation" => operation.to_s,
          "generation" => plane["generation"],
          "authentication" => "effective_uid_and_protected_provenance",
          "fresh_password_proven" => false,
          "inherited_loader_provenance" => provenance["inherited_loader_provenance"].to_s.empty? ? "unresolved" : provenance["inherited_loader_provenance"],
          "provenance_digest" => Digest::SHA256.hexdigest(canonical_json(provenance_material))
        }
      end

      def bootstrap_identity!(operation)
        raise Failure.new("operator_required", "#{operation} bootstrap preparation requires effective uid 0") unless Process.euid.zero?
        {
          "euid" => Process.euid,
          "operation" => operation.to_s,
          "bootstrap_only" => true,
          "certified" => false
        }
      end

      def protection_findings(path, domain)
        return [finding("#{domain}_missing", "#{path} does not exist.", true)] unless path && File.exist?(path)
        findings = []
        ancestry(path).each do |entry|
          stat = File.lstat(entry)
          findings << finding("#{domain}_symlink", "#{entry} is a symlink.", true) if stat.symlink?
          findings << finding("#{domain}_owner", "#{entry} is owned by uid #{stat.uid}, not uid 0.", true) unless stat.uid.zero?
          findings << finding("#{domain}_writable", "#{entry} is group- or world-writable.", true) unless (stat.mode & 0o022).zero?
        rescue SystemCallError => error
          findings << finding("#{domain}_unreadable", "Cannot inspect #{entry}: #{error.message}", true)
        end
        findings
      end

      def protected?(path)
        protection_findings(path, "path").empty?
      end

      def verify_materialized_source(root, manifest)
        findings = []
        expected = Array(manifest["files"])
        expected_paths = expected.map { |entry| entry["path"] }.sort
        actual_paths = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.each_with_object([]) do |path, rows|
          next if [".", ".."].include?(File.basename(path)) || File.directory?(path)
          rows << path.delete_prefix("#{root}/")
        end.sort
        findings << finding("source_file_set_mismatch", "Materialized source file set differs from its canonical manifest.", true) unless actual_paths == expected_paths
        expected.each do |entry|
          path = File.join(root, entry["path"])
          unless File.file?(path) && !File.symlink?(path)
            findings << finding("source_file_missing", "Materialized source #{entry['path']} is missing or unsafe.", true)
            next
          end
          findings << finding("source_file_digest", "Materialized source #{entry['path']} differs from planned bytes.", true) unless Digest::SHA256.file(path).hexdigest == entry["digest"]
          mode = File.stat(path).mode & 0o777
          findings << finding("source_file_mode", "Materialized source #{entry['path']} differs from planned mode.", true) unless mode == (entry["mode"] & 0o777)
        end
        findings
      end

      def current_metadata(path)
        metadata(path)
      end

      def write_atomic(path, bytes, mode: 0o600)
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir, mode: 0o700)
        temp = File.join(dir, ".#{File.basename(path)}.tmp-#{Process.pid}-#{rand(1_000_000)}")
        File.open(temp, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
          file.write(bytes)
          file.flush
          file.fsync
        end
        File.rename(temp, path)
        File.open(dir, File::RDONLY) { |file| file.fsync }
        path
      ensure
        File.unlink(temp) if defined?(temp) && temp && File.exist?(temp)
      end

      def canonical_json(value)
        JSON.generate(canonical_value(value))
      end

      def canonical_value(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
            source = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
            result[key] = canonical_value(value[source])
          end
        when Array
          value.map { |item| canonical_value(item) }
        else
          value
        end
      end

      def finding(code, detail, blocking)
        { "code" => code, "detail" => detail, "blocking" => blocking == true }
      end

      def validate_bundle(files)
        paths = files.map { |entry| entry["path"] }
        paths.each do |path|
          validate_relative!(path)
          root = path.split("/", 2).first
          raise Failure.new("invalid_bundle", "unknown authority bundle entry #{path}") unless ALLOWED_ROOTS.include?(root)
          raise Failure.new("invalid_bundle", "authority bundle contains symlink #{path}") if files.find { |item| item["path"] == path }["type"] == "symlink"
        end
        controls = paths.select { |path| path.match?(%r{\Acontrols/[^/]+\.json\z}) }
        findings = []
        findings << finding("ledger_missing", "Authority bundle requires ledger.yml.", true) unless paths.include?("ledger.yml")
        findings << finding("controls_missing", "Authority bundle requires at least one controls/HARNESS.json document.", true) if controls.empty?
        total = 0
        if paths.include?("ledger.yml")
          ledger = parse_yaml(yield("ledger.yml"), "ledger.yml")
          ledger_errors = Schema.validate("ledger", ledger)
          raise Failure.new("invalid_bundle", "ledger.yml is invalid: #{ledger_errors.first.pointer} #{ledger_errors.first.message}") unless ledger_errors.empty?
        end
        settings = {}
        if paths.include?("settings.json")
          settings = parse_json(yield("settings.json"), "settings.json")
          raise Failure.new("invalid_bundle", "settings.json must contain a machine settings object") unless settings.is_a?(Hash) && settings.keys.all? { |key| key.is_a?(String) }
        end
        control_map = {}
        controls.sort.each do |path|
          name = File.basename(path, ".json")
          raise Failure.new("invalid_bundle", "unknown harness #{name}") unless Backends.names.include?(name)
          bytes = yield(path)
          total += bytes.bytesize
          document = parse_json(bytes, path)
          errors = Controls.validate(document)
          unless errors.empty?
            first = errors.first
            raise Failure.new("invalid_bundle", "#{path} is invalid at #{first['pointer']}: #{first['message']}")
          end
          control_map[name] = { "path" => path, "digest" => Digest::SHA256.hexdigest(bytes) }
        end
        files.each do |entry|
          bytes = yield(entry["path"])
          raise Failure.new("oversized_bundle", "#{entry['path']} exceeds #{MAX_FILE} bytes") if bytes.bytesize > MAX_FILE
          total += bytes.bytesize unless controls.include?(entry["path"])
        end
        raise Failure.new("oversized_bundle", "authority bundle exceeds #{MAX_BUNDLE} bytes") if total > MAX_BUNDLE
        {
          "ledger_digest" => paths.include?("ledger.yml") ? Digest::SHA256.hexdigest(yield("ledger.yml")) : nil,
          "settings" => settings,
          "controls" => control_map,
          "has_global" => paths.any? { |path| path.start_with?("global/") },
          "has_code_specs" => paths.any? { |path| path.start_with?("code_specs/") },
          "findings" => findings
        }
      end
      private_class_method :validate_bundle

      def source_manifest(kind, reference, files, bundle)
        {
          "schema" => "polispec.plane.source-manifest/v1",
          "kind" => kind,
          "ref" => reference,
          "files" => files.map { |entry| entry.slice("path", "mode", "digest", "size") }.sort_by { |entry| entry["path"] },
          "bundle" => bundle
        }
      end
      private_class_method :source_manifest

      def digest_manifest(manifest)
        Digest::SHA256.hexdigest(canonical_json(manifest))
      end
      private_class_method :digest_manifest

      def git_entries(repo, commit, bundle_only:)
        output = git(repo, "ls-tree", "-r", "-z", "--full-tree", commit)
        rows = output.split("\0").reject(&:empty?)
        raise Failure.new("manifest_too_large", "Git manifest exceeds #{MAX_FILES} files") if rows.length > MAX_FILES
        total = 0
        entries = rows.map do |row|
          head, path = row.split("\t", 2)
          mode, type, = head.split(" ", 3)
          next if bundle_only && !bundle_path?(path)
          bytes = git_blob(repo, commit, path)
          total += bytes.bytesize
          raise Failure.new("manifest_too_large", "Git manifest exceeds #{MAX_RUNTIME_BYTES} bytes") if total > MAX_RUNTIME_BYTES
          { "path" => path, "mode" => mode.to_i(8), "type" => mode == "120000" ? "symlink" : type, "digest" => Digest::SHA256.hexdigest(bytes), "size" => bytes.bytesize }
        end.compact
        entries.sort_by { |entry| entry["path"] }
      end
      private_class_method :git_entries

      def filesystem_entries(root)
        raise Failure.new("missing_prerequisite", "source directory is missing at #{root}") unless File.directory?(root)
        entries = []
        Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
          next if [".", ".."].include?(File.basename(path))
          relative = path.delete_prefix("#{root}/")
          stat = File.lstat(path)
          next if stat.directory?
          bytes = stat.symlink? ? "" : bounded_read(path)
          entries << { "path" => relative, "mode" => stat.mode & 0o7777, "type" => stat.symlink? ? "symlink" : "blob", "digest" => Digest::SHA256.hexdigest(bytes), "size" => bytes.bytesize }
        end
        entries
      end
      private_class_method :filesystem_entries

      def bundle_path?(path)
        ALLOWED_ROOTS.include?(path.split("/", 2).first)
      end
      private_class_method :bundle_path?

      def validate_relative!(path)
        invalid = path.nil? || path.empty? || path.start_with?("/") || path.include?("\0") || path.split("/").any? { |part| part == ".." || part.empty? }
        raise Failure.new("invalid_bundle", "invalid authority bundle path #{path.inspect}") if invalid
      end
      private_class_method :validate_relative!

      def parse_json(bytes, name)
        value = JSON.parse(bytes)
        raise Failure.new("invalid_bundle", "#{name} must contain an object") unless value.is_a?(Hash)
        value
      rescue JSON::ParserError => error
        raise Failure.new("invalid_bundle", "#{name} is invalid JSON: #{error.message}")
      end
      private_class_method :parse_json

      def parse_yaml(bytes, name)
        value = YAML.safe_load(bytes, permitted_classes: [Date, Time], aliases: false)
        raise Failure.new("invalid_bundle", "#{name} must contain a mapping") unless value.is_a?(Hash)
        value
      rescue Psych::Exception => error
        raise Failure.new("invalid_bundle", "#{name} is invalid YAML: #{error.message}")
      end
      private_class_method :parse_yaml

      def git(repo, *args)
        output, error, status = capture(["git", "-C", repo, *args])
        raise Failure.new("git_failed", error.strip.empty? ? "git #{args.first} failed" : error.strip) unless status.success?
        output
      end
      private_class_method :git

      def git_blob(repo, commit, path)
        validate_relative!(path)
        output, error, status = capture(["git", "-C", repo, "show", "#{commit}:#{path}"])
        raise Failure.new("git_failed", error.strip.empty? ? "cannot read #{path} from #{commit}" : error.strip) unless status.success?
        raise Failure.new("oversized_bundle", "#{path} exceeds #{MAX_FILE} bytes") if output.bytesize > MAX_FILE
        output
      end
      private_class_method :git_blob

      def capture(argv)
        stdout = +""
        stderr = +""
        status = nil
        Open3.popen3(*argv) do |stdin, out, err, waiter|
          stdin.close
          readers = [[out, stdout], [err, stderr]].map do |io, target|
            Thread.new do
              loop do
                chunk = io.readpartial(16_384)
                target << chunk
                raise Failure.new("subprocess_output_limit", "#{argv.first} output exceeds #{MAX_COMMAND_OUTPUT} bytes") if target.bytesize > MAX_COMMAND_OUTPUT
              end
            rescue EOFError
              nil
            end
          end
          unless waiter.join(COMMAND_TIMEOUT)
            Process.kill("TERM", waiter.pid) rescue nil
            waiter.join(1)
            Process.kill("KILL", waiter.pid) rescue nil if waiter.alive?
            raise Failure.new("subprocess_timeout", "#{argv.first} exceeded #{COMMAND_TIMEOUT} seconds")
          end
          readers.each(&:value)
          status = waiter.value
        end
        [stdout, stderr, status]
      rescue Timeout::Error
        raise Failure.new("subprocess_timeout", "#{argv.first} exceeded #{COMMAND_TIMEOUT} seconds")
      end
      private_class_method :capture

      def bounded_read(path)
        raise Failure.new("invalid_bundle", "#{path} is not a regular file") unless File.file?(path) && !File.symlink?(path)
        size = File.size(path)
        raise Failure.new("oversized_bundle", "#{path} exceeds #{MAX_FILE} bytes") if size > MAX_FILE
        File.binread(path)
      end
      private_class_method :bounded_read

      def launcher_interpreter(path)
        return nil unless File.file?(path) && !File.symlink?(path)
        first = File.open(path, "rb", &:gets).to_s.strip
        return nil unless first.start_with?("#!/")
        candidate = first.delete_prefix("#!").split(/\s+/, 2).first
        return nil unless candidate.start_with?("/") && File.file?(candidate)
        File.realpath(candidate)
      rescue SystemCallError
        nil
      end
      private_class_method :launcher_interpreter

      def launcher_content(interpreter, entrypoint, sdk)
        unset = %w[RUBYLIB RUBYOPT GEM_HOME GEM_PATH BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_BIN_PATH LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH RPLUGIN_HOME]
        [
          "#!/bin/sh",
          "unset #{unset.join(' ')}",
          "export RPLUGIN_HOME=#{Shellwords.escape(File.expand_path(sdk))}",
          "exec #{Shellwords.escape(File.realpath(interpreter))} #{Shellwords.escape(File.expand_path(entrypoint))} \"$@\""
        ].join("\n") + "\n"
      end
      private_class_method :launcher_content

      def write_exact(path, bytes, mode)
        if File.exist?(path) || File.symlink?(path)
          raise Failure.new("runtime_conflict", "runtime target #{path} is not a regular owned file") unless File.file?(path) && !File.symlink?(path)
          existing = File.binread(path)
          raise Failure.new("runtime_conflict", "runtime target #{path} has conflicting bytes") unless existing == bytes
          return path
        end
        FileUtils.mkdir_p(File.dirname(path), mode: 0o755)
        write_atomic(path, bytes, mode: mode)
        File.chmod(mode, path)
        path
      end
      private_class_method :write_exact

      def runtime_descriptor(path)
        return {} unless File.file?(path) && !File.symlink?(path)
        data = JSON.parse(bounded_read(path))
        return {} unless data.is_a?(Hash)
        %w[release launcher interpreter sdk].each do |key|
          value = data[key]
          raise Failure.new("runtime_metadata_invalid", "runtime metadata #{key} must be an absolute path") if value && (!value.is_a?(String) || !value.start_with?("/") || value.include?("\0"))
        end
        data
      rescue JSON::ParserError => error
        raise Failure.new("runtime_metadata_invalid", "runtime metadata is malformed: #{error.message}")
      end
      private_class_method :runtime_descriptor

      def verify_release(files, release)
        findings = []
        expected_paths = files.map { |entry| entry["path"] }.sort
        actual_paths = Dir.glob(File.join(release, "**", "*"), File::FNM_DOTMATCH).sort.each_with_object([]) do |path, rows|
          next if [".", ".."].include?(File.basename(path)) || File.directory?(path) && !File.symlink?(path)
          rows << path.delete_prefix("#{release}/")
        end.sort
        findings << finding("runtime_release_file_set", "Pinned runtime contains missing or extra entries.", true) unless actual_paths == expected_paths
        files.each do |entry|
          path = File.join(release, entry["path"])
          current = release
          entry["path"].split("/")[0...-1].each do |part|
            current = File.join(current, part)
            findings << finding("runtime_release_symlink_ancestry", "Pinned runtime path #{entry['path']} has symlinked intermediate ancestry.", true) if File.symlink?(current)
          end
          if entry["type"] == "symlink"
            unless File.symlink?(path) && Digest::SHA256.hexdigest(File.readlink(path)) == entry["digest"]
              findings << finding("runtime_release_symlink", "Pinned runtime symlink #{entry['path']} differs from committed provenance.", true)
            end
            next
          end
          unless File.file?(path) && !File.symlink?(path)
            findings << finding("runtime_release_incomplete", "Pinned runtime is missing #{entry['path']}.", true)
            next
          end
          actual = Digest::SHA256.file(path).hexdigest
          findings << finding("runtime_release_digest", "Pinned runtime file #{entry['path']} does not match its committed bytes.", true) unless actual == entry["digest"]
          mode = File.stat(path).mode & 0o777
          findings << finding("runtime_release_mode", "Pinned runtime file #{entry['path']} has mode #{mode.to_s(8)}, expected #{(entry['mode'] & 0o777).to_s(8)}.", true) unless mode == (entry["mode"] & 0o777)
        end
        findings
      end
      private_class_method :verify_release

      def metadata(path)
        return { "path" => path, "present" => false } unless path && File.exist?(path)
        stat = File.stat(path)
        result = { "path" => path, "realpath" => File.realpath(path), "uid" => stat.uid, "mode" => stat.mode & 0o7777, "present" => true }
        result["digest"] = stat.file? ? Digest::SHA256.file(path).hexdigest : tree_digest(path)
        result
      rescue SystemCallError => error
        { "path" => path, "present" => false, "error" => error.message }
      end
      private_class_method :metadata

      def tree_digest(root)
        rows = Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).sort.each_with_object([]) do |path, result|
          next if [".", ".."].include?(File.basename(path))
          stat = File.lstat(path)
          relative = path.delete_prefix("#{root}/")
          row = { "path" => relative, "mode" => stat.mode & 0o7777, "type" => stat.ftype }
          row["digest"] = Digest::SHA256.file(path).hexdigest if stat.file? && !stat.symlink?
          row["digest"] = Digest::SHA256.hexdigest(File.readlink(path)) if stat.symlink?
          result << row
        end
        Digest::SHA256.hexdigest(canonical_json(rows))
      end
      private_class_method :tree_digest

      def ancestry(path)
        expanded = File.expand_path(path)
        list = []
        current = expanded
        loop do
          list << current
          break if current == "/"
          current = File.dirname(current)
        end
        list.reverse
      end
      private_class_method :ancestry

      def realpath_or_nil(path)
        File.realpath(path)
      rescue SystemCallError
        nil
      end
      private_class_method :realpath_or_nil
    end
  end
end
