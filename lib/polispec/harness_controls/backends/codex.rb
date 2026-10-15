#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../../harness/codex"

module Polispec
  module HarnessControls
    module Backends
      module Codex
        CONFIG_LIMIT = 65_536
        CONTROL_LIMIT = 1_048_576
        PROBE_LIMIT = 65_536
        PROBE_TIMEOUT = 5

        module_function

        def plan(document, context)
          values = stringify(context)
          validate_document!(document)
          scope = scope_for(values)
          edition = edition_for(values)
          paths = paths_for(scope, values)
          controls = canonical_value(document)
          restrictions = native_restrictions(controls)
          control_content = JSON.pretty_generate(controls) + "\n"
          raise Polispec::Error, "control document exceeds #{CONTROL_LIMIT} bytes" if control_content.bytesize > CONTROL_LIMIT

          control_ids = Array(controls["controls"]).map { |control| control["id"].to_s }
          control_digest = Digest::SHA256.hexdigest(canonical_json(controls))
          artifacts = [artifact(paths["controls"], control_content, "json", "control_document", [""], control_ids)]
          findings = []
          runtime = runtime_argv(values, scope, findings)
          existing_unsafe = unsafe_existing_toml?(values["existing"], paths["config"])
          config_generated = !runtime.nil? && !existing_unsafe

          if existing_unsafe
            findings << finding("unsafe_existing_toml", "Existing #{paths['config']} cannot be merged by the bounded Codex emitter.", nil, "codex.configuration", "Use lifecycle inspection with a supported TOML merger or remove the conflicting unmanaged file through the operator.")
          end

          if config_generated
            callback = runtime + ["hook", "pretool", "--harness", "codex", "--controls-file", paths["controls"]]
            callback += ["--controls-project", values["project"]] if scope == "project"
            config_content = config_toml(scope, edition, callback, restrictions)
            raise Polispec::Error, "generated Codex TOML exceeds #{CONFIG_LIMIT} bytes" if config_content.bytesize > CONFIG_LIMIT
            artifacts << artifact(paths["config"], config_content, "toml", "toml_block", ["codex/v1"], control_ids)
            if scope != "managed"
              artifacts << artifact(paths["rules"], exec_rules, "starlark", "exclusive", [""], control_ids)
              findings << finding("hook_trust_required", "Codex requires explicit trust for the generated #{scope} PreToolUse hook.", nil, "codex.callback_denial", "Review and trust the generated hook in Codex before relying on it.")
            end
          end

          findings.concat(restrictions["findings"])
          findings.concat(control_findings(controls, config_generated))
          capabilities = capabilities_for(controls, scope, edition, config_generated, restrictions)
          operation_id = Digest::SHA256.hexdigest(([control_digest, "codex", scope, edition] + artifacts.map { |item| item["path"] }.sort).join("\0"))
          {
            "schema" => "polispec.harness.plan/v1",
            "operation_id" => "op_#{operation_id[0, 24]}",
            "control_digest" => control_digest,
            "edition" => edition,
            "harness" => "codex",
            "scope" => scope,
            "artifacts" => artifacts,
            "capabilities" => capabilities,
            "authority" => authority(scope),
            "findings" => findings
          }
        end

        TOOL_EVENTS = %w[PreToolUse PostToolUse].freeze

        def normalize(native_event, events: ["PreToolUse"])
          data = native_event.is_a?(String) ? JSON.parse(native_event) : native_event
          raise Polispec::Error, "Codex hook input must be a JSON object" unless data.is_a?(Hash)
          values = stringify(data)
          event = values["hook_event_name"] || values["event"]
          raise Polispec::Error, "Codex backend accepts only #{events.join(" or ")} input" unless event.to_s.empty? || events.include?(event.to_s)
          tool_name = values["tool_name"] || values["toolName"]
          tool_input = values["tool_input"] || values["toolInput"]
          if event.to_s.empty? || TOOL_EVENTS.include?(event.to_s)
            raise Polispec::Error, "Codex #{event.to_s.empty? ? events.first : event} input requires tool_name" unless tool_name.is_a?(String) && !tool_name.empty?
            raise Polispec::Error, "Codex #{event.to_s.empty? ? events.first : event} input requires object tool_input" unless tool_input.is_a?(Hash)
          else
            tool_name = nil
            tool_input = {}
          end

          Polispec::Harness::Input.new(
            tool_name: tool_name,
            tool_input: tool_input,
            cwd: values["cwd"],
            session_id: values["session_id"] || values["sessionId"],
            agent_type: values["agent_type"] || values["agentType"],
            event: event.to_s.empty? ? "PreToolUse" : event.to_s
          )
        rescue JSON::ParserError => error
          raise Polispec::Error, "invalid Codex hook JSON: #{error.message}"
        end

        def render(verdict, native_event = nil)
          normalize(native_event) if native_event
          values = verdict.respond_to?(:to_h) ? stringify(verdict.to_h) : stringify(verdict)
          level = values["level"].to_s
          return { "stdout" => "", "stderr" => "", "exit_status" => 0 } if level == "allow"
          raise Polispec::Error, "unsupported verdict level #{level.inspect}" unless %w[warn deny].include?(level)

          reason = verdict_reason(values, level)
          output = {
            "hookSpecificOutput" => {
              "hookEventName" => "PreToolUse",
              "permissionDecision" => "deny",
              "permissionDecisionReason" => reason
            }
          }
          { "stdout" => JSON.generate(output) + "\n", "stderr" => "", "exit_status" => 0 }
        end

        def probe(_receipt, runner = nil)
          feature = runner ? probe_hooks_feature(runner) : nil
          hook_detail = if feature == true
                          "The installed CLI reports hooks enabled; controlled callback denial remains unverified."
                        elsif feature == false
                          "The installed CLI did not report an enabled hooks feature."
                        else
                          "No bounded installed-runtime hook feature evidence is available."
                        end
          [
            probe_row("callback_denial", feature == false ? "unavailable" : "unverified", feature_evidence(feature), hook_detail),
            probe_row("exec_policy", "unverified", "not_run", "Requirements exec policy needs an installed receipt and controlled command fixture."),
            probe_row("filesystem_sandbox", "unverified", "not_run", "Filesystem containment needs a controlled native sandbox write probe."),
            probe_row("network_sandbox", "unverified", "not_run", "Network containment needs a controlled native egress probe."),
            probe_row("hosted_tools", "unavailable", "not_covered", "Hosted and specialized tool paths are outside complete PreToolUse coverage."),
            probe_row("nested_execution", "unverified", "not_run", "Nested Codex requirements inheritance has not been exercised for this receipt.")
          ]
        end

        def validate_document!(document)
          raise Polispec::Error, "control document must be a JSON object" unless document.is_a?(Hash)
          errors = Polispec::Controls.validate(document)
          return if errors.empty?

          first = errors.first
          raise Polispec::Error, "invalid control document at #{first['pointer']}: #{first['message']}"
        end
        private_class_method :validate_document!

        def scope_for(values)
          scope = values["scope"].to_s
          raise Polispec::Error, "Codex scope must be project, user, or managed" unless %w[project user managed].include?(scope)

          scope
        end
        private_class_method :scope_for

        def edition_for(values)
          edition = values["edition"].to_s
          edition = "standard" if edition.empty?
          raise Polispec::Error, "Codex edition must be standard or lock" unless %w[standard lock].include?(edition)

          edition
        end
        private_class_method :edition_for

        def paths_for(scope, values)
          case scope
          when "project"
            project = values["project"].to_s
            raise Polispec::Error, "project scope requires an absolute project path" unless absolute_path?(project)
            { "controls" => File.join(project, ".polispec", "harness", "codex", "controls.json"), "config" => File.join(project, ".codex", "config.toml"), "rules" => File.join(project, ".codex", "rules", "polispec.rules") }
          when "user"
            home = File.expand_path(values["home"].to_s.empty? ? Dir.home : values["home"].to_s)
            raise Polispec::Error, "user home must resolve to an absolute path" unless absolute_path?(home)
            { "controls" => File.join(home, ".config", "polispec", "harness", "codex", "controls.json"), "config" => File.join(home, ".codex", "config.toml"), "rules" => File.join(home, ".codex", "rules", "polispec.rules") }
          else
            { "controls" => "/etc/polispec/harness/codex/controls.json", "config" => "/etc/codex/requirements.toml", "rules" => nil }
          end
        end
        private_class_method :paths_for

        def runtime_argv(values, scope, findings)
          runtime = values["runtime_argv"]
          if runtime
            unless runtime.is_a?(Array) && !runtime.empty? && runtime.all? { |item| item.is_a?(String) && !item.empty? && !item.include?("\0") } && absolute_path?(runtime.first)
              raise Polispec::Error, "runtime_argv must be a nonempty absolute-executable argv prefix"
            end
            return runtime.dup
          end

          path = values["runtime_path"].to_s
          path = File.join(ROOT, "bin", "polispec") if path.empty? && scope != "managed"
          if path.empty?
            findings << finding("managed_runtime_required", "Managed Codex hooks require a verified absolute runtime argv.", nil, "codex.callback_denial", "Supply runtime_argv from verified plane authority.")
            return nil
          end
          raise Polispec::Error, "runtime_path must be absolute" unless absolute_path?(path)

          [path]
        end
        private_class_method :runtime_argv

        def config_toml(scope, edition, callback, restrictions)
          profile = edition == "lock" ? "polispec-lock" : "polispec-standard"
          paths = restrictions["paths"]
          lines = ["# polispec:begin codex/v1"]
          lines << "default_permissions = #{toml_string(profile)}"
          lines << "allow_managed_hooks_only = true" if scope == "managed"
          lines << ""
          if scope == "managed"
            lines << "[allowed_permission_profiles]"
            lines << "#{toml_key(profile)} = true"
            lines << ""
          end
          lines << "[permissions.#{toml_key(profile)}]"
          lines << "extends = \":workspace\"" unless paths
          lines << ""
          filesystem_toml(lines, profile, paths) if paths
          lines << "[permissions.#{toml_key(profile)}.network]"
          lines << "enabled = true"
          lines << ""
          lines << "[features]"
          lines << "hooks = true"
          lines << ""
          if scope == "managed"
            lines << "[hooks]"
            lines << "managed_dir = #{toml_string(File.dirname(callback.first))}"
            lines << ""
          end
          lines << "[[hooks.PreToolUse]]"
          lines << "matcher = \"*\""
          lines << ""
          lines << "[[hooks.PreToolUse.hooks]]"
          lines << "type = \"command\""
          lines << "command = #{toml_string(Shellwords.join(callback))}"
          lines << "timeout = 10"
          lines << "statusMessage = \"Checking polispec controls\""
          if scope == "managed"
            lines << ""
            lines << "[rules]"
            lines << "prefix_rules = #{managed_exec_rules}"
          end
          network_toml(lines, edition, restrictions["network"])
          lines << ""
          lines << "# polispec:end codex/v1"
          lines.join("\n") + "\n"
        end
        private_class_method :config_toml

        def filesystem_toml(lines, profile, paths)
          lines << "[permissions.#{toml_key(profile)}.filesystem]"
          lines << "\":root\" = \"read\"" if paths["read"].empty?
          lines << "\":minimal\" = \"read\"" unless paths["read"].empty?
          paths["read"].each { |path| lines << "#{toml_key(path)} = \"read\"" }
          paths["write"].each { |path| lines << "#{toml_key(path)} = \"write\"" }
          lines << ""
        end
        private_class_method :filesystem_toml

        def network_toml(lines, edition, network)
          return if edition == "standard" && network.nil?

          domains = edition == "lock" ? [] : network.fetch("domains", [])
          lines << ""
          lines << "[experimental_network]"
          lines << "enabled = true"
          lines << "managed_allowed_domains_only = true"
          lines << ""
          lines << "[experimental_network.domains]"
          domains.sort.each { |domain| lines << "#{toml_key(domain)} = \"allow\"" }
        end
        private_class_method :network_toml

        def native_restrictions(document)
          path_entries = []
          network_entries = []
          conditional_paths = false
          conditional_network = false
          findings = []
          Array(document["controls"]).each do |control|
            next unless control.is_a?(Hash) && control["effect"] == "restrict"

            params = control["effect_params"]
            next unless params.is_a?(Hash)
            if control["trigger"] != "pre_tool" || !control.fetch("match", {}).empty?
              axes = %w[paths network].select { |axis| params[axis].is_a?(Hash) }
              axes.each do |axis|
                conditional_paths = true if axis == "paths"
                conditional_network = true if axis == "network"
                detail = if control["trigger"] == "pre_tool"
                           "Control #{control['id']} has a predicate, so its #{axis} restriction is enforced by the PreToolUse callback without broadening it into global Codex configuration."
                         else
                           "Control #{control['id']} uses #{control['trigger']}, for which this backend emits no hook; its #{axis} restriction is not compiled into global Codex configuration."
                         end
                next_step = control["trigger"] == "pre_tool" ? "Use the callback result or split out an unconditional restriction for native sandbox compilation." : "Use a backend event with verified #{control['trigger']} support or revise the trigger."
                findings << finding("conditional_native_restriction_unavailable", detail, control["id"], "codex.#{axis == 'paths' ? 'filesystem' : 'network'}_sandbox", next_step)
              end
              next
            end
            paths = params["paths"]
            path_entries << normalized_paths(paths) if paths.is_a?(Hash)
            network = params["network"]
            network_entries << normalized_network(network) if network.is_a?(Hash)
          end

          paths, paths_status = compatible_restriction(path_entries)
          network, network_status = compatible_restriction(network_entries)
          paths_conflict = paths_status == "unsupported"
          network_conflict = network_status == "unsupported"
          paths_status = "unsupported" if conditional_paths
          network_status = "unsupported" if conditional_network
          if paths_conflict
            findings << finding("conflicting_native_path_restrictions", "Distinct path allowlists cannot be intersected safely by the bounded Codex emitter, so none were widened or compiled globally.", nil, "codex.filesystem_sandbox", "Use one unconditional path restriction set or rely on callback enforcement.")
          end
          if network_conflict
            findings << finding("conflicting_native_network_restrictions", "Distinct network modes or allowlists cannot be combined without changing a control, so none were widened or compiled globally.", nil, "codex.network_sandbox", "Use one unconditional network restriction set or rely on callback enforcement.")
          end
          network = nil if network && network["mode"] == "open"
          {
            "paths" => paths,
            "paths_status" => paths_status,
            "network" => network,
            "network_status" => network_status,
            "findings" => findings
          }
        end
        private_class_method :native_restrictions

        def normalized_paths(paths)
          { "read" => Array(paths["read"]).uniq.sort, "write" => Array(paths["write"]).uniq.sort }
        end
        private_class_method :normalized_paths

        def normalized_network(network)
          mode = network["mode"]
          { "mode" => mode, "domains" => mode == "allowlist" ? Array(network["domains"]).uniq.sort : [] }
        end
        private_class_method :normalized_network

        def compatible_restriction(entries)
          return [nil, "generated"] if entries.empty?

          distinct = entries.uniq
          return [distinct.first, "generated"] if distinct.length == 1

          [nil, "unsupported"]
        end
        private_class_method :compatible_restriction

        def managed_exec_rules
          rules = ["--dangerously-bypass-approvals-and-sandbox", "--yolo"].map do |flag|
            "{ pattern = [{ token = \"codex\" }, { token = #{toml_string(flag)} }], decision = \"forbidden\", justification = \"Polispec forbids nested sandbox bypass\" }"
          end
          "[\n  #{rules.join(",\n  ")}\n]"
        end
        private_class_method :managed_exec_rules

        def exec_rules
          ["--dangerously-bypass-approvals-and-sandbox", "--yolo"].map do |flag|
            "prefix_rule(pattern=[\"codex\", #{JSON.generate(flag)}], decision=\"forbidden\", justification=\"Polispec forbids nested sandbox bypass\")"
          end.join("\n") + "\n"
        end
        private_class_method :exec_rules

        def capabilities_for(document, scope, edition, generated, restrictions)
          rows = Array(document["controls"]).map do |control|
            effect = control["effect"].to_s
            disposition = generated ? "generated" : "unavailable"
            detail = if control["trigger"] == "schedule"
                       disposition = "unsupported"
                       "Schedules use the lifecycle schedule port; this PreToolUse backend does not install or claim them."
                     elsif control["trigger"] != "pre_tool"
                       disposition = "unsupported"
                       "Codex backend emits only PreToolUse hooks and cannot enforce the #{control['trigger']} trigger."
                     elsif %w[inject observe].include?(effect)
                       disposition = "unsupported"
                       "This effect is not emitted by the Codex PreToolUse denial adapter."
                     elsif effect == "restrict" && !control.fetch("match", {}).empty?
                       "The callback evaluates this predicate exactly; no equivalent global sandbox restriction is claimed."
                     elsif effect == "ask"
                       "Codex native ask is unsafe; the callback emits deny pending exact operator authorization."
                     else
                       "The canonical control is evaluated by the generated PreToolUse callback."
                     end
            capability_name = if control["trigger"] == "pre_tool"
                                effect == "ask" ? "codex.callback_deny_for_ask" : "codex.pre_tool_use"
                              else
                                "codex.#{control['trigger']}"
                              end
            capability(control["id"], capability_name, disposition, detail)
          end
          generated_disposition = generated ? "generated" : "unavailable"
          rows.concat([
            capability(nil, "codex.callback_denial", generated_disposition, "PreToolUse explicit deny is generated, but callback errors and timeouts can fail open."),
            capability(nil, "codex.exec_policy", generated_disposition, "Native rules forbid direct nested Codex sandbox-bypass flags; prefix coverage is incomplete."),
            capability(nil, "codex.filesystem_sandbox", generated ? restrictions["paths_status"] : "unavailable", restrictions["paths_status"] == "unsupported" ? "Conflicting or conditional path restrictions remain callback-only; the baseline profile is not claimed equivalent." : "A workspace or declared path permission profile is generated; live containment remains unverified."),
            capability(nil, "codex.network_sandbox", generated ? (edition == "lock" ? "generated" : restrictions["network_status"]) : "unavailable", network_capability_detail(edition, restrictions)),
            capability(nil, "codex.hosted_tools", "unverified", "Hosted and specialized tool coverage is not established by generated hooks."),
            capability(nil, "codex.nested_execution", "unverified", scope == "managed" ? "Requirements are expected to bind nested processes but need native evidence." : "Same-user configuration can be bypassed by a nested Codex home or flags.")
          ])
          rows
        end
        private_class_method :capabilities_for

        def network_capability_detail(edition, restrictions)
          return "Managed proxy requirements carry an empty domain allowlist; live egress remains unverified." if edition == "lock"
          return "Conflicting or conditional network restrictions remain callback-only; open native network is not claimed equivalent." if restrictions["network_status"] == "unsupported"

          "Standard uses open network unless one unconditional declared allowlist is compiled."
        end
        private_class_method :network_capability_detail

        def control_findings(document, generated)
          findings = []
          Array(document["controls"]).each do |control|
            if control["trigger"] == "schedule"
              findings << finding("schedule_port_required", "Control #{control['id']} requires lifecycle installation through the schedule port; the Codex hook plan does not install it.", control["id"], "codex.schedule", "Install the schedule through the lifecycle schedule adapter.")
            elsif control["trigger"] != "pre_tool"
              findings << finding("unsupported_codex_trigger", "Codex backend emits only PreToolUse and cannot enforce #{control['trigger']} for control #{control['id']}.", control["id"], "codex.pre_tool_use", "Use a backend event with verified #{control['trigger']} support or revise the trigger.")
            elsif control["effect"] == "ask"
              findings << finding("native_ask_unavailable", "Codex native ask can fail and continue, so control #{control['id']} is rendered as deny.", control["id"], "codex.callback_deny_for_ask", "Obtain exact operator authorization before retrying the denied call.")
            elsif %w[inject observe].include?(control["effect"])
              findings << finding("unsupported_codex_effect", "Codex backend does not emit #{control['effect']} for control #{control['id']}.", control["id"], "codex.pre_tool_use", "Use a backend with verified native support or revise the control.")
            end
          end
          unless generated
            findings << finding("codex_configuration_unavailable", "Codex native configuration was not generated.", nil, "codex.configuration", "Resolve the reported runtime or merge prerequisite and plan again.")
          end
          findings
        end
        private_class_method :control_findings

        def unsafe_existing_toml?(existing, path)
          return false if existing.nil? || existing == "" || existing == {}
          value = existing.is_a?(Hash) ? (existing[path] || existing[path.to_sym]) : existing
          !value.nil? && value.to_s.strip != ""
        end
        private_class_method :unsafe_existing_toml?

        def authority(scope)
          managed = scope == "managed"
          { "kind" => managed ? "operator_required" : "same_user", "protected" => false, "certified" => false, "detail" => managed ? "Installing and protecting requirements needs operator authority; generated paths do not prove it." : "The generated configuration is mutable by the same user and requires hook trust." }
        end
        private_class_method :authority

        def artifact(path, content, format, kind, entries, control_ids)
          {
            "path" => path,
            "content" => content,
            "digest" => Digest::SHA256.hexdigest(content),
            "format" => format,
            "ownership" => { "kind" => kind, "entries" => entries, "control_ids" => control_ids }
          }
        end
        private_class_method :artifact

        def capability(control_id, name, disposition, detail)
          { "control_id" => control_id, "capability" => name, "disposition" => disposition, "detail" => detail }
        end
        private_class_method :capability

        def finding(code, detail, control_id, capability_name, next_step)
          { "code" => code, "detail" => detail, "control_id" => control_id, "harness" => "codex", "capability" => capability_name, "next_step" => next_step }
        end
        private_class_method :finding

        def verdict_reason(values, level)
          rule = values["rule_id"].to_s.empty? ? "control" : values["rule_id"].to_s
          reason = values["reason"].to_s.empty? ? "polispec control denied this call" : values["reason"].to_s
          text = "[POLISPEC #{rule}] #{level == 'warn' ? 'AUTHORIZATION REQUIRED' : 'DENIED'}: #{reason}."
          text += " #{values['next_step']}" unless values["next_step"].to_s.empty?
          if level == "warn"
            id = values["allow_once_id"]
            text += if id.to_s.empty?
                      " Exact operator authorization is required before this tool call may be retried."
                    else
                      " The operator must run `polispec allow-once #{id}` interactively before this exact call is retried; the agent must never run it."
                    end
          end
          text
        end
        private_class_method :verdict_reason

        def probe_hooks_feature(runner)
          result = runner.call(["codex", "features", "list"], timeout: PROBE_TIMEOUT, max_output: PROBE_LIMIT)
          values = stringify(result)
          return nil unless values["exit_status"].to_i == 0

          row = values["stdout"].to_s.each_line.find { |line| line.match?(/\Ahooks\s+stable\s+(?:true|false)\s*\z/) }
          return nil unless row

          row.match?(/\btrue\s*\z/)
        rescue StandardError
          nil
        end
        private_class_method :probe_hooks_feature

        def feature_evidence(feature)
          return "installed_hooks_enabled" if feature == true
          return "installed_hooks_not_enabled" if feature == false

          "not_observed"
        end
        private_class_method :feature_evidence

        def probe_row(axis, status, evidence, detail)
          { "axis" => axis, "status" => status, "evidence" => evidence, "detail" => detail }
        end
        private_class_method :probe_row

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

        def toml_string(value)
          JSON.generate(value.to_s)
        end
        private_class_method :toml_string

        def toml_key(value)
          JSON.generate(value.to_s)
        end
        private_class_method :toml_key

        def absolute_path?(path)
          path.is_a?(String) && path.start_with?(File::SEPARATOR) && !path.include?("\0")
        end
        private_class_method :absolute_path?
      end

      register("codex", Codex)
    end
  end
end
