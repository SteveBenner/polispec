#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../lint"

module Polispec
  class LintCommand
    USAGE = "usage: polispec lint [PATH...] [--host] [--shipped] [--only RULE[,RULE]...] [--strict] [--json]"

    Options = Struct.new(:roots, :files, :host, :shipped, :only, :strict, :json)

    def self.run(args)
      new.run(args)
    end

    def run(args)
      options = parse(args.dup)
      return usage unless options

      roots = options.roots
      roots = [default_root] if roots.empty? && options.files.empty? && !options.host && !options.shipped
      report = Lint.run(roots: roots, files: options.files, host: options.host, shipped: options.shipped, only: options.only)
      strict = options.strict || Engine::Settings.lint_strict?
      ok = report.ok?(strict)
      options.json ? puts(JSON.generate(report.to_h(ok))) : print_text(report)
      ok ? 0 : 1
    rescue Polispec::Error => e
      warn "polispec lint: #{e.message}"
      1
    end

    private

    def usage
      warn USAGE
      2
    end

    def parse(args)
      options = Options.new([], [], false, false, [], false, false)
      until args.empty?
        arg = args.shift
        case arg
        when "--json" then options.json = true
        when "--host" then options.host = true
        when "--shipped" then options.shipped = true
        when "--strict" then options.strict = true
        when "--only"
          value = args.shift
          return nil if value.nil? || value.start_with?("--")

          rules = value.split(",")
          return nil if rules.empty? || !(rules - Lint::RULES).empty?

          options.only.concat(rules)
        when /\A-/ then return nil
        else
          return nil unless File.exist?(arg)

          File.directory?(arg) ? options.roots << File.expand_path(arg) : options.files << File.expand_path(arg)
        end
      end
      options.only = Lint::RULES.dup if options.only.empty?
      options.only.uniq!
      options
    end

    def default_root
      out = Environments.git(Dir.pwd, "rev-parse", "--show-toplevel")
      out ? out.strip : Dir.pwd
    end

    def shown(path)
      text = path.to_s
      return text unless text.start_with?("/")

      cwd = Dir.pwd
      home = Dir.home
      if text == cwd
        "."
      elsif text.start_with?("#{cwd}/")
        text[(cwd.length + 1)..]
      elsif text == home
        "~"
      elsif text.start_with?("#{home}/")
        "~#{text[home.length..]}"
      else
        text
      end
    rescue ArgumentError
      text
    end

    def plural(count, word)
      "#{count} #{word}#{count == 1 ? '' : 's'}"
    end

    def print_text(report)
      report.findings.each do |finding|
        place = finding.line ? "#{shown(finding.path)}:#{finding.line}" : shown(finding.path)
        puts "#{finding.severity.upcase}  #{finding.rule}  #{finding.code}  #{place}  #{finding.message}"
      end
      counts = report.counts
      puts "polispec lint: #{plural(report.targets, 'target')}, #{plural(counts['error'], 'error')}, #{plural(counts['warn'], 'warning')}, #{counts['info']} info"
    end
  end
end

Polispec::CLI.register("lint", Polispec::LintCommand, summary: "sweep generated and shipped files for schema, hygiene, drift, reference and description findings")
