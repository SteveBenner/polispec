#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "digest"
require "shellwords"
require_relative "../../harness/base"

module Polispec
  module HarnessControls
    module Backends
      module Antigravity
        LIMIT = 1_048_576
        PROBE_LIMIT = 65_536
        PROBE_TIMEOUT = 5

        module_function

        def plan(document, context)
          validate_document!(document)
          values = stringify(context)
          scope = scope_for(values)
          edition = edition_for(values)
          paths = paths_for(scope, values)
          controls = canonical_value(document)
          control_ids = Array(controls["controls"]).map { |control| control["id"].to_s }.sort
          control_digest = Digest::SHA256.hexdigest(canonical_json(controls))
          findings = base_findings(scope, edition)
          runtime = runtime_argv(values, scope, findings)
          restrictions = native_restrictions(controls, scope)
          findings.concat(restrictions["findings"])
          artifacts = [artifact(paths["controls"], json_content(controls), "json", "control_document", [""], control_ids)]

          if runtime
            callback = runtime + ["hook", "pretool", "--harness", "antigravity", "--controls-file", paths["controls"]]
            callback += ["--controls-project", values["project"]] if scope == "project"
            hook = hook_fragment(callback)
            hook_kind = scope == "managed" ? "exclusive" : "json_entries"
            hook_entries = scope == "managed" ? [""] : ["/polispec"]
            artifacts << artifact(paths["hooks"], json_content(hook), "json", hook_kind, hook_entries, control_ids)
            if restrictions["settings"]
              artifacts << artifact(paths["settings"], json_content(restrictions["settings"]), "json", "json_entries", ["/permissions/deny", "/enableTerminalSandbox"], control_ids)
            end
          end

          capabilities = capabilities_for(controls, !runtime.nil?, scope, edition, restrictions)
          findings.concat(control_findings(controls))
          findings << finding("antigravity_configuration_unavailable", "Antigravity native configuration was not generated.", nil, "antigravity.configuration", "Supply a verified absolute runtime argv and plan again.") unless runtime
          material = {
            "artifact_paths" => artifacts.map { |item| item["path"] }.sort,
            "control_digest" => control_digest,
            "edition" => edition,
            "harness" => "antigravity",
            "scope" => scope
          }
          {
            "schema" => "polispec.harness.plan/v1",
            "operation_id" => Digest::SHA256.hexdigest(canonical_json(material)),
            "control_digest" => control_digest,
            "edition" => edition,
            "harness" => "antigravity",
            "scope" => scope,
            "artifacts" => artifacts,
            "capabilities" => capabilities,
            "authority" => authority(scope),
            "findings" => findings
          }
        end

        def normalize(payload)
          data = payload.is_a?(String) ? JSON.parse(payload) : payload
          raise Polispec::Error, "Antigravity hook input must be a JSON object" unless data.is_a?(Hash)

          values = stringify(data)
          tool_call = stringify(values["toolCall"])
          raise Polispec::Error, "Antigravity PreToolUse input requires toolCall" unless values["toolCall"].is_a?(Hash)
          raise Polispec::Error, "Antigravity PreToolUse input requires toolCall.name" unless nonempty_string?(tool_call["name"])
          raise Polispec::Error, "Antigravity PreToolUse input requires object toolCall.args" unless tool_call["args"].is_a?(Hash)
          raise Polispec::Error, "Antigravity PreToolUse input requires conversationId" unless nonempty_string?(values["conversationId"])
          workspaces = values["workspacePaths"]
          valid_workspaces = workspaces.is_a?(Array) && workspaces.all? { |path| absolute_path?(path) }
          raise Polispec::Error, "Antigravity workspacePaths must contain absolute paths" unless valid_workspaces
          raise Polispec::Error, "Antigravity modelName must be a string" unless values["modelName"].nil? || values["modelName"].is_a?(String)

          Harness::Input.new(
            tool_name: tool_call["name"],
            tool_input: tool_call["args"],
            cwd: workspaces.first,
            session_id: values["conversationId"],
            agent_type: values["modelName"],
            event: "PreToolUse"
          )
        rescue JSON::ParserError => error
          raise Polispec::Error, "invalid Antigravity hook JSON: #{error.message}"
        end

        def render(verdict, event = nil)
          normalize(event) if event.is_a?(Hash) || event.is_a?(String) && event.lstrip.start_with?("{")
          raise Polispec::Error, "Antigravity render event must be PreToolUse" unless event.nil? || event.is_a?(Hash) || event.to_s.lstrip.start_with?("{") || event == "PreToolUse"

          values = verdict.respond_to?(:to_h) ? stringify(verdict.to_h) : stringify(verdict)
          level = (values["level"] || values["decision"]).to_s
          decision = case level
                     when "allow" then "allow"
                     when "ask", "warn" then "ask"
                     else "deny"
                     end
          output = { "decision" => decision }
          output["reason"] = verdict_reason(values, level) unless decision == "allow"
          { "stdout" => JSON.generate(output) + "\n", "stderr" => "", "exit_status" => 0 }
        end

        def probe(_receipt = {}, runner = nil)
          version = runner ? probe_version(runner) : nil
          runtime_status = version ? "unverified" : "unavailable"
          runtime_evidence = version ? "installed_version:#{version}" : "not_observed"
          [
            probe_row("runtime_presence", runtime_status, runtime_evidence, version ? "agy answered a bounded version probe; native hooks remain unverified." : "No installed agy runtime answered the bounded version probe."),
            probe_row("cli_callback_denial", "unverified", "not_run", "No controlled native PreToolUse denial journey was run."),
            probe_row("hook_failure_mode", "unverified", "not_documented", "Native hook error and timeout consequences are not documented or exercised."),
            probe_row("config_provenance", "unverified", "not_run", "No installed runtime proved which Antigravity hook files were loaded."),
            probe_row("cli_permissions", "unverified", "not_run", "No native permissions or terminal sandbox denial journey was run."),
            probe_row("gui_hooks", "unavailable", "directive_only", "GUI hook delivery is not established and remains directive-only."),
            probe_row("managed_scope", "unavailable", "not_documented", "No native managed Antigravity hook scope is documented."),
            probe_row("lock", "unavailable", "uncertifiable", "Antigravity surfaces are never certified for lock by this backend.")
          ]
        end

        def hook_fragment(callback)
          {
            "polispec" => {
              "PreToolUse" => [
                {
                  "matcher" => "*",
                  "hooks" => [
                    {
                      "type" => "command",
                      "command" => Shellwords.join(callback),
                      "timeout" => 10
                    }
                  ]
                }
              ]
            }
          }
        end
        private_class_method :hook_fragment

        def native_restrictions(document, scope)
          candidates = []
          findings = []
          Array(document["controls"]).each do |control|
            next unless control["effect"] == "restrict"
            network = control.fetch("effect_params", {})["network"]
            next unless network.is_a?(Hash)
            unless control["trigger"] == "pre_tool"
              findings << finding("unsupported_trigger_network_restriction", "Control #{control['id']} has no generated #{control['trigger']} hook, so no native Antigravity network setting is claimed for it.", control["id"], "antigravity.cli_network", "Use a verified native event implementation or revise the trigger.")
              next
            end
            unless control.fetch("match", {}).empty?
              findings << finding("conditional_native_network_restriction_unavailable", "Control #{control['id']} remains PreToolUse callback-only because a global Antigravity network setting is not equivalent to its predicate.", control["id"], "antigravity.cli_network", "Use callback enforcement or an unconditional pre_tool network restriction.")
              next
            end
            candidates << { "mode" => network["mode"], "domains" => Array(network["domains"]).uniq.sort }
          end
          distinct = candidates.uniq
          if distinct.length > 1
            findings << finding("conflicting_native_network_restrictions", "Distinct Antigravity network modes or allowlists cannot be intersected safely, so none were compiled globally.", nil, "antigravity.cli_network", "Use one unconditional network restriction or rely on callback enforcement.")
            return { "settings" => nil, "status" => "unsupported", "findings" => findings }
          end
          return { "settings" => nil, "status" => "unavailable", "findings" => findings } if distinct.empty?

          network = distinct.first
          if network["mode"] == "open"
            findings << finding("open_network_has_no_native_fragment", "Open network requests do not emit a restrictive Antigravity permission fragment.", nil, "antigravity.cli_network", "Rely on the documented Antigravity default or manage open-network policy outside this restriction compiler.")
            return { "settings" => nil, "status" => "unsupported", "findings" => findings }
          end
          unless network["domains"].empty?
            findings << finding("antigravity_network_allowlist_unrepresentable", "Antigravity deny precedence prevents a bounded fragment from expressing an exact domain allowlist without broadening or denying listed domains.", nil, "antigravity.cli_network", "Use callback enforcement for the exact domain allowlist.")
            return { "settings" => nil, "status" => "unsupported", "findings" => findings }
          end
          unless scope == "user"
            findings << finding("antigravity_network_scope_unrepresentable", "CLI permissions are user-global, so the requested #{scope} network restriction was not globalized.", nil, "antigravity.cli_network", "Use callback enforcement or install an explicitly reviewed user-scope restriction.")
            return { "settings" => nil, "status" => "unsupported", "findings" => findings }
          end

          settings = {
            "enableTerminalSandbox" => true,
            "permissions" => {
              "deny" => ["execute_url(*)", "read_url(*)", "unsandboxed(*)"]
            }
          }
          { "settings" => settings, "status" => "generated", "findings" => findings }
        end
        private_class_method :native_restrictions

        def paths_for(scope, values)
          home = home_for(values)
          case scope
          when "project"
            project = values["project"].to_s
            raise Polispec::Error, "project scope requires an absolute project path" unless absolute_path?(project)
            {
              "controls" => File.join(project, ".polispec", "harness", "antigravity", "controls.json"),
              "hooks" => File.join(project, ".agents", "hooks.json"),
              "settings" => File.join(home, ".gemini", "antigravity-cli", "settings.json")
            }
          when "user"
            {
              "controls" => File.join(home, ".config", "polispec", "harness", "antigravity", "controls.json"),
              "hooks" => File.join(home, ".gemini", "config", "hooks.json"),
              "settings" => File.join(home, ".gemini", "antigravity-cli", "settings.json")
            }
          else
            {
              "controls" => "/etc/polispec/harness/antigravity/controls.json",
              "hooks" => "/etc/polispec/harness/antigravity/hooks.json",
              "settings" => "/etc/polispec/harness/antigravity/settings.json"
            }
          end
        end
        private_class_method :paths_for

        def capabilities_for(document, generated, scope, edition, restrictions)
          rows = Array(document["controls"]).map do |control|
            trigger = control["trigger"].to_s
            effect = control["effect"].to_s
            disposition = generated ? "generated" : "unavailable"
            detail = if trigger == "schedule"
                       disposition = "unsupported"
                       "Schedules require the lifecycle schedule port."
                     elsif trigger != "pre_tool"
                       disposition = "unsupported"
                       "The generated Antigravity hook handles only PreToolUse."
                     elsif scope == "managed"
                       disposition = "unavailable"
                       "The generated file is operator staging and has no documented native managed load path."
                     elsif %w[deny ask restrict].include?(effect)
                       effect == "ask" ? "The callback emits ask and never auto_approve." : "The PreToolUse callback evaluates the canonical control."
                     else
                       disposition = "unsupported"
                       "The PreToolUse decision protocol does not implement this effect."
                     end
            capability(control["id"], "antigravity.#{trigger == 'pre_tool' ? 'pre_tool_use' : trigger}", disposition, detail)
          end
          generated_disposition = generated ? "generated" : "unavailable"
          rows.concat([
            capability(nil, "antigravity.cli_callback_denial", scope == "managed" ? "unavailable" : generated_disposition, scope == "managed" ? "The operator artifact has no documented native managed load path." : "A CLI PreToolUse hook is generated; native delivery and failure behavior remain unverified."),
            capability(nil, "antigravity.cli_network", generated ? restrictions["status"] : "unavailable", "Only an exact unconditional user-scope empty allowlist can produce a native deny fragment; other restrictions remain callback-only."),
            capability(nil, "antigravity.gui", "unsupported", "GUI surfaces remain directive-only and are not claimed to execute the generated hook."),
            capability(nil, "antigravity.managed_scope", "unsupported", "The managed artifact is operator-owned staging; no native managed configuration scope is documented."),
            capability(nil, "antigravity.lock", edition == "lock" ? "unsupported" : "unavailable", "Antigravity is never certified for lock.")
          ])
        end
        private_class_method :capabilities_for

        def base_findings(scope, edition)
          rows = [
            finding("antigravity_gui_directive_only", "Antigravity GUI surfaces are directive-only because native hook delivery is not established.", nil, "antigravity.gui", "Use agy CLI for native probe work and keep GUI controls advisory."),
            finding("antigravity_lock_uncertifiable", "Antigravity is never certified for lock.", nil, "antigravity.lock", "Use a harness with protected native enforcement for lock workloads.")
          ]
          if scope == "managed"
            rows << finding("antigravity_managed_scope_unavailable", "No native managed Antigravity hook path is documented; the generated exclusive artifact is operator-owned staging only.", nil, "antigravity.managed_scope", "Deploy only through an operator-approved immutable mechanism and do not claim native loading.")
          end
          rows << finding("antigravity_lock_requested", "The requested lock edition remains uncertifiable on Antigravity.", nil, "antigravity.lock", "Select a certifiable harness for sealed enforcement.") if edition == "lock"
          rows
        end
        private_class_method :base_findings

        def control_findings(document)
          Array(document["controls"]).each_with_object([]) do |control, rows|
            if control["trigger"] == "schedule"
              rows << finding("schedule_port_required", "Control #{control['id']} requires lifecycle installation through the schedule port.", control["id"], "antigravity.schedule", "Install the schedule through the lifecycle schedule adapter.")
            elsif control["trigger"] != "pre_tool"
              rows << finding("unsupported_antigravity_trigger", "The Antigravity backend cannot enforce #{control['trigger']} through the generated PreToolUse hook.", control["id"], "antigravity.#{control['trigger']}", "Use a verified native event implementation or revise the trigger.")
            elsif %w[inject observe].include?(control["effect"])
              rows << finding("unsupported_antigravity_effect", "The PreToolUse decision protocol does not implement #{control['effect']}.", control["id"], "antigravity.pre_tool_use", "Use a supported deny, ask, or restrict effect.")
            end
          end
        end
        private_class_method :control_findings

        def runtime_argv(values, scope, findings)
          runtime = values["runtime_argv"]
          if runtime
            valid = runtime.is_a?(Array) && !runtime.empty? && runtime.all? { |item| nonempty_string?(item) && !item.include?("\0") } && absolute_path?(runtime.first)
            raise Polispec::Error, "runtime_argv must be a nonempty absolute-executable argv prefix" unless valid
            return runtime.dup
          end
          path = values["runtime_path"].to_s
          path = File.join(ROOT, "bin", "polispec") if path.empty? && scope != "managed"
          if path.empty?
            findings << finding("managed_runtime_required", "Managed Antigravity hooks require a verified absolute runtime argv.", nil, "antigravity.cli_callback_denial", "Supply runtime_argv from verified plane authority.")
            return nil
          end
          raise Polispec::Error, "runtime_path must be absolute" unless absolute_path?(path)
          [path]
        end
        private_class_method :runtime_argv

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
          raise Polispec::Error, "Antigravity scope must be project, user, or managed" unless %w[project user managed].include?(scope)
          scope
        end
        private_class_method :scope_for

        def edition_for(values)
          edition = values["edition"].to_s
          edition = "standard" if edition.empty?
          raise Polispec::Error, "Antigravity edition must be standard or lock" unless %w[standard lock].include?(edition)
          edition
        end
        private_class_method :edition_for

        def home_for(values)
          home = File.expand_path(values["home"].to_s.empty? ? Dir.home : values["home"].to_s)
          raise Polispec::Error, "user home must resolve to an absolute path" unless absolute_path?(home)
          home
        end
        private_class_method :home_for

        def authority(scope)
          if scope == "managed"
            { "kind" => "operator_required", "protected" => false, "certified" => false, "detail" => "The namespaced artifact requires operator installation but has no documented native managed load path." }
          else
            { "kind" => "same_user", "protected" => false, "certified" => false, "detail" => "Antigravity hooks and permissions are mutable by the same user." }
          end
        end
        private_class_method :authority

        def artifact(path, content, format, kind, entries, control_ids)
          raise Polispec::Error, "generated Antigravity artifact exceeds #{LIMIT} bytes" if content.bytesize > LIMIT
          { "path" => path, "content" => content, "digest" => Digest::SHA256.hexdigest(content), "format" => format, "ownership" => { "kind" => kind, "entries" => entries, "control_ids" => control_ids } }
        end
        private_class_method :artifact

        def capability(control_id, name, disposition, detail)
          { "control_id" => control_id, "capability" => name, "disposition" => disposition, "detail" => detail }
        end
        private_class_method :capability

        def finding(code, detail, control_id, capability_name, next_step)
          { "code" => code, "detail" => detail, "control_id" => control_id, "harness" => "antigravity", "capability" => capability_name, "next_step" => next_step }
        end
        private_class_method :finding

        def probe_version(runner)
          result = stringify(runner.call(["agy", "--version"], timeout: PROBE_TIMEOUT, max_output: PROBE_LIMIT))
          return nil unless result["exit_status"].to_i == 0
          value = result["stdout"].to_s.strip
          value.empty? ? nil : value[0, PROBE_LIMIT]
        rescue StandardError
          nil
        end
        private_class_method :probe_version

        def probe_row(axis, status, evidence, detail)
          { "axis" => axis, "status" => status, "evidence" => evidence, "detail" => detail }
        end
        private_class_method :probe_row

        def verdict_reason(values, level)
          rule = values["rule_id"].to_s.empty? ? "control" : values["rule_id"].to_s
          reason = values["reason"].to_s.empty? ? "polispec control denied this call" : values["reason"].to_s
          text = "[POLISPEC #{rule}] #{%w[warn ask].include?(level) ? 'AUTHORIZATION REQUIRED' : 'DENIED'}: #{reason}."
          text += " #{values['next_step']}" unless values["next_step"].to_s.empty?
          text
        end
        private_class_method :verdict_reason

        def json_content(value)
          JSON.pretty_generate(canonical_value(value)) + "\n"
        end
        private_class_method :json_content

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

        def nonempty_string?(value)
          value.is_a?(String) && !value.empty?
        end
        private_class_method :nonempty_string?

        def absolute_path?(path)
          path.is_a?(String) && path.start_with?(File::SEPARATOR) && !path.include?("\0")
        end
        private_class_method :absolute_path?
      end

      register("antigravity", Antigravity)
    end
  end
end
