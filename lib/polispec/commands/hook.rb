#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

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

  class HookCommand
    HARNESSES = %w[claude codex hermes pi deepseek antigravity].freeze
    ADAPTERS = { "claude" => :Claude, "codex" => :Codex }.freeze
    SESSION_LIMIT = 1200
    USAGE = "usage: polispec hook pretool|session --harness <claude|codex|hermes|pi|deepseek|antigravity>\n       polispec hook git <pre-commit|pre-push|reference-transaction|install|uninstall> [args...]"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      sub = args.shift
      return GitHook.run(args) if sub == "git"

      harness = harness_from(args)
      return usage unless %w[pretool session].include?(sub) && HARNESSES.include?(harness) && !$stdin.tty?

      adapter = Harness.const_get(ADAPTERS.fetch(harness, :Generic)).new(harness)
      DeferredEvents.active = true
      sub == "pretool" ? pretool(adapter) : session(adapter)
      0
    rescue StandardError, ScriptError
      0
    ensure
      flush_events
    end

    private

    def usage
      warn USAGE
      1
    end

    def flush_events
      queue = DeferredEvents.queue.dup
      DeferredEvents.queue.clear
      DeferredEvents.active = false
      return if queue.empty?

      $stdout.flush
      emit_all(queue) unless detached(queue)
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

    def harness_from(args)
      index = args.index("--harness")
      index ? args[index + 1].to_s : nil
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def pretool(adapter)
      started = clock
      input = adapter.parse($stdin.read)
      output = begin
        decide(adapter, input, started)
      rescue StandardError, ScriptError => e
        internal(adapter, input, e)
      end
      $stdout.write(output) if output
    rescue Errno::EPIPE, IOError, Polispec::Error
      nil
    end

    def decide(adapter, input, started)
      ledger = Ledger.load
      Fastpath.refresh(ledger)
      cwd = input.cwd.to_s.empty? ? Dir.pwd : input.cwd.to_s
      calls = adapter.calls(input)
      baseline = Layers.baseline?
      return nil unless baseline || relevant?(ledger, cwd, calls)

      actions = calls.flat_map { |tool, data| Array(Classify.call(tool, data, cwd)) }
      groups = group(actions, ledger, cwd, baseline)
      return nil if groups.empty?

      mode = enforce_mode
      outcomes = groups.map do |kind, project, list|
        if kind == :live
          evaluate(adapter, input, ledger, cwd, project, list, mode, started)
        else
          evaluate_baseline(adapter, input, ledger, cwd, project, list, mode, started)
        end
      end
      worst = outcomes.max_by { |outcome| outcome.verdict.severity }
      mode == "enforce" ? adapter.render(worst.verdict) : nil
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
          id = owner ? owner.id : GLOBAL_ID
          (groups[[:baseline, id]] ||= [:baseline, id, []])[2] << action
        end
      end
      groups.values
    end

    GLOBAL_ID = "global"

    def evaluate_baseline(adapter, input, ledger, cwd, id, actions, mode, started)
      env = id == GLOBAL_ID ? "dev" : Engine::Envs.cwd_env({}, ledger, id, cwd)
      target = Target.new(project: id, env: env, policy: { "rules" => [] }, roster: nil, policy_source: "global", digest: Layers.fingerprint)
      context = { ledger: ledger, cwd: cwd, session_id: input.session_id, role: (input.agent_type.to_s.empty? ? nil : input.agent_type), issue_allow_once: mode == "enforce" && !adapter.ask? }
      outcome = Engine.explain(actions, target, context)
      record(adapter, input, cwd, target, outcome, mode, started)
      outcome
    end

    def evaluate(adapter, input, ledger, cwd, project, actions, mode, started)
      loaded = PolicySource.resolve(project, ledger: ledger)
      target = Target.new(
        project: project.id, env: Engine::Envs.cwd_env(loaded.policy, ledger, project.id, cwd), policy: loaded.policy,
        roster: nil, policy_source: loaded.source, digest: loaded.digest
      )
      context = { ledger: ledger, cwd: cwd, session_id: input.session_id, role: (input.agent_type.to_s.empty? ? nil : input.agent_type), issue_allow_once: mode == "enforce" && !adapter.ask? }
      outcome = Engine.explain(actions, target, context)
      record(adapter, input, cwd, target, outcome, mode, started)
      outcome
    end

    def record(adapter, input, cwd, target, outcome, mode, started)
      verdict = outcome.verdict
      Events.emit(
        "polispec.verdict", project: target.project, env: outcome.env, action_class: outcome.action_class, verdict: verdict.level,
        rule_id: verdict.rule_id, tool: input.tool_name, harness: adapter.name, session_id: input.session_id, cwd: cwd,
        policy_digest: target.digest, policy_source: target.policy_source, duration_ms: ((clock - started) * 1000).round(2)
      )
      return if verdict.allow?

      State.append_jsonl("verdicts", {
        "ts" => Time.now.utc.iso8601, "project" => target.project, "env" => outcome.env, "action_class" => outcome.action_class,
        "verdict" => verdict.level, "rule_id" => verdict.rule_id, "tool" => input.tool_name, "harness" => adapter.name,
        "session_id" => input.session_id, "enforced" => mode == "enforce", "allow_once_id" => verdict.allow_once_id,
        "raw" => outcome.rows.map { |row| row.action.raw.to_s }.first.to_s[0, 300]
      })
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
      input = adapter.parse($stdin.read)
      cwd = input.cwd.to_s.empty? ? Dir.pwd : input.cwd.to_s
      ledger = Ledger.load
      located = ledger.locate(cwd)
      return unless located && located.project.status == "live"

      text = SessionText.new(ledger, located.project, input, cwd, enforce_mode).to_s
      $stdout.write(adapter.render_session(text, input.event)) unless text.empty?
    rescue Errno::EPIPE, IOError, Polispec::Error
      nil
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
