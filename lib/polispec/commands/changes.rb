#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../changes"
require_relative "../sessions"

module Polispec
  class ChangesCommand
    USAGE = <<~TEXT.chomp.freeze
      usage: polispec changes list [--since 24h] [--json]
             polispec changes show <id> [--json]
             polispec changes verify [--json]
             polispec changes await <id> [--timeout 600] [--active 1h] [--json]
    TEXT
    UNITS = { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.freeze
    VALUE_FLAGS = { "list" => %w[--since], "show" => [], "verify" => [], "await" => %w[--timeout --active] }.freeze
    POLL = 2.0

    def self.run(args)
      new.run(args)
    end

    def run(args)
      verb, *rest = args
      return usage unless VALUE_FLAGS.key?(verb)

      opts = parse(verb, rest)
      return usage unless opts

      send("run_#{verb}", opts)
    end

    private

    def parse(verb, args)
      allowed = VALUE_FLAGS.fetch(verb)
      opts = { json: false, values: {}, rest: [] }
      queue = args.dup
      until queue.empty?
        arg = queue.shift
        name, inline = arg.start_with?("--") ? arg.split("=", 2) : [arg, nil]
        if name == "--json"
          return nil unless inline.nil?

          opts[:json] = true
        elsif allowed.include?(name)
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

    def seconds(text)
      match = text.to_s.match(/\A(\d+)([smhd]?)\z/)
      match ? match[1].to_i * UNITS.fetch(match[2].empty? ? "s" : match[2]) : nil
    end

    def run_list(opts)
      return usage unless opts[:rest].empty?

      window = seconds(opts[:values].fetch("--since", "24h"))
      return usage unless window

      cutoff = Time.now - window
      entries = Changes.records.select { |entry| (at = Sessions.stamp(entry["ts"])) && at >= cutoff }
      if opts[:json]
        puts JSON.generate(entries)
      else
        puts "polispec changes, last #{opts[:values].fetch('--since', '24h')}: #{entries.length}"
        entries.each { |entry| puts "#{entry['ts']} #{entry['id']} #{entry['kind']} #{subject_text(entry)} #{entry['epoch_before'] || '-'} -> #{entry['epoch_after'] || '-'} [#{Effect.describe(entry['effects'])}] by #{entry['actor']}" }
      end
      0
    end

    def subject_text(entry)
      entry["subject"].is_a?(Hash) ? entry["subject"].map { |key, value| "#{key}=#{value.is_a?(Array) ? value.join(',') : value}" }.join(" ") : ""
    end

    def run_show(opts)
      id = opts[:rest].first
      return usage unless id && opts[:rest].length == 1

      entry = Changes.find(id)
      unless entry
        warn "polispec changes: unknown change #{id}"
        return 1
      end
      puts(opts[:json] ? JSON.generate(entry) : JSON.pretty_generate(entry))
      0
    end

    def run_verify(opts)
      return usage unless opts[:rest].empty?

      result = Changes.chain.verify
      if opts[:json]
        puts JSON.generate(result)
      else
        puts "changes: #{result['records']} record#{result['records'] == 1 ? '' : 's'}; #{result['ok'] ? 'chain ok' : "#{result['findings'].length} finding#{result['findings'].length == 1 ? '' : 's'}"}"
        (result["findings"] + result["interrupted"]).each { |item| puts "  #{item['kind']} #{item['id'] || '-'}: #{item['detail']}" }
      end
      result["ok"] ? 0 : 1
    end

    def run_await(opts)
      id = opts[:rest].first
      return usage unless id && opts[:rest].length == 1

      timeout = seconds(opts[:values].fetch("--timeout", "600"))
      window = seconds(opts[:values].fetch("--active", "1h"))
      return usage unless timeout && window

      change = Changes.find(id)
      unless change
        warn "polispec changes: unknown change #{id}"
        return 2
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      rows = []
      loop do
        rows = statuses(change, window)
        break if rows.all? { |row| row["status"] == "crossed" }

        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if left <= 0

        sleep([POLL * (1 + rand * 0.2), left].min)
      end
      done = rows.all? { |row| row["status"] == "crossed" }
      if opts[:json]
        puts JSON.generate("change" => id, "crossed" => done, "sessions" => rows)
      else
        puts "change #{id} #{change['kind']} (#{change['epoch_after'] || '-'}): #{rows.count { |row| row['status'] == 'crossed' }} of #{rows.length} active session#{rows.length == 1 ? '' : 's'} crossed"
        rows.reject { |row| row["status"] == "crossed" }.each { |row| puts "  #{row['status']} #{row['session_id']} #{row['harness']} last call #{row['last_call'] || 'none'}#{row['detail'] ? " (#{row['detail']})" : ''}" }
      end
      done ? 0 : 1
    end

    def statuses(change, window)
      at = Sessions.stamp(change["ts"])
      classes = Array(change["effects"]).map { |item| item["class"] }
      Sessions.active(window).map do |session|
        row = { "session_id" => session["session_id"], "harness" => session["harness"], "last_call" => session["last_call"], "epoch" => session["epoch"], "status" => "pending" }
        crossed = session["epochs"].any? do |stamp, epoch|
          epoch == change["epoch_after"] || (Sessions.stamp(stamp) && at && Sessions.stamp(stamp) > at && epoch != change["epoch_before"])
        end
        stale = stale_launcher?(session["launcher"])
        if classes.include?("reload") && stale
          row["status"] = "reload"
          row["detail"] = "launcher #{session['launcher']['version']} predates this change; run /reload-plugins or start a new session"
        elsif classes.include?("trust") && session["harness"] == "codex"
          row["status"] = "trust"
          row["detail"] = "a Codex hook definition changed; review it in /hooks and start a new session"
        elsif crossed
          row["status"] = "crossed"
        end
        row
      end
    end

    def stale_launcher?(launcher)
      version = Effect.launcher_version(launcher)
      version && Effect.version_less?(version, Polispec.version)
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("changes", Polispec::ChangesCommand, summary: "list, show, verify and await the chained records of changes to the policy, ledger, settings and runtime")
