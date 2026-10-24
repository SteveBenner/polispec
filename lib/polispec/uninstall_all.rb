#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "digest"
require "fileutils"
require "securerandom"
require "stringio"
require "time"
require "open3"
require_relative "deployments"
require_relative "native_install"
require_relative "native_pin"
require_relative "native_settings"
require_relative "stewardship"
require_relative "changes"
require_relative "operator/tty"
require_relative "harness_controls/lifecycle"

module Polispec
  module UninstallAll
    SCHEMA = "polispec.backup/v1"
    ORDER = %w[controls hooks git_hooks rplugin pin plugin ledger settings state].freeze
    CLASS_NAMES = %w[wiring pins rplugin data].freeze
    ID_PATTERN = /\Abkp_[0-9a-f]{12}\z/.freeze
    PHRASE = "uninstall polispec"
    RESTORE_PHRASE = "restore polispec"
    REWIRE_ORDER = %w[pin rplugin hooks git_hooks controls].freeze
    PRELOAD = %w[Changes Effect Chain GitHook Layers Events Exceptions Ledger Delegate Runtime].freeze

    module_function

    def preload
      PRELOAD.each do |name|
        Polispec.const_get(name)
      rescue NameError
        nil
      end
      Operator::Tty
      HarnessControls::Lifecycle
      GitHook::Installer
    end

    def backups_dir
      File.join(NativePin.data_home, "backups")
    end

    def new_id
      "bkp_#{SecureRandom.hex(6)}"
    end

    def stamp
      Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    end

    def restore_command(id)
      "#{File.join(Runtime.root, 'bin', 'polispec')} restore #{id}"
    end

    def sha_of(path)
      if File.symlink?(path)
        "symlink:#{File.readlink(path)}"
      elsif File.file?(path)
        Digest::SHA256.file(path).hexdigest
      else
        "absent"
      end
    end

    def present?(path)
      File.symlink?(path) || File.exist?(path)
    end

    def write_json(path, data)
      temporary = "#{path}.#{Process.pid}.tmp"
      File.write(temporary, "#{JSON.pretty_generate(data)}\n")
      File.chmod(0o600, temporary)
      File.rename(temporary, path)
    end

    def candidates(persist)
      if persist
        Deployments.scan!
        Deployments.entries
      else
        Deployments.entries + Deployments.scan!(persist: false)
      end
    end

    def select_entries(list, keep)
      list.select { |entry| entry["status"] == "active" && !keep.include?(entry["class"]) }
          .sort_by { |entry| [ORDER.index(entry["kind"]) || ORDER.length, entry["target"].to_s] }
    end

    def git_config_path(checkout)
      out, status = Trace.capture2({ "GIT_DIR" => nil, "GIT_WORK_TREE" => nil }, "git", "-C", checkout, "rev-parse", "--git-path", "config", err: File::NULL, trace: :quiet)
      status.success? ? File.expand_path(out.strip, checkout) : nil
    rescue SystemCallError
      nil
    end

    def files_for(entry)
      details = entry["details"] || {}
      case entry["kind"]
      when "hooks" then hooks_files(entry, details)
      when "controls" then Array(details["artifacts"])
      when "git_hooks" then [git_config_path(details["checkout"].to_s)].compact
      when "rplugin" then [entry["target"]]
      when "pin"
        bin = details["bin_link"].to_s
        [entry["target"]] + (!bin.empty? && File.symlink?(bin) && File.readlink(bin).start_with?("#{NativePin.data_home}/") ? [bin] : [])
      else []
      end
    end

    def hooks_files(entry, details)
      plan = NativeInstall.uninstall(details["harness"], scope: details["scope"], project: details["project"] || Dir.pwd, dry_run: true)
      ([entry["target"]] + plan.changes.map { |change| change["file"] }).uniq
    rescue StandardError
      [entry["target"]]
    end

    def describe(entry)
      details = entry["details"] || {}
      case entry["kind"]
      when "controls" then "controls: uninstall installation #{entry['target']}"
      when "hooks" then "hooks: remove polispec hooks, links and receipt for #{details['harness']} (#{details['scope']}) at #{entry['target']}"
      when "git_hooks" then "git_hooks: unset core.hooksPath in #{details['checkout']}"
      when "rplugin" then "rplugin: rplugin uninstall polispec (#{entry['target']})"
      when "pin" then "pin: remove the current link #{entry['target']} and a bin link into the data home; release directories stay"
      when "plugin" then "plugin: #{plugin_command(entry)}"
      else
        reason = kept_reason(entry["target"].to_s)
        reason ? "#{entry['kind']}: keep #{entry['target']} (#{reason})" : "#{entry['kind']}: move #{entry['target']} into the backup"
      end
    end

    def plugin_command(entry)
      details = entry["details"] || {}
      if details["harness"] == "claude"
        "run: claude plugin uninstall #{details['key']}"
      else
        "run: codex plugin remove polispec@polispec"
      end
    end

    def build_plan(keep, persist)
      list = Trace.step("scan deployments", persist: persist, keep: keep) do
        found = candidates(persist)
        Trace.info("deployments found", count: found.length)
        found
      end
      select_entries(list, keep).map do |entry|
        live = Deployments.status_of(entry)
        Trace.info("deployment", kind: entry["kind"], target: Trace.path(entry["target"].to_s), live: live)
        { "entry" => entry, "live" => live, "files" => live == "gone" && entry["kind"] != "hooks" ? [] : files_for(entry), "describe" => describe(entry) }
      end
    end

    def parse_keep(value)
      items = value.to_s.split(",").map(&:strip).reject(&:empty?)
      unknown = items - CLASS_NAMES
      raise Polispec::Error, "--keep takes #{CLASS_NAMES.join(', ')}; unknown #{unknown.join(', ')}" unless unknown.empty?

      items
    end

    def run(keep:, dry_run:, json:)
      preload
      keep = parse_keep(keep.is_a?(Array) ? keep.join(",") : keep)
      id = new_id
      dir = File.join(backups_dir, id)
      preview = build_plan(keep, false)
      return dry(preview, id, dir, keep, json) if dry_run

      begin
        Operator::Tty.confirm!(PHRASE, prompt: confirm_prompt(preview, dir))
      rescue Operator::Tty::NotTty => e
        return refuse("not_tty", e.message, json)
      rescue Operator::Tty::PhraseMismatch => e
        return refuse("phrase_mismatch", e.message, json)
      end
      execute(id, dir, keep, json)
    rescue Polispec::Error => e
      refuse("error", e.message, json)
    end

    def refuse(code, message, json)
      if json
        puts JSON.generate({ "ok" => false, "error" => code, "message" => message })
      else
        warn "polispec: #{code}: #{message}"
      end
      1
    end

    def confirm_prompt(preview, dir)
      "Remove every polispec deployment listed below, after a backup to #{dir}.\n#{preview.map { |item| "  #{item['describe']}" }.join("\n")}"
    end

    def dry(preview, id, dir, keep, json)
      files = preview.flat_map { |item| item["files"] }.uniq
      command = restore_command(id)
      if json
        steps = preview.map { |item| { "kind" => item["entry"]["kind"], "target" => item["entry"]["target"], "live_status" => item["live"], "action" => item["describe"] } }
        puts JSON.generate({ "ok" => true, "dry_run" => true, "backup_id" => id, "backup_dir" => dir, "keep" => keep, "files" => files, "steps" => steps, "restore_command" => command })
      else
        puts "dry run: uninstall --all would write the backup #{id} at #{dir}"
        puts "keep: #{keep.empty? ? 'nothing' : keep.join(', ')}"
        puts "files it would copy into the backup:"
        files.each { |file| puts "  #{file}" }
        puts "  (none)" if files.empty?
        puts "steps in order:"
        preview.each_with_index { |item, index| puts "  #{index + 1}. #{item['describe']}#{item['live'] == 'gone' ? '  [gone]' : ''}" }
        puts "  (nothing deployed)" if preview.empty?
        puts "restore with: #{command}"
      end
      0
    end

    def execute(id, dir, keep, json)
      plan = build_plan(keep, true)
      FileUtils.mkdir_p(backups_dir, mode: 0o700)
      FileUtils.mkdir_p(dir, mode: 0o700)
      Trace.info("backup directory", id: id, dir: Trace.path(dir))
      backup = {
        "schema" => SCHEMA, "id" => id, "created_at" => Time.now.utc.iso8601, "polispec_version" => Polispec.version,
        "runtime_root" => Runtime.root, "keep" => keep, "entries" => plan.map { |item| item["entry"] },
        "files" => [], "data" => [], "steps" => [], "restore_command" => restore_command(id), "restored_at" => nil
      }
      manifest = Deployments.path
      FileUtils.cp(manifest, File.join(dir, "deployments.json"), preserve: true) if File.file?(manifest)
      Trace.step("backup files", id: id) do
        plan.each do |item|
          item["files"].each { |file| copy_in(backup, dir, item["entry"], file) }
        end
        write_json(File.join(dir, "backup.json"), backup)
        Trace.info("backup manifest written", path: Trace.path(File.join(dir, "backup.json")), files: backup["files"].length)
      end
      before = Changes.epoch
      Changes.record(kind: "uninstall", subject: { "backup_id" => id, "keep" => keep }, epoch_before: before)
      statuses = {}
      plan.reject { |item| item["entry"]["class"] == "data" }.each do |item|
        statuses[item["entry"]["id"]] = run_step(item, backup)
        refresh_after(backup, item["entry"]["id"])
      end
      write_json(File.join(dir, "backup.json"), backup)
      Trace.step("move data") { move_data(plan, backup, dir, statuses) }
      write_json(File.join(dir, "backup.json"), backup)
      report(backup, dir, json)
    end

    def copy_in(backup, dir, entry, file)
      return unless present?(file)
      return if backup["files"].any? { |record| record["original"] == file }

      Trace.info("backup copy", file: Trace.path(file), size: (File.lstat(file).size rescue nil), sha256: sha_of(file)) if Trace.on?

      stored = File.join("files", file.sub(%r{\A/}, ""))
      target = File.join(dir, stored)
      FileUtils.mkdir_p(File.dirname(target))
      stat = File.lstat(file)
      record = { "entry" => entry["id"], "original" => file, "stored" => stored, "mode" => stat.mode & 0o7777, "sha256_before" => sha_of(file), "sha256_after" => nil }
      if stat.symlink?
        record["kind"] = "symlink"
        record["link_target"] = File.readlink(file)
        File.symlink(record["link_target"], target)
      elsif stat.file?
        record["kind"] = "file"
        FileUtils.cp(file, target, preserve: true)
      else
        return
      end
      backup["files"] << record
    end

    def refresh_after(backup, entry_id)
      backup["files"].each do |record|
        record["sha256_after"] = sha_of(record["original"]) if record["entry"] == entry_id
      end
    end

    def run_step(item, backup)
      entry = item["entry"]
      status, detail = Trace.step("surface #{entry['kind']}", target: Trace.path(entry["target"].to_s), live: item["live"]) do
        result = perform(entry, item["live"])
        Trace.info("surface result", status: result[0], detail: result[1])
        result
      end
      backup["steps"] << { "entry" => entry["id"], "kind" => entry["kind"], "target" => entry["target"], "status" => status, "detail" => detail }
      status
    rescue StandardError, ScriptError => e
      backup["steps"] << { "entry" => entry["id"], "kind" => entry["kind"], "target" => entry["target"], "status" => "failed", "detail" => "#{e.class}: #{e.message}" }
      "failed"
    end

    def perform(entry, live)
      details = entry["details"] || {}
      case entry["kind"]
      when "controls" then step_controls(entry, live)
      when "hooks" then step_hooks(entry, details, live)
      when "git_hooks" then step_git_hooks(entry, details, live)
      when "rplugin" then step_rplugin(entry, live)
      when "pin" then step_pin(entry, details, live)
      when "plugin" then ["reported", plugin_command(entry)]
      else ["ok", "handled with the data moves"]
      end
    end

    def step_controls(entry, live)
      return ["gone", "installation #{entry['target']} is no longer active"] if live == "gone"

      HarnessControls::Lifecycle.uninstall(entry["target"])
      ["ok", "uninstalled #{entry['target']}"]
    rescue HarnessControls::Lifecycle::Failure => e
      if e.code == "operator_required" || e.exit_status == 3
        ["skipped", "operator_required: #{e.message}"]
      else
        ["failed", "#{e.code}: #{e.message}"]
      end
    end

    def step_hooks(entry, details, live)
      plan = NativeInstall.uninstall(details["harness"], scope: details["scope"], project: details["project"] || Dir.pwd)
      status = live == "gone" ? "gone" : "ok"
      [status, plan.changes.map { |change| "#{change['action']} #{change['file']}" }.join("; ")]
    end

    def step_git_hooks(entry, details, live)
      return ["gone", "checkout #{details['checkout']} is gone"] if live == "gone"

      out = StringIO.new
      GitHook::Installer.new(details["project"], details["env"], out: out).uninstall
      ["ok", out.string.strip]
    end

    def step_rplugin(entry, live)
      return ["gone", "#{entry['target']} is gone"] if live == "gone"

      result = Stewardship.rplugin("uninstall", Stewardship::PLUGIN_ID)
      result[:ok] ? ["ok", "rplugin uninstall polispec"] : ["failed", "rplugin uninstall polispec: #{result[:tail]}"]
    end

    def step_pin(entry, details, live)
      return ["gone", "#{entry['target']} is gone"] if live == "gone"

      removed = []
      current = entry["target"]
      if File.symlink?(current)
        File.delete(current)
        removed << current
      end
      bin = details["bin_link"].to_s
      if !bin.empty? && File.symlink?(bin) && File.readlink(bin).start_with?("#{NativePin.data_home}/")
        File.delete(bin)
        removed << bin
      end
      ["ok", "removed #{removed.join(', ')}; releases kept"]
    end

    def move_data(plan, backup, dir, statuses)
      data = plan.select { |item| item["entry"]["class"] == "data" }
      state_item = data.find { |item| item["entry"]["kind"] == "state" }
      others = data - [state_item].compact
      others.each { |item| statuses[item["entry"]["id"]] = move_one(item["entry"], backup, dir) }
      removable = statuses.select { |_id, status| %w[ok gone].include?(status) }.keys
      removable += [state_item["entry"]["id"]] if state_item
      begin
        Deployments.mark_removed_all(removable, backup["id"])
      rescue StandardError => e
        warn "polispec: deployments manifest not updated: #{e.message}"
      end
      statuses[state_item["entry"]["id"]] = move_one(state_item["entry"], backup, dir) if state_item
    end

    def shelf_dir
      source = Layers.source
      return nil unless source

      File.expand_path(source.kind == :dir ? source.root : File.join(source.repo, source.path.to_s))
    rescue StandardError
      nil
    end

    def kept_reason(path)
      expanded = File.expand_path(path)
      shelf = shelf_dir
      return "it lies in the global shelf #{shelf}" if shelf && (expanded == shelf || expanded.start_with?("#{shelf}/"))

      dir = File.directory?(expanded) ? expanded : File.dirname(expanded)
      out, status = Trace.capture2({ "GIT_DIR" => nil, "GIT_WORK_TREE" => nil }, "git", "-C", dir, "rev-parse", "--show-toplevel", err: File::NULL, trace: :quiet)
      status.success? ? "it lies in the git working tree #{out.strip}" : nil
    rescue SystemCallError
      nil
    end

    def move_one(entry, backup, dir)
      source = entry["target"]
      unless present?(source)
        backup["steps"] << { "entry" => entry["id"], "kind" => entry["kind"], "target" => source, "status" => "gone", "detail" => "nothing to move" }
        Trace.info("data gone", kind: entry["kind"], path: Trace.path(source))
        return "gone"
      end
      reason = kept_reason(source)
      if reason
        Trace.info("data kept", kind: entry["kind"], path: Trace.path(source), reason: reason)
        backup["steps"] << { "entry" => entry["id"], "kind" => entry["kind"], "target" => source, "status" => "kept", "detail" => "not moved: #{reason}" }
        return "kept"
      end
      stored = File.join("data", source.sub(%r{\A/}, ""))
      destination = File.join(dir, stored)
      FileUtils.mkdir_p(File.dirname(destination))
      method = relocate(source, destination)
      Trace.info("data moved", kind: entry["kind"], path: Trace.path(source), method: method)
      backup["data"] << { "entry" => entry["id"], "original" => source, "stored" => stored, "kind" => File.directory?(destination) ? "dir" : "file", "method" => method }
      backup["steps"] << { "entry" => entry["id"], "kind" => entry["kind"], "target" => source, "status" => "ok", "detail" => "moved into #{stored} (#{method})" }
      "ok"
    rescue StandardError, ScriptError => e
      backup["steps"] << { "entry" => entry["id"], "kind" => entry["kind"], "target" => source, "status" => "failed", "detail" => "#{e.class}: #{e.message}" }
      "failed"
    end

    def relocate(source, destination)
      File.rename(source, destination)
      "rename"
    rescue Errno::EXDEV
      FileUtils.cp_r(source, destination, preserve: true)
      File.rename(source, "#{source}.moved-#{stamp}")
      "copy_aside"
    end

    def report(backup, dir, json)
      failed = backup["steps"].reject { |step| %w[ok gone reported kept].include?(step["status"]) }
      ok = failed.empty?
      if json
        puts JSON.generate({ "ok" => ok, "backup_id" => backup["id"], "backup_dir" => dir, "keep" => backup["keep"], "steps" => backup["steps"], "restore_command" => backup["restore_command"] })
      else
        puts "uninstall --all: backup #{backup['id']} at #{dir}"
        backup["steps"].each { |step| puts "  #{step['status'].ljust(8)} #{step['kind'].ljust(10)} #{step['target']}  #{step['detail']}" }
        puts "restore with: #{backup['restore_command']}"
      end
      ok ? 0 : 1
    end

    module Restore
      module_function

      def load_backup(id)
        raise Polispec::Error, "#{id.inspect} is not a backup id (bkp_ and 12 hex digits)" unless ID_PATTERN.match?(id.to_s)

        dir = File.join(UninstallAll.backups_dir, id)
        file = File.join(dir, "backup.json")
        raise Polispec::Error, "no backup #{id} at #{dir}" unless File.file?(file)

        data = JSON.parse(File.read(file))
        raise Polispec::Error, "#{file} is not a #{SCHEMA} document" unless data.is_a?(Hash) && data["schema"] == SCHEMA

        [data, dir]
      rescue JSON::ParserError => e
        raise Polispec::Error, "#{file} is not valid JSON: #{e.message.lines.first.to_s.strip}"
      end

      def list(json:)
        base = UninstallAll.backups_dir
        rows = Dir.glob(File.join(base, "bkp_*", "backup.json")).sort.filter_map do |file|
          data = JSON.parse(File.read(file))
          { "id" => data["id"], "created_at" => data["created_at"], "restored_at" => data["restored_at"], "keep" => data["keep"], "entries" => Array(data["entries"]).length, "restore_command" => data["restore_command"] }
        rescue JSON::ParserError, SystemCallError
          nil
        end
        if json
          puts JSON.generate({ "backups" => rows })
        elsif rows.empty?
          puts "no backups under #{base}"
        else
          rows.each { |row| puts "#{row['id']}  #{row['created_at']}  entries #{row['entries']}  #{row['restored_at'] ? "restored #{row['restored_at']}" : 'not restored'}" }
        end
        0
      end

      def plan_lines(backup, mode)
        lines = backup["data"].map { |item| "data (bytes): copy #{item['stored']} back to #{item['original']} when that path is absent" }
        if mode == "rewire"
          steps = backup["steps"].select { |step| step["status"] == "ok" }.map { |step| step["entry"] }
          chosen = backup["entries"].select { |entry| steps.include?(entry["id"]) && REWIRE_ORDER.include?(entry["kind"]) }
          chosen = chosen.sort_by { |entry| REWIRE_ORDER.index(entry["kind"]) }
          lines += chosen.map { |entry| "rewire #{entry['kind']}: #{entry['target']}" }
        else
          lines += backup["files"].map { |record| "bytes: copy #{record['stored']} back to #{record['original']} unless edited since" }
        end
        lines
      end

      def run(id:, mode:, dry_run:, json:)
        UninstallAll.preload
        raise Polispec::Error, "--mode takes rewire or bytes" unless %w[rewire bytes].include?(mode)

        backup, dir = Trace.step("load backup", id: id, mode: mode) { load_backup(id) }
        lines = plan_lines(backup, mode)
        if dry_run
          if json
            puts JSON.generate({ "ok" => true, "dry_run" => true, "backup_id" => id, "mode" => mode, "steps" => lines })
          else
            puts "dry run: restore #{id} (#{mode}) would"
            lines.each { |line| puts "  #{line}" }
            puts "  (nothing to restore)" if lines.empty?
          end
          return 0
        end
        begin
          Operator::Tty.confirm!(RESTORE_PHRASE, prompt: "Restore backup #{id} (#{mode}):\n#{lines.map { |line| "  #{line}" }.join("\n")}")
        rescue Operator::Tty::NotTty => e
          return UninstallAll.refuse("not_tty", e.message, json)
        rescue Operator::Tty::PhraseMismatch => e
          return UninstallAll.refuse("phrase_mismatch", e.message, json)
        end
        execute(backup, dir, mode, json)
      rescue Polispec::Error => e
        UninstallAll.refuse("error", e.message, json)
      end

      def execute(backup, dir, mode, json)
        results = []
        Trace.step("restore data") { restore_data(backup, dir, results) }
        restored = Trace.step("restore #{mode}") { mode == "rewire" ? rewire(backup, results) : restore_bytes(backup, dir, results) }
        Trace.step("sync deployments") { sync_manifest(backup, restored) }
        Changes.record(kind: "restore", subject: { "backup_id" => backup["id"], "mode" => mode }, epoch_before: Changes.epoch)
        backup["restored_at"] = Time.now.utc.iso8601
        backup["restore_results"] = results
        UninstallAll.write_json(File.join(dir, "backup.json"), backup)
        report(backup, mode, results, json)
      end

      def restore_data(backup, dir, results)
        backup["data"].each do |item|
          source = File.join(dir, item["stored"])
          target = item["original"]
          if UninstallAll.present?(target)
            results << { "item" => target, "kind" => "data", "status" => "data_conflict", "detail" => "#{target} exists; left as it is" }
            Trace.info("data conflict", path: Trace.path(target))
          elsif !UninstallAll.present?(source)
            results << { "item" => target, "kind" => "data", "status" => "failed", "detail" => "#{source} is missing from the backup" }
          else
            FileUtils.mkdir_p(File.dirname(target))
            FileUtils.cp_r(source, target, preserve: true)
            results << { "item" => target, "kind" => "data", "status" => "ok", "detail" => "copied back" }
            Trace.info("data restored", path: Trace.path(target))
          end
        rescue StandardError => e
          results << { "item" => target, "kind" => "data", "status" => "failed", "detail" => "#{e.class}: #{e.message}" }
        end
      end

      def restore_bytes(backup, dir, results)
        edited = []
        backup["files"].each do |record|
          target = record["original"]
          current = UninstallAll.sha_of(target)
          unless current == "absent" || current == record["sha256_after"]
            edited << record["entry"]
            results << { "item" => target, "kind" => record["kind"], "status" => "edited_since", "detail" => "#{target} changed after the uninstall; left as it is" }
            Trace.info("conflict, edited since the uninstall", path: Trace.path(target))
            next
          end
          source = File.join(dir, record["stored"])
          FileUtils.mkdir_p(File.dirname(target))
          if record["kind"] == "symlink"
            File.delete(target) if File.symlink?(target)
            File.symlink(record["link_target"], target)
          else
            FileUtils.cp(source, target, preserve: true)
          end
          results << { "item" => target, "kind" => record["kind"], "status" => "ok", "detail" => "copied back" }
          Trace.info("file restored", path: Trace.path(target), kind: record["kind"])
        rescue StandardError => e
          edited << record["entry"]
          results << { "item" => target, "kind" => record["kind"], "status" => "failed", "detail" => "#{e.class}: #{e.message}" }
        end
        ok_steps = backup["steps"].select { |step| step["status"] == "ok" }.map { |step| step["entry"] }
        backup["entries"].select { |entry| ok_steps.include?(entry["id"]) && entry["class"] != "data" && !edited.include?(entry["id"]) }
      end

      def rewire(backup, results)
        ok_steps = backup["steps"].select { |step| step["status"] == "ok" }.map { |step| step["entry"] }
        chosen = backup["entries"].select { |entry| ok_steps.include?(entry["id"]) && REWIRE_ORDER.include?(entry["kind"]) }
        chosen = chosen.sort_by { |entry| REWIRE_ORDER.index(entry["kind"]) }
        restored = []
        chosen.each do |entry|
          status, detail = Trace.step("rewire #{entry['kind']}", target: Trace.path(entry["target"].to_s)) do
            outcome = rewire_one(entry)
            Trace.info("rewire result", status: outcome[0], detail: outcome[1])
            outcome
          end
          results << { "item" => entry["target"], "kind" => entry["kind"], "status" => status, "detail" => detail }
          restored << entry if status == "ok"
        rescue StandardError, ScriptError => e
          results << { "item" => entry["target"], "kind" => entry["kind"], "status" => "failed", "detail" => "#{e.class}: #{e.message}" }
        end
        restored
      end

      def rewire_one(entry)
        details = entry["details"] || {}
        case entry["kind"]
        when "pin" then rewire_pin(details)
        when "rplugin" then rewire_rplugin(details)
        when "hooks"
          NativeInstall.install(details["harness"], scope: details["scope"], project: details["project"] || Dir.pwd)
          ["ok", "installed #{details['harness']} hooks at #{entry['target']}"]
        when "git_hooks"
          GitHook::Installer.new(details["project"], details["env"], out: StringIO.new).install
          ["ok", "installed git hooks for #{details['project']} #{details['env']}"]
        else
          ["manual", "reinstall #{entry['target']} with: polispec harness install <the control document you installed it from> --harness #{details['harness']} --scope #{details['scope']}#{details['project'] ? " --project #{details['project']}" : ''}"]
        end
      end

      def rewire_pin(details)
        release = details["release"].to_s
        commit = details["commit"].to_s
        if !release.empty? && File.directory?(release) && NativePin.release_valid?(release)
          NativePin.swap_current(commit)
          NativePin.link_bin!([], [], false) unless details["bin_link"].to_s.empty?
          ["ok", "pointed current at releases/#{commit}"]
        else
          NativePin.pin!(ref: details["ref"], source: details["source"])
          ["ok", "pinned #{details['ref']} again"]
        end
      end

      def rewire_rplugin(details)
        source = details["source"].to_s
        ref = details["ref"].to_s
        return ["failed", "the backup records no rplugin source"] if source.empty?

        args = ["install", source]
        args += ["--ref", ref] unless ref.empty?
        result = Stewardship.rplugin(*args)
        result[:ok] ? ["ok", "rplugin #{args.join(' ')}"] : ["failed", "rplugin #{args.join(' ')}: #{result[:tail]}"]
      end

      def sync_manifest(backup, restored)
        restored.each do |entry|
          Deployments.record(kind: entry["kind"], target: entry["target"], klass: entry["class"], details: entry["details"] || {}, source: "restore")
        end
        data_ids = backup["data"].map { |item| item["entry"] }
        backup["entries"].select { |entry| data_ids.include?(entry["id"]) }.each do |entry|
          Deployments.record(kind: entry["kind"], target: entry["target"], klass: entry["class"], details: entry["details"] || {}, source: "restore")
        end
      end

      def report(backup, mode, results, json)
        failed = results.reject { |row| %w[ok manual].include?(row["status"]) }
        ok = failed.empty?
        if json
          puts JSON.generate({ "ok" => ok, "backup_id" => backup["id"], "mode" => mode, "results" => results })
        else
          puts "restore #{backup['id']} (#{mode})"
          results.each { |row| puts "  #{row['status'].ljust(13)} #{row['kind'].ljust(10)} #{row['item']}  #{row['detail']}" }
        end
        ok ? 0 : 1
      end
    end
  end
end
