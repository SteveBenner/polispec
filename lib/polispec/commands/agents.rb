#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  class AgentsCommand
    USAGE = "usage: polispec agents render <project-id|repo-path> [--from worktree|<ref>] [--check] [--json]"
    Target = Struct.new(:root, :project, :policy_path)

    def self.run(args)
      new.run(args)
    end

    def run(args)
      args = args.dup
      json = args.delete("--json")
      check = args.delete("--check")
      from = take_option(args, "--from") || "worktree"
      verb, subject = args
      return usage unless verb == "render" && subject && args.length == 2

      target = locate(subject)
      source = from == "worktree" ? AgentsRender.source_from_worktree(target.root, target.policy_path) : AgentsRender.source_from_ref(target.root, from, target.policy_path)
      rendered = AgentsRender.render(source)
      files = AgentsRender.plan(target.root, rendered)
      files.each { |file| AgentsRender.apply(file) } unless check
      report(rendered, files, json: json, check: check)
    end

    private

    def take_option(args, name)
      index = args.index(name)
      return nil unless index

      value = args[index + 1]
      args.slice!(index, 2)
      value
    end

    def usage
      warn USAGE
      2
    end

    def locate(subject)
      ledger = Ledger.load
      project = ledger.project(subject)
      return Target.new(File.expand_path(project.repo), project, project.policy) if project

      raise Polispec::Error, "#{subject} is neither a ledger project nor a directory" unless File.directory?(subject)

      root = toplevel(subject) || File.expand_path(subject)
      located = ledger.locate(root)&.project
      Target.new(root, located, located ? located.policy : AgentsRender::POLICY_PATH)
    end

    def toplevel(dir)
      out = Environments.git(File.expand_path(dir), "rev-parse", "--show-toplevel")
      out && File.realpath(out.strip)
    rescue SystemCallError
      nil
    end

    def status_of(file, check)
      return file[:changed] ? "differs" : "unchanged" if check

      file[:changed] ? "wrote" : "unchanged"
    end

    def report(rendered, files, json:, check:)
      rows = files.map { |file| { "path" => file[:path], "status" => status_of(file, check) } }
      if json
        puts JSON.generate("project" => rendered.project, "row" => rendered.row, "files" => rows)
      elsif check
        differing = rows.select { |row| row["status"] == "differs" }
        puts(differing.empty? ? "ok" : differing.map { |row| "differs #{row['path']}" })
      else
        rows.each { |row| puts "#{row['status']} #{row['path']}" }
      end
      check && rows.any? { |row| row["status"] == "differs" } ? 1 : 0
    end
  end
end

Polispec::CLI.register("agents", Polispec::AgentsCommand, summary: "render the [ENVS] AGENTS.md row and .agents/directives/envs.md from environments.yml")
