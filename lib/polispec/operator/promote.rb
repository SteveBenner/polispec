#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "git"
require_relative "gates"

module Polispec
  module Operator
    module Promote
      TARGET = /\A[a-z0-9][a-z0-9-]{0,40}\z/
      BOOTSTRAP_FROM = { "test" => "main", "stable" => "test" }.freeze
      Plan = Struct.new(:project, :git, :to, :source_ref, :target, :from_sha, :to_sha, :version, :tag, :gates, :preflight, :actor, :started, :waived, keyword_init: true)

      module_function

      def call(project_id, to:, dry_run: false, waive_soak: false)
        to = to.to_s
        raise Failure.new("invalid_target", "--to must name an environment") unless TARGET.match?(to)
        raise Failure.new("waive_soak_unsupported", "--waive-soak applies to promotions past test") if waive_soak && to == "test"

        started = Gates.now_ms
        project = Gates.load_project(project_id, bootstrap_from: BOOTSTRAP_FROM[to])
        unless project.promotion["to_#{to}"].is_a?(Hash) || %w[test stable].include?(to)
          known = project.promotion.keys.map { |key| key.to_s.delete_prefix("to_") }
          raise Failure.new("invalid_target", "--to must be #{Gates.name_list(known)}")
        end
        Gates.with_lock("promote-#{project.id}") do
          result = to == "test" ? to_test(project, dry_run, started) : to_hop(project, to, dry_run, started, waive_soak)
          result.merge("duration_ms" => Gates.now_ms - started)
        end
      rescue Failure => e
        emit_failure(project_id, to, e, started) unless dry_run
        raise
      end

      def promotion_config(project, to)
        config = project.promotion["to_#{to}"]
        unless config.is_a?(Hash)
          raise Failure.new("policy_unavailable", "project #{project.id} policy has no promotion.to_#{to} (source #{project.source})", "policy_source" => project.source)
        end
        if project.source.start_with?("bootstrap:") && BOOTSTRAP_FROM.key?(to) && config["from"] != BOOTSTRAP_FROM[to]
          raise Failure.new("bootstrap_mismatch", "the bootstrap policy from #{BOOTSTRAP_FROM[to]} promotes to #{to} from #{config['from'].inspect}", "policy_source" => project.source)
        end
        config
      end

      def to_test(project, dry_run, started)
        config = promotion_config(project, "test")
        actor = Gates.actor
        unless Array(config["actor"]).include?(actor)
          raise Failure.new("actor_denied", "promotion to test is limited to #{Array(config['actor']).join(', ')}; this caller is #{actor}")
        end

        git = Git.new(project.repo)
        git.fetch
        plan = plan_to_test(project, config, git, actor)
        plan.started = started
        plan.gates = Gates.run_all(Gates.effective_gates(project, "test"), context(plan))
        return preview(plan) if dry_run

        publish(plan)
      end

      def plan_to_test(project, config, git, actor)
        source = config["from"]
        target = project.environment("test")["branch"]
        stable = project.environment("prod")["branch"]
        main_tip = remote_tip(git, source)
        check_drift(git, stable, main_tip)
        previous = git.rev("origin/#{target}")
        if previous
          raise Failure.new("nothing_to_promote", "#{target} already points at #{main_tip[0, 12]}") if previous == main_tip
          raise Failure.new("not_fast_forward", "#{target} (#{previous[0, 12]}) is not an ancestor of #{source} (#{main_tip[0, 12]})", "from_sha" => previous, "to_sha" => main_tip) unless git.ancestor?(previous, main_tip)
        end
        version = Gates.version_at(git, main_tip)
        check_version_bump(git, version) if config["requires_version_bump"]
        tag = Gates.interpolate(config["tag"] || "v{VERSION}", "VERSION" => version)
        raise Failure.new("tag_exists", "tag #{tag} already exists", "tag" => tag) if git.tag_commit(tag)

        Plan.new(project: project, git: git, to: "test", source_ref: source, target: target, from_sha: previous || Git::ZEROS,
                 to_sha: main_tip, version: version, tag: tag, gates: [], actor: actor)
      end

      def remote_tip(git, branch)
        tip = git.rev("origin/#{branch}")
        raise Failure.new("missing_ref", "origin/#{branch} does not exist") unless tip

        tip
      end

      def check_drift(git, stable, main_tip)
        stable_tip = git.rev("origin/#{stable}")
        return if stable_tip.nil? || git.ancestor?(stable_tip, main_tip)

        raise Failure.new("drift", "main lacks #{stable}'s tip #{stable_tip}; run `git merge #{stable}` on main", "stable_sha" => stable_tip, "main_sha" => main_tip)
      end

      def check_version_bump(git, version)
        last = git.latest_tag
        return if last.nil?

        current = Gem::Version.new(version)
        return if current > git.tag_version(last)

        raise Failure.new("version_not_bumped", "VERSION #{version} does not exceed the last tag #{last}", "version" => version, "last_tag" => last)
      rescue ArgumentError
        raise Failure.new("invalid_version", "VERSION #{version.inspect} is not a valid version")
      end

      def context(plan)
        Gates::Context.new(project: plan.project, git: plan.git, sha: plan.to_sha, version: plan.version, tag: plan.tag, to: plan.to)
      end

      def preview(plan)
        {
          "ok" => true, "dry_run" => true, "project" => plan.project.id, "to" => plan.to, "from_sha" => plan.from_sha,
          "to_sha" => plan.to_sha, "tag" => plan.tag, "version" => plan.version, "actor" => plan.actor, "preflight" => plan.preflight, "gates" => plan.gates,
          "policy_source" => plan.project.source, "waived" => plan.waived
        }.compact
      end

      def publish(plan)
        git = plan.git
        refspecs = ["#{plan.to_sha}:refs/heads/#{plan.target}"]
        refspecs << "refs/tags/#{plan.tag}" if plan.to == "test"
        git.create_tag(plan.tag, plan.to_sha) if plan.to == "test"
        begin
          git.push_atomic("origin", refspecs)
        rescue Failure
          git.drop_tag(plan.tag, plan.to_sha) if plan.to == "test"
          raise
        end
        local = git.advance_branch(plan.target, plan.to_sha)
        record = State.append_jsonl("promotions", record_for(plan))
        result = base_result(plan, record, local)
        finish(plan, result)
      end

      def record_for(plan)
        {
          "id" => Gates.new_id("prm"), "project" => plan.project.id, "to" => plan.to, "from_sha" => plan.from_sha,
          "to_sha" => plan.to_sha, "tag" => plan.tag, "actor" => plan.actor, "preflight" => plan.preflight, "gates" => plan.gates, "waived" => plan.waived, "at" => Time.now.utc.iso8601,
          "latest" => (plan.project.promotion["to_#{plan.to}"]["release"] || {})["flip_latest"] == "deferred" && plan.to == "stable" ? "deferred" : nil
        }.compact
      end

      def base_result(plan, record, local)
        {
          "ok" => true, "project" => plan.project.id, "to" => plan.to, "from_sha" => plan.from_sha, "to_sha" => plan.to_sha,
          "tag" => plan.tag, "version" => plan.version, "actor" => plan.actor, "gates" => plan.gates, "record_id" => record["id"],
          "local_branch" => local.to_s, "policy_source" => plan.project.source, "release" => { "status" => "none" }, "deploys" => [], "waived" => plan.waived
        }.compact
      end

      def finish(plan, result)
        config = plan.project.promotion["to_#{plan.to}"]
        emit(plan, "ok")
        begin
          result["release"] = release(plan, config)
          result["deploys"] = run_after(plan, config)
        rescue Failure => e
          raise e.with_payload("promoted" => true, "to_sha" => plan.to_sha, "tag" => plan.tag, "record_id" => result["record_id"])
        end
        result
      end

      def release(plan, config)
        settings = config["release"] || {}
        if plan.to == "test" && settings["github_prerelease"]
          github(plan, ["release", "create", plan.tag, "--prerelease", "--title", plan.tag, "--generate-notes", "--verify-tag"], "prerelease")
        elsif plan.to == "stable" && settings["flip_latest"] == "deferred"
          github(plan, ["release", "edit", plan.tag, "--prerelease=false", "--latest=false"], "deferred")
        elsif plan.to == "stable" && settings["flip_latest"]
          github(plan, ["release", "edit", plan.tag, "--prerelease=false", "--latest"], "latest")
        else
          { "status" => "none" }
        end
      end

      def github(plan, argv, kind)
        execution = Gates.exec(["gh", *argv], chdir: plan.project.repo)
        unless execution.ok?
          raise Failure.new("release_failed", "gh #{argv.first(2).join(' ')} #{plan.tag} failed; the promotion itself landed", "output_tail" => execution.tail)
        end

        { "status" => kind, "tag" => plan.tag }
      end

      def run_after(plan, config)
        vars = context(plan).vars
        Array(config["after"]).map { |entry| after_step(plan, Gates.argv_for(entry, vars)) }
      end

      def after_step(plan, argv)
        if argv[0] == "polispec" && argv[1] == "deploy"
          deploy_step(plan, argv[2..])
        else
          execution = Gates.exec(argv, chdir: plan.project.repo)
          raise Failure.new("after_failed", "after step #{argv.join(' ')} failed", "output_tail" => execution.tail) unless execution.ok?

          { "command" => argv.join(" "), "exit" => execution.code }
        end
      end

      def deploy_step(plan, args)
        project, env, *rest = args
        tag = rest.each_cons(2).find { |flag, _| flag == "--tag" }&.last
        Deploy.call(project, env, tag: tag, confirmed: plan.to != "test")
      end

      def to_hop(project, to, dry_run, started, waive_soak = false)
        config = promotion_config(project, to)
        stable = to == "stable"
        phrased = stable || config["phrase"]
        if stable
          raise Failure.new("actor_denied", "promotion to stable must allow the operator actor") unless Array(config["actor"]).include?("operator")
        elsif !dry_run && !Array(config["actor"]).include?(Gates.actor)
          raise Failure.new("actor_denied", "promotion to #{to} is limited to #{Array(config['actor']).join(', ')}; this caller is #{Gates.actor}")
        end

        Gates.require_terminal!("promote --to #{to}") if phrased && !dry_run
        gates = Gates.effective_gates(project, to)
        waived = waive_soak ? waive_soak!(project, to, gates, dry_run) : nil
        git = Git.new(project.repo)
        git.fetch
        plan = plan_to_hop(project, config, git, to, stable ? "operator" : Gates.actor)
        plan.started = started
        plan.waived = waived
        plan.preflight = Gates.run_all(Array(config["preflight"]), context(plan))
        plan.gates = Gates.run_all(gates, context(plan), waive: waived ? %w[soaked] : [])
        return preview(plan) if dry_run

        if phrased
          phrase = Gates.interpolate(config["phrase"] || "promote {project} to stable", "project" => project.id)
          warn "promoting #{project.id} #{plan.version} (#{plan.to_sha[0, 12]}) from #{plan.source_ref} to #{plan.target}"
          Gates.confirm!(phrase)
        end
        publish(plan)
      end

      def waive_soak!(project, to, gates, dry_run)
        raise Failure.new("nothing_to_waive", "promotion to #{to} has no soaked gate") unless gates.any? { |gate| gate["builtin"] == "soaked" }
        return %w[soak] if dry_run

        Gates.require_terminal!("promote --waive-soak")
        Gates.confirm!("waive soak for #{project.id}")
        %w[soak]
      end

      def plan_to_hop(project, config, git, to, actor)
        source = config["from"]
        target = project.environment(Gates.env_key(to))["branch"]
        tip = remote_tip(git, source)
        previous = git.rev("origin/#{target}")
        if previous
          raise Failure.new("nothing_to_promote", "#{target} already points at #{tip[0, 12]}") if previous == tip
          raise Failure.new("not_fast_forward", "#{target} (#{previous[0, 12]}) is not an ancestor of #{source} (#{tip[0, 12]})", "from_sha" => previous, "to_sha" => tip) unless git.ancestor?(previous, tip)
        end
        version = Gates.version_at(git, tip)
        tag = Gates.interpolate(project.promotion["to_test"]["tag"] || "v{VERSION}", "VERSION" => version)
        found = git.tag_commit(tag)
        raise Failure.new("tag_mismatch", "tag #{tag} does not point at #{tip[0, 12]}", "tag" => tag, "tag_sha" => found, "sha" => tip) unless found == tip

        Plan.new(project: project, git: git, to: to, source_ref: source, target: target, from_sha: previous || Git::ZEROS,
                 to_sha: tip, version: version, tag: tag, gates: [], actor: actor)
      end

      def emit(plan, result)
        Events.emit(
          "polispec.promote", project: plan.project.id, to: plan.to, from_sha: plan.from_sha, to_sha: plan.to_sha, tag: plan.tag,
                              actor: plan.actor, gates: plan.gates, waived: plan.waived, result: result, duration_ms: Gates.now_ms - plan.started
        )
      end

      def emit_failure(project_id, to, failure, started)
        Events.emit(
          "polispec.promote", project: project_id, to: to, from_sha: nil, to_sha: failure.payload["to_sha"], tag: failure.payload["tag"],
                              actor: Gates.actor, gates: [], result: failure.code, duration_ms: started ? Gates.now_ms - started : nil
        )
      end
    end
  end
end
