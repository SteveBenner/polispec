#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "digest"
require "fileutils"
require "time"
require_relative "native_pin"
require_relative "operator/git"
require_relative "stewardship"

module Polispec
  module NativeInstall
    HOOK_MARKER = "/bin/polispec-guard"
    CODEX_BLOCK_BEGIN = "# >>> polispec hooks >>>"
    CODEX_BLOCK_END = "# <<< polispec hooks <<<"
    HARNESSES = %w[claude codex].freeze
    SCOPES = %w[user project].freeze
    RULE_NAMES = %w[polispec.md polispec-stewardship.md].freeze
    CLAUDE_EVENTS = { "PreToolUse" => "pretool", "SessionStart" => "session", "SubagentStart" => "session" }.freeze
    CODEX_EVENTS = [
      ["PreToolUse", "*", "pretool"],
      ["SessionStart", "startup|resume|clear|compact", "session"],
      ["SubagentStart", "*", "session"]
    ].freeze
    TRUST_NOTE = "Codex asks you to review and trust new hooks; open codex and approve the polispec hooks (/hooks) before they run."

    class Plan
      attr_reader :harness, :scope, :target, :wired_root, :changes, :messages, :backups, :links, :files_written, :preview
      attr_accessor :ok, :ledger_created

      def initialize(harness, scope, target, wired_root, dry_run)
        @harness = harness
        @scope = scope
        @target = target
        @wired_root = wired_root
        @dry_run = dry_run
        @changes = []
        @messages = []
        @backups = []
        @links = []
        @files_written = []
        @preview = nil
        @ok = true
      end

      def dry_run?
        @dry_run
      end

      def change(file, action)
        @changes << { "file" => file, "action" => action }
      end

      def say(message)
        @messages << message
      end

      def show(before, after)
        @preview = { "before" => before, "after" => after }
      end

      def to_h
        { "harness" => harness, "scope" => scope, "target" => target, "changes" => changes, "ok" => ok }
      end
    end

    module_function

    def stamp
      Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    end

    def codex_home
      value = ENV["CODEX_HOME"].to_s
      File.expand_path(value.empty? ? "~/.codex" : value)
    end

    def wired_root
      current = NativePin.current_link
      File.exist?(current) ? current : Runtime.root
    end

    def pinned_note?
      !File.exist?(NativePin.current_link)
    end

    def target_file(harness, scope, project)
      case harness
      when "claude" then scope == "user" ? File.join(Stewardship.claude_home, "settings.json") : File.join(project, ".claude", "settings.json")
      else scope == "user" ? File.join(codex_home, "config.toml") : File.join(project, ".codex", "config.toml")
      end
    end

    def guard_command(root, kind, harness_flag)
      "'#{File.join(root, 'bin', 'polispec-guard')}' #{kind} --harness #{harness_flag}"
    end

    def receipt_path(harness, scope, target)
      File.join(State.home, "installs", "#{harness}-#{scope}-#{Digest::SHA256.hexdigest(target)[0, 12]}.json")
    end

    def ours?(path, root)
      [root, NativePin.data_home, Runtime.root].any? { |base| path == base || path.start_with?("#{base}/") }
    end

    def write_file(plan, path, content)
      return false if File.file?(path) && File.read(path) == content

      plan.change(path, File.exist?(path) ? "rewrite (backup first)" : "create")
      plan.files_written << path
      return true if plan.dry_run?

      mode = File.exist?(path) ? File.stat(path).mode & 0o7777 : 0o600
      if File.exist?(path)
        backup = "#{path}.polispec-backup-#{stamp}"
        FileUtils.cp(path, backup, preserve: true)
        plan.backups << backup
      end
      FileUtils.mkdir_p(File.dirname(path))
      temporary = "#{path}.#{Process.pid}.tmp"
      File.write(temporary, content)
      File.chmod(mode, temporary)
      File.rename(temporary, path)
      true
    end

    def place_link(plan, path, target)
      if File.symlink?(path)
        raw = File.readlink(path)
        if raw == target
          plan.links << { "path" => path, "target" => target }
          return
        end
        unless ours?(File.expand_path(raw, File.dirname(path)), plan.wired_root)
          plan.say("kept #{path} (points at #{raw})")
          return
        end
      elsif File.exist?(path)
        plan.say("kept #{path} (not a symlink)")
        return
      end
      plan.change(path, "link -> #{target}")
      plan.links << { "path" => path, "target" => target }
      return if plan.dry_run?

      FileUtils.mkdir_p(File.dirname(path))
      temporary = "#{path}.#{Process.pid}.tmp"
      File.symlink(target, temporary)
      File.rename(temporary, path)
    end

    def drop_link(plan, path, expected)
      return unless File.symlink?(path)

      raw = File.readlink(path)
      allowed = expected ? raw == expected : ours?(File.expand_path(raw, File.dirname(path)), plan.wired_root)
      unless allowed
        plan.say("kept #{path} (points at #{raw})")
        return
      end
      plan.change(path, "unlink")
      File.delete(path) unless plan.dry_run?
    end

    def read_json(path)
      return {} unless File.file?(path)

      text = File.read(path)
      return {} if text.strip.empty?

      data = JSON.parse(text)
      raise Polispec::Error, "#{path} is not a JSON object" unless data.is_a?(Hash)

      data
    rescue JSON::ParserError => e
      raise Polispec::Error, "#{path} is not valid JSON: #{e.message.lines.first.to_s.strip}"
    end

    def marked_command?(hook)
      hook.is_a?(Hash) && hook["command"].to_s.include?(HOOK_MARKER)
    end

    def group_hooks(group)
      group.is_a?(Hash) && group["hooks"].is_a?(Array) ? group["hooks"] : []
    end

    def strip_marked(groups)
      groups.map do |group|
        next group unless group.is_a?(Hash) && group_hooks(group).any? { |hook| marked_command?(hook) }

        stripped = group.dup
        stripped["hooks"] = group_hooks(group).reject { |hook| marked_command?(hook) }
        stripped
      end.reject { |group| group.is_a?(Hash) && group["hooks"].is_a?(Array) && group["hooks"].empty? }
    end

    def double_guard_claude(plan, project, force)
      files = [File.join(Stewardship.claude_home, "settings.json")]
      files << File.join(project, ".claude", "settings.json") if plan.scope == "project"
      files.each do |file|
        enabled = read_json(file)["enabledPlugins"]
        next unless enabled.is_a?(Hash)

        key = enabled.keys.find { |name| name.to_s.start_with?("polispec@") && enabled[name] == true }
        next unless key
        next if force

        raise Polispec::Error, "polispec already runs as the Claude Code plugin #{key}; installing hooks too would run the guard twice. Use one, or pass --force."
      end
    end

    def double_guard_codex(force)
      return if force

      base = File.join(codex_home, "plugins")
      hit = %w[*polispec* */*polispec* */*/*polispec*].flat_map { |pattern| Dir.glob(File.join(base, pattern)) }.first
      return unless hit

      raise Polispec::Error, "polispec already runs as the Codex plugin at #{hit}; installing hooks too would run the guard twice. Use one, or pass --force."
    end

    def install(harness, scope: "user", project: Dir.pwd, force: false, dry_run: false)
      raise Polispec::Error, "unknown harness #{harness}" unless HARNESSES.include?(harness)
      raise Polispec::Error, "unknown scope #{scope}" unless SCOPES.include?(scope)

      project = File.expand_path(project)
      root = wired_root
      plan = Plan.new(harness, scope, target_file(harness, scope, project), root, dry_run)
      plan.say("note: polispec is not pinned; run polispec pin so the hooks point at a read-only release") if pinned_note?
      harness == "claude" ? install_claude(plan, project, force) : install_codex(plan, project, force)
      ensure_ledger(plan) if scope == "user"
      write_receipt(plan) unless dry_run
      plan
    end

    def ensure_ledger(plan)
      result = Ledger.create_starter!(Ledger.default_path, dry: plan.dry_run?)
      path = result["path"]
      if !result["created"]
        plan.say("ledger: kept #{path}")
      elsif plan.dry_run?
        plan.say("ledger: would create #{path}")
      else
        plan.ledger_created = path
        plan.say("ledger: created #{path} (no projects yet)")
      end
    rescue Operator::Failure => e
      plan.say("ledger: #{e.message}")
    end

    def install_claude(plan, project, force)
      double_guard_claude(plan, project, force)
      path = plan.target
      data = read_json(path)
      before = JSON.pretty_generate(data["hooks"] || {})
      hooks = data["hooks"].is_a?(Hash) ? data["hooks"] : {}
      CLAUDE_EVENTS.each do |event, kind|
        command = guard_command(plan.wired_root, kind, "claude-code")
        ours = { "hooks" => [{ "type" => "command", "command" => command, "timeout" => 10 }] }
        groups = hooks[event].is_a?(Array) ? hooks[event] : []
        marked = groups.select { |group| group_hooks(group).any? { |hook| marked_command?(hook) } }
        next if marked.length == 1 && marked.first == ours

        hooks[event] = strip_marked(groups) + [ours]
      end
      data["hooks"] = hooks
      after = JSON.pretty_generate(hooks)
      plan.show(before, after)
      write_file(plan, path, "#{JSON.pretty_generate(data)}\n")
      skills = plan.scope == "user" ? File.join(Stewardship.claude_home, "skills", "polispec") : File.join(project, ".claude", "skills", "polispec")
      place_link(plan, skills, File.join(plan.wired_root, "skills", "polispec"))
      if plan.scope == "user"
        RULE_NAMES.each { |name| place_link(plan, File.join(Stewardship.claude_home, "rules", "polispec", name), File.join(plan.wired_root, "rules", name)) }
      else
        plan.say("rules are user scope; run with --scope user to load them in every session")
      end
    end

    def codex_block(root)
      lines = [CODEX_BLOCK_BEGIN]
      CODEX_EVENTS.each_with_index do |(event, matcher, kind), index|
        command = guard_command(root, kind, "codex").gsub("\\") { "\\\\" }.gsub('"') { '\\"' }
        lines << "" unless index.zero?
        lines.concat(["[[hooks.#{event}]]", "matcher = \"#{matcher}\"", "", "[[hooks.#{event}.hooks]]", "type = \"command\"", "command = \"#{command}\"", "timeout = 10"])
      end
      lines << CODEX_BLOCK_END
      "#{lines.join("\n")}\n"
    end

    def codex_block_pattern
      /(?:\n)?^#{Regexp.escape(CODEX_BLOCK_BEGIN)}\n.*?^#{Regexp.escape(CODEX_BLOCK_END)}\n?/m
    end

    def install_codex(plan, project, force)
      double_guard_codex(force)
      path = plan.target
      original = File.file?(path) ? File.read(path) : ""
      block = codex_block(plan.wired_root)
      updated =
        if original.match?(codex_block_pattern)
          original.sub(/^#{Regexp.escape(CODEX_BLOCK_BEGIN)}\n.*?^#{Regexp.escape(CODEX_BLOCK_END)}\n?/m) { block }
        elsif original.empty?
          block
        else
          "#{original}#{original.end_with?("\n") ? '' : "\n"}\n#{block}"
        end
      plan.show(original[codex_block_pattern].to_s.sub(/\A\n/, ""), block)
      write_file(plan, path, updated)
      place_link(plan, File.join(codex_home, "skills", "polispec"), File.join(plan.wired_root, "skills", "polispec")) if plan.scope == "user"
      plan.say(TRUST_NOTE)
    end

    def write_receipt(plan)
      receipt, previous = read_receipt(plan)
      previous ||= {}
      FileUtils.mkdir_p(File.dirname(receipt), mode: 0o700)
      record = {
        "schema" => "polispec.install/v1",
        "harness" => plan.harness,
        "scope" => plan.scope,
        "target" => plan.target,
        "wired_root" => plan.wired_root,
        "files_written" => Array(previous["files_written"]) | plan.files_written,
        "links" => plan.links,
        "backups" => Array(previous["backups"]) | plan.backups,
        "installed_at" => Time.now.utc.iso8601
      }
      created = plan.ledger_created || previous["ledger_created"]
      record["ledger_created"] = created if created
      File.write(receipt, "#{JSON.pretty_generate(record)}\n")
      File.chmod(0o600, receipt)
    end

    def read_receipt(plan)
      path = receipt_path(plan.harness, plan.scope, plan.target)
      return [path, nil] unless File.file?(path)

      [path, JSON.parse(File.read(path))]
    rescue JSON::ParserError, SystemCallError
      [path, nil]
    end

    def uninstall(harness, scope: "user", project: Dir.pwd, dry_run: false)
      raise Polispec::Error, "unknown harness #{harness}" unless HARNESSES.include?(harness)
      raise Polispec::Error, "unknown scope #{scope}" unless SCOPES.include?(scope)

      project = File.expand_path(project)
      plan = Plan.new(harness, scope, target_file(harness, scope, project), wired_root, dry_run)
      harness == "claude" ? uninstall_claude(plan, project) : uninstall_codex(plan)
      receipt, record = read_receipt(plan)
      remove_links(plan, expected_links(plan, project), record)
      if File.file?(receipt) && !dry_run
        File.rename(receipt, "#{receipt}.uninstalled-#{stamp}")
        plan.change(receipt, "rename to .uninstalled")
      elsif File.file?(receipt)
        plan.change(receipt, "rename to .uninstalled")
      end
      plan
    end

    def expected_links(plan, project)
      if plan.harness == "claude"
        links = [plan.scope == "user" ? File.join(Stewardship.claude_home, "skills", "polispec") : File.join(project, ".claude", "skills", "polispec")]
        links += RULE_NAMES.map { |name| File.join(Stewardship.claude_home, "rules", "polispec", name) } if plan.scope == "user"
        links
      else
        plan.scope == "user" ? [File.join(codex_home, "skills", "polispec")] : []
      end
    end

    def remove_links(plan, paths, record)
      recorded = record ? Array(record["links"]).each_with_object({}) { |item, map| map[item["path"]] = item["target"] } : {}
      (paths | recorded.keys).each { |path| drop_link(plan, path, recorded[path]) }
    end

    def uninstall_claude(plan, _project)
      path = plan.target
      return unless File.file?(path)

      data = read_json(path)
      hooks = data["hooks"]
      return unless hooks.is_a?(Hash)

      before = JSON.pretty_generate(hooks)
      CLAUDE_EVENTS.each_key do |event|
        next unless hooks[event].is_a?(Array)

        remaining = strip_marked(hooks[event])
        remaining.empty? ? hooks.delete(event) : hooks[event] = remaining
      end
      data.delete("hooks") if hooks.empty?
      plan.show(before, hooks.empty? ? "" : JSON.pretty_generate(hooks))
      write_file(plan, path, "#{JSON.pretty_generate(data)}\n")
    end

    def uninstall_codex(plan)
      path = plan.target
      return unless File.file?(path)

      original = File.read(path)
      return unless original.match?(codex_block_pattern)

      plan.show(original[codex_block_pattern].to_s.sub(/\A\n/, ""), "")
      write_file(plan, path, original.sub(codex_block_pattern, ""))
    end
  end
end
