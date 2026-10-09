#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Freeze
    CACHE_TTL = 300
    COMMAND_TIMEOUT = 5
    COMMAND_SOURCES = %w[command teach.calendar teach.activity].freeze
    ALIAS_COMMANDS = {
      "teach.calendar" => %w[bin/teach calendar freezes --json].freeze,
      "teach.activity" => %w[bin/teach activity --json].freeze
    }.freeze
    Window = Struct.new(:id, :kind, :from, :until_at, :source, :course, :detail, keyword_init: true) do
      def to_h
        { "id" => id, "kind" => kind, "from" => from&.utc&.iso8601, "until" => until_at&.utc&.iso8601, "source" => source, "course" => course, "detail" => detail }.compact
      end

      def label
        parts = [id, kind, course, detail].compact.map(&:to_s).reject(&:empty?)
        "#{parts.join(' ')} until #{until_at ? until_at.utc.iso8601 : 'further notice'}"
      end
    end

    class << self
      def active(policy, scope, now: Time.now, project: nil)
        Array(policy["freezes"]).select { |freeze| Array(freeze["applies_to"]).include?(scope) }.flat_map do |freeze|
          windows_for(freeze, policy, project).select { |window| covers?(window, freeze, now) }
        end
      end

      def clear_cache
        Dir.glob(File.join(State.cache_dir, "freeze-*.json")).each { |file| File.delete(file) }
      end

      private

      def windows_for(freeze, policy, project)
        return manual_windows(freeze, policy) unless freeze["source"]
        return command_windows(freeze, policy, project) if COMMAND_SOURCES.include?(freeze["source"])

        finding(policy, "freeze_source_unknown", "#{freeze['id']}: source #{freeze['source']} is not supported")
        []
      end

      def manual_windows(freeze, policy)
        if freeze["rrule"]
          finding(policy, "freeze_rrule_unsupported", "#{freeze['id']}: rrule is not evaluated in v1")
          return []
        end
        from = parse_time(freeze["from"])
        until_at = parse_time(freeze["until"])
        return [] if from.nil? && until_at.nil?

        [Window.new(id: freeze["id"], kind: "manual", from: from, until_at: until_at, source: "manual")]
      end

      def command_argv(freeze)
        return ALIAS_COMMANDS[freeze["source"]] if ALIAS_COMMANDS.key?(freeze["source"])

        argv = freeze["command"]
        argv.is_a?(Array) && !argv.empty? && argv.all? { |item| item.is_a?(String) && !item.empty? } ? argv : nil
      end

      def command_windows(freeze, policy, project)
        argv = command_argv(freeze)
        if argv.nil?
          finding(policy, "freeze_source_unavailable", "#{freeze['id']}: source command needs a non-empty command list")
          return []
        end
        owner, owner_project = command_owner(freeze, policy, project)
        return [] unless owner

        alias_source = ALIAS_COMMANDS.key?(freeze["source"]) ? freeze["source"] : nil
        entries = calendar(owner, owner_project, argv)
        entries = entries.select { |entry| entry["kind"] == freeze["kind"] } if alias_source == "teach.calendar" || (alias_source.nil? && freeze["kind"])
        entries.map do |entry|
          Window.new(id: freeze["id"], kind: entry["kind"], from: parse_time(entry["from"]), until_at: parse_time(entry["until"]),
                     source: "command", course: alias_source == "teach.activity" ? nil : entry["course"],
                     detail: alias_source == "teach.calendar" ? nil : entry["detail"])
        end
      end

      def command_owner(freeze, policy, project)
        named = freeze["project"]
        return [policy, project] if named.nil? || named == policy["project"]

        entry = Polispec::Ledger.load.project(named)
        unless entry
          finding(policy, "freeze_source_unavailable", "#{freeze['id']}: project #{named} is not in the ledger")
          return nil
        end
        [Polispec::PolicySource.load(entry).first, entry]
      rescue Polispec::Error => e
        finding(policy, "freeze_source_unavailable", "#{freeze['id']}: #{e.message}")
        nil
      end

      def covers?(window, freeze, now)
        lead = lead_seconds(freeze)
        start = window.from ? window.from - lead : nil
        return false if start && now < start
        return false if window.until_at && now > window.until_at

        !start.nil? || !window.until_at.nil?
      end

      def lead_seconds(freeze)
        (freeze["lead_minutes"].to_i * 60) + (freeze["lead_hours"].to_i * 3600)
      end

      def calendar(policy, project, argv)
        checkout = prod_checkout(policy, project)
        key = Digest::SHA256.hexdigest("#{policy['project']}|#{checkout}|#{argv.join("\u0000")}")[0, 12]
        path = File.join(State.cache_dir, "freeze-#{key}.json")
        cached = read_cached(path)
        return cached unless cached.nil?

        windows = fetch_calendar(policy, checkout, argv)
        write_cached(path, windows)
        windows
      end

      def prod_checkout(policy, project)
        spec = (policy["environments"] || {})["prod"] || {}
        value = spec["checkout"].to_s
        return nil if value.empty?
        return project ? File.expand_path(project.repo) : nil if value == "repo"

        File.expand_path(value)
      end

      def fetch_calendar(policy, checkout, argv)
        program = checkout && File.expand_path(argv.first, checkout)
        unless program && File.executable?(program) && File.file?(program)
          finding(policy, "freeze_source_unavailable", "#{argv.first} is not available in #{checkout || 'the prod checkout'}; no freeze windows")
          return []
        end
        parse_calendar(policy, run_calendar([program, *argv.drop(1)], checkout))
      rescue StandardError => e
        finding(policy, "freeze_source_unavailable", "#{e.class}: #{e.message}")
        []
      end

      def run_calendar(argv, checkout)
        out = nil
        Open3.popen3(*argv, chdir: checkout) do |stdin, stdout, stderr, waiter|
          stdin.close
          reader = drain(stdout)
          drain(stderr)
          unless waiter.join(COMMAND_TIMEOUT)
            Process.kill("KILL", waiter.pid)
            raise Polispec::Error, "freeze command timed out"
          end
          raise Polispec::Error, "freeze command exited #{waiter.value.exitstatus}" unless waiter.value.success?

          out = reader.value
        end
        out
      end

      def drain(stream)
        thread = Thread.new do
          begin
            stream.read
          rescue IOError
            ""
          end
        end
        thread.report_on_exception = false
        thread
      end

      def parse_calendar(policy, text)
        data = JSON.parse(text)
        windows = data.is_a?(Hash) ? data["windows"] : nil
        return windows.select { |entry| entry.is_a?(Hash) } if windows.is_a?(Array)

        finding(policy, "freeze_source_unavailable", "freeze command output has no windows array")
        []
      rescue JSON::ParserError => e
        finding(policy, "freeze_source_unavailable", "freeze command output is not JSON: #{e.message[0, 80]}")
        []
      end

      def read_cached(path)
        raw = JSON.parse(File.read(path))
        return nil unless raw["fetched_at"].to_i + CACHE_TTL > Time.now.to_i

        raw["windows"]
      rescue SystemCallError, JSON::ParserError
        nil
      end

      def write_cached(path, windows)
        State.ensure_dirs
        temp = "#{path}.#{Process.pid}.tmp"
        File.write(temp, JSON.generate("fetched_at" => Time.now.to_i, "windows" => windows), perm: 0o600)
        File.rename(temp, path)
      rescue SystemCallError
        nil
      end

      def parse_time(value)
        return nil if value.nil? || value.to_s.empty?

        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      def finding(policy, kind, detail)
        Events.emit("polispec.finding", project: policy["project"], kind: kind, detail: detail, policy_source: "freeze")
      end
    end
  end
end
