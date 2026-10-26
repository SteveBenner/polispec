#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "yaml"
require "date"

module Polispec
  module RuleLocator
    RULE_TOKEN = /\b[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+\b/.freeze
    LOOKUP_ERRORS = [Polispec::Error, SystemCallError, KeyError, TypeError, NoMethodError].freeze

    module_function

    def line_of(text, rule_id)
      return nil unless text

      index = text.lines.index { |line| line.match?(/\bid:\s*["']?#{Regexp.escape(rule_id)}["']?\s*[,}\s]/) || line.match?(/\bid:\s*["']?#{Regexp.escape(rule_id)}["']?\z/) }
      index && index + 1
    end

    def module_text(name)
      entry = Catalog.entry_named(name)
      return [entry["text"], entry["label"], "catalog"] if entry

      store = Layers.store
      text = store && store.read("modules/#{name}.yml")
      text ? [text, "modules/#{name}.yml", "shelf"] : nil
    rescue *LOOKUP_ERRORS
      nil
    end

    def doc_of(text)
      data = YAML.safe_load(text.to_s, permitted_classes: [Date, Time], aliases: false)
      data.is_a?(Hash) ? data : {}
    rescue Psych::Exception, ArgumentError
      {}
    end

    def describe(layer_name, rule, text, path, module_name, doc)
      reason = rule["reason"].to_s
      body = doc["description"].to_s.empty? ? doc["summary"].to_s : doc["description"].to_s
      {
        "rule_id" => rule["id"], "layer" => layer_name, "module" => module_name, "verdict" => rule["verdict"].to_s,
        "description" => reason.empty? ? body : reason, "rulebook_description" => body, "source" => { "path" => path, "line" => line_of(text, rule["id"]) },
        "match" => rule["match"], "rule" => rule
      }
    end

    def search_chain(project, ledger, rule_id)
      side = Probes.resolved(project, ledger)
      return nil unless side.chain

      found = search_layers(side.chain, rule_id) { |layer| [policy_text(project), layer.name == "repo" ? project.policy : layer.source.to_s] }
      found&.merge("project" => project.id)
    end

    def search_shelf(ledger, rule_id)
      store = Layers.store
      search_layers(Layers.load(nil, nil, ledger: ledger), rule_id) do |layer|
        entry = layer.name.start_with?("path:") ? ledger.path_entry(layer.name.delete_prefix("path:")) : nil
        if entry then [store&.read(entry.policy), entry.policy]
        elsif layer.name == "global" then [store&.global_text, "global.yml"]
        else [nil, layer.source.to_s]
        end
      end
    end

    def layer_hit(layer, rule, rule_id)
      layer.modules.each do |label|
        name = label.to_s.start_with?("catalog:") ? Catalog.module_name(label) : label.to_s[/\A[a-z0-9-]+/]
        found = name && module_text(name)
        next unless found && found[0].include?(rule_id)

        return describe(layer.name, rule, found[0], found[1], name, doc_of(found[0])).merge("label" => label.to_s)
      end
      text, path = yield(layer)
      describe(layer.name, rule, text, path, nil, doc_of(text))
    end

    def search_layers(chain, rule_id, &fallback)
      chain.layers.each do |layer|
        rule = Array(layer.rules).find { |item| item.is_a?(Hash) && item["id"] == rule_id }
        next unless rule

        return layer_hit(layer, rule, rule_id, &fallback)
      end
      nil
    end

    def locate_in(layer, rule, project, ledger)
      layer_hit(layer, rule, rule["id"]) { |item| layer_text(item, project, ledger) }
    rescue *LOOKUP_ERRORS
      nil
    end

    def layer_text(layer, project, ledger)
      store = Layers.store
      name = layer.name.to_s
      if name.start_with?("path:")
        entry = ledger&.path_entry(name.delete_prefix("path:"))
        [entry && store&.read(entry.policy), entry ? entry.policy : layer.source.to_s]
      elsif name == "global"
        [store&.global_text, "global.yml"]
      elsif name == "repo" && project
        [policy_text(project), project.policy]
      elsif name.start_with?("child:")
        child = ledger&.project(name.delete_prefix("child:"))
        [child && policy_text(child), child ? child.policy : layer.source.to_s]
      else
        [nil, layer.source.to_s]
      end
    end

    def policy_text(project)
      repo = File.expand_path(project.repo)
      [project.trust_ref, "main"].uniq.each do |branch|
        text = Environments.git(repo, "show", "#{branch}:#{project.policy}")
        return text if text
      end
      nil
    end

    def search_files(rule_id)
      store = Layers.store
      texts = []
      texts << [store.global_text, "global.yml", "global"] if store && store.global_text
      Catalog.shipped_files.each { |sub, path| texts << [File.read(sub.module_path), path, "catalog"] }
      texts.each do |text, path, layer|
        next unless text.include?(rule_id)

        doc = doc_of(text)
        rule = Array(doc["rules"]).find { |item| item.is_a?(Hash) && item["id"] == rule_id }
        next unless rule

        name = layer == "catalog" ? Catalog.module_name(path.delete_prefix("catalog/").delete_suffix(".yml")) : nil
        return describe(layer, rule, text, path, name, doc)
      end
      nil
    end

    def locate(rule_id, project_id = nil)
      ledger = Ledger.load
      projects = project_id ? [ledger.project(project_id)].compact : ledger.projects.reject { |project| project.status == "retired" }
      projects.each do |project|
        found = search_chain(project, ledger, rule_id)
        return found if found
      rescue *LOOKUP_ERRORS
        next
      end
      search_files(rule_id) || search_shelf(ledger, rule_id)
    rescue *LOOKUP_ERRORS
      nil
    end
  end
end
