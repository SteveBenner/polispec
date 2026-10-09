#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Layers
    PROFILES = %w[personal service live].freeze
    SEVERITY = { "allow" => 0, "warn" => 1, "deny" => 2 }.freeze
    GIT_ENV = { "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil, "GIT_OPTIONAL_LOCKS" => "0" }.freeze
    MODULE_NAME = /\A[a-z0-9][a-z0-9-]{0,40}\z/
    EMPTY_EXTRAS = { "freezes" => [], "hermetic" => {}, "to_test" => [], "to_stable" => [], "preflight" => [] }.freeze

    Source = Struct.new(:kind, :root, :repo, :ref, :path, keyword_init: true) do
      def key
        [kind, root, repo, ref, path]
      end

      def describe
        kind == :dir ? "dir:#{root}" : "#{repo}@#{ref}:#{path}"
      end
    end
    Mod = Struct.new(:name, :doc, :text)
    Layer = Struct.new(:name, :source, :digest, :rules, :modules, :extras, keyword_init: true) do
      def to_h
        { "layer" => name, "source" => source, "digest" => digest, "rules" => rules.length, "modules" => modules }
      end
    end
    Chain = Struct.new(:layers, :errors, :profile, :applied, keyword_init: true) do
      def effective_digest
        "sha256:#{Digest::SHA256.hexdigest(layers.map { |layer| layer.digest.to_s }.join("\n"))}"
      end

      def to_h
        { "profile" => profile, "layers" => layers.map(&:to_h), "effective_digest" => effective_digest, "errors" => errors }
      end
    end

    class Store
      attr_reader :source, :errors

      def initialize(source)
        @source = source
        @errors = []
        @modules = {}
        @global = load_document("global", "global.yml")
        @profiles = load_document("profiles", "profiles.yml")
      end

      def global_doc
        @global && @global[0]
      end

      def global_text
        @global && @global[1]
      end

      def profile_modules(profile)
        return [] unless @profiles && profile

        Array(@profiles[0].dig("profiles", profile))
      end

      def profiles_text
        @profiles && @profiles[1]
      end

      def profiles_map
        map = @profiles && @profiles[0]["profiles"]
        map.is_a?(Hash) ? map : {}
      end

      def read(relative)
        source.kind == :dir ? read_dir(relative) : read_repo(relative)
      end

      def expand(names, errors, seen = {}, stack = [], out = [])
        Array(names).each do |name|
          if stack.include?(name)
            errors << "include cycle: #{(stack[stack.index(name)..] + [name]).join(' -> ')}"
            next
          end
          next if seen[name]

          seen[name] = true
          mod = fetch(name, stack.last, errors)
          next unless mod

          expand(mod.doc["includes"], errors, seen, stack + [name], out)
          out << mod
        end
        out
      end

      private

      def fetch(name, parent, errors)
        context = parent ? " (included by #{parent})" : ""
        unless MODULE_NAME.match?(name.to_s)
          errors << "module name #{name.inspect}#{context} is not valid"
          return nil
        end
        unless @modules.key?(name)
          @modules[name] = load_module(name)
        end
        mod = @modules[name]
        if mod.is_a?(String)
          errors << "module #{name}#{context}: #{mod}"
          return nil
        end
        mod
      end

      def load_module(name)
        text = read("modules/#{name}.yml")
        return "not found in #{source.describe}" if text.nil?

        data = Schema::Document.parse(text, "modules/#{name}.yml")
        problems = Schema.validate("module", data).map { |error| "#{error.pointer} #{error.message}".strip }
        problems << "/name must equal #{name}" if problems.empty? && data["name"] != name
        return problems.first(3).join("; ") unless problems.empty?

        Mod.new(name, data, text)
      rescue Schema::Document::ParseError => e
        e.message
      end

      def load_document(kind, relative)
        text = read(relative)
        return nil if text.nil?

        data = Schema::Document.parse(text, relative)
        problems = Schema.validate(kind, data).map { |error| "#{relative} #{error.pointer} #{error.message}".strip }
        if problems.empty?
          [data, text]
        else
          @errors.concat(problems.first(3))
          nil
        end
      rescue Schema::Document::ParseError => e
        @errors << e.message
        nil
      end

      def read_dir(relative)
        file = File.join(source.root, relative)
        File.file?(file) ? File.read(file) : nil
      rescue SystemCallError
        nil
      end

      def read_repo(relative)
        object = "#{source.ref}:#{[source.path, relative].reject { |part| part.to_s.empty? }.join('/')}"
        out, status = Open3.capture2(GIT_ENV, "git", "-C", source.repo, "show", object, err: File::NULL)
        status.success? ? out : nil
      rescue SystemCallError
        nil
      end
    end

    class << self
      def source
        dir = ENV["POLISPEC_GLOBAL"].to_s.strip
        return Source.new(kind: :dir, root: File.expand_path(dir)) unless dir.empty?

        repo = Engine::Settings.text("polispec.global.repo", nil)
        return nil unless repo

        Source.new(kind: :repo, repo: File.expand_path(repo), ref: Engine::Settings.text("polispec.global.ref", "main"),
                   path: Engine::Settings.text("polispec.global.path", "polispec").sub(%r{\A/+}, "").sub(%r{/+\z}, ""))
      end

      def store
        src = source
        return nil unless src

        @stores ||= {}
        @stores[src.key] ||= Store.new(src)
      end

      def global
        shelf = store
        return nil unless shelf

        profiles = shelf.profiles_map
        names = Array(shelf.global_doc && shelf.global_doc["includes"]) + profiles.values.flat_map { |list| Array(list) }
        modules = shelf.expand(names.uniq, []).to_h { |mod| [mod.name, mod.doc] }
        (shelf.global_doc || {}).merge("profiles" => profiles, "modules" => modules)
      end

      def baseline?
        shelf = store
        return false unless shelf && shelf.global_doc

        doc = shelf.global_doc
        !Array(doc["rules"]).empty? || !Array(doc["includes"]).empty? || !shelf.profiles_map.empty?
      end

      def fingerprint
        shelf = store
        return "" unless shelf

        sha([shelf.source.key.inspect, shelf.global_text.to_s, shelf.profiles_text.to_s].join("\n--\n"))
      end

      def fallback_rules
        rules = store&.global_doc&.dig("fallback_rules")
        rules.is_a?(Array) && !rules.empty? ? rules : nil
      end

      def reset!
        @stores = nil
      end

      def load(project, path = nil, policy: nil, digest: nil, ledger: nil, policy_source: nil)
        ledger ||= safe_ledger
        errors = []
        shelf = store
        profile = effective_profile(project, policy, errors)
        layers = []
        if shelf
          errors.concat(shelf.errors)
          layer = global_layer(shelf, profile, ledger, errors)
          layers << layer if layer
        end
        layers << repo_layer(shelf, policy, digest, policy_source, errors) if policy.is_a?(Hash)
        children(project, ledger, path).each do |child|
          layer = child_layer(child, ledger)
          layers << layer if layer
        end
        Chain.new(layers: layers, errors: errors, profile: profile, applied: check_overrides(layers, errors))
      end

      def chain_for(target, ctx)
        ledger = ctx[:ledger]
        project = ledger && target.project ? ledger.project(target.project) : nil
        return nil if source.nil? && children(project, ledger, ctx[:cwd]).empty?

        key = [source&.key, ctx[:cwd]]
        memo = target.instance_variable_get(:@polispec_chain)
        return memo[1] if memo && memo[0] == key

        chain = load(project, ctx[:cwd], policy: target.policy, digest: target.digest, ledger: ledger, policy_source: target.policy_source)
        chain = nil if chain.layers.length < 2 && chain.errors.empty? && !includes?(target.policy)
        target.instance_variable_set(:@polispec_chain, [key, chain])
        chain
      end

      def pick(target, ctx, &matcher)
        chain = chain_for(target, ctx)
        return [Array(target.policy["rules"]).find(&matcher), nil] unless chain

        hits = []
        chain.layers.each_with_index do |layer, index|
          rule = layer.rules.find { |candidate| !overridden?(chain, index, candidate, matcher) && matcher.call(candidate) }
          hits << [index, rule] if rule
        end
        best = hits.max_by { |index, rule| [SEVERITY.fetch(rule["verdict"], 0), index] }
        return [nil, nil] unless best

        layer = chain.layers[best[0]]
        [best[1], chain.layers.length > 1 ? "layer #{layer.name} #{layer.digest.to_s[0, 19]}" : nil]
      end

      def compose(project, policy, digest, ledger: nil)
        return [policy, digest] unless policy.is_a?(Hash) && store

        chain = load(project, nil, policy: policy, digest: digest, ledger: ledger)
        unless chain.errors.empty?
          Events.emit("polispec.finding", project: project&.id, kind: "layers_invalid", detail: chain.errors.first(3).join("; "), policy_source: store.source.describe)
        end
        merged = merge_policy(policy, chain.layers.map(&:extras))
        raw_digests[merged] = digest
        [merged, chain.effective_digest]
      end

      def policy_errors(policy, project: nil, ledger: nil)
        return [] unless policy.is_a?(Hash) && store

        chain = load(project, nil, policy: policy, ledger: ledger)
        chain.errors
      end

      def document_errors(kind, data, file)
        return [] unless data.is_a?(Hash)

        dir = File.dirname(File.expand_path(file))
        dir = File.dirname(dir) if kind == "module" && File.basename(dir) == "modules"
        shelf = Store.new(Source.new(kind: :dir, root: dir))
        errors = []
        shelf.expand(data["includes"], errors, {}, kind == "module" ? [data["name"]] : [])
        errors
      end

      private

      def raw_digests
        @raw_digests ||= ObjectSpace::WeakMap.new
      end

      def includes?(policy)
        policy.is_a?(Hash) && !Array(policy["includes"]).empty?
      end

      def safe_ledger
        Ledger.load
      rescue Polispec::Error
        nil
      end

      def effective_profile(project, policy, errors)
        return nil unless project

        base = PROFILES.include?(project.profile) ? project.profile : "personal"
        named = policy.is_a?(Hash) ? policy["profile"] : nil
        return base unless PROFILES.include?(named)

        if PROFILES.index(named) < PROFILES.index(base)
          errors << "policy profile #{named} is looser than the ledger profile #{base}; #{base} applies"
          return base
        end
        named
      end

      def global_layer(shelf, profile, ledger, errors)
        doc = shelf.global_doc
        if doc.nil?
          errors << "global.yml not found in #{shelf.source.describe}" if shelf.errors.empty?
          return nil
        end

        seen = {}
        mods = shelf.expand(doc["includes"], errors, seen)
        mods += shelf.expand(shelf.profile_modules(profile), errors, seen)
        texts = [shelf.global_text] + mods.map(&:text)
        texts << shelf.profiles_text if shelf.profiles_text && profile
        Layer.new(
          name: "global", source: shelf.source.describe, digest: sha(texts.join("\n--\n")),
          rules: mods.flat_map { |mod| Array(mod.doc["rules"]) } + Array(doc["rules"]),
          modules: mods.map(&:name), extras: extras_of(mods.map(&:doc) + [doc])
        )
      end

      def repo_layer(shelf, policy, digest, label, errors)
        mods = shelf ? shelf.expand(policy["includes"], errors) : []
        Layer.new(
          name: "repo", source: label || "policy", digest: raw_digests[policy] || digest || sha(JSON.generate(policy)),
          rules: mods.flat_map { |mod| Array(mod.doc["rules"]) } + Array(policy["rules"]),
          modules: mods.map(&:name), extras: extras_of(mods.map(&:doc))
        )
      end

      def child_layer(child, ledger)
        loaded = PolicySource.resolve(child, ledger: ledger)
        return nil if loaded.source == "defaults" || !loaded.policy.is_a?(Hash)

        Layer.new(name: "child:#{child.id}", source: loaded.source, digest: loaded.digest, rules: Array(loaded.policy["rules"]), modules: [], extras: EMPTY_EXTRAS)
      end

      def children(project, ledger, path)
        return [] unless project && ledger && path && !path.to_s.empty?

        base = File.expand_path(project.repo)
        full = File.expand_path(path.to_s)
        nested = ledger.projects.reject { |other| other.status == "retired" || other.id == project.id }.select do |other|
          root = File.expand_path(other.repo)
          root.start_with?("#{base}/") && (full == root || full.start_with?("#{root}/"))
        end
        nested.sort_by { |other| File.expand_path(other.repo).length }
      end

      def extras_of(docs)
        docs.each_with_object({ "freezes" => [], "hermetic" => {}, "to_test" => [], "to_stable" => [], "preflight" => [] }) do |doc, memo|
          memo["freezes"].concat(Array(doc["freezes"]))
          memo["to_test"].concat(Array(doc.dig("gates", "to_test")))
          memo["to_stable"].concat(Array(doc.dig("gates", "to_stable")))
          memo["preflight"].concat(Array(doc["preflight"]))
          (doc["hermetic"] || {}).each do |tier, config|
            slot = (memo["hermetic"][tier] ||= { "isolate" => [], "protected_roots" => [] })
            slot["isolate"] |= Array(config["isolate"])
            slot["protected_roots"] |= Array(config["protected_roots"])
          end
        end
      end

      def check_overrides(layers, errors)
        applied = []
        layers.each_with_index do |layer, lower|
          layer.rules.each do |rule|
            id = rule["overrides"]
            next unless id

            upper = (0...lower).find { |index| layers[index].rules.any? { |candidate| candidate["id"] == id } }
            if upper.nil?
              errors << "rule #{rule['id']} (layer #{layer.name}) overrides #{id}, which no upper layer defines"
              next
            end
            target = layers[upper].rules.find { |candidate| candidate["id"] == id }
            if target["overridable"] == true
              applied << [upper, id, rule]
            else
              errors << "rule #{rule['id']} (layer #{layer.name}) overrides #{id} (layer #{layers[upper].name}), which is not overridable"
            end
          end
        end
        applied
      end

      def overridden?(chain, index, candidate, matcher)
        chain.applied.any? { |upper, id, rule| upper == index && id == candidate["id"] && matcher.call(rule) }
      end

      def merge_policy(policy, extras)
        merged = policy.dup
        freezes = unite(extras.flat_map { |item| item["freezes"] }, Array(policy["freezes"]))
        merged["freezes"] = freezes unless freezes.empty?
        hermetic = merge_hermetic(extras, policy["hermetic"])
        merged["hermetic"] = hermetic unless hermetic.empty?
        merge_gates(merged, extras)
        merged
      end

      def merge_gates(merged, extras)
        return unless merged["promotion"].is_a?(Hash)

        promotion = merged["promotion"].dup
        %w[to_test to_stable].each do |key|
          section = promotion[key]
          next unless section.is_a?(Hash)

          section = section.dup
          section["gates"] = unite(extras.flat_map { |item| item[key] }, Array(section["gates"]))
          section["preflight"] = unite(extras.flat_map { |item| item["preflight"] }, Array(section["preflight"])) if key == "to_stable" && (section.key?("preflight") || extras.any? { |item| !item["preflight"].empty? })
          promotion[key] = section
        end
        merged["promotion"] = promotion
      end

      def merge_hermetic(extras, own)
        result = {}
        extras.each do |item|
          item["hermetic"].each do |tier, config|
            slot = (result[tier] ||= { "isolate" => [], "protected_roots" => [] })
            slot["isolate"] |= config["isolate"]
            slot["protected_roots"] |= config["protected_roots"]
          end
        end
        (own || {}).each do |tier, config|
          slot = (result[tier] ||= {})
          config.each do |key, value|
            slot[key] = value.is_a?(Array) ? (Array(slot[key]) | value) : value
          end
        end
        result.each_value { |slot| slot.delete_if { |_, value| value.respond_to?(:empty?) && value.empty? } }
        result.delete_if { |_, slot| slot.empty? }
      end

      def unite(upper, own)
        ids = own.map { |item| item["id"] }
        upper.reject { |item| ids.include?(item["id"]) }.uniq { |item| item["id"] } + own
      end

      def sha(text)
        "sha256:#{Digest::SHA256.hexdigest(text)}"
      end
    end
  end
end
