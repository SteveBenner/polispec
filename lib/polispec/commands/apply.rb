#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../plan"
require_relative "../stewardship"
require_relative "../changes"

module Polispec
  class ApplyCommand
    def self.run(args)
      new.run(args)
    end

    def run(args)
      @json = args.include?("--json")
      parsed = Plan::Args.parse(args, "apply")
      @json = parsed.json
      perform(parsed)
    rescue Packages::Usage => e
      warn "polispec: #{e.message}"
      warn Plan::Args.usage("apply")
      2
    rescue Operator::Failure => e
      e.report(json: @json)
      1
    end

    private

    def perform(parsed)
      spec = parsed.spec
      refuse_sealed(spec) unless parsed.dry
      steward(parsed) if parsed.with_stewardship && !parsed.dry
      return package_run(parsed, dry: true) if parsed.dry && spec.kind == :package

      plan = Plan.build(spec)
      if parsed.dry
        @json ? puts(plan.to_json) : plan.render_text
        return 0
      end
      gate(plan, parsed.confirm)
      before = Changes.epoch
      status = send("apply_#{spec.kind}", plan, parsed)
      record_change(spec, plan, before) if status == 0
      status
    end

    def record_change(spec, plan, before)
      files = Array(plan.data["files"]).select { |item| %w[add replace].include?(item["action"]) }.map { |item| item["path"] }
      Changes.record(kind: "apply", subject: { "target" => plan.data["target"], "plan_id" => plan.plan_id }, epoch_before: before,
                     details: { "project" => spec.kind == :project ? spec.id : nil, "files" => files })
    end

    def steward(parsed)
      @stewardship = Stewardship.ensure!(quiet: @json)
    end

    def refuse_sealed(spec)
      return unless %i[global ledger].include?(spec.kind) && sealed?

      raise Operator::Failure.new("sealed_authority", "the sealed plane owns the global layer and the ledger; change the sealed source and reseal")
    end

    def sealed?
      require_relative "../harness_controls/plane"
      HarnessControls::Plane.resolve["status"] == "active"
    rescue StandardError
      false
    end

    def gate(plan, confirm)
      payload = { "plan_id" => plan.plan_id, "classification" => plan.data["classification"], "reasons" => plan.data["reasons"] }
      if !confirm.nil? && confirm != plan.plan_id
        raise Operator::Failure.new("plan_changed", "the plan changed since #{confirm}; it is now #{plan.plan_id}", payload)
      end
      return unless plan.needs_confirm?
      return unless confirm.nil?

      raise Operator::Failure.new("confirm_required", "this plan is #{plan.data['classification']} and needs confirmation: run polispec apply again with --confirm #{plan.plan_id}", payload)
    end

    def package_run(parsed, dry:)
      spec = parsed.spec
      package = Packages.find(spec.package)
      options = Packages::Runner::Options.new(repo: spec.repo, variant: spec.variant, params: spec.params, commit: parsed.commit, push: parsed.push,
                                              checkouts: parsed.checkouts, dry: dry, json: @json,
                                              extra: @stewardship ? { "stewardship" => @stewardship.map(&:to_h) } : {})
      Packages::Runner.new(package, options).run
    end

    def apply_package(plan, parsed)
      package_run(parsed, dry: false)
    end

    def apply_project(plan, parsed)
      artifacts = plan.artifacts
      project = artifacts[:project]
      repo = artifacts[:repo]
      git = Operator::Git.new(repo)
      branch = git.current_branch
      raise Operator::Failure.new("not_on_main", "HEAD is #{branch || 'detached'}, not main; apply commits on main only", "repo" => repo) unless branch == "main"

      dir = artifacts[:dir]
      paths = plan.data["files"].select { |item| %w[add replace].include?(item["action"]) }.map { |item| item["path"] }
      unless artifacts[:from] == "worktree"
        paths.each do |relative|
          target = File.join(repo, relative)
          FileUtils.mkdir_p(File.dirname(target))
          write_atomic(target, artifacts[:proposed_files].fetch(dir.empty? ? relative : relative.delete_prefix("#{dir}/")))
        end
      end
      commit(git, paths, plan, project.id)
    end

    def apply_global(plan, parsed)
      artifacts = plan.artifacts
      source = artifacts[:source]
      raise Operator::Failure.new("global_not_repo", "apply global needs polispec.global.repo; the global layer is a plain directory") unless source.kind == :repo

      git = Operator::Git.new(source.repo)
      branch = git.current_branch
      raise Operator::Failure.new("not_on_ref", "#{source.ref} is not checked out in #{source.repo} (HEAD is #{branch || 'detached'})") unless branch == source.ref

      prefix = source.path.to_s.empty? ? "" : "#{source.path}/"
      paths = plan.data["files"].select { |item| %w[add replace].include?(item["action"]) }.map { |item| item["path"] }
      unless artifacts[:from] == "worktree"
        paths.each do |relative|
          target = File.join(source.repo, relative)
          FileUtils.mkdir_p(File.dirname(target))
          write_atomic(target, artifacts[:proposed_files].fetch(relative.delete_prefix(prefix)))
        end
      end
      commit(git, paths, plan, "global")
    end

    def apply_ledger(plan, parsed)
      artifacts = plan.artifacts
      live = Ledger.default_path
      bytes = artifacts[:bytes]
      result = Schema.validate_file("ledger", artifacts[:file])
      raise Operator::Failure.new("ledger_invalid", "#{artifacts[:file]} does not validate") unless result.ok

      backup = nil
      if File.file?(live)
        backup = File.join(File.dirname(live), "#{File.basename(live)}.bak-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}")
        FileUtils.cp(live, backup, preserve: true)
      end
      write_atomic(live, bytes, File.file?(live) ? File.stat(live).mode & 0o777 : nil)
      report("plan_id" => plan.plan_id, "target" => "ledger", "ledger" => live, "backup" => backup, "applied" => true)
      0
    end

    def write_atomic(path, text, mode = nil)
      temp = "#{path}.#{Process.pid}.tmp"
      File.write(temp, text)
      File.chmod(mode, temp) if mode
      File.rename(temp, path)
    end

    def commit(git, paths, plan, label)
      if paths.empty?
        report("plan_id" => plan.plan_id, "target" => plan.data["target"], "committed" => [], "detail" => "no files change")
        return 0
      end

      git.run!("add", "--", *paths, code: "stage_failed")
      staged = git.run!("diff", "--cached", "--name-only", "--", *paths, code: "stage_failed").out.lines.map(&:chomp)
      if staged.empty?
        report("plan_id" => plan.plan_id, "target" => plan.data["target"], "committed" => [], "detail" => "nothing to commit for #{label}")
        return 0
      end

      git.run!("commit", "--quiet", "-m", "Apply polispec plan #{plan.plan_id}", "--", *staged, code: "commit_failed")
      report("plan_id" => plan.plan_id, "target" => plan.data["target"], "committed" => staged, "detail" => "committed #{staged.join(', ')}")
      0
    end

    def report(fields)
      if @json
        puts JSON.generate(fields.merge("ok" => true).merge(@stewardship ? { "stewardship" => @stewardship.map(&:to_h) } : {}))
      else
        puts "apply #{fields['plan_id']}: #{fields['detail'] || "applied #{fields['target']}"}"
      end
    end
  end
end

Polispec::CLI.register("apply", Polispec::ApplyCommand, summary: "carry out a package or a project, global or ledger plan; loosening plans need --confirm PLAN_ID")
