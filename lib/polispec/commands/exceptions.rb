#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "stringio"
require_relative "../exceptions"
require_relative "../harness_controls/plane"
require_relative "../plan"
require_relative "apply"
require_relative "../changes"
require_relative "../lint"

module Polispec
  class ExceptionsCommand
    USAGE = <<~TEXT.chomp.freeze
      usage: polispec exceptions list [--json]
             polispec exceptions add --command GLOB [--tool NAME] [--kind control|rule] [--rule ID] [--global] [--note TEXT]
             polispec exceptions promote PROPOSAL_ID... [--command GLOB] [--global] [--note TEXT]
             polispec exceptions remove ENTRY_ID
    TEXT
    VALUE_FLAGS = {
      "list" => [],
      "add" => %w[--command --tool --kind --rule --note],
      "promote" => %w[--command --note],
      "remove" => []
    }.freeze
    SWITCHES = {
      "list" => %w[--json],
      "add" => %w[--global],
      "promote" => %w[--global],
      "remove" => []
    }.freeze

    def self.run(args)
      new.run(args)
    end

    def run(args)
      verb, *rest = args
      return usage unless VALUE_FLAGS.key?(verb)

      opts = parse(verb, rest)
      return usage unless opts

      send("run_#{verb}", opts)
    rescue Operator::Tty::NotTty => e
      warn "polispec: not_tty: #{e.message}"
      1
    rescue Operator::Tty::PhraseMismatch => e
      warn "polispec: confirmation_failed: #{e.message}"
      1
    rescue Operator::Failure => e
      e.report(json: false)
      1
    end

    private

    def parse(verb, args)
      opts = { switches: [], values: {}, rest: [] }
      queue = args.dup
      until queue.empty?
        arg = queue.shift
        name, inline = arg.start_with?("--") ? arg.split("=", 2) : [arg, nil]
        if SWITCHES.fetch(verb).include?(name)
          return nil unless inline.nil?

          opts[:switches] << name
        elsif VALUE_FLAGS.fetch(verb).include?(name)
          value = inline || queue.shift
          return nil if value.nil? || opts[:values].key?(name)

          opts[:values][name] = value
        elsif arg.start_with?("--")
          return nil
        else
          opts[:rest] << arg
        end
      end
      opts
    end

    def usage
      warn USAGE
      2
    end

    def run_list(opts)
      return usage unless opts[:rest].empty?

      Exceptions.reset!
      loaded = Exceptions.load
      path = Exceptions.path
      proposals = Exceptions.proposals
      if opts[:switches].include?("--json")
        puts JSON.generate("enabled" => Exceptions.enabled?, "path" => path, "problems" => loaded.problems, "entries" => loaded.entries, "proposals" => proposals)
      else
        puts "enabled: #{Exceptions.enabled? ? 'yes' : 'no'}"
        puts "file: #{path || 'no global layer'}"
        loaded.problems.each { |problem| puts "problem: #{problem}" }
        loaded.entries.each { |entry| puts entry_line(entry) }
        proposals.each { |proposal| puts proposal_line(proposal) }
      end
      0
    end

    def entry_line(entry)
      scope = entry["scope"]["global"] == true ? "global" : entry["scope"]["project"]
      [entry["id"], entry["kind"], entry["tool"], entry["command"] || "-", entry["rule"] || "-", scope, entry["note"]].compact.join(" ")
    end

    def proposal_line(proposal)
      age = (Time.now.utc - Time.iso8601(proposal["created"])).to_i
      [proposal["id"], proposal["kind"], proposal["tool"], proposal["command"] || "-", proposal["rule"] || "-", proposal["cwd"], "#{age}s"].join(" ")
    rescue ArgumentError
      proposal["id"].to_s
    end

    def run_add(opts)
      return usage unless opts[:rest].empty?

      values = opts[:values]
      kind = values.fetch("--kind", "control")
      tool = values.fetch("--tool", "Bash")
      return usage unless %w[control rule].include?(kind) && !tool.empty?
      return usage if tool == "Bash" ? !values.key?("--command") : values.key?("--command")
      return usage if kind == "rule" ? (!values.key?("--rule") || tool != "Bash") : values.key?("--rule")

      scope = opts[:switches].include?("--global") ? { "global" => true } : { "project" => project_root(Dir.pwd) }
      spec = { kind: kind, tool: tool, command: values["--command"], rule: values["--rule"], scope: scope, note: values["--note"] }
      mutate(label: "add", verb: "added", proposals: []) do |entries|
        built = new_entry(spec)
        [entries + [built], [built]]
      end
    end

    def run_promote(opts)
      ids = opts[:rest]
      values = opts[:values]
      return usage if ids.empty? || ids.uniq.length != ids.length || !ids.all? { |id| id.match?(Exceptions::PROPOSAL_ID) }
      return usage if values.key?("--command") && ids.length != 1

      found = Exceptions.find_proposals(ids)
      missing = ids.find { |id| !found.key?(id) }
      raise Operator::Failure.new("unknown_proposal", "#{missing} is not a pending proposal; list them with polispec exceptions list") if missing

      specs = ids.map do |id|
        proposal = found.fetch(id)
        scope = opts[:switches].include?("--global") ? { "global" => true } : { "project" => project_root(proposal["cwd"]) }
        exact = proposal["command"].nil? ? nil : Exceptions.literal(proposal["command"])
        { kind: proposal["kind"], tool: proposal["tool"], command: values.fetch("--command", exact), rule: proposal["rule"], scope: scope, note: values["--note"], cwd: proposal["cwd"] }
      end
      mutate(label: "promote", verb: "added", proposals: ids, shown: specs) do |entries|
        built = specs.map { |spec| new_entry(spec) }
        [entries + built, built]
      end
    end

    def run_remove(opts)
      id = opts[:rest].first
      return usage unless opts[:rest].length == 1 && id.match?(Exceptions::ENTRY_ID)

      mutate(label: "remove", verb: "removed", proposals: []) do |entries|
        target = entries.find { |entry| entry["id"] == id }
        raise Operator::Failure.new("unknown_exception", "#{id} is not a recorded exception") unless target

        [entries.reject { |entry| entry["id"] == id }, [target]]
      end
    end

    def new_entry(spec)
      command = spec[:command]
      if spec[:tool] == "Bash"
        text = Exceptions.normalize(command)
        raise Operator::Failure.new("invalid_pattern", "the command pattern is empty") if text.empty?
        raise Operator::Failure.new("invalid_pattern", "the first word of the pattern must not contain a glob character: #{Exceptions.first_word(text)}") if Exceptions.first_word(text).match?(Exceptions::GLOB_CHARS)
      elsif !command.nil?
        raise Operator::Failure.new("invalid_pattern", "a command pattern applies to tool Bash only")
      end
      Exceptions.build_entry(kind: spec[:kind], tool: spec[:tool], command: command, rule: spec[:rule], scope: spec[:scope], note: spec[:note], now: Time.now)
    end

    def project_root(directory)
      expanded = Exceptions.canonical_path(directory)
      return expanded unless File.directory?(expanded)

      out, status = Trace.capture2(Operator::Git.env, "git", "-C", expanded, "rev-parse", "--show-toplevel", err: File::NULL, trace: :quiet)
      status.success? && !out.strip.empty? ? Exceptions.canonical_path(out.strip) : expanded
    rescue SystemCallError
      Exceptions.canonical_path(directory)
    end

    def preflight
      Trace.step("preflight") { preflight_checks }
    end

    def preflight_checks
      plane = HarnessControls::Plane.resolve
      Trace.info("plane status", status: plane["status"])
      raise Operator::Failure.new("sealed_authority", "the sealed plane is broken; repair it before recording exceptions") if plane["status"] == "broken"
      raise Operator::Failure.new("sealed_authority", "the sealed plane owns the global layer; change the sealed source and reseal") if plane["status"] == "active"

      source = Layers.source
      raise Operator::Failure.new("global_unconfigured", "no global layer is configured (polispec.global.repo)") unless source
      raise Operator::Failure.new("global_not_repo", "exceptions are recorded in a git shelf; the global layer is a plain directory") unless source.kind == :repo

      Trace.info("global source", kind: source.kind, ref: source.ref, repo: Trace.path(source.repo), path: source.path)

      git = Operator::Git.new(source.repo)
      branch = git.current_branch
      Trace.info("shelf branch", branch: branch || "detached", expected: source.ref)
      raise Operator::Failure.new("not_on_ref", "#{source.ref} is not checked out in #{source.repo} (HEAD is #{branch || 'detached'})") unless branch == source.ref

      scope = source.path.to_s.empty? ? "." : source.path
      dirty = git.run!("status", "--porcelain", "--", scope).out.lines.first
      Trace.info("shelf status", scope: scope, clean: dirty ? "no" : "yes")
      raise Operator::Failure.new("dirty_shelf", "uncommitted changes under #{scope} would be committed with the exception: #{dirty.to_s[3..].to_s.strip}") if dirty
      source
    end

    def mutate(label:, verb:, proposals:, shown: nil)
      source = preflight
      Exceptions.reset!
      loaded = Trace.step("load exceptions") do
        result = Exceptions.load
        Trace.info("exceptions loaded", path: Trace.path(Exceptions.path), entries: result.entries.length, problems: result.problems.length)
        result
      end
      raise Operator::Failure.new("exceptions_invalid", "#{Exceptions::FILE} is invalid: #{loaded.problems.first}") unless loaded.problems.empty?

      entries, touched = Trace.step("build entry", action: label) do
        pair = yield(loaded.entries)
        pair[1].each do |entry|
          Trace.info("entry", id: entry["id"], kind: entry["kind"], tool: entry["tool"], command: entry["command"], rule: entry["rule"], scope: entry["scope"]["global"] == true ? "global" : entry["scope"]["project"], note_length: entry["note"].to_s.length)
        end
        pair
      end
      combined = entries
      duplicate = combined.map { |entry| entry["id"] }.tally.find { |_, count| count > 1 }
      raise Operator::Failure.new("duplicate", "#{duplicate.first} is already recorded") if duplicate
      raise Operator::Failure.new("exceptions_invalid", "more than #{Exceptions::MAX_ENTRIES} exceptions would be recorded") if combined.length > Exceptions::MAX_ENTRIES

      Trace.step("validate document", entries: combined.length) do
        document = Schema::Document.parse(Exceptions.dump(combined), Exceptions::FILE)
        problems = Exceptions.validate(document)
        raise Operator::Failure.new("exceptions_invalid", "the resulting document is invalid: #{problems.first}") unless problems.empty?
      end

      ids = touched.map { |entry| entry["id"] }
      phrase = ids.empty? ? "exceptions #{label}" : "exceptions #{label} #{(label == 'promote' ? proposals : ids).join(' ')}"
      Operator::Tty.confirm!(phrase, prompt: prompt(label, touched, shown))
      before = Changes.epoch
      status = commit_change(source, Exceptions.dump(combined), verb, ids, proposals)
      Changes.record(kind: "exceptions.#{label}", subject: { "entry_ids" => ids }, epoch_before: before) if status == 0
      status
    end

    def prompt(label, touched, shown)
      lines = ["Record this change to #{Exceptions::FILE} (#{label}):"]
      touched.each_with_index do |entry, index|
        lines << "  #{entry['id']}"
        lines << "    kind: #{entry['kind']}  tool: #{entry['tool']}"
        lines << "    command: #{entry['command'] || '-'}"
        lines << "    rule: #{entry['rule'] || '-'}"
        lines << "    scope: #{entry['scope']['global'] == true ? 'global' : entry['scope']['project']}"
        lines << "    note: #{entry['note'] || '-'}"
        lines << "    proposal cwd: #{shown[index][:cwd]}" if shown
      end
      lines.join("\n")
    end

    def commit_change(source, text, verb, ids, proposals)
      target = File.join(source.repo, source.path, Exceptions::FILE)
      original = File.file?(target) ? File.binread(target) : nil
      plan_id = nil
      Trace.step("write exceptions.yml", path: Trace.path(target), bytes: text.bytesize) do
        Lint.guard_write!(text, path: target, kind: "exceptions")
        begin
          write_atomic(target, text)
          plan_id = apply_global
        rescue StandardError, ScriptError => e
          Trace.step("restore previous bytes", path: Trace.path(target), had_original: original ? "yes" : "no") { restore(source, target, original) }
          warn "polispec: exceptions_failed: #{e.message}" unless e.is_a?(Operator::Failure)
          raise
        end
      end
      Trace.step("forget proposals", ids: proposals) { Exceptions.forget(proposals) } unless proposals.empty?
      puts "exceptions: #{verb} #{ids.join(' ')} (plan #{plan_id}, committed in #{source.repo})"
      0
    ensure
      Exceptions.reset!
    end

    def apply_global
      plan = Trace.step("plan global") do
        built = Plan.build(Plan::SPEC.new(kind: :global))
        Trace.info("plan built", plan_id: built.plan_id, classification: built.data["classification"])
        built
      end
      captured = StringIO.new
      previous = $stdout
      status = Trace.step("apply global", plan_id: plan.plan_id) do
        begin
          $stdout = captured
          ApplyCommand.new.run(["global", "--confirm", plan.plan_id])
        ensure
          $stdout = previous
        end
      end
      raise Operator::Failure.new("apply_failed", "apply global did not complete (exit #{status})") unless status.zero?

      plan.plan_id
    end

    def restore(source, target, original)
      if original
        write_atomic(target, original)
      elsif File.file?(target)
        State.ensure_dirs
        FileUtils.mv(target, File.join(State.home, "#{Exceptions::FILE}.failed-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}"))
      end
      Operator::Git.new(source.repo).run("restore", "--staged", "--", File.join(source.path, Exceptions::FILE))
    rescue StandardError
      nil
    end

    def write_atomic(path, bytes)
      temp = "#{path}.#{Process.pid}.tmp"
      File.binwrite(temp, bytes)
      File.rename(temp, path)
    end
  end
end

Polispec::CLI.register("exceptions", Polispec::ExceptionsCommand, summary: "list, add, promote and remove persistent exceptions to guard asks")
