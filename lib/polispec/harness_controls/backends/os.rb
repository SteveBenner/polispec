#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../backends"
require_relative "../contracts"
require_relative "../language"
require_relative "../../harness/base"

module Polispec
  module HarnessControls
    module Backends
      module Os
        BWRAP = "/usr/bin/bwrap"
        CONFIG_LIMIT = 65_536
        PROBE_LIMIT = 65_536
        PROBE_TIMEOUT = 10
        SCOPES = %w[project user managed].freeze
        EDITIONS = %w[standard lock].freeze

        module_function

        def plan(document, context = {})
          validate_document!(document)
          context = stringify(context)
          scope = scope_for(context)
          edition = edition_for(context)
          paths = artifact_paths(scope, context)
          runtime, runtime_findings = runtime_argv(context, scope)
          controls = canonical_value(document)
          control_digest = Digest::SHA256.hexdigest(canonical_json(controls))
          control_ids = Array(controls["controls"]).map { |control| control["id"].to_s }.sort
          controls_content = JSON.pretty_generate(controls) + "\n"
          restrictions = compile_restrictions(controls, scope, context, edition)
          findings = runtime_findings + restrictions["findings"]
          unless File.executable?(BWRAP)
            findings << finding("bubblewrap_unavailable", "The required bubblewrap executable #{BWRAP} is absent or not executable.", nil, "os.executable", "Install a supported native sandbox before relying on OS containment.")
          end
          artifacts = [artifact(paths["controls"], controls_content, "json", "control_document", [""], control_ids)]

          if runtime && restrictions["compilable"]
            sandbox = sandbox_document(runtime, restrictions, edition)
            content = JSON.pretty_generate(canonical_value(sandbox)) + "\n"
            raise Polispec::Error, "generated OS sandbox plan exceeds #{CONFIG_LIMIT} bytes" if content.bytesize > CONFIG_LIMIT

            artifacts << artifact(paths["sandbox"], content, "json", "exclusive", [""], control_ids)
            findings << finding("native_os_probe_required", "The bubblewrap plan is generated but namespace startup, filesystem denial, and network behavior are not yet native-verified.", nil, "os.sandbox", "Run the bounded scratch probe before treating any containment axis as supported.")
          else
            findings << finding("os_sandbox_plan_unavailable", "A runnable OS sandbox artifact was not generated because required runtime or restriction prerequisites are unavailable.", nil, "os.sandbox", "Resolve every reported prerequisite and plan again.")
          end

          findings.concat(control_findings(controls, restrictions))
          operation_material = [control_digest, "os", scope, edition] + artifacts.map { |item| item["path"] }.sort
          {
            "schema" => "polispec.harness.plan/v1",
            "operation_id" => Digest::SHA256.hexdigest(operation_material.join("\0")),
            "control_digest" => control_digest,
            "edition" => edition,
            "harness" => "os",
            "scope" => scope,
            "artifacts" => artifacts,
            "capabilities" => capabilities_for(controls, restrictions, !runtime.nil?),
            "authority" => authority(scope),
            "findings" => findings
          }
        end

        def normalize(_native_event)
          raise Unavailable.new(:normalize, "os sandbox backend")
        end

        def render(_verdict, _native_event = nil)
          raise Unavailable.new(:render, "os sandbox backend")
        end

        def probe(receipt, runner = nil)
          sandbox = sandbox_from(receipt)
          return unavailable_probes("No installed OS sandbox artifact was supplied.") unless sandbox
          return unavailable_probes("The planned bubblewrap executable is absent or not executable.") unless File.file?(sandbox["executable"].to_s) && File.executable?(sandbox["executable"].to_s)
          return unavailable_probes("No bounded native runner was supplied.") unless runner

          prefix = validated_probe_prefix(sandbox)
          readiness = run_probe(runner, prefix + ["/usr/bin/true"])
          unless readiness["exit_status"] == 0
            evidence = readiness["stderr"].to_s.include?("No permissions to create a new namespace") ? "user_namespaces_unavailable" : "sandbox_start_failed"
            return [
              probe_row("filesystem", "unavailable", evidence, "Bubblewrap could not start an isolated namespace; no filesystem denial is certified."),
              probe_row("network", "unavailable", evidence, "Bubblewrap could not start an isolated namespace; no network behavior is certified.")
            ]
          end

          filesystem = filesystem_probe(sandbox, receipt, runner, prefix)
          network = probe_row("network", "unverified", "namespace_started", sandbox.dig("network", "mode") == "deny" ? "A network namespace started without host sharing, but no bounded egress observation was supplied." : "The standard plan shares the host network by design; containment is not claimed.")
          [filesystem, network]
        rescue StandardError => error
          unavailable_probes("OS probe failed safely: #{error.class}: #{error.message}")
        end

        def validate_document!(document)
          raise Polispec::Error, "control document must be a JSON object" unless document.is_a?(Hash)
          errors = Language.validate(document)
          return if errors.empty?

          first = errors.first
          raise Polispec::Error, "invalid control document at #{first['pointer']}: #{first['message']}"
        end
        private_class_method :validate_document!

        def scope_for(context)
          scope = context["scope"].to_s
          raise Polispec::Error, "OS scope must be project, user, or managed" unless SCOPES.include?(scope)

          scope
        end
        private_class_method :scope_for

        def edition_for(context)
          edition = context["edition"].to_s
          edition = "standard" if edition.empty?
          raise Polispec::Error, "OS edition must be standard or lock" unless EDITIONS.include?(edition)

          edition
        end
        private_class_method :edition_for

        def artifact_paths(scope, context)
          case scope
          when "project"
            project = context["project"].to_s
            raise Polispec::Error, "project scope requires an absolute project path" unless absolute_path?(project)
            base = File.join(project, ".polispec", "harness", "os")
          when "user"
            home = File.expand_path(context["home"].to_s.empty? ? Dir.home : context["home"].to_s)
            raise Polispec::Error, "user home must resolve to an absolute path" unless absolute_path?(home)
            base = File.join(home, ".config", "polispec", "harness", "os")
          else
            base = "/etc/polispec/harness/os"
          end
          { "controls" => File.join(base, "controls.json"), "sandbox" => File.join(base, "sandbox.json") }
        end
        private_class_method :artifact_paths

        def runtime_argv(context, scope)
          runtime = context["runtime_argv"]
          if runtime
            valid = runtime.is_a?(Array) && !runtime.empty? && runtime.all? { |item| item.is_a?(String) && !item.empty? && !item.include?("\0") } && absolute_path?(runtime.first)
            raise Polispec::Error, "runtime_argv must be a nonempty absolute-executable argv prefix" unless valid
            return [runtime.dup, []]
          end

          path = context["runtime_path"].to_s
          path = File.join(ROOT, "bin", "polispec") if path.empty? && scope != "managed"
          if path.empty?
            return [nil, [finding("managed_runtime_required", "Managed OS sandbox planning requires a verified absolute runtime argv.", nil, "os.runtime", "Supply runtime_argv from verified plane authority.")]]
          end
          raise Polispec::Error, "runtime_path must be absolute" unless absolute_path?(path)

          [[path], []]
        end
        private_class_method :runtime_argv

        def compile_restrictions(document, scope, context, edition)
          path_entries = []
          network_entries = []
          findings = []
          unsupported = false
          Array(document["controls"]).each do |control|
            next unless control["effect"] == "restrict"

            params = control["effect_params"] || {}
            unless control["trigger"] == "pre_tool" && control.fetch("match", {}).empty?
              unsupported = true
              findings << finding("conditional_os_restriction_unsupported", "Control #{control['id']} cannot be converted to a global OS sandbox without changing its trigger or predicates.", control["id"], "os.sandbox", "Use one unconditional restriction or retain callback-level enforcement.")
              next
            end
            paths = params["paths"]
            path_entries << normalize_paths(paths) if paths.is_a?(Hash)
            network = params["network"]
            network_entries << normalize_network(network) if network.is_a?(Hash)
          end

          paths, path_conflict = identical_or_refused(path_entries)
          network, network_conflict = identical_or_refused(network_entries)
          if path_conflict
            unsupported = true
            findings << finding("conflicting_os_path_restrictions", "Distinct path restrictions cannot be intersected safely by the bounded bubblewrap compiler.", nil, "os.filesystem", "Use one unconditional path restriction set.")
          end
          if network_conflict
            unsupported = true
            findings << finding("conflicting_os_network_restrictions", "Distinct network modes or allowlists cannot be combined without widening a control.", nil, "os.network", "Use one unconditional network restriction set.")
          end

          if paths && !paths["read"].empty?
            unsupported = true
            findings << finding("os_read_allowlist_unsupported", "Bubblewrap cannot express the declared read allowlist while retaining the pinned runtime and required libraries with this bounded compiler.", nil, "os.filesystem", "Use callback enforcement or a native policy compiler with verified read-path support.")
          end
          if paths && paths["write"].any? { |path| glob_path?(path) }
            unsupported = true
            findings << finding("os_write_glob_unsupported", "Bubblewrap bind mounts require concrete paths; declared write globs were not expanded or executed.", nil, "os.filesystem", "Use concrete absolute writable paths or callback enforcement.")
          end
          if edition == "standard" && network && network["mode"] == "allowlist"
            unsupported = true
            findings << finding("os_domain_allowlist_unsupported", "Bubblewrap network namespaces cannot enforce a domain allowlist.", nil, "os.network", "Use a verified native proxy allowlist or lock empty-network mode.")
          end

          default_writes = scope == "project" && paths.nil? ? [context["project"].to_s] : []
          writes = paths ? paths["write"] : default_writes
          {
            "compilable" => !unsupported,
            "writable_paths" => writes,
            "path_declared" => !paths.nil?,
            "network_declared" => !network.nil?,
            "network_mode" => edition == "lock" ? "deny" : "open",
            "findings" => findings
          }
        end
        private_class_method :compile_restrictions

        def normalize_paths(paths)
          { "read" => Array(paths["read"]).uniq.sort, "write" => Array(paths["write"]).uniq.sort }
        end
        private_class_method :normalize_paths

        def normalize_network(network)
          mode = network["mode"]
          { "mode" => mode, "domains" => mode == "allowlist" ? Array(network["domains"]).uniq.sort : [] }
        end
        private_class_method :normalize_network

        def identical_or_refused(entries)
          return [nil, false] if entries.empty?

          distinct = entries.uniq
          return [distinct.first, false] if distinct.length == 1

          [nil, true]
        end
        private_class_method :identical_or_refused

        def sandbox_document(runtime, restrictions, edition)
          mode = edition == "lock" ? "deny" : "open"
          argv = bwrap_prefix(restrictions["writable_paths"], mode)
          {
            "schema" => "polispec.os-sandbox/v1",
            "backend" => "bubblewrap",
            "executable" => BWRAP,
            "argv_prefix" => argv,
            "runtime_argv" => runtime,
            "launch_argv" => argv + runtime,
            "filesystem" => { "root" => "read_only", "writable_paths" => restrictions["writable_paths"].sort },
            "network" => { "mode" => mode, "allowlist" => [] },
            "certified" => false
          }
        end
        private_class_method :sandbox_document

        def bwrap_prefix(writable_paths, network_mode)
          argv = [BWRAP, "--die-with-parent", "--new-session", "--unshare-all"]
          argv << "--share-net" if network_mode == "open"
          argv.concat(["--ro-bind", "/", "/"])
          writable_paths.sort.each { |path| argv.concat(["--bind", path, path]) }
          argv.concat(["--proc", "/proc", "--dev", "/dev", "--"])
        end
        private_class_method :bwrap_prefix

        def validated_probe_prefix(sandbox)
          raise Polispec::Error, "invalid OS sandbox schema" unless sandbox["schema"] == "polispec.os-sandbox/v1"
          raise Polispec::Error, "invalid OS sandbox backend" unless sandbox["backend"] == "bubblewrap" && sandbox["executable"] == BWRAP
          filesystem = stringify(sandbox["filesystem"])
          raise Polispec::Error, "invalid OS sandbox filesystem root" unless filesystem["root"] == "read_only"
          writable_paths = filesystem["writable_paths"]
          valid_paths = writable_paths.is_a?(Array) && writable_paths.length <= 256 && writable_paths.all? { |path| absolute_path?(path) && !glob_path?(path) } && writable_paths == writable_paths.uniq.sort
          raise Polispec::Error, "invalid OS sandbox writable paths" unless valid_paths
          network = stringify(sandbox["network"])
          raise Polispec::Error, "invalid OS sandbox network" unless %w[open deny].include?(network["mode"]) && network["allowlist"] == []
          expected = bwrap_prefix(writable_paths, network["mode"])
          raise Polispec::Error, "OS sandbox argv_prefix does not match the bounded plan" unless sandbox["argv_prefix"] == expected

          expected
        end
        private_class_method :validated_probe_prefix

        def capabilities_for(document, restrictions, runtime_available)
          generated = restrictions["compilable"] && runtime_available
          rows = Array(document["controls"]).map do |control|
            if control["trigger"] == "schedule"
              capability(control["id"], "os.schedule", "supported", "The schedule module can produce a verify-only Rplugin::ScheduleJob after lifecycle authorization.")
            elsif control["effect"] == "restrict" && control["trigger"] == "pre_tool" && control.fetch("match", {}).empty? && generated
              capability(control["id"], "os.sandbox", "generated", "The unconditional restriction is represented in the bubblewrap plan; native execution remains unverified.")
            else
              capability(control["id"], "os.sandbox", "unsupported", "This control cannot be enforced by the generated process-level OS sandbox.")
            end
          end
          rows.concat([
            capability(nil, "os.executable", File.executable?(BWRAP) ? "supported" : "unavailable", File.executable?(BWRAP) ? "Bubblewrap is present; namespace startup still requires a live probe." : "Bubblewrap is absent or not executable."),
            capability(nil, "os.filesystem", generated ? "generated" : "unsupported", generated ? "A read-only root and explicit writable binds are generated; denial remains unverified." : "Filesystem restrictions were not safely compiled."),
            capability(nil, "os.network", generated ? "generated" : "unsupported", restrictions["network_mode"] == "deny" ? "Lock emits an unshared network namespace with an empty allowlist; egress remains unverified." : "Standard explicitly shares the host network and claims no egress containment.")
          ])
          rows
        end
        private_class_method :capabilities_for

        def control_findings(document, restrictions)
          Array(document["controls"]).each_with_object([]) do |control, result|
            if control["trigger"] == "schedule"
              result << finding("schedule_lifecycle_required", "Scheduled control #{control['id']} requires an installation receipt before the schedule port job can be planned or installed.", control["id"], "os.schedule", "Invoke Schedule.install only after lifecycle authorization and prepared transaction state.")
              next
            end
            next if control["effect"] == "restrict" && restrictions["compilable"] && control["trigger"] == "pre_tool" && control.fetch("match", {}).empty?

            result << finding("unsupported_os_control", "OS sandbox planning does not enforce #{control['trigger']} #{control['effect']} control #{control['id']}.", control["id"], "os.sandbox", "Use a native harness callback or an unconditional supported OS restriction.")
          end
        end
        private_class_method :control_findings

        def sandbox_from(receipt)
          values = stringify(receipt.respond_to?(:to_h) ? receipt.to_h : receipt)
          return stringify(values["sandbox"]) if values["sandbox"].is_a?(Hash)

          artifact = Array(values["artifacts"]).find { |item| item.is_a?(Hash) && item["path"].to_s.end_with?("/sandbox.json") }
          return nil unless artifact

          JSON.parse(artifact["content"].to_s)
        rescue JSON::ParserError
          nil
        end
        private_class_method :sandbox_from

        def filesystem_probe(sandbox, receipt, runner, prefix)
          values = stringify(receipt.respond_to?(:to_h) ? receipt.to_h : receipt)
          root = values["probe_root"].to_s
          unless safe_scratch_root?(root)
            return probe_row("filesystem", "unavailable", "scratch_root_required", "A safe absolute probe_root under /tmp is required for the denial journey.")
          end

          outside_dir = File.join(root, "outside")
          unless File.executable?("/usr/bin/ruby") && safe_scratch_root?(outside_dir)
            return probe_row("filesystem", "unavailable", "scratch_fixture_required", "The fixed Ruby probe runtime and pre-created inert outside directory are required.")
          end

          outside = File.join(outside_dir, "blocked.txt")
          return probe_row("filesystem", "unavailable", "scratch_target_exists", "The outside probe target already exists and will not be overwritten.") if File.exist?(outside) || File.symlink?(outside)

          program = "begin; File.open(ARGV.fetch(0), File::WRONLY|File::CREAT|File::EXCL){|f| f.write(\"blocked\\n\")}; STDOUT.write(\"POLISPEC_OS_WRITE_SUCCEEDED\\n\"); exit 72; rescue Errno::EACCES, Errno::EROFS, Errno::EPERM; STDOUT.write(\"POLISPEC_OS_DENIED\\n\"); exit 73; rescue; STDERR.write(\"POLISPEC_OS_ERROR\\n\"); exit 74; end"
          result = run_probe(runner, prefix + ["/usr/bin/ruby", "-e", program, outside])
          return probe_row("filesystem", "failed", "outside_write_created_target", "The sandbox created the outside probe target.") if File.exist?(outside) || File.symlink?(outside)
          if result["exit_status"] == 73 && result["stdout"].to_s == "POLISPEC_OS_DENIED\n"
            return probe_row("filesystem", "supported", "outside_write_denied", "A native bubblewrap invocation returned the dedicated permission-denial sentinel without creating the outside target.")
          end
          if result["exit_status"] == 72 && result["stdout"].to_s == "POLISPEC_OS_WRITE_SUCCEEDED\n"
            return probe_row("filesystem", "failed", "outside_write_succeeded", "The sandbox reported that the outside write succeeded.")
          end

          probe_row("filesystem", "unavailable", "probe_result_unrecognized", "The fixed denial probe returned no recognized permission-denial evidence.")
        end
        private_class_method :filesystem_probe

        def safe_scratch_root?(path)
          return false unless path.start_with?("/tmp/") && !path.split("/").include?("..") && File.directory?(path)
          expanded = File.expand_path(path)
          return false unless File.realpath(path) == expanded

          components = expanded.split(File::SEPARATOR).reject(&:empty?)
          current = File::SEPARATOR
          components.each do |component|
            current = File.join(current, component)
            return false if File.lstat(current).symlink?
          end
          true
        rescue SystemCallError
          false
        end
        private_class_method :safe_scratch_root?

        def run_probe(runner, argv)
          stringify(runner.call(argv, timeout: PROBE_TIMEOUT, max_output: PROBE_LIMIT))
        rescue StandardError => error
          { "stdout" => "", "stderr" => "#{error.class}: #{error.message}", "exit_status" => 1 }
        end
        private_class_method :run_probe

        def unavailable_probes(detail)
          [probe_row("filesystem", "unavailable", "not_observed", detail), probe_row("network", "unavailable", "not_observed", detail)]
        end
        private_class_method :unavailable_probes

        def probe_row(axis, status, evidence, detail)
          { "axis" => axis, "status" => status, "evidence" => evidence, "detail" => detail }
        end
        private_class_method :probe_row

        def authority(scope)
          { "kind" => scope == "managed" ? "operator_required" : "same_user", "protected" => false, "certified" => false, "detail" => scope == "managed" ? "Installing and protecting the sandbox plan requires operator authority." : "The generated plan and runtime remain same-user mutable." }
        end
        private_class_method :authority

        def artifact(path, content, format, kind, entries, control_ids)
          { "path" => path, "content" => content, "digest" => Digest::SHA256.hexdigest(content), "format" => format, "ownership" => { "kind" => kind, "entries" => entries, "control_ids" => control_ids } }
        end
        private_class_method :artifact

        def capability(control_id, name, disposition, detail)
          { "control_id" => control_id, "capability" => name, "disposition" => disposition, "detail" => detail }
        end
        private_class_method :capability

        def finding(code, detail, control_id, capability_name, next_step)
          { "code" => code, "detail" => detail, "control_id" => control_id, "harness" => "os", "capability" => capability_name, "next_step" => next_step }
        end
        private_class_method :finding

        def canonical_json(value)
          JSON.generate(canonical_value(value))
        end
        private_class_method :canonical_json

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
        private_class_method :canonical_value

        def stringify(value)
          return {} unless value.is_a?(Hash)

          value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
        end
        private_class_method :stringify

        def glob_path?(path)
          path.to_s.match?(/[\*\?\[\]\{\}]/)
        end
        private_class_method :glob_path?

        def absolute_path?(path)
          path.is_a?(String) && path.start_with?(File::SEPARATOR) && !path.include?("\0")
        end
        private_class_method :absolute_path?
      end

      register("os", Os)
    end
  end
end
