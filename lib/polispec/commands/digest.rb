#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  class DigestCommand
    USAGE = "usage: polispec digest [--since 24h] [--json]"
    UNITS = { "m" => 60, "h" => 3600, "d" => 86_400 }.freeze

    def self.run(args)
      new.run(args)
    end

    def run(args)
      args = args.dup
      json = args.delete("--json")
      since = option(args, "--since") || "24h"
      seconds = window_seconds(since)
      return usage unless seconds && args.empty?

      ledger = Ledger.load
      cutoff = Time.now - seconds
      report = build(ledger, cutoff)
      json ? puts(JSON.generate("since" => since, "projects" => report)) : print_text(since, report)
      0
    end

    private

    def build(ledger, cutoff)
      report = Hash.new { |hash, key| hash[key] = { "deny" => [], "warn" => [], "pauses" => [], "allow_once" => [] } }
      State.read_jsonl("verdicts").each do |record|
        next unless recent?(record["ts"], cutoff)

        report[record["project"].to_s][record["verdict"]] << record.slice("ts", "env", "action_class", "rule_id", "harness", "enforced", "raw", "verdict") if %w[deny warn].include?(record["verdict"])
      end
      Engine::Logs.read(ledger.pauses_log).each do |record|
        report[record["project"].to_s]["pauses"] << record if recent?(record["started_at"], cutoff)
      end
      Engine::Logs.read(ledger.allow_once_log).each do |record|
        stamp = record["issued_at"] || record["redeemed_at"] || record["consumed_at"]
        report[record["project"].to_s]["allow_once"] << record.slice("event", "id") if recent?(stamp, cutoff)
      end
      report.to_h
    end

    def recent?(stamp, cutoff)
      stamp && Time.parse(stamp.to_s) >= cutoff
    rescue ArgumentError
      false
    end

    def window_seconds(text)
      match = text.to_s.match(/\A(\d+)([mhd])\z/)
      match ? match[1].to_i * UNITS[match[2]] : nil
    end

    def option(args, flag)
      index = args.index(flag)
      return nil unless index

      value = args[index + 1]
      args.slice!(index, 2)
      value
    end

    def print_text(since, report)
      puts "polispec digest, last #{since}"
      return puts("  nothing recorded") if report.empty?

      report.each do |project, data|
        puts "#{project.empty? ? '(unknown)' : project}: deny #{data['deny'].length}, warn #{data['warn'].length}, pauses #{data['pauses'].length}, allow-once events #{data['allow_once'].length}"
        rule_counts(data).each { |rule, count| puts "  #{rule} x#{count}" }
        data["pauses"].each { |pause| puts "  pause #{pause['minutes']}m by #{pause['actor']}: #{pause['reason']}" }
      end
    end

    def rule_counts(data)
      (data["deny"] + data["warn"]).group_by { |record| "#{record['verdict']} #{record['rule_id']}#{record['enforced'] ? '' : ' (advise)'}" }.map { |rule, list| [rule, list.length] }
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("digest", Polispec::DigestCommand, summary: "warns, denies, pauses and allow-once over a time window")
