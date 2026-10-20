#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "timeout"
require_relative "../harness/hermes"
require_relative "../harness/antigravity"
require_relative "../harness_controls/plane"
require_relative "../harness_controls/lifecycle"
require_relative "../harness_controls/evaluate"
require_relative "../harness_controls/authorizations"
require_relative "../judgments"
require_relative "../exceptions"
require_relative "../editions"
require_relative "../effect"
require_relative "../sessions"
require_relative "../notice"
require_relative "../fastpath"
require_relative "../classify/benign"
require_relative "../classify/shapes"

module Polispec
  module DeferredEvents
    @active = false
    @queue = []

    class << self
      attr_accessor :active
      attr_reader :queue
    end

    def emit(type, fields = {})
      return super unless DeferredEvents.active

      DeferredEvents.queue << [type, fields]
      nil
    end
  end
  Events.singleton_class.prepend(DeferredEvents)

  class InputTooLarge < Polispec::Error; end

  class HookCommand
    HARNESSES = %w[claude codex hermes pi deepseek antigravity].freeze
    ADAPTERS = { "claude" => :Claude, "codex" => :Codex, "hermes" => :Hermes, "antigravity" => :Antigravity }.freeze
    SESSION_LIMIT = 1200
    INPUT_LIMIT = 8_388_608
    HOOK_BUDGET = 7.0
    AUTH_MATERIAL_LIMIT = 262_144
    FIXED_DENIALS = {
      "claude" => ["{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"[POLISPEC internal] guard unavailable; call denied.\"}}\n", 0],
      "codex" => ["{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"[POLISPEC internal] guard unavailable; call denied.\"}}\n", 0],
      "hermes" => ["{\"action\":\"block\",\"message\":\"[POLISPEC internal] guard unavailable; call denied.\"}\n", 2],
      "antigravity" => ["{\"decision\":\"deny\",\"reason\":\"[POLISPEC internal] guard unavailable; call denied.\"}\n", 0],
      "pi" => ["{\"decision\":\"block\",\"reason\":\"[POLISPEC internal] guard unavailable; call denied.\"}\n", 0],
      "deepseek" => ["{\"decision\":\"block\",\"reason\":\"[POLISPEC internal] guard unavailable; call denied.\"}\n", 0]
    }.freeze
    OVERSIZE_REASON = "hook input exceeds 8 MiB; call denied. Split the change into smaller calls."
    USAGE = "usage: polispec hook pretool|session --harness <claude|codex|hermes|pi|deepseek|antigravity>\n       polispec hook git <pre-commit|pre-push|reference-transaction|install|uninstall> [args...]"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      sub = args.shift
      return GitHook.run(args) if sub == "git"

      @subcommand = sub
      indexes = args.each_index.select { |index| args[index] == "--harness" }
      named = indexes.map { |index| args[index + 1].to_s }.select { |name| HARNESSES.include?(name) }.uniq
      @native_harness = named.first if named.length == 1
      harness, options = parse_options(args)
      unless %w[pretool session].include?(sub) && HARNESSES.include?(harness) && !$stdin.tty?
        return hard_deny(@native_harness, Polispec::Error.new("invalid hook invocation")) if sub == "pretool" && HARNESSES.include?(@native_harness)
        return usage
      end
      @native_harness = harness
      @deadline = clock + HOOK_BUDGET
      adapter = Harness.const_get(ADAPTERS.fetch(harness, :Generic)).new(harness)
      DeferredEvents.active = true
      PolicySource.memoize { sub == "pretool" ? pretool(adapter, options) : within_budget { session(adapter) } }
    rescue StandardError, ScriptError => error
      hard_deny(@native_harness, error)
    ensure
      flush_events
    end

    private

    def usage
      warn USAGE
      1
    end

    public

    def explain(harness, raw, options = {})
      raise Polispec::Error, "unknown harness #{harness}" unless HARNESSES.include?(harness)
      @explain = true
      @subcommand = "pretool"
      @deadline = clock + HOOK_BUDGET
      DeferredEvents.active = true
      klass = Harness.const_get(ADAPTERS.fetch(harness, :Generic))
      adapter = Class.new(klass) { def ask?; true; end }.new(harness)
      within_budget do
        PolicySource.memoize do
          input = adapter.parse(raw)
          @input = input
          @diagnostic_read = diagnostic_input?(adapter, input)
          @judged = { "targets" => [], "raw" => nil, "control" => nil, "fastpath_key" => nil, "governed" => false, "mode" => nil, "verdict" => nil, "error" => nil }
          @explain_state = nil
          judge(adapter, input, { "controls_file" => options["controls_file"], "controls_project" => options["controls_project"] })
          raise Polispec::Error, "judgment failed: #{@judged['error']}" if @judged["error"]
          explained(input)
        end
      end
    ensure
      DeferredEvents.queue.clear
      DeferredEvents.active = false
      @explain = false
    end

    private

    def explained(input)
      verdict = @judged["verdict"]
      state = @explain_state || { "actions" => [], "documents" => [] }
      trusted = state["ledger"] ? trusted_declaration(state["ledger"], state["cwd"], state["baseline"], input) : nil
      {
        "verdict" => verdict ? verdict.level.to_s : "allow",
        "rule_id" => verdict ? verdict.rule_id : nil,
        "reason" => verdict ? verdict.reason : nil,
        "governed" => @judged["governed"] == true,
        "control" => @judged["control"] && { "verdict" => @judged["control"]["verdict"], "ask_ids" => @judged["control"]["ask_ids"] },
        "actions" => Array(state["actions"]).map do |action|
          declared = nil
          if action.action_class == "mcp.call"
            declared = HarnessControls::Evaluate.declared_action?(state["documents"], action, input, state["control_context"] || { "actions" => state["actions"] }, protected_only: true)
            declared ||= trusted ? trusted.call(action) == true : false
          end
          { "class" => action.action_class, "server" => action.env_hint["server"], "operation" => action.env_hint["operation"], "declared" => declared }
        end
      }
    end

    def flush_events
      return DeferredEvents.queue.clear if @explain
      queue = DeferredEvents.queue.dup
      DeferredEvents.queue.clear
      DeferredEvents.active = false
      return if queue.empty?
      remaining = remaining_budget
      return unless remaining.positive?
      Timeout.timeout(remaining) do
        $stdout.flush
        detached(queue)
      end
    rescue StandardError
      nil
    end

    def detached(queue)
      return false unless Process.respond_to?(:fork)

      pid = fork do
        begin
          $stdin.reopen(File::NULL)
          $stdout.reopen(File::NULL, "w")
          $stderr.reopen(File::NULL, "w")
          Process.setsid
          emit_all(queue)
        ensure
          exit!(0)
        end
      end
      !pid.nil?
    rescue NotImplementedError, SystemCallError
      false
    end

    def emit_all(queue)
      queue.each { |type, fields| Events.emit(type, fields) }
    end

    def parse_options(args)
      values = { "controls_file" => nil, "controls_project" => nil }
      list = args.dup
      harness = nil
      until list.empty?
        flag = list.shift
        value = list.shift
        return [nil, values] unless %w[--harness --controls-file --controls-project].include?(flag) && value && !value.start_with?("--")
        key = flag.delete_prefix("--").tr("-", "_")
        return [nil, values] if key == "harness" ? harness : values[key]
        if key == "harness"
          harness = value
        else
          return [nil, values] unless value.start_with?("/") && !value.include?("\0")
          values[key] = File.expand_path(value)
        end
      end
      return [nil, values] if values["controls_project"] && !values["controls_file"]
      [harness, values]
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def remaining_budget
      return 0.0 unless @deadline
      [@deadline - clock, 0.0].max
    end

    def within_budget(&block)
      remaining = remaining_budget
      raise Timeout::Error, "hook budget exhausted" unless remaining.positive?
      Timeout.timeout(remaining, &block)
    end

    def pretool(adapter, options)
      within_budget do
        started = clock
        @started = started
        raw = bounded_input
        input = adapter.parse(raw)
        @input = input
        @diagnostic_read = diagnostic_input?(adapter, input)
        output = decide(adapter, input, started, options)
        $stdout.write(output) if output
        adapter.exit_status.to_i
      end
    end

    def decide(adapter, input, started, options)
      @judged = { "targets" => [], "raw" => nil, "control" => nil, "fastpath_key" => nil, "governed" => false, "mode" => nil, "verdict" => nil, "error" => nil }
      @rule_lifts = []
      output = judge(adapter, input, options)
      output = noticed(adapter, input, output)
      record_judgment(adapter, input, started, output)
      output
    end

    def noticed(adapter, input, output)
      @epoch = Effect.epoch(@ledger)
      line = Notice.line_for(input.session_id, @epoch)
      line ? adapter.with_notice(output, line, input.event) : output
    rescue StandardError, ScriptError
      output
    end

    def judge(adapter, input, options)
      cwd = input.cwd.to_s.empty? ? Dir.pwd : input.cwd.to_s
      calls = adapter.calls(input)
      begin
        @plane = HarnessControls::Plane.resolve
        raise Polispec::Error, "sealed authority is broken" if @plane["status"] == "broken"
        @exceptions_active = exceptions_active?
        @exceptions_used = []
        @exception_asks = []
        @exception_entries = nil
        ledger = Ledger.load
        @ledger = ledger
        actions = calls.flat_map { |tool, data| Array(Classify.call(tool, data, cwd)) }
        baseline = Layers.baseline?
        option_applies = options["controls_file"] && (!options["controls_project"] || project_applies?(options["controls_project"], cwd, actions))
        control_gate = @plane["status"] == "active" || option_applies || HarnessControls::Features.enabled?("harness_controls")
        actions.concat(HarnessControls::RootGuard.classify(input.tool_name, input.tool_input, cwd)) if control_gate
        governed = baseline || relevant?(ledger, cwd, calls) || @plane["status"] == "active" || option_applies
        opaque = control_gate && governed && calls.any? { |tool, data| Classify.opaque_shell?(tool, data, cwd) }
        if control_gate && actions.empty? && governed
          known = calls.flat_map { |tool, data| Classify.positive(tool, data, cwd) }
          actions.concat(known)
          actions << unknown_action(input, cwd, calls, false, opaque) if known.empty? && !(calls.any? && calls.all? { |tool, data| Classify.benign?(tool, data, cwd) || Classify.parsed_shell?(tool, data, cwd) })
        end
        if opaque && actions.none? { |action| action.raw.is_a?(Hash) && action.raw["unknown_tool"] }
          actions << unknown_action(input, cwd, calls, true, true)
        end
        groups = group(actions, ledger, cwd, baseline)
        @explain_state = { "actions" => actions, "ledger" => ledger, "cwd" => cwd, "baseline" => baseline, "documents" => [] } if @explain
        mode = enforce_mode
        @judged["mode"] = mode
        @policy_digests = []
        @outcome_authority = {}
        outcomes = groups.map do |kind, project, list|
          if kind == :live
            evaluate(adapter, input, ledger, cwd, project, list, mode)
          else
            evaluate_baseline(adapter, input, ledger, cwd, project, list, mode)
          end
        end
      rescue StandardError, ScriptError => error
        raise unless @diagnostic_read

        @judged["error"] = error.class.name
        return nil
      end
      legacy = outcomes.max_by { |outcome| outcome.verdict.severity }
      unless control_gate
        @judged["governed"] = governed || !legacy.nil?
        @judged["verdict"] = legacy && legacy.verdict
        stamp_exceptions({})
        return mode == "enforce" && legacy ? adapter.render(legacy.verdict) : nil
      end
      documents = control_documents(adapter, input, cwd, actions, options)
      @explain_state["documents"] = documents if @explain
      governed ||= !documents.empty?
      @judged["governed"] = governed
      return nil unless governed

      edition = HarnessControls::Plane.requested_edition
      scan = HarnessControls::Environment.guard_state(plane: @plane)
      explicit_root_guard = Engine::Settings.root_guard
      effective_digest = HarnessControls::Evaluate.effective_digest(documents)
      fast_context = { "plane" => @plane, "control_digest" => effective_digest, "edition" => edition,
                       "fail_mode" => "closed_mutations", "root_guard" => scan["root_guard"] == true || explicit_root_guard,
                       "mcp_default" => Editions.included?("mcp_default.ask", edition) ? "ask" : "deny" }
      Fastpath.refresh(ledger, fast_context) unless @explain
      @judged["fastpath_key"] = fastpath_key(ledger, fast_context)
      protected_paths = HarnessControls::Evaluate.protected_paths(@plane, documents, ledger)
      target_for = control_target_resolver(ledger, cwd, baseline)
      control_context = {
        "actions" => actions, "documents" => documents, "edition" => edition,
        "root_guard" => !Editions.allowed?("root_guard.optional", edition) || explicit_root_guard || scan["root_guard"] == true,
        "protected_paths" => protected_paths, "role" => input.agent_type,
        "env" => legacy && legacy.env, "target" => nil, "target_for" => target_for,
        "engine_context" => { cwd: cwd, ledger: ledger, predicate_memo: {}, findings: [] },
        "trusted_declaration" => trusted_declaration(ledger, cwd, baseline, input),
        "excepted" => control_lifter(input, cwd)
      }
      @explain_state["control_context"] = control_context if @explain
      control = Controls.evaluate(input, control_context)
      worst = compose_ask_authority(control, adapter, input, actions, documents, edition, outcomes, ledger, cwd)
      @judged["control"] = { "control_digest" => effective_digest, "edition" => edition, "verdict" => control["verdict"] ? control["verdict"].level.to_s : "allow", "ask_ids" => Array(control["ask_ids"]).map(&:to_s) }
      stamp_exceptions(control)
      propose_exceptions(worst, outcomes, input, cwd)
      @judged["verdict"] = worst
      emit_control_events(control, adapter, input, cwd)
      output = mode == "enforce" ? adapter.render(worst) : nil
      if output.nil? && worst.allow? && !control["injections"].empty?
        output = adapter.render_context(control["injections"].map { |item| item.dig("effect_params", "text") }.compact.join("\n"), input.event)
      end
      output
    end

    def bounded_input
      bytes = +""
      loop do
        chunk = $stdin.readpartial(4096)
        raise Polispec::InputTooLarge, "hook input exceeds #{INPUT_LIMIT} bytes" if chunk.bytesize > INPUT_LIMIT - bytes.bytesize
        bytes << chunk
      end
    rescue EOFError
      raise Polispec::Error, "hook input is empty" if bytes.empty?
      bytes
    end

    def hard_deny(harness, error)
      return usage unless @subcommand == "pretool" && HARNESSES.include?(harness)
      bytes, status = FIXED_DENIALS.fetch(harness)
      bytes = bytes.sub("guard unavailable; call denied.", OVERSIZE_REASON) if error.is_a?(Polispec::InputTooLarge)
      $stdout.write(bytes)
      record_failure(harness, error, bytes)
      status
    rescue Errno::EPIPE, IOError
      1
    end

    def control_documents(adapter, input, cwd, actions, options)
      rows = []
      key = adapter.name == "claude" ? "claude-code" : adapter.name
      if @plane["status"] == "active"
        path = @plane.dig("controls", key)
        rows << load_control_document(path, true, "managed", "/") if path
        overlays = HarnessControls::Lifecycle.effective_receipts(harness: key, cwd: cwd)
        rows.concat(Array(overlays["receipts"]))
      elsif options["controls_file"]
        project = options["controls_project"]
        unless project && !project_applies?(project, cwd, actions)
          scope = project ? "project" : "user"
          root = project || File.join(Dir.home, ".config", "polispec")
          expected = project ? File.join(root, ".polispec", "harness", key, "controls.json") : File.join(root, "harness", key, "controls.json")
          raise Polispec::Error, "control document path is not the canonical #{scope} target" unless canonical_path(options["controls_file"]) == canonical_path(expected)
          boundary = project || File.dirname(options["controls_file"])
          rows << load_control_document(options["controls_file"], false, scope, boundary)
        end
        overlays = HarnessControls::Lifecycle.effective_receipts(harness: key, cwd: cwd)
        rows.concat(Array(overlays["receipts"]))
      end
      rows
    end

    def load_control_document(path, protected, scope, boundary)
      raise Polispec::Error, "control document path is unavailable" unless path.is_a?(String) && path.start_with?("/") && File.file?(path) && !File.symlink?(path)
      bytes = File.binread(path, 1_048_577)
      raise Polispec::Error, "control document exceeds 1 MiB" if bytes.bytesize > 1_048_576
      document = JSON.parse(bytes)
      errors = Controls.validate(document)
      raise Polispec::Error, "control document is invalid: #{errors.first && errors.first['message']}" unless errors.empty?
      digest = Digest::SHA256.hexdigest(JSON.generate(canonical_value(document)))
      { "document" => document, "control_digest" => digest, "scope" => scope, "boundary" => boundary, "protected" => protected, "owned_paths" => [path] }
    rescue JSON::ParserError => error
      raise Polispec::Error, "control document JSON is invalid: #{error.message}"
    end

    def project_applies?(root, cwd, actions)
      boundary = canonical_path(root)
      candidates = [cwd] + actions.map { |action| action.env_hint["path"] }.compact
      candidates.any? do |path|
        value = canonical_path(path)
        value == boundary || value.start_with?("#{boundary}/")
      end
    end

    def control_target_resolver(ledger, cwd, baseline)
      cache = {}
      lambda do |action|
        key = action.__id__
        next cache[key] if cache.key?(key)
        owner = Engine::Envs.owner(action, ledger, cwd)
        if owner && owner.status == "live"
          loaded = PolicySource.resolve(owner, ledger: ledger)
          env = Engine::Envs.cwd_env(loaded.policy, ledger, owner.id, cwd)
          target = Target.new(project: owner.id, env: env, policy: loaded.policy, roster: nil, policy_source: loaded.source, digest: loaded.digest)
          target.env = Engine::Envs.for_action(action, target, { cwd: cwd, ledger: ledger })
          cache[key] = target
        elsif baseline
          id = owner ? owner.id : (Engine::Envs.path_entry(action, ledger, cwd) || GLOBAL_ENTRY).id
          path = !owner && id != GLOBAL_ID
          env = id == GLOBAL_ID || path ? "dev" : Engine::Envs.cwd_env({}, ledger, id, cwd)
          target = Target.new(project: id, env: env, policy: { "rules" => [] }, roster: nil, policy_source: path ? "path" : "global", digest: Layers.fingerprint)
          target.env = Engine::Envs.for_action(action, target, { cwd: cwd, ledger: ledger })
          cache[key] = target
        else
          cache[key] = Target.new(project: GLOBAL_ID, env: "dev", policy: { "rules" => [] }, roster: nil, policy_source: "controls", digest: nil)
        end
      end
    end

    def trusted_declaration(ledger, cwd, baseline, input)
      target_for = control_target_resolver(ledger, cwd, baseline)
      lambda do |action|
        target = target_for.call(action)
        next false unless target && target.policy.is_a?(Hash)
        matcher = lambda do |candidate|
          match = candidate["match"] || {}
          next false unless declares?(match, action)
          context = { cwd: cwd, ledger: ledger, predicate_memo: {}, findings: [], tool: input.tool_name.to_s, role: input.agent_type.to_s }
          matched = Engine::Match.rule?(match, action, target.env, target, context)
          raise Polispec::Error, "policy declaration predicate evidence is unavailable" unless context[:findings].empty?
          matched
        end
        rule = if target.policy_source == "controls"
                 action.action_class == "mcp.call" ? nil : Layers.shipped_rules.find(&matcher)
               else
                 Layers.pick(target, { cwd: cwd, ledger: ledger }, &matcher).first
               end
        note_relaxed(rule, ledger, cwd)
        !rule.nil?
      end
    end

    def declares?(match, action)
      hint = action.env_hint || {}
      raw = action.raw.is_a?(Hash) ? action.raw : {}
      if action.action_class == "mcp.call"
        exact = match["server"].to_s == hint["server"].to_s && match["operation"].to_s == hint["operation"].to_s
        exact && !match["server"].to_s.empty? && !match["operation"].to_s.empty?
      elsif raw["opaque"] == true
        Array(match["shape"]).include?("opaque_shell")
      elsif raw["unknown_tool"] == true
        !match["tool"].to_s.empty? && match["tool"].to_s.casecmp?(hint["tool"].to_s)
      else
        false
      end
    end

    def note_relaxed(rule, ledger, cwd)
      return unless @judged && rule.is_a?(Hash) && rule.dig("match", "in_development") == true

      @judged["relaxed"] = [{ "rule" => "POLISPEC-TOOL-UNKNOWN", "reason" => "development", "projects" => ledger.development(cwd) }]
    end

    def compose_ask_authority(control, adapter, input, actions, documents, edition, outcomes, ledger, cwd)
      legacy_verdicts = Array(outcomes).map(&:verdict).compact
      control_verdict = control["verdict"]
      independent = legacy_verdicts + [control_verdict]
      return Verdict.worst(independent) if independent.any?(&:deny?)
      return Verdict.worst(independent) if adapter.ask?
      warning_rows = environment_warning_rows(outcomes)
      legacy_warn = !warning_rows.empty?
      control_warn = control_verdict.warn?
      return Verdict.worst(independent) unless legacy_warn || control_warn
      return Verdict.worst(independent) if !Editions.included?("legacy_warn", edition) && (control_warn || !legacy_warn)
      return Verdict.worst(independent) if @plane["status"] != "active" && !control_warn

      ask_set = warning_rows.map { |row| ["environment", *row] }
      ask_set.concat(Array(control["ask_ids"]).map { |id| ["control", id.to_s] }) if control_warn
      ask_set = ask_set.uniq.sort_by { |row| row.map(&:to_s) }
      control_digest = HarnessControls::Evaluate.effective_digest(documents)
      policy_digests = Array(@policy_digests).compact.map(&:to_s).uniq.sort
      rule_id = "ask_#{Digest::SHA256.hexdigest(JSON.generate([ask_set, policy_digests, control_digest]))}"
      session = input.session_id.to_s
      return authorization_denial(rule_id, "protected authorization requires an actual nonempty session identity") if session.empty?
      target_pairs = warning_rows.map { |row| row.values_at(0, 1) }.uniq.sort
      project, env = authorization_target(target_pairs, documents)
      action_material = canonical_value({
        "tool" => input.tool_name.to_s, "arguments" => input.tool_input, "cwd" => canonical_path(cwd),
        "actions" => actions.map(&:to_h), "asks" => ask_set, "policy_digests" => policy_digests,
        "control_digest" => control_digest, "harness" => adapter.name, "session" => session,
        "governed_targets" => target_pairs
      })
      material_bytes = JSON.generate(action_material)
      raise Polispec::Error, "authorization material exceeds its bounded representation" if material_bytes.bytesize > AUTH_MATERIAL_LIMIT
      action_digest = Digest::SHA256.hexdigest(material_bytes)
      return authorization_denial(rule_id, "exact operator authorization requires an active protected plane") unless @plane["status"] == "active"
      context = {
        "generation" => @plane["generation"].to_s, "project" => project, "action_digest" => action_digest,
        "rule_id" => rule_id, "session_id" => session, "harness" => adapter.name,
        "action_class" => actions.map(&:action_class).uniq.sort.join(","),
        "env" => env
      }
      return Verdict.new(level: "allow", rule_id: rule_id, reason: "the exact protected one-use authorization was consumed") if HarnessControls::Authorizations.consume(context)
      id = HarnessControls::Authorizations.request(context)
      Verdict.new(level: "deny", rule_id: rule_id, reason: "the exact composed ask set awaits operator authorization", next_step: "The operator may redeem #{id} through the protected authorizations command.", allow_once_id: id)
    rescue HarnessControls::Authorizations::Failure => error
      authorization_denial("POLISPEC-AUTHORIZATION-UNAVAILABLE", "protected authorization is unavailable (#{error.code})")
    end

    def environment_warning_rows(outcomes)
      Array(outcomes).flat_map do |outcome|
        authority = @outcome_authority[outcome.object_id] || {}
        Array(outcome.rows).select { |row| row.verdict.warn? }.map do |row|
          [authority["project"].to_s, row.env.to_s, row.verdict.rule_id.to_s, authority["policy_digest"].to_s]
        end
      end.uniq.sort
    end

    def authorization_target(pairs, documents)
      if pairs.empty?
        scopes = Array(documents).map { |entry| [entry["scope"], entry["boundary"], entry["control_digest"]] }.sort_by { |row| row.map(&:to_s) }
        bytes = JSON.generate(scopes)
        raise Polispec::Error, "control scope identity exceeds its bounded representation" if bytes.bytesize > AUTH_MATERIAL_LIMIT
        return ["scope_#{Digest::SHA256.hexdigest(bytes)}", "controls"]
      end
      pairs.each do |project, env|
        raise Polispec::Error, "governed authorization target is invalid" if project.empty? || env.empty? || project.bytesize > 256 || env.bytesize > 256
      end
      return pairs.first if pairs.length == 1
      bytes = JSON.generate(pairs)
      raise Polispec::Error, "governed authorization targets exceed their bounded representation" if bytes.bytesize > AUTH_MATERIAL_LIMIT
      digest = Digest::SHA256.hexdigest(bytes)
      ["multi_#{digest}", "multi_#{digest}"]
    end

    def authorization_denial(rule_id, reason)
      Verdict.new(level: "deny", rule_id: rule_id, reason: reason, next_step: "Restore the protected authorization service and retry.")
    end

    def emit_control_events(control, adapter, input, cwd)
      return if @explain
      Array(control["observations"]).each do |entry|
        metadata = entry.dig("effect_params", "metadata")
        Events.emit("polispec.control.observed", { "control_id" => entry["id"], "harness" => adapter.name, "event" => "control.observed", "metadata" => metadata })
      end
    rescue StandardError
      nil
    end

    def policy_declares?(ledger, cwd, action_class)
      located = ledger.locate(cwd)
      return false unless located && located.project.status == "live"
      policy = PolicySource.resolve(located.project, ledger: ledger).policy
      Array(policy["rules"]).any? { |rule| Array((rule["match"] || {})["class"]).include?(action_class) }
    rescue StandardError
      false
    end

    def diagnostic_read?(tool_name)
      Harness::Base::READ_TOOLS.map(&:downcase).include?(tool_name.to_s.downcase)
    end

    def diagnostic_input?(adapter, input)
      calls = adapter.calls(input)
      names = Harness::Base::READ_TOOLS.map(&:downcase)
      !calls.empty? && calls.all? do |tool, data|
        next false unless names.include?(tool.to_s.downcase) && data.is_a?(Hash)
        path = Harness::Base::PATH_KEYS.map { |key| data[key] }.find { |value| value.is_a?(String) && !value.empty? }
        !path.nil?
      end
    rescue StandardError
      false
    end

    def exceptions_active?
      Exceptions.active?(HarnessControls::Plane.requested_edition, @plane["status"])
    rescue StandardError
      false
    end

    def exception_entries
      @exception_entries ||= Exceptions.load.entries
    end

    def shell_tool?(name)
      Harness::Base::SHELL_TOOLS.include?(name.to_s)
    end

    def exception_triggers(input, cwd, calls, opaque)
      return [] unless shell_tool?(input.tool_name)

      list = calls.flat_map do |tool, data|
        if opaque
          Classify.opaque_shell?(tool, data, cwd) ? Classify.opaque_commands(tool, data, cwd) : []
        else
          [Classify::Support.command_text(tool, data)]
        end
      end
      list.compact.map { |text| Exceptions.normalize(text) }.reject(&:empty?).uniq
    end

    def control_lifter(input, cwd)
      return nil unless @exceptions_active

      lambda do |action|
        found = []
        asks = []
        if action.raw.is_a?(Hash) && action.raw["unknown_tool"] == true
          name = action.raw["tool"].to_s
          tool = Exceptions.canonical_tool(name)
          if shell_tool?(name)
            Array(action.raw["triggers"]).each do |trigger|
              id = Exceptions.covers(exception_entries, kind: "control", tool: tool, command: trigger, cwd: cwd)
              id ? found << id : asks << { "tool" => tool, "command" => trigger }
            end
            asks << nil if Array(action.raw["triggers"]).empty?
          else
            id = Exceptions.covers(exception_entries, kind: "control", tool: tool, cwd: cwd)
            id ? found << id : asks << { "tool" => tool, "command" => nil }
          end
        else
          id = Exceptions.covers(exception_entries, kind: "control", tool: input.tool_name.to_s, cwd: cwd)
          id ? found << id : asks << { "tool" => input.tool_name.to_s, "command" => nil }
        end
        @exceptions_used.concat(found)
        @exception_asks.concat(asks.compact)
        asks.empty? ? found.first : nil
      end
    end

    def rule_lifter(input, cwd)
      return nil unless @exceptions_active

      lambda do |row|
        raw = row.action.raw
        next nil unless row.verdict.warn? && raw.is_a?(String) && Exceptions.canonical_tool(input.tool_name) == "Bash"

        id = Exceptions.covers(exception_entries, kind: "rule", tool: "Bash", command: raw, rule: row.verdict.rule_id, cwd: cwd)
        @rule_lifts << [row.action, id] if id && @rule_lifts
        id
      end
    end

    def stamp_exceptions(control)
      used = (Array(control["exceptions"]) + Array(@exceptions_used)).flatten.compact.uniq
      @judged["exceptions"] = used unless used.empty?
      Array(control["exceptions"]).flatten.compact.uniq.each { |id| (@judged["exception_rows"] ||= []) << { "row" => -1, "entry" => id } }
    end

    def propose_exceptions(worst, outcomes, input, cwd)
      return unless @exceptions_active && !@explain && @plane["status"] != "active" && worst.warn?

      proposed = {}
      @exception_asks.uniq.each do |ask|
        id = Exceptions.propose(kind: "control", tool: ask["tool"], command: ask["command"], cwd: cwd)
        proposed[id] ||= ask["command"] || ask["tool"] if id
      end
      if Exceptions.canonical_tool(input.tool_name) == "Bash"
        Array(outcomes).flat_map { |outcome| Array(outcome.rows) }.select { |row| row.verdict.warn? && row.action.raw.is_a?(String) }.uniq { |row| [row.action.raw, row.verdict.rule_id] }.each do |row|
          id = Exceptions.propose(kind: "rule", tool: "Bash", command: row.action.raw, rule: row.verdict.rule_id, cwd: cwd)
          proposed[id] ||= "#{row.verdict.rule_id}: #{Exceptions.normalize(row.action.raw)}" if id
        end
      end
      return if proposed.empty?

      shown = proposed.first(5)
      more = proposed.length - shown.length
      labels = shown.map { |_, label| label.to_s.length > 80 ? "#{label.to_s[0, 77]}..." : label.to_s }.join("; ")
      hint = "To stop asking for [#{labels}]#{more.positive? ? " and #{more} more" : ''}, the operator can run in a separate terminal: polispec exceptions promote #{shown.map(&:first).join(' ')}"
      worst.next_step = [worst.next_step, hint].compact.join(" ")
    rescue StandardError
      nil
    end

    def unknown_action(input, cwd, calls = [], opaque = false, shaped = opaque)
      name = input.tool_name.to_s
      klass = shaped ? "shell.exec" : diagnostic_read?(name) ? "tool.read" : "tool.internal"
      raw = { "unknown_tool" => true, "tool" => name }
      raw["opaque"] = true if shaped
      raw["triggers"] = exception_triggers(input, cwd, calls, opaque) if @exceptions_active
      hint = { "path" => cwd, "tool" => name }
      hint.merge!("shape" => ["opaque_shell"], "cwds" => calls.flat_map { |tool, data| Classify.command_cwds(tool, data, cwd) }.uniq) if shaped
      Action.new(class: klass, env_hint: hint, raw: raw)
    end

    def canonical_value(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
          source = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          result[key] = canonical_value(value[source])
        end
      when Array then value.map { |item| canonical_value(item) }
      else value
      end
    end

    def canonical_path(path)
      expanded = File.expand_path(path.to_s)
      existing = expanded
      existing = File.dirname(existing) until File.exist?(existing) || existing == "/"
      joined = File.join(File.realpath(existing), expanded[existing.length..-1].to_s).sub(%r{/+\z}, "")
      joined.empty? ? "/" : joined
    rescue SystemCallError
      expanded
    end

    def relevant?(ledger, cwd, calls)
      live = ledger.projects.select { |project| project.status == "live" }
      return false if live.empty?

      located = ledger.locate(cwd)
      return true if located && located.project.status == "live"

      haystack = calls.map { |_, data| [data["command"], data["file_path"], data["path"], data["notebook_path"]].compact.join(" ") }.join(" ").downcase
      live.any? { |project| needles(project, ledger).any? { |needle| haystack.include?(needle) } }
    end

    def needles(project, ledger)
      root = File.expand_path(ledger.envs_root)
      [project.id, File.basename(project.repo.to_s), root, File.join(File.basename(File.dirname(root)), File.basename(root))].map(&:downcase).reject(&:empty?)
    end

    def group(actions, ledger, cwd, baseline = false)
      groups = {}
      actions.each do |action|
        owner = Engine::Envs.owner(action, ledger, cwd)
        if owner && owner.status == "live"
          (groups[[:live, owner.id]] ||= [:live, owner, []])[2] << action
        elsif baseline && !(owner && owner.status == "retired")
          id = owner ? owner.id : (Engine::Envs.path_entry(action, ledger, cwd) || GLOBAL_ENTRY).id
          (groups[[:baseline, id]] ||= [:baseline, id, []])[2] << action
        end
      end
      groups.values
    end

    GLOBAL_ID = "global"
    GLOBAL_ENTRY = Struct.new(:id).new(GLOBAL_ID)

    def evaluate_baseline(adapter, input, ledger, cwd, id, actions, mode)
      path = id != GLOBAL_ID && ledger.project(id).nil? && !ledger.path_entry(id).nil?
      env = id == GLOBAL_ID || path ? "dev" : Engine::Envs.cwd_env({}, ledger, id, cwd)
      digest = Layers.fingerprint
      @policy_digests << digest unless digest.to_s.empty?
      target = Target.new(project: id, env: env, policy: { "rules" => [] }, roster: nil, policy_source: path ? "path" : "global", digest: digest)
      context = { ledger: ledger, cwd: cwd, session_id: input.session_id, role: (input.agent_type.to_s.empty? ? nil : input.agent_type), tool: input.tool_name.to_s, issue_allow_once: mode == "enforce" && !adapter.ask? }
      context.merge!(excepted: rule_lifter(input, cwd), exceptions_used: @exceptions_used) if @exceptions_active
      outcome = Engine.explain(actions, target, context)
      @outcome_authority[outcome.object_id] = { "project" => target.project, "policy_digest" => target.digest }
      note_target(target, outcome, context)
      outcome
    end

    def evaluate(adapter, input, ledger, cwd, project, actions, mode)
      loaded = PolicySource.resolve(project, ledger: ledger)
      @policy_digests << loaded.digest unless loaded.digest.to_s.empty?
      target = Target.new(
        project: project.id, env: Engine::Envs.cwd_env(loaded.policy, ledger, project.id, cwd), policy: loaded.policy,
        roster: nil, policy_source: loaded.source, digest: loaded.digest
      )
      context = { ledger: ledger, cwd: cwd, session_id: input.session_id, role: (input.agent_type.to_s.empty? ? nil : input.agent_type), tool: input.tool_name.to_s, issue_allow_once: mode == "enforce" && !adapter.ask? }
      context.merge!(excepted: rule_lifter(input, cwd), exceptions_used: @exceptions_used) if @exceptions_active
      outcome = Engine.explain(actions, target, context)
      @outcome_authority[outcome.object_id] = { "project" => target.project, "policy_digest" => target.digest }
      note_target(target, outcome, context)
      outcome
    end

    def note_target(target, outcome, context)
      offset = @judged["targets"].sum { |entry| Array(entry["rows"]).length }
      @judged["targets"] << Judgments.target(target, outcome, context)
      note_exception_rows(outcome, offset)
      @judged["raw"] ||= Array(outcome.rows).map { |row| row.action.raw.to_s }.find { |text| !text.empty? }
    rescue StandardError
      nil
    end

    def note_exception_rows(outcome, offset)
      return if @rule_lifts.nil? || @rule_lifts.empty?

      Array(outcome.rows).each_with_index do |row, index|
        found = @rule_lifts.index { |action, _| action.equal?(row.action) }
        next unless found

        (@judged["exception_rows"] ||= []) << { "row" => offset + index, "entry" => @rule_lifts.delete_at(found).last }
      end
    rescue StandardError
      nil
    end

    def fastpath_key(ledger, context)
      Fastpath.key(ledger, context)
    rescue StandardError
      nil
    end

    def record_judgment(adapter, input, started, output)
      judged = @judged || {}
      Judgments.record do
        cwd = input.cwd.to_s.empty? ? Dir.pwd : input.cwd.to_s
        {
          "action" => Judgments.action(tool: input.tool_name, harness: adapter.name, event: input.event, session_id: input.session_id, agent_type: input.agent_type, cwd: cwd, arguments: input.tool_input, raw: judged["raw"]),
          "targets" => Array(judged["targets"]), "control" => judged["control"],
          "engine" => Judgments.engine(judged["mode"], plane: @plane, fastpath_key: judged["fastpath_key"]),
          "outcome" => Judgments.outcome(judged["verdict"], enforced: judged["mode"] == "enforce", rendered: Judgments.rendered(output), governed: judged["governed"], error: judged["error"], duration_ms: ((clock - started) * 1000).round(2))
        }.tap { |record| record["exceptions"] = judged["exceptions"] if judged["exceptions"].is_a?(Array) && !judged["exceptions"].empty? }.tap { |record| record["relaxed"] = judged["relaxed"] if judged["relaxed"].is_a?(Array) && !judged["relaxed"].empty? }.tap { |record| record["epoch"] = @epoch if @epoch }.tap { |record| record["exception_rows"] = judged["exception_rows"] if judged["exception_rows"].is_a?(Array) && !judged["exception_rows"].empty? }
      end
    end

    def record_failure(harness, error, bytes)
      input = @input || Harness::Input.new(tool_name: nil, tool_input: nil, cwd: nil, session_id: nil, agent_type: nil, event: nil)
      judged = @judged || {}
      Judgments.record do
        cwd = input.cwd.to_s.empty? ? Dir.pwd : input.cwd.to_s
        verdict = Verdict.new(level: "deny", rule_id: Judgments::INTERNAL_RULE, reason: "#{error.class}: #{error.message.to_s[0, 200]}")
        {
          "action" => Judgments.action(tool: input.tool_name, harness: harness, event: input.event, session_id: input.session_id, agent_type: input.agent_type, cwd: cwd, arguments: input.tool_input, raw: judged["raw"]),
          "targets" => Array(judged["targets"]), "control" => judged["control"],
          "engine" => Judgments.engine(judged["mode"], plane: @plane, fastpath_key: judged["fastpath_key"]),
          "outcome" => Judgments.outcome(verdict, enforced: true, rendered: Judgments.rendered(bytes), governed: true, error: error.class.name, duration_ms: @started ? ((clock - @started) * 1000).round(2) : nil)
        }.tap { |record| (epoch = Effect.epoch(@ledger)) && record["epoch"] = epoch }
      end
    end

    def internal(adapter, input, error)
      Events.emit("polispec.finding", project: nil, kind: "internal", detail: "#{error.class}: #{error.message.to_s[0, 200]}", policy_source: nil)
      return nil unless input && enforcing? && deny_on_error?(adapter, input)

      adapter.render_deny("[POLISPEC internal] the guard failed while judging this call (#{error.class}) and fails closed for it. Run `polispec doctor`, or ask #{Engine::Settings.operator}.")
    rescue StandardError
      nil
    end

    def enforcing?
      enforce_mode == "enforce"
    rescue StandardError
      true
    end

    def deny_on_error?(adapter, input)
      state = ledger_state(input)
      return false if state == :elsewhere
      return true if state == :ledgered && adapter.writer?(input)

      adapter.shell?(input) && Harness::Base::INLINE_PROD.match?(adapter.command_text(input))
    end

    def ledger_state(input)
      cwd = input.cwd.to_s.empty? ? Dir.pwd : input.cwd.to_s
      located = Ledger.load.locate(cwd)
      located && located.project.status == "live" ? :ledgered : :elsewhere
    rescue StandardError
      :unknown
    end

    def enforce_mode
      Engine::Settings.enforce_mode
    end

    def session(adapter)
      input = session_input(adapter, bounded_input)
      cwd = input.cwd.to_s.empty? ? Dir.pwd : input.cwd.to_s
      ledger = Ledger.load
      located = ledger.locate(cwd)
      live = located && located.project.status == "live"
      text = live ? SessionText.new(ledger, located.project, input, cwd, enforce_mode).to_s : ""
      note_session(adapter, input, ledger, located, cwd, text)
      return 0 unless live

      $stdout.write(adapter.render_session(text, input.event)) unless text.empty?
      0
    rescue Errno::EPIPE, IOError, Polispec::Error
      1
    end

    def note_session(adapter, input, ledger, located, cwd, text)
      return unless %w[SessionStart SubagentStart].include?(input.event.to_s)

      Sessions.record(session_id: input.session_id, harness: adapter.name, event: input.event, agent_type: input.agent_type, cwd: cwd,
                      project: located ? located.project.id : nil, epoch: Effect.epoch(ledger), text: text)
    rescue StandardError, ScriptError
      nil
    end

    def session_input(_adapter, raw)
      data = JSON.parse(raw)
      raise Polispec::Error, "session hook input must be an object" unless data.is_a?(Hash)
      workspaces = data["workspacePaths"]
      cwd = data["cwd"] || data["workdir"] || data["working_directory"]
      cwd ||= workspaces.first if workspaces.is_a?(Array) && workspaces.first.is_a?(String)
      session_id = data["session_id"] || data["sessionId"] || data["session"] || data["conversationId"]
      event = data["hook_event_name"] || data["event"] || "SessionStart"
      Harness::Input.new(tool_name: nil, tool_input: {}, cwd: cwd, session_id: session_id, agent_type: data["agent_type"] || data["profile"] || data["modelName"], event: event)
    rescue JSON::ParserError => error
      raise Polispec::Error, "invalid session hook JSON: #{error.message}"
    end

    class SessionText
      def initialize(ledger, project, input, cwd, mode)
        @ledger = ledger
        @project = project
        @input = input
        @cwd = cwd
        @mode = mode
        @loaded = PolicySource.resolve(project, ledger: ledger)
        @policy = @loaded.policy
        @roster = PolicySource.load_roster(project)
      end

      def to_s
        required = [headline, branches, state_line, policy_line].compact
        optional = [role_line, roles_line] + instructions
        fit(required, optional.compact)
      end

      private

      def env
        @env ||= Engine::Envs.cwd_env(@policy, @ledger, @project.id, @cwd)
      end

      def envs
        Engine::Envs.environments(@policy)
      end

      def headline
        "POLISPEC: #{@project.id} is a live project. You are in its #{env} environment (branch #{branch_of(env)}). Verdicts: allow, warn (ask the user first), deny (stop; relay the next step)."
      end

      def branch_of(name)
        (envs[name] || {})["branch"] || name
      end

      def branches
        "Branches: dev=#{branch_of('dev')}, test=#{branch_of('test')} (agents move it only with `polispec promote #{@project.id} --to test`), prod=#{branch_of('prod')} (operator only; never touch it, its checkout, services or secrets)."
      end

      def state_line
        parts = []
        pause = Engine::Pauses.active(@ledger, @project.id)
        parts << "PAUSED until #{pause['expires_at']}" if pause
        windows = %w[promote.to_stable desk.dispatch].flat_map { |scope| Freeze.active(@policy, scope, project: @project) }
        parts << "FROZEN: #{windows.map(&:label).uniq.join('; ')}" unless windows.empty?
        parts.empty? ? nil : "Active: #{parts.join(' | ')}."
      end

      def policy_line
        digest = @loaded.digest.to_s.sub("sha256:", "")[0, 12]
        source = @loaded.source == "defaults" ? "LEDGER DEFAULTS (#{@loaded.finding && @loaded.finding['kind']})" : @loaded.source[0, 20]
        "Policy #{digest} from #{source}; guard mode #{@mode}."
      end

      def role_line
        return nil unless @roster && @input.agent_type

        role = (@roster["roles"] || {}).find { |name, spec| name == @input.agent_type || (spec["default"] || {})["agent"] == @input.agent_type }
        role ? "Your role: #{describe(role[0], role[1])}." : nil
      end

      def roles_line
        return nil unless @roster && @roster["roles"].is_a?(Hash) && !@roster["roles"].empty?

        "Role defaults: #{@roster['roles'].map { |name, spec| describe(name, spec) }.join('; ')}."
      end

      def describe(name, spec)
        default = spec["default"] || {}
        shape = [default["harness"], default["model"], default["effort"]].compact.join("/")
        "#{name}=#{shape}"
      end

      def instructions
        Array((@policy["agents"] || {})["instructions"]).map { |line| "- #{line}" }
      end

      def fit(required, optional)
        text = required.join("\n")
        optional.each do |line|
          candidate = "#{text}\n#{line}"
          text = candidate if candidate.length <= SESSION_LIMIT
        end
        text.length > SESSION_LIMIT ? "#{text[0, SESSION_LIMIT - 3]}..." : text
      end
    end
  end
end

Polispec::CLI.register("hook", Polispec::HookCommand, summary: "harness hook entry point: pretool and session")
