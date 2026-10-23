#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "digest"
require "fileutils"
require "time"
require "open3"
require_relative "state"
require_relative "native_pin"
require_relative "stewardship"

module Polispec
  module Deployments
    SCHEMA = "polispec.deployments/v1"
    FILE = "deployments.json"
    LOCK = "deployments.lock"
    KINDS = %w[hooks controls git_hooks pin rplugin plugin ledger settings state].freeze
    CLASSES = {
      "hooks" => "wiring", "controls" => "wiring", "git_hooks" => "wiring", "plugin" => "wiring",
      "pin" => "pins", "rplugin" => "rplugin", "ledger" => "data", "settings" => "data", "state" => "data"
    }.freeze
    STATUSES = %w[present drifted gone removed].freeze

    module_function

    def path
      File.join(State.home, FILE)
    end

    def lock_path
      File.join(State.home, LOCK)
    end

    def entry_id(kind, target)
      "dep_#{Digest::SHA256.hexdigest("#{kind}\0#{target}")[0, 12]}"
    end

    def empty
      { "schema" => SCHEMA, "entries" => [] }
    end

    def load(file = path)
      return empty unless File.file?(file)

      text = File.read(file)
      return empty if text.strip.empty?

      data = JSON.parse(text)
      raise Polispec::Error, "#{file} is not a deployments manifest" unless data.is_a?(Hash) && data["entries"].is_a?(Array)

      data
    rescue JSON::ParserError => e
      raise Polispec::Error, "#{file} is not valid JSON: #{e.message.lines.first.to_s.strip}"
    rescue SystemCallError => e
      raise Polispec::Error, "#{file} cannot be read: #{e.message}"
    end

    def entries(file = path)
      load(file)["entries"]
    end

    def mutate
      dir = State.home
      FileUtils.mkdir_p(dir, mode: 0o700)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        data = load
        result = yield data["entries"]
        write(data)
        result
      end
    end

    def write(data)
      target = path
      temporary = "#{target}.#{Process.pid}.tmp"
      File.write(temporary, "#{JSON.pretty_generate(data)}\n")
      File.chmod(0o600, temporary)
      File.rename(temporary, target)
    end

    def best_effort
      yield
    rescue StandardError, ScriptError => e
      warn "polispec: deployments manifest not updated: #{e.message}"
      nil
    end

    def upsert(list, kind:, target:, klass:, details:, source:)
      now = Time.now.utc.iso8601
      id = entry_id(kind, target)
      entry = list.find { |item| item["id"] == id }
      if entry
        entry["details"] = (entry["details"] || {}).merge(details)
        entry["updated_at"] = now
        entry["status"] = "active"
        entry.delete("removed_at")
        entry.delete("backup_id")
        entry["source"] = source
        return [entry, false]
      end
      entry = {
        "id" => id, "kind" => kind, "target" => target, "class" => klass || CLASSES.fetch(kind), "details" => details,
        "source" => source, "recorded_at" => now, "updated_at" => now, "status" => "active"
      }
      list << entry
      [entry, true]
    end

    def record(kind:, target:, klass: nil, details: {}, source: "install")
      best_effort { mutate { |list| upsert(list, kind: kind, target: target.to_s, klass: klass, details: stringify(details), source: source).first } }
    end

    def retire(kind:, target:, backup_id: nil)
      return nil unless File.file?(path)

      best_effort { mutate { |list| mark_removed(list, entry_id(kind, target.to_s), backup_id) } }
    end

    def mark_removed(list, id, backup_id)
      entry = list.find { |item| item["id"] == id }
      return nil unless entry

      now = Time.now.utc.iso8601
      entry["status"] = "removed"
      entry["removed_at"] = now
      entry["updated_at"] = now
      entry["backup_id"] = backup_id if backup_id
      entry
    end

    def mark_removed_all(ids, backup_id)
      mutate { |list| ids.each { |id| mark_removed(list, id, backup_id) } }
    end

    def mark_active(ids, source: "restore")
      mutate do |list|
        ids.each do |id|
          entry = list.find { |item| item["id"] == id }
          next unless entry

          entry["status"] = "active"
          entry["source"] = source
          entry["updated_at"] = Time.now.utc.iso8601
          entry.delete("removed_at")
          entry.delete("backup_id")
        end
      end
    end

    def stringify(value)
      case value
      when Hash then value.each_with_object({}) { |(key, item), memo| memo[key.to_s] = stringify(item) }
      when Array then value.map { |item| stringify(item) }
      else value
      end
    end

    def status_of(entry)
      return "removed" if entry["status"] == "removed"

      details = entry["details"] || {}
      target = entry["target"].to_s
      case entry["kind"]
      when "hooks" then hooks_status(target, details)
      when "controls" then controls_status(target)
      when "git_hooks" then git_hooks_status(target, details)
      when "pin" then pin_status(target)
      when "rplugin" then File.exist?(target) || File.symlink?(target) ? "present" : "gone"
      when "plugin" then plugin_status(target, details)
      else File.exist?(target) ? "present" : "gone"
      end
    rescue StandardError
      "drifted"
    end

    def hooks_status(target, details)
      return "gone" unless File.file?(target)

      text = File.read(target)
      marked =
        if details["harness"] == "codex"
          text.include?("# >>> polispec hooks >>>")
        else
          text.include?("/bin/polispec-guard")
        end
      marked ? "present" : "drifted"
    end

    def controls_status(target)
      require_relative "harness_controls/lifecycle"
      HarnessControls::Lifecycle.owned_installations.any? { |item| item["installation_id"] == target } ? "present" : "gone"
    end

    def git_hooks_status(target, details)
      checkout = details["checkout"].to_s
      return "gone" if checkout.empty? || !File.directory?(checkout)

      out, status = Open3.capture2({ "GIT_DIR" => nil, "GIT_WORK_TREE" => nil }, "git", "-C", checkout, "config", "--get", "core.hooksPath", err: File::NULL)
      return "drifted" unless status.success?

      File.expand_path(out.strip, checkout) == target ? "present" : "drifted"
    end

    def pin_status(target)
      return "gone" unless File.symlink?(target) || File.exist?(target)

      NativePin.release_valid?(File.realpath(target)) ? "present" : "drifted"
    rescue SystemCallError
      "drifted"
    end

    def plugin_status(target, details)
      if details["harness"] == "claude"
        file = details["settings"].to_s
        return "gone" unless File.file?(file)

        enabled = JSON.parse(File.read(file))["enabledPlugins"]
        enabled.is_a?(Hash) && enabled.key?(details["key"].to_s) ? "present" : "gone"
      else
        File.exist?(target) ? "present" : "gone"
      end
    end

    def with_status(list = entries)
      list.map { |entry| entry.merge("live_status" => status_of(entry)) }
    end

    def hooks_candidates
      Dir.glob(File.join(State.home, "installs", "*.json")).sort.filter_map do |file|
        record = JSON.parse(File.read(file))
        next unless record.is_a?(Hash) && record["target"]

        project = nil
        if record["scope"] == "project"
          project = File.dirname(File.dirname(record["target"]))
        end
        { kind: "hooks", target: record["target"], details: { "harness" => record["harness"], "scope" => record["scope"], "project" => project, "receipt" => file, "wired_root" => record["wired_root"] } }
      rescue JSON::ParserError, SystemCallError
        nil
      end
    end

    def controls_candidates
      require_relative "harness_controls/lifecycle"
      HarnessControls::Lifecycle.owned_installations.map do |item|
        { kind: "controls", target: item["installation_id"], details: { "installation_id" => item["installation_id"], "harness" => item["harness"], "scope" => item["scope"], "artifacts" => item["artifacts"] } }
      end
    rescue HarnessControls::Lifecycle::Failure, Polispec::Error
      []
    end

    def git_hooks_candidates
      base = File.join(State.home, GitHook::SHIM_DIR)
      return [] unless File.directory?(base)

      Dir.glob(File.join(base, "*", "*")).sort.filter_map do |shim|
        next unless File.directory?(shim)

        env = File.basename(shim)
        project = File.basename(File.dirname(shim))
        checkout = begin
          GitHook::Installer.new(project, env, out: File.open(File::NULL, "w"), resolve_policy: false).checkout_path(env)
        rescue StandardError
          nil
        end
        next unless checkout && File.directory?(checkout)

        out, status = Open3.capture2({ "GIT_DIR" => nil, "GIT_WORK_TREE" => nil }, "git", "-C", checkout, "config", "--get", "core.hooksPath", err: File::NULL)
        next unless status.success? && File.expand_path(out.strip, checkout) == shim

        { kind: "git_hooks", target: shim, details: { "project" => project, "env" => env, "checkout" => checkout } }
      end
    end

    def pin_details
      current = NativePin.current_link
      return nil unless File.symlink?(current)

      release = File.realpath(current)
      meta = release_meta(release)
      bin = NativePin.bin_link
      linked = File.symlink?(bin) && File.readlink(bin).start_with?("#{NativePin.data_home}/")
      { "commit" => File.basename(release), "release" => release, "ref" => meta["ref"], "source" => meta["source"], "version" => meta["version"], "bin_link" => linked ? bin : nil }
    rescue SystemCallError
      nil
    end

    def release_meta(dir)
      Runtime::RELEASE_FILES.each do |name|
        file = File.join(dir, name)
        return JSON.parse(File.read(file)) if File.file?(file)
      end
      {}
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def pin_candidates
      details = pin_details
      details ? [{ kind: "pin", target: NativePin.current_link, details: details }] : []
    end

    def rplugin_candidates
      link = Stewardship.store_link
      return [] unless File.symlink?(link) || File.exist?(link)

      real = File.realpath(link)
      meta = release_meta(real)
      [{ kind: "rplugin", target: link, details: { "release" => real, "commit" => meta["commit"], "source" => meta["source"], "ref" => meta["ref"] } }]
    rescue SystemCallError
      [{ kind: "rplugin", target: link, details: {} }]
    end

    def plugin_candidates
      list = []
      settings = File.join(Stewardship.claude_home, "settings.json")
      if File.file?(settings)
        enabled = begin
          JSON.parse(File.read(settings))["enabledPlugins"]
        rescue JSON::ParserError
          nil
        end
        if enabled.is_a?(Hash)
          enabled.keys.select { |key| key.to_s.start_with?("polispec@") }.each do |key|
            list << { kind: "plugin", target: "claude:#{key}", details: { "harness" => "claude", "key" => key, "settings" => settings } }
          end
        end
      end
      base = File.join(codex_home, "plugins")
      %w[*polispec* */*polispec* */*/*polispec*].flat_map { |pattern| Dir.glob(File.join(base, pattern)) }.uniq.sort.each do |dir|
        list << { kind: "plugin", target: dir, details: { "harness" => "codex" } }
      end
      list
    end

    def codex_home
      value = ENV["CODEX_HOME"].to_s
      File.expand_path(value.empty? ? "~/.codex" : value)
    end

    def data_candidates
      require_relative "native_settings"
      [
        { kind: "ledger", target: Ledger.default_path, details: {} },
        { kind: "settings", target: NativeSettings.path, details: {} },
        { kind: "state", target: State.home, details: {} }
      ].select { |item| File.exist?(item[:target]) }
    end

    def candidates
      hooks_candidates + controls_candidates + git_hooks_candidates + pin_candidates + rplugin_candidates + plugin_candidates + data_candidates
    end

    def scan!(persist: true)
      found = candidates
      return scan_in_memory(found) unless persist

      mutate do |list|
        found.filter_map do |item|
          entry, added = upsert_scanned(list, item)
          entry if added
        end
      end
    end

    def refresh_stewardship
      best_effort do
        items = pin_candidates + rplugin_candidates
        next if items.empty?

        mutate { |list| items.each { |item| upsert(list, kind: item[:kind], target: item[:target].to_s, klass: nil, details: stringify(item[:details]), source: "install") } }
      end
    end

    def upsert_scanned(list, item)
      id = entry_id(item[:kind], item[:target].to_s)
      return [nil, false] if list.any? { |entry| entry["id"] == id }

      upsert(list, kind: item[:kind], target: item[:target].to_s, klass: nil, details: stringify(item[:details]), source: "scan")
    end

    def scan_in_memory(found)
      existing = entries.map { |entry| entry["id"] }
      found.filter_map do |item|
        id = entry_id(item[:kind], item[:target].to_s)
        next if existing.include?(id)

        now = Time.now.utc.iso8601
        { "id" => id, "kind" => item[:kind], "target" => item[:target].to_s, "class" => CLASSES.fetch(item[:kind]), "details" => stringify(item[:details]), "source" => "scan", "recorded_at" => now, "updated_at" => now, "status" => "active" }
      end
    end
  end
end
