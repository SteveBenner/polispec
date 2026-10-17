require_relative "root_guard"
require_relative "../exceptions"

module Polispec
  module HarnessControls
    module Evaluate
      EFFECT_LEVEL = { "deny" => "deny", "ask" => "warn", "restrict" => "deny" }.freeze

      module_function

      def call(input, context)
        values = stringify(context)
        actions = Array(values["actions"])
        controls = Array(values["documents"]).flat_map { |entry| document_controls(entry) }
        matches = controls.select { |control| matches?(control, input, actions, values) }
        denies = matches.select { |control| control["effect"] == "deny" || control["effect"] == "restrict" && restriction_violated?(control, actions) }
        asks = matches.select { |control| control["effect"] == "ask" }
        observations = matches.select { |control| control["effect"] == "observe" }
        injections = matches.select { |control| control["effect"] == "inject" }
        root_risks = actions.select { |action| action.action_class == "shell.exec" && action.raw.is_a?(Hash) && action.raw["root_guard_risk"] }
        protected = actions.select { |action| protected_action?(action, Array(values["protected_paths"])) }
        if !protected.empty?
          denies << { "id" => "POLISPEC-CONTROL-PROTECTION", "reason" => "the call changes protected polispec authority" }
        end
        if values["root_guard"] == true && !root_risks.empty?
          denies << { "id" => "POLISPEC-ROOT-GUARD", "reason" => root_risks.first.raw["root_guard_risk"]["detail"] }
        end
        if denies.any?
          control = denies.sort_by { |item| item["id"].to_s }.first
          return result("deny", control, asks, observations, injections)
        end
        return result("warn", asks.sort_by { |item| item["id"].to_s }.first, asks, observations, injections) unless asks.empty?

        result("allow", nil, asks, observations, injections)
      end

      def declared?(documents, action_class, input, context, protected_only: true)
        actions = Array(context["actions"]).select { |action| action.action_class == action_class }
        !actions.empty? && actions.all? { |action| declared_action?(documents, action, input, context, protected_only: protected_only) }
      end

      def declared_action?(documents, action, input, context, protected_only: true)
        Array(documents).any? do |entry|
          values = stringify(entry)
          next false if protected_only && values["protected"] != true
          Array(values.dig("document", "controls")).any? do |control|
            match = control["match"] || {}
            exact = match["server"].to_s == action.env_hint["server"].to_s && match["operation"].to_s == action.env_hint["operation"].to_s
            exact && !match["server"].to_s.empty? && !match["operation"].to_s.empty? && control["action"] == action.action_class && matches_action?(control, input, action, stringify(context))
          end
        end
      end

      def effective_digest(documents)
        material = Array(documents).map do |entry|
          values = stringify(entry)
          [values["protected"] == true, values["installation_id"], values["control_digest"], values["scope"]]
        end.sort_by { |row| row.map(&:to_s) }
        Digest::SHA256.hexdigest(JSON.generate(material))
      end

      def protected_paths(plane, documents, ledger = nil)
        paths = []
        values = stringify(plane)
        paths.concat(Array(values["authority_files"]))
        paths.concat(Array(values["controls"]&.values)) if values["controls"].is_a?(Hash)
        paths << values["operator_records"]
        paths.concat(runtime_paths(values.dig("provenance", "runtime")))
        paths.concat(Array(values["runtime_argv"]).select { |item| item.to_s.start_with?("/") })
        paths.concat(Array(documents).flat_map { |entry| Array(stringify(entry)["owned_paths"]) })
        paths << ledger.path if ledger && ledger.respond_to?(:path)
        paths << exceptions_path
        program = File.expand_path($PROGRAM_NAME.to_s)
        paths << program if File.file?(program)
        paths.concat($LOADED_FEATURES.select { |path| path.include?("/rplugin/") && path.start_with?("/") })
        paths.concat(%w[/etc/polispec /usr/local/lib/polispec /var/lib/polispec /run/polispec])
        paths << Authorizations::DISABLED_PATH if defined?(Authorizations::DISABLED_PATH)
        paths.compact.map { |path| canonical_path(path) }.uniq.sort
      end

      def exceptions_path
        Exceptions.path
      rescue StandardError
        nil
      end

      def document_controls(entry)
        values = stringify(entry)
        Array(values.dig("document", "controls"))
      end
      private_class_method :document_controls

      def matches?(control, input, actions, context)
        return false unless control.is_a?(Hash) && control["trigger"] == "pre_tool"
        candidates = actions.select { |action| action.action_class == control["action"] }
        return false if candidates.empty?
        candidates.any? { |action| matches_action?(control, input, action, context) }
      end
      private_class_method :matches?

      def matches_action?(control, input, action, context)
        control.is_a?(Hash) && control["trigger"] == "pre_tool" && control["action"] == action.action_class && match_fields?(control["match"] || {}, action, input, context)
      end
      private_class_method :matches_action?

      def match_fields?(match, action, input, context)
        extensions = %w[path tool server operation domain role]
        local = match.select { |key, _| extensions.include?(key.to_s) }
        target = context["target_for"].respond_to?(:call) ? context["target_for"].call(action) : context["target"]
        env = target && target.respond_to?(:env) ? target.env : context["env"] || "dev"
        engine_context = context["engine_context"].is_a?(Hash) ? context["engine_context"] : {}
        legacy = match.reject { |key, _| extensions.include?(key.to_s) }
        findings = engine_context[:findings] || engine_context["findings"]
        before = findings.is_a?(Array) ? findings.length : 0
        legacy_match = Engine::Match.rule?(legacy, action, env, target, engine_context)
        if findings.is_a?(Array) && findings.length > before
          raise Polispec::Error, "control predicate evidence is unavailable"
        end
        return false unless legacy_match
        local.all? do |key, expected|
          case key.to_s
          when "path" then File.fnmatch?(expected.to_s, action.env_hint["path"].to_s, File::FNM_PATHNAME | File::FNM_DOTMATCH)
          when "tool" then expected.to_s == input.tool_name.to_s
          when "server" then expected.to_s == action.env_hint["server"].to_s
          when "operation" then expected.to_s == action.env_hint["operation"].to_s
          when "domain" then expected.to_s == action.env_hint["domain"].to_s
          when "role" then expected.to_s == context["role"].to_s
          else false
          end
        end
      end
      private_class_method :match_fields?

      def restriction_violated?(control, actions)
        params = control["effect_params"] || {}
        paths = params["paths"] || {}
        network = params["network"] || {}
        actions.any? do |action|
          path = action.env_hint["path"].to_s
          if action.action_class == "fs.write" || action.action_class == "fs.delete" || action.action_class == "control.edit"
            allowed = Array(paths["write"])
            paths.key?("write") && allowed.none? { |glob| File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_DOTMATCH) }
          elsif action.action_class == "secrets.read"
            allowed = Array(paths["read"])
            paths.key?("read") && allowed.none? { |glob| File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_DOTMATCH) }
          elsif %w[web.fetch mcp.call].include?(action.action_class) && network["mode"] == "allowlist"
            !Array(network["domains"]).include?(action.env_hint["domain"].to_s)
          else
            false
          end
        end
      end
      private_class_method :restriction_violated?

      def protected_action?(action, paths)
        return false unless %w[fs.write fs.delete control.edit policy.edit].include?(action.action_class)
        target = action.env_hint["path"].to_s
        return false if target.empty?
        absolute = canonical_path(target)
        policy = action.action_class == "policy.edit"
        return false if policy && File.directory?(absolute)
        fallback = policy || action.env_hint["unknown"] == true
        paths.any? do |path|
          protected = canonical_path(path)
          absolute == protected || absolute.start_with?("#{protected}/") || (!fallback && protected.start_with?("#{absolute}/"))
        end
      end
      private_class_method :protected_action?

      def runtime_paths(value)
        case value
        when Hash
          value.flat_map { |key, item| key.to_s.end_with?("path", "realpath") ? [item] : runtime_paths(item) }
        when Array then value.flat_map { |item| runtime_paths(item) }
        else []
        end
      end
      private_class_method :runtime_paths

      def canonical_path(path)
        expanded = File.expand_path(path.to_s)
        existing = expanded
        existing = File.dirname(existing) until File.exist?(existing) || existing == "/"
        File.join(File.realpath(existing), expanded[existing.length..-1].to_s).sub(%r{/+\z}, "").yield_self { |item| item.empty? ? "/" : item }
      rescue SystemCallError
        expanded
      end
      private_class_method :canonical_path

      def result(level, control, asks, observations, injections)
        reason = control && control["reason"].to_s
        reason = "polispec control #{control && control['id']} requires this disposition" if reason.to_s.empty?
        verdict = Verdict.new(level: level, rule_id: control && control["id"] || "POLISPEC-CONTROLS", reason: reason,
                              next_step: level == "allow" ? nil : "Use an operator-authorized control change or exact one-use authorization.")
        { "verdict" => verdict, "ask_ids" => asks.map { |item| item["id"].to_s }.sort, "observations" => observations, "injections" => injections }
      end
      private_class_method :result

      def stringify(value)
        return {} unless value.is_a?(Hash)
        value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
      end
      private_class_method :stringify
    end


    module Guard
      module_function

      def evaluate(input, context)
        values = stringify(context)
        result = Evaluate.call(input, values)
        return result if result["verdict"].deny?
        actions = Array(values["actions"])
        undeclared = actions.select { |action| action.action_class == "mcp.call" }.reject do |action|
          protected = Evaluate.declared_action?(values["documents"], action, input, values, protected_only: true)
          trusted = values["trusted_declaration"].respond_to?(:call) && values["trusted_declaration"].call(action)
          protected || trusted
        end
        unknown = actions.select { |action| action.raw.is_a?(Hash) && action.raw["unknown_tool"] == true }
        return result if undeclared.empty? && unknown.empty?
        lifter = values["excepted"]
        if lifter.respond_to?(:call)
          covered = (unknown + undeclared).map { |action| lifter.call(action) }
          unless covered.any?(&:nil?)
            result["exceptions"] = covered.uniq
            return result
          end
        end
        code = undeclared.empty? ? "POLISPEC-TOOL-UNKNOWN" : "POLISPEC-MCP-UNDECLARED"
        reason = undeclared.empty? ? "the non-read-only tool could not be positively classified" : "one or more MCP operations are not declared by protected controls or committed policy"
        level = values["edition"] == "lock" ? "deny" : "warn"
        result["verdict"] = Verdict.new(level: level, rule_id: code, reason: reason, next_step: "Ask the operator to declare the exact operation.")
        result["ask_ids"] = Array(result["ask_ids"]) + [code] if level == "warn"
        result
      end

      def stringify(value)
        return {} unless value.is_a?(Hash)
        value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
      end
      private_class_method :stringify
    end
  end
end
