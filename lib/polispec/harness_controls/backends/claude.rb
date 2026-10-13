require "digest"
require "json"
require "pathname"

require_relative "../backends"
require_relative "../contracts"
require_relative "../language"
require_relative "../../harness/base"

module Polispec
  module HarnessControls
    module Backends
      module Claude
        MINIMUM_FAILURE_CLOSED_VERSION = [2, 1, 295].freeze
        MINIMUM_SANDBOX_VERSION = [2, 1, 285].freeze
        SCOPES = %w[project user managed].freeze
        EDITIONS = %w[standard lock].freeze

        module_function

        def plan(document, context = {})
          context = stringify_hash(context)
          validation_errors = Language.validate(document)
          unless validation_errors.empty?
            details = validation_errors.map { |error| error.is_a?(Hash) ? error["message"] || error.inspect : error.to_s }
            raise Polispec::Error, "invalid control document: #{details.join("; ")}"
          end
          scope = context.fetch("scope", "project").to_s
          edition = context.fetch("edition", "standard").to_s
          raise Polispec::Error, "unsupported Claude control scope: #{scope}" unless SCOPES.include?(scope)
          raise Polispec::Error, "unsupported Claude control edition: #{edition}" unless EDITIONS.include?(edition)

          project = absolute_directory(context["project"], "project") if scope == "project"
          home = absolute_directory(context.fetch("home", Dir.home), "home")
          settings_path, controls_path = paths_for(scope, project, home)
          runtime_argv = runtime_argv_for(context)
          control_ids = document.fetch("controls").map { |control| control.fetch("id") }.sort
          controls_content = artifact_content(document)
          version = parse_version(context["version"])
          version_state = failure_closed_version_state(context["version"], version)
          restrictions = restrictions_for(document, edition)
          callback = runtime_argv + ["hook", "pretool", "--harness", "claude", "--controls-file", controls_path]
          settings = settings_fragment(
            scope: scope,
            callback: callback,
            failure_closed: version_state == "supported",
            settings_path: settings_path,
            controls_path: controls_path,
            runtime_argv: runtime_argv,
            restrictions: restrictions
          )
          settings_content = artifact_content(settings)
          artifacts = [
            artifact(
              path: controls_path,
              content: controls_content,
              format: "json",
              ownership: {
                "kind" => "control_document",
                "entries" => ["/"],
                "control_ids" => control_ids
              }
            ),
            artifact(
              path: settings_path,
              content: settings_content,
              format: "json",
              ownership: {
                "kind" => "json_entries",
                "entries" => settings_ownership_entries(settings, callback),
                "control_ids" => control_ids
              }
            )
          ]
          capabilities = capabilities_for(document, version, version_state, restrictions)
          findings = findings_for(
            document: document,
            context: context,
            scope: scope,
            edition: edition,
            version_state: version_state,
            runtime_argv: runtime_argv,
            settings_path: settings_path,
            controls_path: controls_path,
            restrictions: restrictions
          )
          control_digest = Digest::SHA256.hexdigest(controls_content)
          operation_material = {
            "artifact_paths" => artifacts.map { |item| item.fetch("path") }.sort,
            "control_digest" => control_digest,
            "edition" => edition,
            "harness" => "claude-code",
            "scope" => scope
          }

          {
            "schema" => "polispec.harness.plan/v1",
            "operation_id" => Digest::SHA256.hexdigest(JSON.generate(operation_material)),
            "control_digest" => control_digest,
            "edition" => edition,
            "harness" => "claude-code",
            "scope" => scope,
            "artifacts" => artifacts,
            "capabilities" => capabilities,
            "authority" => authority_for(scope, edition, runtime_argv, context),
            "findings" => findings
          }
        end

        def normalize(payload)
          payload = JSON.parse(payload) if payload.is_a?(String)
          raise Polispec::Error, "Claude hook input must be a JSON object" unless payload.is_a?(Hash)

          input = stringify_hash(payload)
          event = input["hook_event_name"] || input["event"]
          raise Polispec::Error, "Claude hook event must be PreToolUse" unless event == "PreToolUse"

          tool_name = input["tool_name"]
          tool_input = input["tool_input"]
          cwd = input["cwd"]
          raise Polispec::Error, "Claude hook input requires tool_name" unless tool_name.is_a?(String) && !tool_name.empty?
          raise Polispec::Error, "Claude hook input requires object tool_input" unless tool_input.is_a?(Hash)
          raise Polispec::Error, "Claude hook cwd must be a string" unless cwd.nil? || cwd.is_a?(String)

          Harness::Input.new(
            tool_name: tool_name,
            tool_input: tool_input,
            cwd: cwd,
            session_id: optional_string(input["session_id"], "session_id"),
            agent_type: optional_string(input["agent_type"], "agent_type"),
            event: event
          )
        rescue JSON::ParserError => e
          raise Polispec::Error, "invalid Claude hook JSON: #{e.message}"
        end

        def render(verdict, event = nil)
          verdict = verdict.to_h if verdict.respond_to?(:to_h) && !verdict.is_a?(Hash)
          verdict = stringify_hash(verdict)
          native_event = event.is_a?(Hash) ? stringify_hash(event)["hook_event_name"] || stringify_hash(event)["event"] : event
          raise Polispec::Error, "Claude render event must be PreToolUse" unless native_event.nil? || native_event == "PreToolUse"

          decision = (verdict["decision"] || verdict["level"]).to_s
          reason = verdict["reason"].to_s
          next_step = verdict["next_step"].to_s
          reason = "#{reason} #{next_step}" unless next_step.empty?
          reason = "polispec denied an unrecognized control verdict" if reason.empty? && !%w[allow deny ask warn].include?(decision)
          output = case decision
                   when "allow"
                     ""
                   when "ask", "warn"
                     JSON.generate(native_decision("ask", reason))
                   else
                     JSON.generate(native_decision("deny", reason))
                   end
          {
            "stdout" => output,
            "stderr" => "",
            "exit_status" => 0
          }
        end

        def probe(_context = {}, _runner = nil)
          [
            probe_axis("hook_dispatch", "An isolated Claude runtime did not invoke the generated PreToolUse hook."),
            probe_axis("hook_failure_closed", "No native failure or timeout journey established onFailure:block behavior."),
            probe_axis("config_provenance", "No native runtime evidence established which Claude settings files were loaded."),
            probe_axis("runtime_provenance", "No protected interpreter and SDK ancestry evidence was supplied."),
            probe_axis("sandbox_filesystem", "No native filesystem denial journey was executed."),
            probe_axis("sandbox_network", "No native network denial journey was executed.")
          ]
        end

        def settings_fragment(scope:, callback:, failure_closed:, settings_path:, controls_path:, runtime_argv:, restrictions:)
          hook = {
            "type" => "command",
            "command" => callback.first,
            "args" => callback.drop(1),
            "timeout" => 10
          }
          hook["onFailure"] = "block" if failure_closed
          deny_paths = ([settings_path, controls_path] + runtime_argv.select { |value| value.start_with?("/") }).uniq.sort
          filesystem = {
            "denyWrite" => deny_paths,
            "denyRead" => deny_paths
          }
          filesystem["allowRead"] = restrictions.fetch("read_paths") unless restrictions.fetch("read_paths").empty?
          filesystem["allowWrite"] = restrictions.fetch("write_paths") unless restrictions.fetch("write_paths").empty?
          filesystem["allowManagedReadPathsOnly"] = true if scope == "managed"
          sandbox = {
            "enabled" => true,
            "failIfUnavailable" => true,
            "allowUnsandboxedCommands" => false,
            "enableWeakerNestedSandbox" => false,
            "filesystem" => filesystem
          }
          network = restrictions.fetch("network")
          sandbox["network"] = network unless network.empty?
          settings = {
            "hooks" => {
              "PreToolUse" => [
                {
                  "matcher" => "*",
                  "hooks" => [hook]
                }
              ]
            },
            "permissions" => {
              "deny" => deny_paths.flat_map { |path| ["Edit(/#{path})", "Read(/#{path})"] }.sort
            },
            "sandbox" => sandbox
          }
          settings["allowManagedHooksOnly"] = true if scope == "managed"
          settings
        end

        def restrictions_for(document, edition)
          read_paths = []
          write_paths = []
          domains = []
          network_allowlist = false
          document.fetch("controls").each do |control|
            next unless control.fetch("effect") == "restrict"

            params = control.fetch("effect_params")
            paths = params["paths"]
            if paths
              read_paths.concat(Array(paths["read"]))
              write_paths.concat(Array(paths["write"]))
            end
            network_params = params["network"]
            if network_params && network_params["mode"] == "allowlist"
              network_allowlist = true
              domains.concat(Array(network_params["domains"]))
            end
          end
          network = if edition == "lock"
                      {
                        "allowedDomains" => [],
                        "allowManagedDomainsOnly" => true,
                        "strictAllowlist" => true,
                        "allowUnixSockets" => [],
                        "allowAllUnixSockets" => false
                      }
                    elsif network_allowlist
                      {
                        "allowedDomains" => domains.uniq.sort,
                        "strictAllowlist" => true,
                        "allowAllUnixSockets" => false
                      }
                    else
                      {}
                    end
          {
            "read_paths" => read_paths.uniq.sort,
            "write_paths" => write_paths.uniq.sort,
            "network" => network
          }
        end

        def capabilities_for(document, version, version_state, restrictions)
          document.fetch("controls").flat_map do |control|
            rows = []
            trigger = control.fetch("trigger")
            trigger_state = "unavailable"
            if trigger == "schedule"
              rows << capability(control, "schedule", "unsupported", "Claude hooks do not provide a native schedule trigger; the rplugin schedule port must dispatch it.")
            elsif trigger != "pre_tool"
              rows << capability(control, "trigger.#{trigger}", "unsupported", "The generated Claude adapter handles only PreToolUse events.")
            else
              trigger_state = version_state
              rows << capability(
                control,
                "hook.pre_tool",
                version_state,
                failure_closed_detail(version_state)
              )
            end
            effect = control.fetch("effect")
            effect_state, effect_detail = effect_disposition(effect, trigger_state)
            rows << capability(control, "effect.#{effect}", effect_state, effect_detail)
            if control.fetch("effect") == "restrict"
              sandbox_state = sandbox_version_state(version)
              detail = if sandbox_state == "supported"
                         "Claude sandbox settings are generated as defense in depth; the PreToolUse callback remains the per-control authority, and native evidence is still required."
                       elsif sandbox_state == "unsupported"
                         "The declared Claude version predates the supported sandbox configuration surface."
                       else
                         "The Claude version is missing or unparseable, so sandbox support is unverified."
                       end
              params = control.fetch("effect_params")
              rows << capability(control, "sandbox.filesystem", sandbox_state, detail) if params.key?("paths")
              rows << capability(control, "sandbox.network", sandbox_state, detail) if params.key?("network")
              if params.dig("paths", "write") && !Array(params.dig("paths", "write")).empty?
                rows << capability(control, "sandbox.filesystem.write_allowlist", "unverified", "Claude does not expose a managed-only write-path allowlist switch; the hook must enforce each control and native denial evidence is required.")
              end
            end
            rows
          end.sort_by { |row| [row.fetch("control_id"), row.fetch("capability")] }
        end

        def findings_for(document:, context:, scope:, edition:, version_state:, runtime_argv:, settings_path:, controls_path:, restrictions:)
          findings = []
          if version_state == "unverified"
            findings << finding("claude_version_unverified", "Claude version is missing or unparseable; onFailure:block support is unverified.", nil, "hook.pre_tool", "Supply an independently verified Claude Code version at or above 2.1.295.")
          elsif version_state == "unsupported"
            findings << finding("claude_version_unsupported", "The declared Claude version predates failure-closed onFailure:block support.", nil, "hook.pre_tool", "Upgrade Claude Code to 2.1.295 or later before treating the hook as failure closed.")
          end
          if scope != "managed"
            findings << finding("mutable_settings_scope", "#{scope} settings can be changed by the same user who runs Claude Code.", nil, "config.provenance", "Use managed settings with independently verified ownership for enforcement claims.")
          end
          if scope == "managed"
            inventory = managed_consequence_inventory(context["existing"])
            detail = "allowManagedHooksOnly blocks user, project, local, plugin, and frontmatter hooks; narrows statusLine, fileSuggestion, and subagentStatusLine commands; disables command-source plugins and headersHelper commands; and makes /goal unavailable."
            detail = "#{detail} allowManagedReadPathsOnly ignores read-path additions outside managed settings, and allowUnsandboxedCommands false prevents repository settings from widening the sandbox."
            detail = "#{detail} Lock edition also ignores domain additions outside managed settings." if edition == "lock"
            detail = "#{detail} Existing lower-scope inventory: #{inventory.join(", ")}." unless inventory.empty?
            detail = "#{detail} Existing lower-scope hook inventory was not supplied." if inventory.empty?
            findings << finding("managed_hook_consequences", detail, nil, "config.managed_hooks", "Review the consequence inventory before applying the managed artifact.")
          end
          unless protected_runtime_supplied?(context, runtime_argv)
            findings << finding("runtime_ancestry_unverified", "The callback has no verified protected interpreter and separately protected SDK ancestry.", nil, "runtime.provenance", "Supply runtime_argv from the verified plane authority with protected interpreter, launcher, and SDK evidence.")
          end
          if edition == "lock" && scope != "managed"
            findings << finding("lock_scope_unenforceable", "Lock edition settings outside managed scope remain mutable by the user.", nil, "edition.lock", "Generate the lock edition in managed scope with operator authority.")
          end
          unless restrictions.fetch("write_paths").empty?
            findings << finding("write_allowlist_hook_authority", "Claude sandbox settings cannot lock write allowlists to managed configuration; the callback enforces these paths.", nil, "sandbox.filesystem.write_allowlist", "Require native hook denial and timeout evidence before certification.")
          end
          findings << finding("native_probe_required", "The plan and generated JSON do not establish native hook, provenance, filesystem, or network behavior.", nil, "probe.native", "Run the bounded isolated Claude probe before certification.")
          document.fetch("controls").each do |control|
            next unless control.fetch("trigger") == "schedule"

            findings << finding("schedule_port_required", "Scheduled control #{control.fetch("id")} is retained in the control document but cannot be dispatched by Claude hooks.", control.fetch("id"), "schedule", "Install the corresponding rplugin schedule-port dispatch.")
          end
          findings.sort_by { |item| [item.fetch("control_id").to_s, item.fetch("code")] }
        end

        def artifact(path:, content:, format:, ownership:)
          {
            "path" => path,
            "content" => content,
            "digest" => Digest::SHA256.hexdigest(content),
            "format" => format,
            "ownership" => ownership
          }
        end

        def artifact_content(value)
          "#{JSON.pretty_generate(value)}\n"
        end

        def settings_ownership_entries(settings, callback)
          entries = [
            "/hooks/PreToolUse/polispec-#{Digest::SHA256.hexdigest(JSON.generate(callback))[0, 16]}",
            "/sandbox/enabled",
            "/sandbox/failIfUnavailable",
            "/sandbox/allowUnsandboxedCommands",
            "/sandbox/enableWeakerNestedSandbox"
          ]
          settings.fetch("permissions").fetch("deny").each do |rule|
            entries << "/permissions/deny/#{pointer_segment(rule)}"
          end
          settings.fetch("sandbox").fetch("filesystem").each do |key, values|
            if values.is_a?(Array)
              if values.empty?
                entries << "/sandbox/filesystem/#{key}"
              else
                values.each { |value| entries << "/sandbox/filesystem/#{key}/#{pointer_segment(value)}" }
              end
            else
              entries << "/sandbox/filesystem/#{key}"
            end
          end
          if settings.fetch("sandbox").key?("network")
            settings.fetch("sandbox").fetch("network").each do |key, value|
              if value.is_a?(Array)
                if value.empty?
                  entries << "/sandbox/network/#{key}"
                else
                  value.each { |item| entries << "/sandbox/network/#{key}/#{pointer_segment(item)}" }
                end
              else
                entries << "/sandbox/network/#{key}"
              end
            end
          end
          entries << "/allowManagedHooksOnly" if settings.key?("allowManagedHooksOnly")
          entries.sort
        end

        def paths_for(scope, project, home)
          case scope
          when "project"
            [File.join(project, ".claude", "settings.json"), File.join(project, ".polispec", "harness", "claude-code", "controls.json")]
          when "user"
            [File.join(home, ".claude", "settings.json"), File.join(home, ".config", "polispec", "harness", "claude-code", "controls.json")]
          when "managed"
            ["/etc/claude-code/managed-settings.d/90-polispec.json", "/etc/polispec/harness/claude-code/controls.json"]
          end
        end

        def runtime_argv_for(context)
          argv = context["runtime_argv"]
          if argv
            unless argv.is_a?(Array) && !argv.empty? && argv.all? { |value| value.is_a?(String) && !value.empty? }
              raise Polispec::Error, "runtime_argv must be a nonempty array of strings"
            end
            raise Polispec::Error, "runtime_argv executable must be absolute" unless Pathname.new(argv.first).absolute?

            return argv.dup
          end
          runtime_path = context["runtime_path"] || File.join(Polispec::ROOT, "bin", "polispec")
          raise Polispec::Error, "runtime_path must be an absolute path" unless runtime_path.is_a?(String) && Pathname.new(runtime_path).absolute?

          [runtime_path]
        end

        def absolute_directory(value, name)
          raise Polispec::Error, "#{name} must be an absolute path" unless value.is_a?(String) && Pathname.new(value).absolute?

          File.expand_path(value)
        end

        def authority_for(scope, edition, runtime_argv, context)
          {
            "requested_scope" => scope,
            "configuration_authority" => scope == "managed" ? "operator_required" : "user_mutable",
            "operator_required" => scope == "managed",
            "runtime_argv_supplied" => context["runtime_argv"].is_a?(Array),
            "protected_runtime" => false,
            "lock_eligible" => false
          }
        end

        def protected_runtime_supplied?(_context, _runtime_argv)
          false
        end

        def parse_version(value)
          match = value.to_s.match(/(?:^|\D)(\d+)\.(\d+)\.(\d+)(?:\D|$)/)
          match && match.captures.map(&:to_i)
        end

        def failure_closed_version_state(value, version)
          return "unverified" if value.nil? || version.nil?

          version_at_least?(version, MINIMUM_FAILURE_CLOSED_VERSION) ? "supported" : "unsupported"
        end

        def sandbox_version_state(version)
          return "unverified" unless version

          version_at_least?(version, MINIMUM_SANDBOX_VERSION) ? "supported" : "unsupported"
        end

        def version_at_least?(version, minimum)
          (version <=> minimum) >= 0
        end

        def failure_closed_detail(state)
          case state
          when "supported"
            "The declared Claude version supports exec-form PreToolUse hooks and onFailure:block; native dispatch and denial evidence is still required."
          when "unsupported"
            "The declared Claude version predates onFailure:block, so hook errors or timeouts cannot be treated as failure closed."
          else
            "The Claude version is missing or unparseable, so failure-closed hook behavior is unverified."
          end
        end

        def effect_disposition(effect, trigger_state)
          return ["unavailable", "The control trigger is unavailable in the generated Claude adapter."] if trigger_state == "unavailable"
          if effect == "inject"
            return ["unsupported", "The Verdict rendering contract does not carry a context payload, so this backend does not claim Claude context injection support."]
          end

          [trigger_state, "Claude PreToolUse can dispatch the #{effect} effect through the polispec callback; native execution evidence is still required."]
        end

        def capability(control, name, disposition, detail)
          {
            "control_id" => control.fetch("id"),
            "capability" => name,
            "disposition" => disposition,
            "detail" => detail
          }
        end

        def finding(code, detail, control_id, capability, next_step)
          {
            "code" => code,
            "detail" => detail,
            "control_id" => control_id,
            "harness" => "claude-code",
            "capability" => capability,
            "next_step" => next_step
          }
        end

        def native_decision(decision, reason)
          {
            "hookSpecificOutput" => {
              "hookEventName" => "PreToolUse",
              "permissionDecision" => decision,
              "permissionDecisionReason" => reason
            }
          }
        end

        def probe_axis(axis, detail)
          {
            "axis" => axis,
            "status" => "unavailable",
            "evidence" => nil,
            "detail" => detail
          }
        end

        def pointer_segment(value)
          value.to_s.gsub("~", "~0").gsub("/", "~1")
        end

        def managed_consequence_inventory(existing)
          return [] unless existing.is_a?(Hash)

          inventory = []
          collect_hook_inventory(stringify_hash(existing), [], inventory)
          inventory.uniq.sort.first(50)
        end

        def collect_hook_inventory(value, path, inventory)
          return unless value.is_a?(Hash)

          value.each do |key, child|
            if key == "hooks" && child.is_a?(Hash)
              child.each do |event, groups|
                Array(groups).each do |group|
                  matcher = group.is_a?(Hash) ? stringify_hash(group)["matcher"] : nil
                  inventory << (path + [event, matcher || "*"]).join(":")
                end
              end
            elsif child.is_a?(Hash)
              collect_hook_inventory(child, path + [key], inventory)
            end
          end
        end

        def optional_string(value, name)
          return nil if value.nil?
          raise Polispec::Error, "Claude hook #{name} must be a string" unless value.is_a?(String)

          value
        end

        def stringify_hash(value)
          return {} if value.nil?
          raise Polispec::Error, "expected an object" unless value.is_a?(Hash)

          value.each_with_object({}) do |(key, item), result|
            result[key.to_s] = item.is_a?(Hash) ? stringify_hash(item) : item
          end
        end
      end

      register("claude-code", Claude)
    end
  end
end
