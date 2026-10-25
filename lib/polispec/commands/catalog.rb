#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "digest"
require_relative "../catalog"

module Polispec
  class CatalogCommand
    USAGE = "usage: polispec catalog list [--json] | show SPEC [--json] | activate SPEC[/SUBSPEC] [--dry-run] | deactivate SPEC[/SUBSPEC] [--dry-run] | provision SPEC/SUBSPEC --from FILE [--dry-run]"
    SEALED = "the sealed plane is active; ask the operator to change the catalog through it"

    class Refused < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    def self.run(args)
      new.run(args)
    end

    def run(args)
      args = args.dup
      json = args.delete("--json")
      dry = args.delete("--dry-run")
      verb = args.shift
      case verb
      when "list" then args.empty? ? list(json) : usage
      when "show" then args.length == 1 ? show(args.first, json) : usage
      when "activate" then args.length == 1 ? change(:activate, args.first, dry) : usage
      when "deactivate" then args.length == 1 ? change(:deactivate, args.first, dry) : usage
      when "provision" then provision(args, dry)
      else usage
      end
    rescue Refused => e
      warn "polispec: #{e.code}: #{e.message}"
      e.code == "usage" ? 2 : 1
    rescue Operator::Tty::NotTty => e
      warn "polispec: not_tty: #{e.message}"
      1
    rescue Operator::Tty::PhraseMismatch => e
      warn "polispec: confirmation_failed: #{e.message}"
      1
    rescue Polispec::Error => e
      warn "polispec: #{e.message.sub(/\Apolispec: /, '')}"
      1
    end

    private

    def usage
      warn USAGE
      2
    end

    def list(json)
      state = Catalog.state
      rows = Catalog.specs.flat_map do |spec|
        spec.subspecs.map { |sub| row(spec, sub, state) }
      end
      if json
        puts JSON.pretty_generate("invalid" => state["invalid"], "subspecs" => rows)
        return 0
      end
      warn "polispec: catalog_state_invalid: #{state['invalid']}; every gate counts on until it is fixed" if state["invalid"]
      rows.each do |item|
        extras = []
        extras << "gate #{item['gate']}" if item["gate"]
        extras << "provision" if item["provision"]
        puts "#{item['spec']}/#{item['subspec']}  #{item['state']}#{extras.empty? ? '' : "  (#{extras.join(', ')})"}  #{item['summary']}"
      end
      0
    end

    def show(name, json)
      spec = Catalog.spec(name)
      raise Refused.new("usage", "unknown catalog spec #{name}") unless spec

      state = Catalog.state
      subspecs = spec.subspecs.map do |sub|
        row(spec, sub, state).merge("rules" => Array(Catalog.shipped_rules_of(spec.name, sub.id)))
      end
      if json
        puts JSON.pretty_generate("spec" => spec.name, "summary" => spec.summary, "subspecs" => subspecs)
        return 0
      end
      puts "#{spec.name}: #{spec.summary}"
      subspecs.each do |item|
        puts "  #{item['subspec']}  #{item['state']}  #{item['summary']}"
        item["rules"].each { |rule| puts "    #{rule['id']}  #{rule['verdict']}  #{rule['reason']}" }
        puts "    (no rules in the release)" if item["rules"].empty?
      end
      0
    end

    def row(spec, sub, state)
      {
        "spec" => spec.name, "subspec" => sub.id, "summary" => sub.summary,
        "gate" => sub.gate, "provision" => sub.provision, "state" => status(spec, sub, state)
      }
    end

    def status(spec, sub, state)
      return "active" if Catalog.active?(spec.name, sub.id)
      return "inactive" unless sub.provision

      provisioned?(spec.name, sub.id, state) ? "provisioned" : "not_provisioned"
    end

    def provisioned?(spec, sub, state)
      entry = Array(state["provisioned"]).find { |item| item["spec"] == spec && item["subspec"] == sub }
      return false unless entry

      path = File.join(Catalog.state_dir, entry["file"].to_s)
      File.file?(path) && Digest::SHA256.hexdigest(File.read(path)) == entry["sha256"]
    rescue SystemCallError
      false
    end

    def target(argument)
      name, sub = argument.split("/", 2)
      spec = Catalog.spec(name)
      raise Refused.new("usage", "unknown catalog spec #{name}") unless spec
      return [spec, nil] unless sub

      found = spec.subspecs.find { |item| item.id == sub }
      raise Refused.new("usage", "unknown subspec #{argument}") unless found

      [spec, found]
    end

    def sealed?
      require_relative "../harness_controls/plane"
      return false unless defined?(HarnessControls::Plane) && HarnessControls::Plane.respond_to?(:resolve)

      state = HarnessControls::Plane.resolve
      raise Polispec::Error, "sealed authority is broken" if state["status"] == "broken"

      state["status"] == "active"
    end

    def change(action, argument, dry)
      spec, sub = target(argument)
      state = Catalog.state
      skipped = []
      ids = if sub
              if action == :activate && sub.provision && !provisioned?(spec.name, sub.id, state)
                raise Refused.new("not_provisioned", "#{spec.name}/#{sub.id} has no provisioned file; run polispec catalog provision #{spec.name}/#{sub.id} --from FILE first")
              end
              [sub.id]
            else
              spec.subspecs.each_with_object([]) do |item, kept|
                if action == :activate && item.provision && !provisioned?(spec.name, item.id, state)
                  skipped << item.id
                else
                  kept << item.id
                end
              end
            end
      raise Refused.new("not_provisioned", "#{spec.name} has no subspec to activate until #{skipped.join(', ')} is provisioned") if ids.empty?

      puts "#{action} #{spec.name}: #{ids.join(', ')}#{skipped.empty? ? '' : " (skipped, not provisioned: #{skipped.join(', ')})"}"
      if dry
        puts "dry run: nothing written"
        return 0
      end
      raise Refused.new("catalog_sealed", SEALED) if sealed?

      Operator::Tty.confirm!("#{action} catalog #{argument}", prompt: "#{action.to_s.capitalize} catalog spec #{argument} on this host (#{ids.join(', ')}).")
      result = action == :activate ? Catalog.activate!(spec.name, ids, release: Polispec.version) : Catalog.deactivate!(spec.name, ids)
      Events.emit("polispec.catalog", action: action.to_s, spec: spec.name, subspecs: ids, actor: "operator")
      print_state(result)
      0
    end

    def provision(args, dry)
      args = args.dup
      index = args.index("--from")
      return usage unless index

      file = args[index + 1]
      args.slice!(index, 2)
      return usage unless file && args.length == 1 && args.first.include?("/")

      spec, sub = target(args.first)
      raise Refused.new("provision_invalid", "#{spec.name}/#{sub.id} takes no provisioned file") unless sub.provision

      text = begin
        File.read(File.expand_path(file))
      rescue SystemCallError => e
        raise Refused.new("provision_invalid", "cannot read #{file}: #{e.message}")
      end
      errors = Catalog.validate_provision(spec.name, sub.id, text)
      raise Refused.new("provision_invalid", errors.join("; ")) unless errors.empty?

      puts "provision #{spec.name}/#{sub.id} from #{file}"
      if dry
        puts "dry run: nothing written"
        return 0
      end
      raise Refused.new("catalog_sealed", SEALED) if sealed?

      Operator::Tty.confirm!("provision catalog #{args.first}", prompt: "Provision #{args.first} on this host from #{file}.")
      result = Catalog.provision!(spec.name, sub.id, text)
      Events.emit("polispec.catalog", action: "provision", spec: spec.name, subspecs: [sub.id], actor: "operator")
      print_state(result)
      0
    end

    def print_state(state)
      active = Array(state["active"])
      puts active.empty? ? "active: none" : "active: #{active.map { |item| "#{item['spec']}/#{item['subspec']}" }.join(', ')}"
      provisioned = Array(state["provisioned"])
      puts "provisioned: #{provisioned.map { |item| "#{item['spec']}/#{item['subspec']}" }.join(', ')}" unless provisioned.empty?
    end
  end
end

Polispec::CLI.register("catalog", Polispec::CatalogCommand, summary: "list the shipped catalog and activate, deactivate or provision a spec on this host (operator)")
