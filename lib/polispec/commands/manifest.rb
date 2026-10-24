#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "../manifest"

module Polispec
  class ManifestCommand
    USAGE = <<~TEXT.chomp.freeze
      usage: polispec manifest <id> [--json] [--write]
             polispec manifest index [--json] [--publish | --unpublish]
             polispec manifest badge <id>
    TEXT

    def self.run(args)
      new.run(args)
    end

    def run(args)
      options = parse(args)
      return usage unless options
      @json = options[:json]
      rest = options[:rest]
      return index(options) if rest == ["index"]
      return badge(rest[1]) if rest.first == "badge" && rest.length == 2
      return usage unless rest.length == 1 && !options[:publish] && !options[:unpublish]

      options[:write] ? write(rest.first) : show(rest.first)
    rescue Operator::Failure => e
      e.report(json: @json)
      1
    rescue Polispec::Error => e
      Operator::Failure.new("error", e.message).report(json: @json)
      1
    end

    private

    def parse(args)
      options = { rest: [], json: false, write: false, publish: false, unpublish: false }
      args.each do |arg|
        case arg
        when "--json" then options[:json] = true
        when "--write" then options[:write] = true
        when "--publish" then options[:publish] = true
        when "--unpublish" then options[:unpublish] = true
        else
          return nil if arg.start_with?("-")

          options[:rest] << arg
        end
      end
      return nil if options[:publish] && options[:unpublish]
      return nil if options[:write] && options[:rest] == ["index"]

      options
    end

    def show(id)
      manifest = Trace.step("compose manifest", project: id) { Manifest.validate!("manifest", Manifest.for(id)) }
      if @json
        puts JSON.generate(manifest)
      else
        puts JSON.pretty_generate(manifest)
      end
      0
    end

    def write(id)
      result = Trace.step("write manifest", project: id) { Manifest.write(id) }
      @json ? puts(JSON.generate({ "ok" => true }.merge(result))) : puts("polispec manifest: #{result['detail']}")
      0
    end

    def index(options)
      return publish if options[:publish]
      return unpublish if options[:unpublish]

      document = Trace.step("compose index") { Manifest.validate!("index", Manifest.index) }
      @json ? puts(JSON.generate(document)) : puts(JSON.pretty_generate(document))
      0
    end

    def publish
      result = Trace.step("publish index") { Manifest.publish }
      @json ? puts(JSON.generate({ "ok" => true }.merge(result))) : puts("polispec manifest: published #{result['entries']} entries to #{result['published']}")
      0
    end

    def unpublish
      result = Trace.step("unpublish index") { Manifest.unpublish }
      @json ? puts(JSON.generate({ "ok" => true }.merge(result))) : puts("polispec manifest: removed #{result['unpublished']}")
      0
    end

    def badge(id)
      print Trace.step("render badge", project: id) { Manifest.badge_svg(Manifest.for(id)) }
      0
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("manifest", Polispec::ManifestCommand, summary: "generate a project or path manifest, commit it with --write, and publish the host index")
