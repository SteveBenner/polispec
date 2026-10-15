#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "open3"
require "tmpdir"
require_relative "process"
require_relative "step"

module Polispec
  module Smoke
    module HostCopy
      PROBES_SCHEMA = "polispec.smoke-host-probes/v1"
      PLACEHOLDER = /\{\{\s*(project|home|tmp)\s*\}\}/
      WORKERS = 4

      module_function

      def load_probes(tree)
        path = File.join(tree, "smoke", "host-probes.yml")
        raise Polispec::Error, "#{path} does not exist" unless File.file?(path)

        data = YAML.safe_load(File.read(path), aliases: false)
        raise Polispec::Error, "#{path}: schema must be #{PROBES_SCHEMA}" unless data.is_a?(Hash) && data["schema"] == PROBES_SCHEMA
        raise Polispec::Error, "#{path}: probes must be a non-empty list" unless data["probes"].is_a?(Array) && !data["probes"].empty?

        names = {}
        data["probes"].each_with_index do |probe, index|
          where = "#{path}: probe #{index}"
          raise Polispec::Error, "#{where} must be a mapping" unless probe.is_a?(Hash)
          raise Polispec::Error, "#{where} has unknown keys #{(probe.keys - %w[name harness tool input cwd]).join(', ')}" unless (probe.keys - %w[name harness tool input cwd]).empty?
          raise Polispec::Error, "#{where} needs a name" unless probe["name"].is_a?(String) && !probe["name"].empty?
          raise Polispec::Error, "#{where} repeats the name #{probe['name']}" if names[probe["name"]]
          raise Polispec::Error, "#{where} harness must be claude or codex" unless %w[claude codex].include?(probe["harness"])
          raise Polispec::Error, "#{where} needs a tool" unless probe["tool"].is_a?(String) && !probe["tool"].empty?
          raise Polispec::Error, "#{where} input must be a mapping" unless probe["input"].is_a?(Hash)
          raise Polispec::Error, "#{where} cwd must be a string" unless probe["cwd"].is_a?(String)

          names[probe["name"]] = true
        end
        data["probes"]
      rescue Psych::Exception => e
        raise Polispec::Error, "#{path}: #{e.message.lines.first.to_s.strip}"
      end

      def expand(value, project, home, tmp)
        case value
        when String then value.gsub(PLACEHOLDER) { { "project" => project, "home" => home, "tmp" => tmp }.fetch(Regexp.last_match(1)) }
        when Hash then value.to_h { |key, item| [key, expand(item, project, home, tmp)] }
        when Array then value.map { |item| expand(item, project, home, tmp) }
        else value
        end
      end

      def per_project?(probe)
        [probe["cwd"], JSON.generate(probe["input"])].any? { |text| text.include?("{{project}}") }
      end

      def copy_ledger(root)
        source = Ledger.default_path
        raise Polispec::Error, "no ledger at the configured path" unless File.file?(source)

        target = File.join(root, "ledger.yml")
        FileUtils.cp(source, target)
        data = YAML.safe_load(File.read(target), permitted_classes: [Date, Time], aliases: false)
        projects = data.is_a?(Hash) && data["projects"].is_a?(Array) ? data["projects"].select { |item| item.is_a?(Hash) && item["status"] != "retired" } : []
        [target, projects.map { |item| { "id" => item["id"].to_s, "repo" => File.expand_path(item["repo"].to_s) } }]
      end

      def copy_global(root)
        target = File.join(root, "global")
        FileUtils.mkdir_p(target)
        source = Layers.source
        return target unless source

        if source.kind == :dir
          FileUtils.cp_r(File.join(source.root, "."), target) if File.directory?(source.root)
        else
          spec = source.path.to_s.empty? ? source.ref : "#{source.ref}:#{source.path}"
          tar, status = Open3.capture2("git", "-C", source.repo, "archive", "--format=tar", spec, binmode: true)
          Open3.capture2("tar", "-x", "-C", target, stdin_data: tar, binmode: true) if status.success?
        end
        target
      end

      def payload(probe, cwd)
        { "hook_event_name" => "PreToolUse", "session_id" => "smoke", "cwd" => cwd, "tool_name" => probe["tool"], "tool_input" => probe["input"] }
      end

      def judge(polispec, probe, cwd, env, root)
        result = Exec.run([polispec, "hook", "pretool", "--harness", probe["harness"]], env: env, chdir: root, stdin: JSON.generate(payload(probe, cwd)), timeout: 30)
        verdict = Step.hook_verdict(nil, result.stdout)
        verdict = { "decision" => "timeout", "rule" => nil } if result.timed_out
        verdict = { "decision" => "error", "rule" => nil } if result.error
        verdict
      end

      def jobs(probes, projects, home, tmp)
        probes.flat_map do |probe|
          if per_project?(probe)
            projects.map { |project| { probe: probe, project: project["id"], repo: project["repo"] } }
          else
            [{ probe: probe, project: "-", repo: nil }]
          end
        end.map do |job|
          expanded = job[:probe].merge("input" => expand(job[:probe]["input"], job[:repo].to_s, home, tmp))
          job.merge(probe: expanded, cwd: expand(job[:probe]["cwd"], job[:repo].to_s, home, tmp), name: job[:probe]["name"])
        end
      end

      def run_jobs(jobs, polispec, env, root)
        queue = Queue.new
        jobs.each_with_index { |job, index| queue << [job, index] }
        results = Array.new(jobs.length)
        Array.new(WORKERS) do
          Thread.new do
            loop do
              job, index = begin
                queue.pop(true)
              rescue ThreadError
                break
              end
              verdict = judge(polispec, job[:probe], job[:cwd], env, root)
              results[index] = { "probe" => job[:name], "project" => job[:project], "decision" => verdict["decision"], "rule" => verdict["rule"] }
            end
          end
        end.each(&:join)
        results
      end

      def run(tree:, out:, polispec:, against: nil)
        root = File.join(out, "host-copy")
        FileUtils.mkdir_p(File.join(root, "polispec-home"))
        probes = load_probes(tree)
        _, projects = copy_ledger(root)
        global = copy_global(root)
        mode = Engine::Settings.enforce_mode
        env = {
          "POLISPEC_LEDGER" => File.join(root, "ledger.yml"), "POLISPEC_GLOBAL" => global, "POLISPEC_HOME" => File.join(root, "polispec-home"),
          "POLISPEC_SMOKE" => File.join(root, "smoke.yml"), "POLISPEC_STATE_HOME" => File.join(root, "state"), "XDG_STATE_HOME" => File.join(root, "xdg-state"), Layout::ENFORCE_ENV => mode
        }
        jobs = jobs(probes, projects, Dir.home, Dir.tmpdir)
        rows = run_jobs(jobs, polispec, env, root)
        diffs = []
        if against
          other = run_jobs(jobs, File.join(against, "bin", "polispec"), env, root)
          rows.each_with_index do |row, index|
            mine = [row["decision"], row["rule"]].compact.join(" ")
            theirs = [other[index]["decision"], other[index]["rule"]].compact.join(" ")
            diffs << { "scenario" => "host-copy", "step" => "#{row['probe']}@#{row['project']}", "candidate" => mine, "against" => theirs } if mine != theirs
          end
        end
        { "mode" => mode, "projects" => projects.map { |item| item["id"] }, "rows" => rows, "diffs" => diffs }
      end
    end
  end
end
