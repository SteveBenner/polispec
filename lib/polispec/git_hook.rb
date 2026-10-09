#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "classify/commands/support"

module Polispec
  class GitHook
    HOOKS = %w[pre-commit pre-push reference-transaction].freeze
    USAGE = "usage: polispec hook git <pre-commit|pre-push|reference-transaction> [git hook args...]\n       polispec hook git install <project-id> <dev|test|prod|all> [--dry-run]\n       polispec hook git uninstall <project-id> <dev|test|prod|all>"
    GIT_ENV = { "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil, "GIT_CEILING_DIRECTORIES" => nil, "GIT_OPTIONAL_LOCKS" => "0" }.freeze
    ZERO = /\A0+\z/.freeze
    SHIM_DIR = "git-hooks"
    SHEBANG = "#!/bin/sh".freeze

    def self.run(args)
      new.run(args.dup)
    end

    def run(args)
      sub = args.shift
      return install(args) if sub == "install"
      return uninstall(args) if sub == "uninstall"
      return usage unless HOOKS.include?(sub)

      judge(sub, args)
    rescue Polispec::Error => e
      warn "polispec: #{e.message}"
      1
    end

    private

    def usage
      warn USAGE
      1
    end

    def judge(hook, args)
      return 0 if ENV["POLISPEC_OPERATOR"] == "1"

      @env = nil
      decide(hook, args)
    rescue StandardError, ScriptError => e
      warn "polispec: git hook error #{e.class}: #{e.message}"
      closed? ? 1 : 0
    end

    def closed?
      Engine::Settings.enforce_mode == "enforce" && @env == "prod"
    rescue StandardError
      false
    end

    def decide(hook, args)
      cwd = toplevel
      return 0 unless cwd

      ledger = Ledger.load
      located = ledger.locate(cwd)
      return 0 unless located && located.project.status == "live"

      project = located.project
      loaded = PolicySource.resolve(project, ledger: ledger)
      @env = Engine::Envs.cwd_env(loaded.policy, ledger, project.id, cwd)
      lines = hook == "pre-commit" ? [] : $stdin.read.to_s.lines.map(&:strip).reject(&:empty?)
      actions = actions_for(hook, args, lines, cwd, loaded.policy)
      return 0 if actions.empty?

      enforce = Engine::Settings.enforce_mode == "enforce"
      target = Target.new(project: project.id, env: @env, policy: loaded.policy, roster: nil, policy_source: loaded.source, digest: loaded.digest)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      outcome = Engine.explain(actions, target, { ledger: ledger, cwd: cwd, session_id: "git-#{hook}", role: nil, issue_allow_once: enforce })
      record(hook, cwd, target, outcome, enforce, started)
      respond(outcome.verdict, enforce)
    end

    def toplevel
      out, status = Open3.capture2(GIT_ENV, "git", "rev-parse", "--show-toplevel", err: File::NULL)
      status.success? ? out.strip : nil
    rescue SystemCallError
      nil
    end

    def respond(verdict, enforce)
      return 0 if verdict.allow?

      unless enforce
        warn "polispec (advise): would #{verdict.level} #{verdict.rule_id}: #{verdict.reason}"
        return 0
      end

      if verdict.deny?
        warn "polispec: denied by #{verdict.rule_id}: #{verdict.reason}"
        warn "next: #{verdict.next_step}"
      else
        warn "polispec: #{verdict.reason}"
        warn "#{Engine::Settings.operator} can approve once with: polispec allow-once #{verdict.allow_once_id}, then retry." if verdict.allow_once_id
      end
      1
    end

    def record(hook, cwd, target, outcome, enforce, started)
      verdict = outcome.verdict
      Events.emit(
        "polispec.verdict", project: target.project, env: outcome.env, action_class: outcome.action_class, verdict: verdict.level,
        rule_id: verdict.rule_id, tool: "git #{hook}", harness: "git", session_id: "git-#{hook}", cwd: cwd,
        policy_digest: target.digest, policy_source: target.policy_source,
        duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(2)
      )
      return if verdict.allow?

      State.append_jsonl("verdicts", {
        "ts" => Time.now.utc.iso8601, "project" => target.project, "env" => outcome.env, "action_class" => outcome.action_class,
        "verdict" => verdict.level, "rule_id" => verdict.rule_id, "tool" => "git #{hook}", "harness" => "git",
        "session_id" => "git-#{hook}", "enforced" => enforce, "allow_once_id" => verdict.allow_once_id,
        "raw" => outcome.rows.map { |row| row.action.raw.to_s }.first.to_s[0, 300]
      })
    end

    def actions_for(hook, args, lines, cwd, policy)
      case hook
      when "pre-commit" then pre_commit(cwd)
      when "pre-push" then pre_push(args, lines, cwd)
      else reference_transaction(args, lines, cwd, policy)
      end
    end

    def hint(cwd, attrs)
      base = { "path" => cwd }
      base["env"] = @env unless @env == "dev"
      base.merge(attrs.each_with_object({}) { |(key, value), memo| memo[key.to_s] = value unless value.nil? })
    end

    def build(klass, raw, cwd, attrs)
      Action.new(class: klass, env_hint: hint(cwd, attrs), raw: raw)
    end

    def current_branch(cwd)
      Classify::Support::Repo.current_branch(cwd)
    end

    def pre_commit(cwd)
      [build("git.commit", "git pre-commit", cwd, ref: current_branch(cwd))]
    end

    def pre_push(args, lines, cwd)
      remote = args[1]
      lines.filter_map do |line|
        _local_ref, local_sha, remote_ref, remote_sha = line.split(" ")
        next if remote_ref.nil?

        raw = "git pre-push #{args.join(' ')} #{remote_ref}".strip
        if remote_ref.start_with?("refs/tags/")
          build("git.tag", raw, cwd, ref: remote_ref.sub(%r{\Arefs/tags/}, ""), remote: remote)
        elsif remote_ref.start_with?("refs/heads/")
          branch = remote_ref.sub(%r{\Arefs/heads/}, "")
          rewrite = local_sha.to_s.match?(ZERO) || (!remote_sha.to_s.match?(ZERO) && !ancestor?(cwd, remote_sha, local_sha))
          build(rewrite ? "git.rewrite" : "git.push", raw, cwd, ref: branch, remote: remote)
        end
      end
    end

    def reference_transaction(args, lines, cwd, policy)
      return [] unless args.first == "prepared"

      envs = Engine::Envs.environments(policy)
      watched = %w[test prod].filter_map { |name| (envs[name] || {})["branch"] }
      lines.filter_map do |line|
        old, new, refname = line.split(" ")
        next if refname.nil?

        raw = "git reference-transaction #{refname}"
        if refname.start_with?("refs/tags/")
          build("git.tag", raw, cwd, ref: refname.sub(%r{\Arefs/tags/}, ""))
        elsif refname.start_with?("refs/heads/")
          branch = refname.sub(%r{\Arefs/heads/}, "")
          next if @env == "dev" && !watched.include?(branch)

          moved = !old.to_s.match?(ZERO) && !new.to_s.match?(ZERO) && !ancestor?(cwd, old, new)
          build(moved ? "git.rewrite" : "git.branch", raw, cwd, ref: branch)
        elsif refname == "HEAD" && @env != "dev"
          build("git.branch", raw, cwd, ref: current_branch(cwd) || "HEAD")
        end
      end
    end

    def ancestor?(cwd, older, newer)
      _out, _err, status = Open3.capture3(GIT_ENV, "git", "-C", cwd, "merge-base", "--is-ancestor", older, newer)
      status.success?
    rescue SystemCallError
      false
    end

    def install(args)
      dry = args.delete("--dry-run")
      project, scope = args
      return usage unless project && scope && args.length == 2

      Installer.new(project, scope).install(dry: dry)
    end

    def uninstall(args)
      project, scope = args
      return usage unless project && scope && args.length == 2

      Installer.new(project, scope).uninstall
    end

    class Installer
      def initialize(project_id, scope, out: $stdout)
        @out = out
        @ledger = Ledger.load
        @project = @ledger.project(project_id) || raise(Polispec::Error, "#{project_id} is not in the ledger")
        raise Polispec::Error, "scope must be dev, test, prod or all" unless (ENVIRONMENTS + ["all"]).include?(scope)

        @names = scope == "all" ? ENVIRONMENTS : [scope]
        @policy = PolicySource.resolve(@project, ledger: @ledger).policy
      end

      def install(dry: false)
        @names.each { |name| install_one(name, dry) }
        0
      end

      def uninstall
        @names.each { |name| uninstall_one(name) }
        0
      end

      private

      def checkout(name)
        return File.expand_path(@project.repo) if name == "dev"

        spec = (@policy["environments"] || {})[name] || {}
        value = spec["checkout"].to_s
        value.empty? || value == "repo" ? File.expand_path(@project.repo) : File.expand_path(value)
      end

      def shim_dir(name)
        File.join(State.home, SHIM_DIR, @project.id, name)
      end

      def git(dir, *args)
        out, status = Open3.capture2(GIT_ENV, "git", "-C", dir, *args, err: File::NULL)
        status.success? ? out.strip : nil
      rescue SystemCallError
        nil
      end

      def checkout?(dir)
        File.directory?(dir) && !git(dir, "rev-parse", "--git-dir").nil?
      end

      def default_hooks(dir)
        common = git(dir, "rev-parse", "--git-common-dir")
        common && File.join(File.expand_path(common, dir), "hooks")
      end

      def install_one(name, dry)
        dir = checkout(name)
        return @out.puts("skipped #{name}: #{dir} is not a git checkout") unless checkout?(dir)

        shims = shim_dir(name)
        current = git(dir, "config", "--get", "core.hooksPath")
        current = File.expand_path(current, dir) if current
        recorded = git(dir, "config", "--get", "polispec.previousHooksPath")
        previous = current == shims ? (recorded || default_hooks(dir)) : (current || default_hooks(dir))
        if dry
          @out.puts "would set core.hooksPath #{shims} in #{dir} (previous #{previous})"
          return
        end

        write_shims(shims, previous)
        if current == shims
          @out.puts "unchanged #{name}: #{dir} already uses #{shims}"
          return
        end

        git(dir, "config", "polispec.previousHooksPath", previous)
        git(dir, "config", "core.hooksPath", shims)
        @out.puts "installed #{name}: #{dir} hooks #{shims} (previous #{previous})"
      end

      def uninstall_one(name)
        dir = checkout(name)
        return @out.puts("skipped #{name}: #{dir} is not a git checkout") unless checkout?(dir)

        current = git(dir, "config", "--get", "core.hooksPath")
        return @out.puts("unchanged #{name}: #{dir} does not use #{shim_dir(name)}") unless current && File.expand_path(current, dir) == shim_dir(name)

        previous = git(dir, "config", "--get", "polispec.previousHooksPath")
        if previous.nil? || previous == default_hooks(dir)
          git(dir, "config", "--unset", "core.hooksPath")
        else
          git(dir, "config", "core.hooksPath", previous)
        end
        git(dir, "config", "--unset", "polispec.previousHooksPath")
        @out.puts "uninstalled #{name}: #{dir}"
      end

      def write_shims(dir, previous)
        FileUtils.mkdir_p(dir)
        HOOKS.each do |hook|
          path = File.join(dir, hook)
          temp = "#{path}.#{Process.pid}.tmp"
          File.write(temp, shim(hook, previous))
          File.chmod(0o755, temp)
          File.rename(temp, path)
        end
      end

      def shim(hook, previous)
        bin = Shellwords.escape(File.join(ROOT, "bin", "polispec"))
        chained = Shellwords.escape(File.join(previous, hook))
        lines = hook == "pre-commit" ? plain_shim(hook, bin, chained) : piped_shim(hook, bin, chained)
        "#{lines.join("\n")}\n"
      end

      def plain_shim(hook, bin, chained)
        [SHEBANG, "#{bin} hook git #{hook} \"$@\" || exit $?", "if [ -x #{chained} ]; then", "  exec #{chained} \"$@\"", "fi", "exit 0"]
      end

      def piped_shim(hook, bin, chained)
        guard = hook == "reference-transaction" ? "[ \"$1\" = prepared ]" : "true"
        [
          SHEBANG, "input=$(cat)", "if #{guard}; then",
          "  printf '%s\\n' \"$input\" | #{bin} hook git #{hook} \"$@\" || exit $?", "fi",
          "if [ -x #{chained} ]; then", "  printf '%s\\n' \"$input\" | #{chained} \"$@\" || exit $?", "fi", "exit 0"
        ]
      end
    end
  end
end
