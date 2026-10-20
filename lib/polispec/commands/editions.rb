#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "../editions"

module Polispec
  class EditionsCommand
    USAGE = "usage: polispec editions [--check] [--json]"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      args = args.dup
      json = args.delete("--json")
      check = args.delete("--check")
      return usage unless args.empty?

      check ? run_check(json) : show(json)
    rescue Polispec::Error => e
      warn "polispec: #{e.message.sub(/\Apolispec: /, '')}"
      1
    end

    private

    def usage
      warn USAGE
      2
    end

    def show(json)
      registry = Editions.registry
      if json
        puts JSON.generate(registry)
        return 0
      end
      puts "edition   meaning"
      registry.fetch("editions").each { |name, text| puts "#{name.ljust(9)} #{text}" }
      puts
      rows = Editions.features.map { |row| [row["id"], row["standard"], row["lock"], row["since"], row["code"]] }
      header = %w[feature standard lock since code]
      widths = header.each_index.map { |i| ([header[i]] + rows.map { |row| row[i] }).map(&:length).max }
      puts header.each_index.map { |i| header[i].ljust(widths[i]) }.join("  ").rstrip
      rows.each { |row| puts row.each_index.map { |i| row[i].ljust(widths[i]) }.join("  ").rstrip }
      0
    end

    def run_check(json)
      findings = Editions.check
      if json
        puts JSON.generate("ok" => findings.empty?, "findings" => findings.map(&:to_h))
      elsif findings.empty?
        puts "polispec editions: 0 findings"
      else
        puts "polispec editions: #{findings.length} finding#{'s' unless findings.length == 1}"
        findings.each do |item|
          where = item.line ? "#{item.file}:#{item.line}" : item.file
          puts "  #{item.kind}  #{where}  #{item.detail}"
        end
      end
      findings.empty? ? 0 : 1
    end
  end

  CLI.register("editions", EditionsCommand, summary: "print the edition registry or check it for drift")
end
