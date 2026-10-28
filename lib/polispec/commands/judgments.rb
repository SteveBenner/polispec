#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../judgments"
require_relative "../operator/tty"

module Polispec
  class JudgmentsCommand
    USAGE = <<~TEXT.chomp.freeze
      usage: polispec judgments list [--since 24h] [--session ID] [--project ID] [--json]
             polispec judgments show <id> [--json]
             polispec judgments verify [--json]
             polispec judgments acknowledge <id> [--reason TEXT] [--json]
    TEXT
    UNITS = { "m" => 60, "h" => 3600, "d" => 86_400 }.freeze
    VALUE_FLAGS = { "list" => %w[--since --session --project], "show" => [], "verify" => [], "acknowledge" => %w[--reason] }.freeze

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

    def run_list(opts)
      return usage unless opts[:rest].empty?

      since = opts[:values].fetch("--since", "24h")
      seconds = window_seconds(since)
      return usage unless seconds

      cutoff = Time.now - seconds
      session = opts[:values]["--session"]
      project = opts[:values]["--project"]
      entries = Judgments.records.select do |entry|
        stamp = Judgments.stamp_of(entry)
        next false unless stamp && stamp >= cutoff
        next false if session && entry.dig("action", "session_id") != session

        project.nil? || Array(entry["targets"]).any? { |target| target["project"] == project }
      end
      if opts[:json]
        puts JSON.generate(entries)
      else
        puts "polispec judgments, last #{since}: #{entries.length}"
        entries.each { |entry| puts line(entry) }
      end
      0
    end

    def line(entry)
      action = entry["action"] || {}
      outcome = entry["outcome"] || {}
      projects = Array(entry["targets"]).map { |target| [target["project"], target["env"]].compact.join("/") }.uniq
      rule = outcome["rule_id"] ? " #{outcome['rule_id']}" : ""
      where = projects.empty? ? (outcome["governed"] ? "governed" : "ungoverned") : projects.join(",")
      "#{entry['ts']} #{entry['id']} #{outcome['verdict']}#{rule} #{action['harness']}:#{action['tool']} #{where} rendered=#{outcome['rendered']}#{outcome['error'] ? " error=#{outcome['error']}" : ''}"
    end

    def run_show(opts)
      id = opts[:rest].first
      return usage unless id && opts[:rest].length == 1

      entry = Judgments.find(id)
      unless entry
        warn "polispec judgments: unknown judgment #{id}"
        return 1
      end

      puts(opts[:json] ? JSON.generate(entry) : JSON.pretty_generate(entry))
      0
    end

    def run_verify(opts)
      return usage unless opts[:rest].empty?

      result = Judgments.verify
      if opts[:json]
        puts JSON.generate(result)
      else
        skips = result["skips"]
        chain = result["ok"] ? "chain ok" : "#{result['findings'].length} finding#{result['findings'].length == 1 ? '' : 's'}"
        cut = result["interrupted"].length
        chain += "; #{cut} interrupted append#{cut == 1 ? '' : 's'}" if cut.positive?
        puts "judgments: #{result['records']} record#{result['records'] == 1 ? '' : 's'} in #{result['files'].length} file#{result['files'].length == 1 ? '' : 's'}; #{chain}"
        (result["findings"] + result["interrupted"]).each { |item| puts "  #{item['kind']} #{item['id'] || '-'}: #{item['detail']}#{item['acknowledged'] ? " (acknowledged by #{item['acknowledged']['by']} at #{item['acknowledged']['at']})" : ''}" }
        puts "skips: #{skips['total']} across #{skips['by_key'].length} fast-path key#{skips['by_key'].length == 1 ? '' : 's'}#{skips['malformed'].positive? ? " (#{skips['malformed']} malformed)" : ''}"
      end
      result["ok"] ? 0 : 1
    end

    def run_acknowledge(opts)
      id = opts[:rest].first
      return usage unless id && opts[:rest].length == 1

      item = Judgments.verify(schema: false)["findings"].find { |entry| entry["id"] == id }
      unless item
        warn "polispec judgments: no verify finding names #{id}; polispec judgments verify lists them"
        return 1
      end
      if item["acknowledged"]
        warn "polispec judgments: #{id} is already acknowledged by #{item['acknowledged']['by']} at #{item['acknowledged']['at']}"
        return 1
      end

      Operator::Tty.confirm!("acknowledge judgment #{id}", prompt: "Record #{item['kind']} at #{id} as examined (#{item['detail']}). doctor then lists it as judgments_acknowledged (info).")
      entry = Judgments.acknowledge!(id, kind: item["kind"], detail: item["detail"], reason: opts[:values]["--reason"], actor: "operator")
      Events.emit("polispec.judgments", action: "acknowledge", id: id, kind: item["kind"], actor: "operator")
      if opts[:json]
        puts JSON.generate({ "id" => id }.merge(entry))
      else
        puts "polispec judgments: acknowledged #{item['kind']} #{id} at #{entry['at']}"
      end
      0
    rescue Operator::Tty::NotTty => e
      warn "polispec judgments: not_tty: #{e.message}"
      1
    rescue Operator::Tty::PhraseMismatch => e
      warn "polispec judgments: confirmation_failed: #{e.message}"
      1
    end

    def window_seconds(text)
      match = text.to_s.match(/\A(\d+)([mhd])\z/)
      match ? match[1].to_i * UNITS[match[2]] : nil
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("judgments", Polispec::JudgmentsCommand, summary: "list, show and verify the chained judgment records, count fast-path skips, and acknowledge an examined chain break")
