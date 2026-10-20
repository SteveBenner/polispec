#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "yaml"
require "digest"
require "shellwords"
require_relative "../../harness/base"
require_relative "../../editions"

module Polispec
  module HarnessControls
    module Backends
      module Hermes
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
          controls_content = json_content(controls)
          control_digest = Digest::SHA256.hexdigest(canonical_json(controls))
          findings = base_findings(scope, edition)
          runtime = runtime_argv(values, scope, findings)
          artifacts = [artifact(paths["controls"], controls_content, "json", "control_document", [""], control_ids)]

          if runtime
            callback = runtime + ["hook", "pretool", "--harness", "hermes", "--controls-file", paths["controls"]]
            callback += ["--controls-project", values["project"]] if scope == "project"
            fragment = hook_fragment(callback)
            artifacts << artifact(paths["config"], yaml_content(fragment), "yaml", "yaml_entries", ["/hooks/pre_tool_call"], control_ids)
          end

          capabilities = capabilities_for(controls, !runtime.nil?, scope, edition)
          findings.concat(control_findings(controls))
          findings << finding("hermes_configuration_unavailable", "Hermes native configuration was not generated.", nil, "hermes.configuration", "Supply a verified absolute runtime argv and plan again.") unless runtime
          material = {
            "artifact_paths" => artifacts.map { |item| item["path"] }.sort,
            "control_digest" => control_digest,
            "edition" => edition,
            "harness" => "hermes",
            "scope" => scope
          }
          {
            "schema" => "polispec.harness.plan/v1",
            "operation_id" => Digest::SHA256.hexdigest(canonical_json(material)),
            "control_digest" => control_digest,
            "edition" => edition,
            "harness" => "hermes",
            "scope" => scope,
            "artifacts" => artifacts,
            "capabilities" => capabilities,
            "authority" => authority(scope),
            "findings" => findings
          }
        end

        def normalize(payload)
          data = payload.is_a?(String) ? JSON.parse(payload) : payload
          raise Polispec::Error, "Hermes hook input must be a JSON object" unless data.is_a?(Hash)

          values = stringify(data)
          raise Polispec::Error, "Hermes backend accepts only pre_tool_call input" unless values["hook_event_name"] == "pre_tool_call"
          raise Polispec::Error, "Hermes pre_tool_call input requires tool_name" unless nonempty_string?(values["tool_name"])
          raise Polispec::Error, "Hermes pre_tool_call input requires object tool_input" unless values["tool_input"].is_a?(Hash)
          raise Polispec::Error, "Hermes hook cwd must be a string" unless values["cwd"].nil? || values["cwd"].is_a?(String)
          raise Polispec::Error, "Hermes hook extra must be an object" unless values["extra"].nil? || values["extra"].is_a?(Hash)

          Harness::Input.new(
            tool_name: values["tool_name"],
            tool_input: values["tool_input"],
            cwd: values["cwd"],
            session_id: optional_string(values["session_id"], "session_id"),
            agent_type: optional_string(values["profile"], "profile"),
            event: "pre_tool_call"
          )
        rescue JSON::ParserError => error
          raise Polispec::Error, "invalid Hermes hook JSON: #{error.message}"
        end

        def render(verdict, event = nil)
          normalize(event) if event.is_a?(Hash) || event.is_a?(String) && event.lstrip.start_with?("{")
          raise Polispec::Error, "Hermes render event must be pre_tool_call" unless event.nil? || event.is_a?(Hash) || event.to_s.lstrip.start_with?("{") || event == "pre_tool_call"

          values = verdict.respond_to?(:to_h) ? stringify(verdict.to_h) : stringify(verdict)
          level = (values["level"] || values["decision"]).to_s
          return { "stdout" => "", "stderr" => "", "exit_status" => 0 } if level == "allow"

          reason = verdict_reason(values, level)
          if %w[warn ask].include?(level)
            output = { "action" => "approve", "message" => reason }
            output["rule_key"] = values["rule_id"].to_s unless values["rule_id"].to_s.empty?
            return { "stdout" => JSON.generate(output) + "\n", "stderr" => "", "exit_status" => 0 }
          end

          { "stdout" => JSON.generate({ "action" => "block", "message" => reason }) + "\n", "stderr" => "", "exit_status" => 2 }
        end

        def probe(_receipt = {}, runner = nil)
          version = runner ? probe_version(runner) : nil
          runtime_status = version ? "unverified" : "unavailable"
          runtime_evidence = version ? "installed_version:#{version}" : "not_observed"
          [
            probe_row("runtime_presence", runtime_status, runtime_evidence, version ? "Hermes answered a bounded version probe; hook behavior remains unverified." : "No installed Hermes runtime answered the bounded version probe."),
            probe_row("callback_denial", "unverified", "not_run", "No controlled native pre_tool_call denial journey was run."),
            probe_row("hook_consent", "unverified", "not_run", "No native hook consent or managed auto-accept journey was run."),
            probe_row("failure_closed", "unverified", "not_run", "No native callback error or timeout journey was run."),
            probe_row("config_provenance", "unverified", "not_run", "No installed runtime proved which Hermes configuration supplied the hook."),
            probe_row("filesystem_restriction", "unavailable", "not_covered", "Hermes exposes no native filesystem allowlist in this backend."),
            probe_row("network_restriction", "unavailable", "not_covered", "Hermes exposes no native network allowlist in this backend."),
            probe_row("process_boundary", "unverified", "not_run", "No protected process boundary or nested-runtime inheritance was exercised.")
          ]
        end

        def hook_fragment(callback)
          {
            "hooks" => {
              "pre_tool_call" => [
                {
                  "command" => Shellwords.join(callback),
                  "matcher" => ".*",
                  "timeout" => 10,
                  "fail_closed" => true
                }
              ]
            }
          }
        end
        private_class_method :hook_fragment

        def paths_for(scope, values)
          home = home_for(values)
          case scope
          when "project"
            project = values["project"].to_s
            raise Polispec::Error, "project scope requires an absolute project path" unless absolute_path?(project)
            {
              "controls" => File.join(project, ".polispec", "harness", "hermes", "controls.json"),
              "config" => File.join(home, ".hermes", "config.yaml")
            }
          when "user"
            {
              "controls" => File.join(home, ".config", "polispec", "harness", "hermes", "controls.json"),
              "config" => File.join(home, ".hermes", "config.yaml")
            }
          else
            { "controls" => "/etc/polispec/harness/hermes/controls.json", "config" => "/etc/hermes/config.yaml" }
          end
        end
        private_class_method :paths_for

        def capabilities_for(document, generated, scope, edition)
          rows = Array(document["controls"]).map do |control|
            trigger = control["trigger"].to_s
            effect = control["effect"].to_s
            disposition = generated ? "generated" : "unavailable"
            detail = if trigger == "schedule"
                       disposition = "unsupported"
                       "Schedules require the lifecycle schedule port."
                     elsif trigger != "pre_tool"
                       disposition = "unsupported"
                       "Hermes blocking hooks are limited to pre_tool_call."
                     elsif %w[deny ask restrict].include?(effect)
                       if effect == "ask"
                         "Hermes action approve requests human approval and never grants the call."
                       elsif scope == "project"
                         "The pre_tool_call callback applies this document only within the validated project root."
                       else
                         "The pre_tool_call callback evaluates the canonical control."
                       end
                     else
                       disposition = "unsupported"
                       "Hermes pre_tool_call output does not implement this effect."
                     end
            capability(control["id"], "hermes.#{trigger == 'pre_tool' ? 'pre_tool_call' : trigger}", disposition, detail)
          end
          generated_disposition = generated ? "generated" : "unavailable"
          rows.concat([
            capability(nil, "hermes.callback_denial", generated_disposition, "A fail-closed pre_tool_call hook is generated; native error and timeout behavior remains unverified."),
            capability(nil, "hermes.hook_consent", generated ? "unverified" : "unavailable", "Hermes requires human consent for the exact hook command; no process-wide auto-consent is emitted."),
            capability(nil, "hermes.filesystem_restriction", "unsupported", "Path restrictions remain callback-only because no equivalent native Hermes allowlist is emitted."),
            capability(nil, "hermes.network_restriction", "unsupported", "Network restrictions remain callback-only because no equivalent native Hermes allowlist is emitted."),
            capability(nil, "hermes.process_boundary", "unverified", "Configuration does not prove containment of nested Hermes processes."),
            capability(nil, "hermes.lock", Editions.lock?(edition) ? "unsupported" : "unavailable", "Hermes configuration and callback ancestry are not certified as a sealed authority.")
          ])
        end
        private_class_method :capabilities_for

        def base_findings(scope, edition)
          rows = []
          if scope == "project"
            rows << finding("hermes_project_config_is_user_global", "Hermes has no project hook configuration file; the profile-global hook passes an absolute project root so this document is skipped for unrelated calls.", nil, "hermes.configuration", "Verify the callback project-root guard before relying on project enforcement.")
          elsif scope == "managed"
            rows << finding("hermes_managed_event_replacement", "Managed pre_tool_call hooks replace the corresponding user hook list for that event.", nil, "hermes.configuration", "Review the complete managed event fragment before installation.")
            rows << finding("hermes_managed_consent_pending", "Managed configuration does not auto-consent to hooks; the exact polispec command remains subject to Hermes consent.", nil, "hermes.hook_consent", "Approve only the exact reviewed callback command through Hermes native consent.")
          end
          rows << finding("hermes_lock_uncertified", "Hermes lock cannot be certified without protected runtime ancestry and native behavioral evidence.", nil, "hermes.lock", "Use a protected process boundary and verify every required axis.") if Editions.lock?(edition)
          rows
        end
        private_class_method :base_findings

        def control_findings(document)
          Array(document["controls"]).each_with_object([]) do |control, rows|
            if control["trigger"] == "schedule"
              rows << finding("schedule_port_required", "Control #{control['id']} requires lifecycle installation through the schedule port.", control["id"], "hermes.schedule", "Install the schedule through the lifecycle schedule adapter.")
            elsif control["trigger"] != "pre_tool"
              rows << finding("unsupported_hermes_trigger", "Hermes cannot enforce #{control['trigger']} as a blocking native hook.", control["id"], "hermes.#{control['trigger']}", "Use a backend event with verified blocking support or revise the trigger.")
            elsif %w[inject observe].include?(control["effect"])
              rows << finding("unsupported_hermes_effect", "Hermes pre_tool_call output does not implement #{control['effect']}.", control["id"], "hermes.pre_tool_call", "Use a supported deny, ask, or restrict effect.")
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
            findings << finding("managed_runtime_required", "Managed Hermes hooks require a verified absolute runtime argv.", nil, "hermes.callback_denial", "Supply runtime_argv from verified plane authority.")
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
          raise Polispec::Error, "Hermes scope must be project, user, or managed" unless %w[project user managed].include?(scope)
          scope
        end
        private_class_method :scope_for

        def edition_for(values)
          edition = values["edition"].to_s
          edition = "standard" if edition.empty?
          raise Polispec::Error, "Hermes edition must be standard or lock" unless %w[standard lock].include?(edition)
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
            { "kind" => "operator_required", "protected" => false, "certified" => false, "detail" => "Installing the managed fragment needs operator authority; the plan does not prove ownership, runtime ancestry, or native behavior." }
          else
            { "kind" => "same_user", "protected" => false, "certified" => false, "detail" => "Hermes configuration and the callback are mutable by the same user." }
          end
        end
        private_class_method :authority

        def artifact(path, content, format, kind, entries, control_ids)
          raise Polispec::Error, "generated Hermes artifact exceeds #{LIMIT} bytes" if content.bytesize > LIMIT
          { "path" => path, "content" => content, "digest" => Digest::SHA256.hexdigest(content), "format" => format, "ownership" => { "kind" => kind, "entries" => entries, "control_ids" => control_ids } }
        end
        private_class_method :artifact

        def capability(control_id, name, disposition, detail)
          { "control_id" => control_id, "capability" => name, "disposition" => disposition, "detail" => detail }
        end
        private_class_method :capability

        def finding(code, detail, control_id, capability_name, next_step)
          { "code" => code, "detail" => detail, "control_id" => control_id, "harness" => "hermes", "capability" => capability_name, "next_step" => next_step }
        end
        private_class_method :finding

        def probe_version(runner)
          result = stringify(runner.call(["hermes", "--version"], timeout: PROBE_TIMEOUT, max_output: PROBE_LIMIT))
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

        def yaml_content(value)
          YAML.dump(canonical_value(value))
        end
        private_class_method :yaml_content

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

        def optional_string(value, name)
          raise Polispec::Error, "Hermes hook #{name} must be a string" unless value.nil? || value.is_a?(String)
          value
        end
        private_class_method :optional_string

        def nonempty_string?(value)
          value.is_a?(String) && !value.empty?
        end
        private_class_method :nonempty_string?

        def absolute_path?(path)
          path.is_a?(String) && path.start_with?(File::SEPARATOR) && !path.include?("\0")
        end
        private_class_method :absolute_path?
      end

      register("hermes", Hermes)
    end
  end
end
