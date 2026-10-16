#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "scenario"
require_relative "process"

module Polispec
  module Smoke
    class FixtureError < Polispec::Error; end

    class Layout
      ENFORCE_ENV = "RPLUGIN_POLISPEC_POLISPEC_ENFORCE"
      FIXED_DATE = "2026-01-01T00:00:00Z"

      attr_reader :scratch, :tree, :polispec, :out, :enforce, :projects, :checkouts

      def initialize(scratch:, tree:, polispec:, out:, enforce:, project_ids:, checkout_ids:)
        @scratch = scratch
        @tree = tree
        @polispec = polispec
        @out = out
        @enforce = enforce
        @projects = project_ids.to_h { |id| [id, File.join(scratch, "projects", id)] }
        @checkouts = checkout_ids.to_h { |id| [id, Scenario::CHECKOUT_ENVS.to_h { |env| [env, File.join(scratch, "envs", id, env)] }] }
      end

      def home
        File.join(scratch, "home")
      end

      def files
        File.join(scratch, "files")
      end

      def global
        File.join(scratch, "global")
      end

      def ledger
        File.join(scratch, "ledger.yml")
      end

      def state
        File.join(scratch, "state")
      end

      def gitconfig
        File.join(scratch, "gitconfig")
      end

      def envs_root
        File.join(scratch, "envs")
      end

      def vars
        base = {
          "scratch" => scratch, "home" => home, "files" => files, "global" => global, "ledger" => ledger,
          "polispec" => polispec, "tree" => tree, "out" => out
        }
        projects.each { |id, repo| base["project.#{id}"] = repo }
        checkouts.each { |id, envs| envs.each { |env, path| base["checkout.#{id}.#{env}"] = path } }
        base
      end

      def env(extra = {}, home: false)
        base = {
          "POLISPEC_LEDGER" => ledger,
          "POLISPEC_HOME" => File.join(scratch, "polispec-home"),
          "POLISPEC_GLOBAL" => global,
          "POLISPEC_STATE_HOME" => state,
          "XDG_STATE_HOME" => File.join(scratch, "xdg-state"),
          "POLISPEC_SMOKE" => File.join(scratch, "smoke.yml"),
          "POLISPEC_SPECS_REPO" => File.join(scratch, "specs-repo"),
          ENFORCE_ENV => enforce,
          "POLISPEC_CODE_DECIDE" => "off",
          "GIT_CONFIG_GLOBAL" => gitconfig,
          "GIT_CONFIG_NOSYSTEM" => "1",
          "GIT_TERMINAL_PROMPT" => "0",
          "GIT_AUTHOR_DATE" => FIXED_DATE,
          "GIT_COMMITTER_DATE" => FIXED_DATE
        }
        base["HOME"] = self.home if home
        base.merge(extra)
      end
    end

    module Fixture
      EXAMPLE_GLOBAL = <<~YAML
        schema: polispec.global/v1
        summary: Smoke baseline with one harmless rule so every path is governed.
        rules:
          - { id: SMOKE-NOSECRETS, match: { class: [secrets.read], env: prod }, verdict: deny, reason: "smoke baseline: no production secrets" }
      YAML

      EMPTY_GLOBAL = "schema: polispec.global/v1\nsummary: Smoke fixture with no global rules.\n".freeze

      module_function

      def build(scenario, scratch:, tree:, polispec:, builder:, out:)
        spec = scenario.fixture
        projects = Array(spec["projects"])
        layout = Layout.new(scratch: scratch, tree: tree, polispec: polispec, out: out, enforce: spec["enforce"] || "enforce",
                            project_ids: projects.map { |item| item["id"] }, checkout_ids: projects.select { |item| item["checkouts"] }.map { |item| item["id"] })
        [layout.scratch, layout.home, layout.files, layout.global, layout.state, File.join(scratch, "projects"), File.join(scratch, "polispec-home")].each { |dir| FileUtils.mkdir_p(dir) }
        File.write(layout.gitconfig, "[user]\n\tname = smoke\n\temail = smoke@example.invalid\n[init]\n\tdefaultBranch = main\n[protocol \"file\"]\n\tallow = always\n")
        seed_ledger(layout, tree)
        write_global(layout, spec)
        write_files(spec["files"], layout.files, layout)
        projects.each { |project| build_project(project, layout, builder) }
        flip_status(layout, projects, builder)
        layout
      end

      def write_files(map, root, layout)
        (map || {}).each do |relative, text|
          target = File.join(root, relative)
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, Scenario.expand(text, layout.vars))
        end
      end

      def seed_ledger(layout, tree)
        example = YAML.safe_load(File.read(File.join(tree, "examples", "ledger.example.yml")), permitted_classes: [Date, Time], aliases: false)
        ledger = {
          "schema" => example["schema"], "host" => "smoke", "envs_root" => layout.envs_root,
          "defaults" => example["defaults"], "projects" => [],
          "pauses_log" => File.join(layout.scratch, "pauses.jsonl"), "allow_once_log" => File.join(layout.scratch, "allow_once.jsonl")
        }
        File.write(layout.ledger, YAML.dump(ledger))
      rescue SystemCallError, Psych::Exception => e
        raise FixtureError, "cannot seed the ledger: #{e.message}"
      end

      def write_global(layout, spec)
        case spec["global"] || "none"
        when "none" then File.write(File.join(layout.global, "global.yml"), EMPTY_GLOBAL)
        when "example" then File.write(File.join(layout.global, "global.yml"), EXAMPLE_GLOBAL)
        when "files" then write_files(spec["global_files"], layout.global, layout)
        end
      end

      def sh(layout, argv, chdir, label)
        result = Exec.run(argv, env: layout.env, chdir: chdir, timeout: 120)
        return result if result.exit == 0 && !result.timed_out

        detail = result.error || (result.timed_out ? "timed out" : "exit #{result.exit}: #{(result.stderr.empty? ? result.stdout : result.stderr).strip.lines.last(3).join(' ').strip[0, 300]}")
        raise FixtureError, "#{label} failed: #{detail}"
      end

      def build_project(project, layout, builder)
        id = project["id"]
        repo = layout.projects.fetch(id)
        FileUtils.mkdir_p(repo)
        files = project["files"] || { "README.md" => "#{id}\n" }
        write_files(files, repo, layout)
        sh(layout, %w[git init -q -b main], repo, "git init #{id}")
        sh(layout, %w[git add -A], repo, "git add #{id}")
        sh(layout, ["git", "commit", "-q", "-m", "smoke fixture"], repo, "git commit #{id}")
        argv = [builder, "apply", "environment-control", "--repo", repo, "--variant", project["variant"] || "service",
                "--param", "serves=#{project['serves'] || 'real_users'}", "--param", "id=#{id}", "--commit", "--json"]
        if project["checkouts"]
          remote = File.join(layout.scratch, "projects", "#{id}.git")
          sh(layout, ["git", "init", "-q", "--bare", "-b", "main", remote], layout.scratch, "git init remote #{id}")
          sh(layout, ["git", "remote", "add", "origin", remote], repo, "git remote #{id}")
          argv += %w[--push --checkouts]
        end
        sh(layout, argv, layout.scratch, "apply environment-control #{id}")
      end

      def flip_status(layout, projects, builder)
        wanted = projects.select { |item| item["status"] == "live" && (item["serves"] || "real_users") == "real_users" }.map { |item| item["id"] }
        return if wanted.empty?

        current = nil
        lines = File.readlines(layout.ledger).map do |line|
          current = Regexp.last_match(1) if line =~ /\A  - id: (\S+)/
          wanted.include?(current) && line =~ /\A    status: / ? "    status: live\n" : line
        end
        proposed = File.join(layout.scratch, "ledger.next.yml")
        File.write(proposed, lines.join)
        planned = sh(layout, [builder, "plan", "ledger", "--from", proposed, "--json"], layout.scratch, "plan ledger")
        plan_id = JSON.parse(planned.stdout)["plan_id"]
        sh(layout, [builder, "apply", "ledger", "--from", proposed, "--confirm", plan_id.to_s, "--json"], layout.scratch, "apply ledger")
      rescue JSON::ParserError
        raise FixtureError, "plan ledger printed no plan id"
      end
    end
  end
end
