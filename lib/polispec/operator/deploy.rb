#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "net/http"
require "uri"
require_relative "git"
require_relative "gates"

module Polispec
  module Operator
    module Deploy
      ENV_PATTERN = /\A[a-z0-9][a-z0-9-]{0,40}\z/
      STEP_TIMEOUT = 1800
      DEFAULT_HEALTH_TIMEOUT = 60
      POLL_SECONDS = 1
      STATE_KEY = "deployments"
      DRAIN_TIMEOUT = 300
      DRAIN_POLL = 5
      RETAIN = 3

      module_function

      def call(project_id, env, tag: nil, confirmed: false, dry_run: false, skip_drain: false)
        name = env.to_s == "prod" ? "stable" : env.to_s
        raise Failure.new("invalid_env", "env must name a deployable environment") unless ENV_PATTERN.match?(name) && name != "dev"
        raise Failure.new("tag_unsupported", "test deploys follow the branch tip; --tag applies to stable only") if tag && name == "test"

        project = Gates.load_project(project_id, bootstrap_from: name == "test" ? "test" : nil)
        unless project.environment(Gates.env_key(name)).is_a?(Hash)
          known = project.policy["environments"].keys.reject { |key| key == "dev" }.map { |key| Gates.row_env(key) }
          raise Failure.new("invalid_env", "env must be #{Gates.name_list(known)}")
        end
        raise Failure.new("skip_drain_unsupported", "--skip-drain applies to stable only") if skip_drain && name == "test"

        Gates.with_lock("deploy-#{project.id}-#{name}") { deploy(project, name, tag, confirmed, dry_run, skip_drain) }
      end

      def deploy(project, name, tag, confirmed, dry_run, skip_drain = false)
        started = Gates.now_ms
        config = project.environment(Gates.env_key(name))
        settings = config["deploy"]
        raise Failure.new("no_deploy", "policy declares no deploy steps for #{name}") unless settings.is_a?(Hash)

        actor = Gates.actor
        authorize(project, name, confirmed, dry_run)
        skipped = skip_drain && settings["drain"].is_a?(Hash) ? skip_drain!(project, dry_run) : false
        settings = settings.reject { |key, _| key == "drain" } if skipped
        dir = File.join(Gates.envs_root(project.ledger), project.id, name)
        source = source_url(project)
        return preview(project, name, dir, source, tag, settings, actor) if dry_run

        record_id = Gates.new_id("dpl")
        guard = Gates::Hermetic.for(project, Gates.tier_of(project, name), record_id)
        run = begin
          settings["strategy"] == "release_dirs" ? release_flow(project, name, config, settings, dir, source, tag, guard, record_id) : in_place_flow(project, name, config, settings, dir, source, tag, guard)
        ensure
          guard_summary = guard&.finish
        end
        health = guard&.violation ? { "status" => "failed", "detail" => guard.violation } : run[:health]
        pinned = config["tier"] == "prod" ? pinned_behind?(run[:git], run[:tag]) : false
        record = State.append_jsonl("deploys", record_for(project, name, run[:sha], run[:tag], health, pinned, record_id, run[:detail], skipped))
        result = result_for(project, name, run[:dir], run[:sha], run[:tag], run[:version], run[:outcome][:steps], health, pinned, actor, record, started)
        result["strategy"] = settings["strategy"] || "in_place"
        result["drain"] = skipped ? "skipped" : run[:drain] if skipped || run[:drain]
        result["activate"] = run[:activate] if run[:activate]
        result["retention"] = run[:retention] if run[:retention]
        result["hermetic"] = guard_summary if guard_summary
        result["ok"] = false if run[:outcome][:code]
        record_state(project, name, run[:tag], run[:sha], pinned) if result["ok"]
        Events.emit("polispec.deploy", project: project.id, env: name, sha: run[:sha], tag: run[:tag], steps: run[:outcome][:steps], health: health["status"],
                                       pinned_behind: pinned, actor: actor, result: result["ok"] ? "ok" : failure_code(run[:outcome], health))
        raise_failure(run[:outcome], health, result) unless result["ok"]
        result
      end

      def in_place_flow(project, name, config, settings, dir, source, tag, guard)
        git = prepare(dir, source)
        drain = []
        early = context_for(project, name, dir, "", "", nil, git, guard)
        started = drain_start(early, settings["drain"], drain)
        ctx = early
        unless started
          sha, resolved = checkout(git, name, config, tag)
          version = Gates.version_at(git, sha)
          ctx = context_for(project, name, dir, sha, version, resolved, git, guard)
        end
        sha = ctx[:sha]
        resolved = ctx[:tag]
        version = ctx[:version]
        outcome = started || run_steps(ctx, settings)
        health = if outcome[:failed]
          { "status" => "failed", "detail" => outcome[:detail] || "deploy step failed" }
        elsif outcome[:code]
          { "status" => "failed", "detail" => outcome[:detail] }
        else
          check_health(settings["health"], ctx)
        end
        { git: git, sha: sha, tag: resolved, version: version, dir: dir, outcome: outcome, health: health, drain: drain.empty? ? nil : drain, detail: outcome[:detail] }
      ensure
        drain_resume(ctx, settings["drain"], drain) if ctx && drain
      end

      def release_flow(project, name, config, settings, dir, source, tag, guard, record_id)
        releases = File.join(File.dirname(dir), "releases")
        FileUtils.mkdir_p(releases, mode: 0o700)
        git, sha, resolved, release = build_release(releases, dir, source, name, config, tag, record_id)
        version = Gates.version_at(git, sha)
        target = File.join(releases, release)
        ctx = context_for(project, name, target, sha, version, resolved, git, guard)
        run = { git: git, sha: sha, tag: resolved, version: version, dir: dir }
        outcome = run_steps(ctx, settings)
        if outcome[:failed] || guard&.violation
          return run.merge(outcome: outcome, health: { "status" => "failed", "detail" => guard&.violation || "deploy step failed" })
        end

        drain = []
        activate = []
        started = drain_start(ctx, settings["drain"], drain)
        if started
          return run.merge(outcome: { steps: outcome[:steps], failed: false, code: started[:code], detail: started[:detail] }, health: { "status" => "failed", "detail" => started[:detail] },
                           drain: drain, detail: started[:detail])
        end

        previous = swap_in(releases, dir, release)
        live = context_for(project, name, dir, sha, version, resolved, git, guard)
        activated = run_activate(live, settings, activate)
        health = activated ? { "status" => "failed", "detail" => activated } : check_health(settings["health"], live)
        health = { "status" => "failed", "detail" => guard.violation } if guard&.violation
        detail = nil
        unless %w[ok unchecked].include?(health["status"]) || previous.nil? || previous == release
          health, detail = roll_back(project, name, settings, dir, releases, previous, release, health, activate, guard)
        end
        run.merge(outcome: outcome, health: health, drain: drain.empty? ? nil : drain, activate: activate.empty? ? nil : activate, detail: detail,
                  retention: retain(releases, File.dirname(dir), [release, previous]))
      ensure
        drain_resume(ctx, settings["drain"], drain) if ctx && drain
        FileUtils.rm_rf(File.join(releases, ".build-#{record_id}")) if releases
      end

      def context_for(project, name, dir, sha, version, tag, git, guard)
        {
          project: project, name: name, dir: dir, sha: sha, version: version, tag: tag, git: git, guard: guard,
          vars: { "sha" => sha, "VERSION" => version, "project" => project.id, "tag" => tag.to_s, "stable_tag" => Gates.stable_tag(project, git).to_s },
          env: { "POLISPEC_PROJECT" => project.id, "POLISPEC_ENV" => name, "POLISPEC_SHA" => sha, "POLISPEC_VERSION" => version }
        }
      end

      def build_release(releases, dir, source, name, config, tag, record_id)
        temp = File.join(releases, ".build-#{record_id}")
        reference = File.exist?(File.join(dir, ".git")) ? dir : nil
        clone_release(source, temp, reference)
        git = Git.new(temp)
        git.fetch
        sha, resolved = checkout(git, name, config, tag)
        git.checkout_detached(sha)
        release = resolved || "sha-#{sha[0, 12]}"
        target = File.join(releases, release)
        if File.exist?(target)
          held = Git.new(target).head
          raise Failure.new("release_conflict", "release #{release} exists at #{held.to_s[0, 12]}, not #{sha[0, 12]}", "release" => release) unless held == sha

          FileUtils.rm_rf(temp)
        else
          File.rename(temp, target)
        end
        [Git.new(target), sha, resolved, release]
      end

      def clone_release(source, dest, reference)
        argv = ["git", "clone", "--quiet"]
        argv += ["--reference", reference, "--dissociate"] if reference
        argv += [source, dest]
        out, err, status = Open3.capture3(Git.env, *argv)
        return if status.success?

        raise Failure.new("clone_failed", "git clone #{source} failed", "output_tail" => Git.tail([err, out].join("\n")))
      rescue SystemCallError => e
        raise Failure.new("clone_failed", "git clone #{source} failed: #{e.message}")
      end

      def swap_in(releases, dir, release)
        previous = current_release(releases, dir)
        swap_link(dir, release)
        previous
      end

      def current_release(releases, dir)
        return File.basename(File.readlink(dir)) if File.symlink?(dir)
        return nil unless File.directory?(dir)

        name = described_tag(dir)
        name = "pre-release-dirs-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}" if name.nil? || File.exist?(File.join(releases, name))
        File.rename(dir, File.join(releases, name))
        name
      end

      def described_tag(dir)
        return nil unless File.exist?(File.join(dir, ".git"))

        result = Git.new(dir).run("describe", "--tags", "--exact-match", "HEAD")
        name = result.out.strip
        result.ok? && Git::TAG_PATTERN.match?(name) ? name : nil
      end

      def swap_link(dir, release)
        temp = "#{dir}.swap-#{Process.pid}"
        File.delete(temp) if File.symlink?(temp)
        File.symlink(File.join("releases", release), temp)
        File.rename(temp, dir)
      end

      def roll_back(project, name, settings, dir, releases, previous, release, failed, activate, guard)
        swap_link(dir, previous)
        git = Git.new(File.join(releases, previous))
        sha = git.head
        version = Gates.version_at(git, sha)
        tag = Git::TAG_PATTERN.match?(previous) ? previous : nil
        ctx = context_for(project, name, dir, sha, version, tag, git, guard)
        reactivated = run_activate(ctx, settings, activate)
        restored = reactivated ? { "status" => "failed", "detail" => reactivated } : check_health(settings["health"], ctx)
        detail = "#{release} failed (#{failed['status']}: #{failed['detail']}); restored #{previous} (#{restored['status']}: #{restored['detail']})"
        [{ "status" => "rolled_back", "detail" => detail, "failed" => failed, "restored" => restored }, detail]
      end

      def run_activate(ctx, settings, log)
        Array(settings["activate"]).each do |command|
          argv = Gates.argv_for(command, ctx[:vars])
          execution = Gates.exec(argv, chdir: ctx[:dir], env: ctx[:env], timeout: STEP_TIMEOUT)
          log << { "command" => argv.join(" "), "exit" => execution.code, "duration_ms" => execution.duration_ms, "output_tail" => (execution.ok? ? nil : execution.tail) }.compact
          return "activate failed: #{argv.join(' ')}: #{execution.tail}" unless execution.ok?
        end
        nil
      end

      def drain_ctx(ctx, drain)
        active = drain["run_in"] == "repo" ? ctx[:project].repo : Gates.active_dir(ctx[:project], ctx[:name])
        active = ctx[:dir] unless File.directory?(active)
        extra = Gates.env_file_vars(ctx[:project], drain["env_from"] || ctx[:name])
        ctx.merge(dir: active, env: extra.merge(ctx[:env]), guard: nil)
      end

      def drain_start(ctx, drain, log)
        return nil unless drain.is_a?(Hash)

        log << { "phase" => "started" }
        run = drain_ctx(ctx, drain)
        if drain["pause"]
          argv = Gates.argv_for(drain["pause"], run[:vars])
          execution = Gates.exec(argv, chdir: run[:dir], env: run[:env], timeout: STEP_TIMEOUT)
          log << { "phase" => "pause", "command" => argv.join(" "), "exit" => execution.code }
          return { failed: false, steps: [], code: "drain_failed", detail: "drain pause failed: #{execution.tail}" } unless execution.ok?
        end
        waited = drain_wait(run, drain, log)
        return waited if waited

        drain_checks(run, drain, log)
      rescue Failure => e
        { failed: false, steps: [], code: "drain_failed", detail: e.message }
      end

      def drain_checks(run, drain, log)
        Array(drain["checks"]).each do |command|
          argv = Gates.argv_for(command, run[:vars])
          execution = Gates.exec(argv, chdir: run[:dir], env: run[:env], timeout: STEP_TIMEOUT)
          log << { "phase" => "check", "command" => argv.join(" "), "exit" => execution.code }
          next if execution.ok?

          return { failed: false, steps: [], code: "drain_check_failed", detail: "drain check failed: #{argv.join(' ')}: #{execution.tail}" }
        end
        nil
      end

      def drain_wait(ctx, drain, log)
        return nil unless drain["wait"]

        argv = Gates.argv_for(drain["wait"], ctx[:vars])
        limit = drain["timeout_s"] || DRAIN_TIMEOUT
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limit
        loop do
          execution = Gates.exec(argv, chdir: ctx[:dir], env: ctx[:env], timeout: limit)
          if execution.ok?
            log << { "phase" => "wait", "command" => argv.join(" "), "exit" => 0 }
            return nil
          end
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if remaining <= 0
            log << { "phase" => "wait", "command" => argv.join(" "), "exit" => execution.code, "timed_out" => true }
            return { failed: false, steps: [], code: "drain_timeout", detail: "drain wait did not succeed within #{limit} s" }
          end
          sleep [DRAIN_POLL, remaining].min
        end
      end

      def drain_resume(ctx, drain, log)
        return unless drain.is_a?(Hash) && drain["resume"] && log.any?

        run = drain_ctx(ctx, drain)
        argv = Gates.argv_for(drain["resume"], run[:vars])
        execution = Gates.exec(argv, chdir: run[:dir], env: run[:env], timeout: STEP_TIMEOUT)
        log << { "phase" => "resume", "command" => argv.join(" "), "exit" => execution.code }
      end

      def retain(releases, project_dir, keep)
        entries = Dir.children(releases).reject { |entry| entry.start_with?(".") }.select { |entry| File.directory?(File.join(releases, entry)) }
        newest = entries.sort_by { |entry| release_rank(entry) }.reverse.first(RETAIN)
        active = Dir.children(project_dir).filter_map do |entry|
          link = File.join(project_dir, entry)
          File.symlink?(link) ? File.basename(File.readlink(link)) : nil
        end
        kept = (newest + active + keep.compact).uniq
        removed = []
        held = []
        (entries - kept).each do |entry|
          path = File.join(releases, entry)
          if reproducible?(path)
            FileUtils.rm_rf(path)
            removed << entry
          else
            hold(releases, entry)
            held << entry
          end
        end
        { "kept" => (entries & kept).sort, "removed" => removed.sort, "held" => held.sort }
      end

      def release_rank(entry)
        Git::TAG_PATTERN.match?(entry) ? Gem::Version.new(entry.sub(/\Av/, "")) : Gem::Version.new("0")
      rescue ArgumentError
        Gem::Version.new("0")
      end

      def reproducible?(path)
        result = Git.new(path).run("status", "--porcelain", "--ignored")
        return false unless result.ok?

        result.out.lines.all? { |line| line.start_with?("!! ") && line[3..].strip.match?(%r{\A(vendor|\.bundle)(/|\z)}) }
      rescue Failure
        false
      end

      def hold(releases, entry)
        held = File.join(releases, ".held")
        FileUtils.mkdir_p(held, mode: 0o700)
        target = File.join(held, entry)
        target = "#{target}-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}" if File.exist?(target)
        File.rename(File.join(releases, entry), target)
      end

      def skip_drain!(project, dry_run)
        return true if dry_run

        Gates.require_terminal!("deploy --skip-drain")
        Gates.confirm!("skip drain for #{project.id}")
        true
      end

      def authorize(project, name, confirmed, dry_run)
        return if name == "test"
        return if dry_run || confirmed

        label = name == "stable" ? "prod" : name
        Gates.require_terminal!("deploy to #{label}")
        phrase = "deploy #{project.id} to #{label}"
        warn "deploying #{project.id} to #{label}"
        Gates.confirm!(phrase)
      end

      def source_url(project)
        remote = project.entry.remote.to_s
        return remote unless remote.empty?

        Git.new(project.repo).remote_url || raise(Failure.new("no_remote", "project #{project.id} has no remote"))
      end

      def preview(project, name, dir, source, tag, settings, actor)
        {
          "ok" => true, "dry_run" => true, "project" => project.id, "env" => name, "dir" => dir, "source" => source, "tag" => tag,
          "cloned" => File.exist?(File.join(dir, ".git")), "steps" => Array(settings["steps"]), "strategy" => settings["strategy"] || "in_place", "activate" => Array(settings["activate"]),
          "drain" => settings["drain"], "health" => settings["health"], "actor" => actor,
          "policy_source" => project.source
        }
      end

      def prepare(dir, source)
        unless File.exist?(File.join(dir, ".git"))
          raise Failure.new("checkout_conflict", "#{dir} exists and is not a git checkout") if Dir.exist?(dir) && !Dir.empty?(dir)

          FileUtils.mkdir_p(File.dirname(dir), mode: 0o700)
          Git.clone(source, dir)
        end
        git = Git.new(dir)
        git.fetch
        git
      end

      def checkout(git, name, config, tag)
        branch = config["branch"]
        return checkout_test(git, branch) if name == "test" || (name != "stable" && config["runs"] == "branch")

        checkout_tag(git, branch, tag)
      end

      def checkout_test(git, branch)
        sha = git.rev("origin/#{branch}")
        raise Failure.new("missing_ref", "origin/#{branch} does not exist") unless sha

        git.checkout_tracking(branch)
        [sha, git.tags_at(sha).max_by { |name| git.tag_version(name) }]
      end

      def checkout_tag(git, branch, tag)
        tip = git.rev("origin/#{branch}")
        raise Failure.new("missing_ref", "origin/#{branch} does not exist") unless tip

        tag ||= git.tags_at(tip).max_by { |name| git.tag_version(name) }
        raise Failure.new("tag_required", "no release tag points at #{branch}'s tip; pass --tag vX.Y.Z") unless tag
        raise Failure.new("invalid_tag", "#{tag.inspect} is not a release tag") unless Git::TAG_PATTERN.match?(tag)

        sha = git.tag_commit(tag)
        raise Failure.new("tag_not_found", "tag #{tag} does not exist") unless sha
        unless git.ancestor?(sha, tip)
          raise Failure.new("tag_not_promoted", "tag #{tag} (#{sha[0, 12]}) is not on #{branch}; only promoted tags run in prod", "tag" => tag, "sha" => sha)
        end

        git.checkout_detached("refs/tags/#{tag}")
        [sha, tag]
      end

      def run_steps(ctx, settings)
        steps = []
        Array(settings["steps"]).each do |command|
          argv = Gates.argv_for(command, ctx[:vars])
          execution = run_command(ctx, argv, STEP_TIMEOUT)
          steps << { "command" => argv.join(" "), "exit" => execution.code, "duration_ms" => execution.duration_ms, "output_tail" => (execution.ok? ? nil : execution.tail) }.compact
          return { steps: steps, failed: true } unless execution.ok?
        end
        { steps: steps, failed: false }
      end

      def run_command(ctx, argv, timeout)
        guard = ctx[:guard]
        return Gates.exec(argv, chdir: ctx[:dir], env: ctx[:env], timeout: timeout) unless guard

        guard.exec(argv, chdir: ctx[:dir], env: ctx[:env], timeout: timeout)
      end

      def check_health(config, ctx)
        return { "status" => "unchecked", "detail" => "policy declares no health check" } unless config.is_a?(Hash)

        if config["run"]
          ran = run_health(config, ctx)
          return ran unless ran["status"] == "ok" && config["url"]
        end
        poll_health(config, ctx[:version])
      end

      def run_health(config, ctx)
        argv = Gates.argv_for(config["run"], ctx[:vars])
        return { "status" => "failed", "detail" => "health run is empty" } if argv.empty?

        execution = run_command(ctx, argv, config["timeout_s"] || STEP_TIMEOUT)
        return { "status" => "ok", "detail" => "run exited 0 in #{execution.duration_ms} ms" } if execution.ok?
        return { "status" => "timeout", "detail" => "run timed out: #{argv.join(' ')}" } if execution.timed_out

        { "status" => "failed", "detail" => "run exited #{execution.code}: #{execution.tail}" }
      end

      def poll_health(config, version)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + (config["timeout_s"] || DEFAULT_HEALTH_TIMEOUT)
        expect = config["expect_version"] ? version : nil
        last = "no response"
        status = "timeout"
        loop do
          ok, detail = probe(config["url"], expect)
          return { "status" => "ok", "detail" => detail } if ok

          last = detail
          status = "failed" if detail.start_with?("version")
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep POLL_SECONDS
        end
        { "status" => status, "detail" => last }
      end

      def probe(url, expect)
        uri = URI.parse(url)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 3, read_timeout: 5) do |http|
          http.get(uri.request_uri)
        end
        return [false, "http #{response.code}"] unless response.is_a?(Net::HTTPSuccess)
        return [true, "http #{response.code}"] unless expect

        reported = versions_in(response.body.to_s)
        return [true, "version #{expect}"] if reported.include?(expect.sub(/\Av/, ""))

        [false, "version mismatch: expected #{expect}, reported #{reported.empty? ? 'none' : reported.join(', ')}"]
      rescue SystemCallError, IOError, Timeout::Error, SocketError, URI::InvalidURIError, Net::ProtocolError => e
        [false, "#{e.class}: #{e.message}"]
      end

      def versions_in(body)
        found = collect_versions(JSON.parse(body))
        found.map { |value| value.to_s.sub(/\Av/, "") }
      rescue JSON::ParserError
        body.scan(/\d+\.\d+\.\d+(?:[.-][0-9A-Za-z.-]+)?/).map { |value| value.sub(/\Av/, "") }
      end

      def collect_versions(node, key = nil)
        case node
        when Hash then node.flat_map { |name, value| collect_versions(value, name.to_s) }
        when Array then node.flat_map { |value| collect_versions(value, key) }
        when String, Numeric then key && key.match?(/version/i) ? [node] : []
        else []
        end
      end

      def pinned_behind?(git, tag)
        latest = git.latest_tag
        return false if latest.nil? || tag.nil?

        git.tag_version(tag) < git.tag_version(latest)
      end

      def record_for(project, name, sha, tag, health, pinned, id = Gates.new_id("dpl"), detail = nil, skipped = false)
        {
          "id" => id, "project" => project.id, "env" => name, "sha" => sha, "tag" => tag, "health" => health["status"],
          "pinned_behind" => pinned, "at" => Time.now.utc.iso8601, "detail" => detail, "drain" => (skipped ? "skipped" : nil)
        }.compact
      end

      def record_state(project, name, tag, sha, pinned)
        path = State.state_file
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          data = read_state(path)
          entry = (data[STATE_KEY] ||= {})[project.id] ||= {}
          entry[name] = { "tag" => tag, "sha" => sha, "pinned_behind" => pinned, "at" => Time.now.utc.iso8601 }
          temp = "#{path}.#{Process.pid}.tmp"
          File.write(temp, YAML.dump(data), perm: 0o600)
          File.rename(temp, path)
        end
      end

      def read_state(path)
        return {} unless File.file?(path)

        data = Polispec::Schema::Document.parse(File.read(path), path)
        data.is_a?(Hash) ? data : {}
      rescue Polispec::Error
        {}
      end

      def result_for(project, name, dir, sha, tag, version, steps, health, pinned, actor, record, started)
        {
          "ok" => health["status"] == "ok" || health["status"] == "unchecked" && steps.all? { |step| step["exit"].zero? },
          "project" => project.id, "env" => name, "dir" => dir, "sha" => sha, "tag" => tag, "version" => version, "steps" => steps,
          "health" => health, "pinned_behind" => pinned, "actor" => actor, "record_id" => record["id"], "policy_source" => project.source,
          "duration_ms" => Gates.now_ms - started
        }
      end

      def failure_code(outcome, health)
        return outcome[:code] if outcome[:code]
        return "step_failed" if outcome[:failed]
        return "rolled_back" if health["status"] == "rolled_back"

        health["status"] == "failed" ? "health_failed" : "health_timeout"
      end

      def raise_failure(outcome, health, result)
        base = { "env" => result["env"], "sha" => result["sha"], "record_id" => result["record_id"] }
        raise Failure.new(outcome[:code], outcome[:detail], base.merge("health" => health)) if outcome[:code]

        if outcome[:failed]
          failed = outcome[:steps].last
          raise Failure.new("deploy_step_failed", "deploy step failed: #{failed['command']}", base.merge("output_tail" => failed["output_tail"]))
        end

        raise Failure.new(failure_code(outcome, health), "health check for #{result['env']} did not pass: #{health['detail']}", base.merge("health" => health))
      end
    end
  end
end
