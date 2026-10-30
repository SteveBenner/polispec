#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "pathname"
require_relative "hook_memo"
require_relative "catalog"

module Polispec
  module Layers
    PROFILES = %w[personal service live].freeze
    SEVERITY = { "allow" => 0, "warn" => 1, "deny" => 2 }.freeze
    GIT_ENV = { "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil, "GIT_OPTIONAL_LOCKS" => "0" }.freeze
    MODULE_NAME = /\A[a-z0-9][a-z0-9-]{0,40}\z/
    PARAM_NAME = /\A[a-z][a-z0-9_]*\z/
    PARAM_TYPES = %w[string integer number boolean list].freeze
    PARAM_KEYS = %w[type default summary].freeze
    PLACEHOLDER_EXACT = /\A\{\{([a-z][a-z0-9_]*)\}\}\z/
    PLACEHOLDER_INLINE = /\{\{([a-z][a-z0-9_]*)\}\}/
    SUBSTITUTION_SKIP = %w[schema name params].freeze
    BUCKETS = %w[freezes to_test to_stable preflight].freeze
    EMPTY_EXTRAS = { "freezes" => [], "hermetic" => {}, "to_test" => [], "to_stable" => [], "preflight" => [] }.freeze

    class ComposedPolicy < Hash
      attr_reader :raw_digest, :composition_errors

      def initialize(policy, raw_digest:, composition_errors:)
        super()
        replace(policy)
        @raw_digest = raw_digest
        @composition_errors = composition_errors
      end
    end

    Source = Struct.new(:kind, :root, :repo, :ref, :path, keyword_init: true) do
      def key
        [kind, root, repo, ref, path]
      end

      def describe
        kind == :dir ? "dir:#{root}" : "#{repo}@#{ref}:#{path}"
      end
    end
    Mod = Struct.new(:name, :doc, :text, :params, :origin) do
      def label
        params.nil? || params.empty? ? name : "#{name}#{canonical}"
      end

      def instance_text
        params.nil? || params.empty? ? text.to_s : "#{text}\n#params #{canonical}"
      end

      def key
        "#{name}#{canonical}"
      end

      private

      def canonical
        JSON.generate((params || {}).sort.to_h)
      end
    end
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

      def initialize(source, local: false)
        @source = source
        @local = local
        @errors = []
        @modules = {}
        @global = local ? nil : load_document("global", "global.yml")
        @profiles = local ? nil : load_document("profiles", "profiles.yml")
      end

      def local?
        @local
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

      def find_module(name)
        @modules[name] = load_module(name) unless @modules.key?(name)
        @modules[name]
      end

      private

      def load_module(name)
        text = read("modules/#{name}.yml")
        return nil if text.nil?

        data = Schema::Document.parse(text, "modules/#{name}.yml")
        Layers.build_raw(name, data, text, @local ? :local : :global)
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

    class Shelf
      def initialize(local, global)
        @local = local
        @global = global
      end

      def expand(includes, errors, seen = {}, stack = [], out = [])
        Array(includes).each do |entry|
          begin
            name, with = Layers.normalize_include(entry)
          rescue Polispec::Error => e
            Layers.note(errors, e.message)
            next
          end
          if stack.include?(name)
            Layers.note(errors, "include cycle: #{(stack[stack.index(name)..] + [name]).join(' -> ')}")
            next
          end

          raw = fetch(name, stack.last, errors)
          next unless raw

          mod = Layers.instantiate(raw, with, errors)
          next unless mod
          next if seen[mod.key]

          seen[mod.key] = true
          inner = raw.origin == :global ? Shelf.new(nil, @global) : self
          inner.expand(mod.doc["includes"], errors, seen, stack + [name], out)
          out << mod
        end
        out
      end

      private

      def describe
        (@local || @global)&.source&.describe
      end

      def fetch(name, parent, errors)
        context = parent ? " (included by #{parent})" : ""
        unless MODULE_NAME.match?(name.to_s)
          Layers.note(errors, "module name #{name.inspect}#{context} is not valid")
          return nil
        end
        local = @local && @local.find_module(name)
        global = @global && @global.find_module(name)
        if local && global
          Layers.note(errors, "module #{name} is ambiguous: defined in #{@local.source.describe} and #{@global.source.describe}")
          return nil
        end
        found = local || global
        if found.nil?
          where = describe || "no module source"
          Layers.note(errors, "module #{name}#{context}: not found in #{where}")
          return nil
        end
        if found.is_a?(String)
          Layers.note(errors, "module #{name}#{context}: #{found}")
          return nil
        end
        found
      end
    end

    class << self
      def source
        require_relative "harness_controls/plane"
        if defined?(HarnessControls::Plane) && HarnessControls::Plane.respond_to?(:resolve)
          plane = HarnessControls::Plane.resolve
          raise Polispec::Error, "sealed authority is broken" if plane["status"] == "broken"
          if plane["status"] == "active"
            root = plane.dig("paths", "global")
            return root ? Source.new(kind: :dir, root: File.expand_path(root)) : nil
          end
        end
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

      def local_store(src)
        return nil unless src

        @stores ||= {}
        @stores[[:local, *src.key]] ||= Store.new(src, local: true)
      end

      def shipped_store
        @stores ||= {}
        @stores[:shipped] ||= Store.new(Source.new(kind: :dir, root: Polispec::ROOT), local: true)
      end

      def shipped_layer(errors)
        layer, noted = HookMemo.fetch(:shipped_layer) do
          local = []
          [shipped_layer_uncached(local), local]
        end
        noted.each { |message| note(errors, message) }
        layer
      end

      def shipped_layer_uncached(errors)
        entries = Catalog.active_modules(errors)
        return nil if entries.empty?

        docs = entries.map { |entry| entry["doc"] }
        Layer.new(
          name: "catalog", source: "catalog:#{File.read(File.join(Polispec::ROOT, 'VERSION')).strip}",
          digest: sha(Catalog.digest), rules: docs.flat_map { |doc| Array(doc["rules"]) },
          modules: entries.map { |entry| entry["label"] }, extras: extras_of(docs)
        )
      end

      def shipped_delete_protected
        HookMemo.fetch(:catalog_delete_protected) do
          delete_protected_union(Catalog.active_modules.map { |entry| entry["doc"] })
        end
      end

      def shipped_delete_backup
        HookMemo.fetch(:catalog_delete_backup) do
          Catalog.active_modules.flat_map do |entry|
            doc = entry["doc"]
            listed = doc.is_a?(Hash) ? doc["delete_backup"] : nil
            listed.is_a?(Hash) ? Array(listed["ignored_names"]).select { |name| name.is_a?(String) && !name.strip.empty? } : []
          end.uniq
        end
      end

      def delete_protected_union(docs)
        union = { "exact" => [], "tree" => [] }
        docs.each do |doc|
          listed = doc.is_a?(Hash) ? doc["delete_protected"] : nil
          next unless listed.is_a?(Hash)

          union.each_key { |kind| union[kind].concat(Array(listed[kind]).select { |path| path.is_a?(String) && !path.strip.empty? }) }
        end
        union.transform_values(&:uniq)
      end

      def shipped_rules
        Array(shipped_layer([])&.rules)
      end

      def local_source(project, policy_source)
        return nil unless project && policy_source

        text = policy_source.to_s
        return nil if %w[policy defaults global ledger].include?(text)

        dir = File.dirname(project.policy.to_s)
        dir = "" if dir == "."
        if text.start_with?("file:")
          return Source.new(kind: :dir, root: File.dirname(File.expand_path(text.delete_prefix("file:"))))
        end
        if text.start_with?("bootstrap:")
          rest = text.delete_prefix("bootstrap:")
          cut = rest.rindex(":")
          return nil unless cut && cut.positive?

          return Source.new(kind: :repo, repo: File.expand_path(project.repo), ref: rest[0...cut], path: dir)
        end
        trust = project.trust_ref.to_s
        return nil if trust.empty? || !text.start_with?("#{trust}:")

        Source.new(kind: :repo, repo: File.expand_path(project.repo), ref: trust, path: dir)
      end

      def normalize_include(entry)
        return [entry, {}] if entry.is_a?(String)

        shaped = entry.is_a?(Hash) && entry["module"].is_a?(String) && (entry.keys - %w[module with]).empty?
        with = shaped ? (entry["with"].nil? ? {} : entry["with"]) : nil
        valid = with.is_a?(Hash) && with.values.all? { |value| scalar_param?(value) || list_param?(value) }
        raise Polispec::Error, "include #{entry.inspect} is not a module name or { module, with }" unless valid

        [entry["module"], with]
      end

      def note(errors, message)
        errors << message unless errors.include?(message)
      end

      def build_raw(name, data, text, origin)
        return "module document must be a mapping" unless data.is_a?(Hash)

        unless data.key?("params")
          problems = Schema.validate("module", data).map { |error| "#{error.pointer} #{error.message}".strip }
          problems << "/name must equal #{name}" if problems.empty? && data["name"] != name
          return problems.first(3).join("; ") unless problems.empty?

          return Mod.new(name, data, text, {}, origin)
        end

        problems = declaration_problems(name, data)
        return problems.first(3).join("; ") unless problems.empty?

        Mod.new(name, data, text, nil, origin)
      end

      def instantiate(raw, with, errors)
        name = raw.name
        declared = raw.doc["params"]
        return Mod.new(name, raw.doc, raw.text, {}, raw.origin) if declared.nil? && with.empty?

        declared = {} unless declared.is_a?(Hash)
        bound, problems = bind_params(name, declared, with)
        unless problems.empty?
          problems.each { |problem| note(errors, problem) }
          return nil
        end
        issues = []
        doc = substitute(raw.doc.reject { |key, _| key == "params" }, bound, name, issues, true)
        if issues.empty?
          Schema.validate("module", doc).first(3).each { |error| issues << "module #{name}: #{error.pointer} #{error.message}".strip }
        end
        unless issues.empty?
          issues.uniq.each { |problem| note(errors, problem) }
          return nil
        end
        Mod.new(name, doc, raw.text, bound, raw.origin)
      end

      def global
        shelf = store
        return nil unless shelf

        profiles = shelf.profiles_map
        names = Array(shelf.global_doc && shelf.global_doc["includes"]) + profiles.values.flat_map { |list| Array(list) }
        modules = Shelf.new(nil, shelf).expand(names.uniq, []).to_h { |mod| [mod.name, mod.doc] }
        (shelf.global_doc || {}).merge("profiles" => profiles, "modules" => modules)
      end

      def baseline?
        shelf = store
        return false unless shelf && shelf.global_doc

        doc = shelf.global_doc
        !Array(doc["rules"]).empty? || !Array(doc["includes"]).empty? || !shelf.profiles_map.empty? || !live_path_entries(safe_ledger).empty?
      end

      def live_path_entries(ledger)
        ledger ? ledger.paths.select { |entry| entry.status == "live" } : []
      end

      def path_layers(shelf, ledger, errors)
        live_path_entries(ledger).filter_map { |entry| path_layer(shelf, entry, errors) }
      end

      def path_layer(shelf, entry, errors)
        text = shelf.read(entry.policy)
        if text.nil?
          note(errors, "path #{entry.id}: #{entry.policy} not found in #{shelf.source.describe}")
          return nil
        end
        data = Schema::Document.parse(text, entry.policy)
        raw = build_raw(data.is_a?(Hash) ? data["name"].to_s : "", data, text, :global)
        if raw.is_a?(String)
          note(errors, "path #{entry.id}: #{entry.policy}: #{raw}")
          return nil
        end
        mod = instantiate(raw, {}, errors)
        return nil unless mod

        Layer.new(
          name: "path:#{entry.id}", source: "#{shelf.source.describe}:#{entry.policy}", digest: sha("#{entry.path}\n#{mod.instance_text}"),
          rules: Array(mod.doc["rules"]).flat_map { |rule| scope_rule(rule, entry) }, modules: [mod.label], extras: extras_of([mod.doc])
        )
      rescue Schema::Document::ParseError => e
        note(errors, "path #{entry.id}: #{e.message}")
        nil
      end

      def scope_rule(rule, entry)
        root = entry.path.sub(%r{/+\z}, "")
        root = File.expand_path(root)
        match = rule["match"].is_a?(Hash) ? rule["match"] : {}
        own = match["path"].to_s
        return [rule.merge("match" => match.merge("path" => root)), rule.merge("match" => match.merge("path" => "#{root}/**/*"))] if own.empty?

        relative = own.sub(%r{\A/+}, "")
        [rule.merge("match" => match.merge("path" => File.join(root, relative)))]
      end

      def fingerprint
        HookMemo.fetch(:layers_fingerprint) { fingerprint_uncached }
      end

      def fingerprint_uncached
        shelf = store
        return "" unless shelf

        scoped = live_path_entries(safe_ledger).map { |entry| [entry.id, entry.path, shelf.read(entry.policy).to_s].join("\n") }
        sha([shipped_layer([])&.digest.to_s, shelf.source.key.inspect, shelf.global_text.to_s, shelf.profiles_text.to_s, *scoped].join("\n--\n"))
      end

      def fallback_rules
        rules = store&.global_doc&.dig("fallback_rules")
        rules.is_a?(Array) && !rules.empty? ? rules : nil
      end

      def reset!
        @stores = nil
      end

      def load(project, path = nil, policy: nil, digest: nil, ledger: nil, policy_source: nil, local: :auto)
        ledger ||= safe_ledger
        errors = []
        gstore = store
        profile = effective_profile(project, policy, errors)
        layers = []
        shipped = shipped_layer(errors)
        layers << shipped if shipped
        if gstore
          errors.concat(gstore.errors)
          layer = global_layer(gstore, profile, ledger, errors)
          layers << layer if layer
          layers.concat(path_layers(gstore, ledger, errors)) if project.nil?
        end
        if policy.is_a?(Hash)
          src = local == :auto ? local_source(project, policy_source) : local
          layers << repo_layer(local_store(src), gstore, policy, digest, policy_source, errors)
        end
        children(project, ledger, path).each do |child|
          layer = child_layer(child, project, ledger, gstore, errors)
          layers << layer if layer
        end
        Chain.new(layers: layers, errors: errors, profile: profile, applied: check_overrides(layers, errors))
      end

      def chain_for(target, ctx)
        ledger = ctx[:ledger]
        project = ledger && target.project ? ledger.project(target.project) : nil
        src = local_source(project, target.policy_source)
        key = [source&.key, src&.key, ctx[:cwd]]
        memo = target.instance_variable_get(:@polispec_chain)
        return memo[1] if memo && memo[0] == key

        chain = load(project, ctx[:cwd], policy: target.policy, digest: target.digest, ledger: ledger, policy_source: target.policy_source, local: src)
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

      def descendants(project, ledger)
        return [] unless project && ledger

        base = File.expand_path(project.repo)
        nested = ledger.projects.reject { |other| other.status == "retired" || other.id == project.id }.select do |other|
          File.expand_path(other.repo).start_with?("#{base}/")
        end
        nested.sort_by { |other| File.expand_path(other.repo).length }
      end

      def compose(project, policy, digest, ledger: nil, local: :auto)
        return [policy, digest] unless policy.is_a?(Hash)

        ledger ||= safe_ledger if project
        gstore = store
        kids = descendants(project, ledger)
        return [policy, digest] unless gstore || includes?(policy) || !kids.empty?

        chain = load(project, nil, policy: policy, digest: digest, ledger: ledger, local: local)
        errors = chain.errors.dup
        taken = taken_ids(chain.layers, policy)
        extras = chain.layers.map(&:extras)
        layers = chain.layers.dup
        kids.each do |child|
          layer = child_layer(child, project, ledger, gstore, errors)
          next unless layer

          layers << layer
          extras << filter_collisions(layer, taken, errors)
        end
        unless errors.empty?
          where = gstore ? gstore.source.describe : (local.is_a?(Source) ? local.describe : "policy")
          Events.emit("polispec.finding", project: project&.id, kind: "layers_invalid", detail: errors.first(3).join("; "), policy_source: where)
        end
        merged = ComposedPolicy.new(merge_policy(policy, extras), raw_digest: digest, composition_errors: errors)
        [merged, Chain.new(layers: layers, errors: errors, profile: nil, applied: []).effective_digest]
      end

      def errors_for(policy)
        policy.composition_errors if policy.is_a?(ComposedPolicy)
      end

      def policy_errors(policy, project: nil, ledger: nil, file: nil)
        return [] unless policy.is_a?(Hash)

        found = errors_for(policy)
        return found if found

        local = file ? Source.new(kind: :dir, root: File.dirname(File.expand_path(file))) : :auto
        merged, = compose(project, policy, nil, ledger: ledger, local: local)
        errors_for(merged) || []
      end

      def document_errors(kind, data, file)
        return [] unless data.is_a?(Hash)

        dir = File.dirname(File.expand_path(file))
        dir = File.dirname(dir) if kind == "module" && File.basename(dir) == "modules"
        errors = []
        if kind == "module"
          shelf = if File.file?(File.join(dir, "global.yml"))
                    Shelf.new(nil, Store.new(Source.new(kind: :dir, root: dir)))
                  else
                    Shelf.new(Store.new(Source.new(kind: :dir, root: dir), local: true), store)
                  end
          entry = { "module" => data["name"].to_s, "with" => sample_params(data) }
          if File.expand_path(file) == File.join(dir, "modules", "#{data['name']}.yml")
            shelf.expand([entry], errors)
          else
            expand_detached(shelf, data, file, errors)
          end
        else
          Shelf.new(nil, Store.new(Source.new(kind: :dir, root: dir))).expand(data["includes"], errors, {}, [])
        end
        errors
      end

      private

      def scalar_param?(value)
        value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
      end

      def list_param?(value)
        value.is_a?(Array) && value.all? { |item| item.is_a?(String) || item.is_a?(Numeric) }
      end

      def type_ok?(type, value)
        case type
        when "string" then value.is_a?(String)
        when "integer" then value.is_a?(Integer)
        when "number" then value.is_a?(Numeric)
        when "boolean" then value == true || value == false
        when "list" then list_param?(value)
        else false
        end
      end

      def deep_dup(value)
        case value
        when Array then value.map { |item| deep_dup(item) }
        when Hash then value.to_h { |key, item| [key, deep_dup(item)] }
        when String then value.dup
        else value
        end
      end

      def declaration_problems(name, data)
        params = data["params"]
        problems = []
        problems << "/name must equal #{name}" if data["name"] != name
        unless params.is_a?(Hash)
          problems << "/params must be object"
          return problems
        end
        params.each do |key, defn|
          problems << "module #{name}: parameter name #{key} is not valid" unless PARAM_NAME.match?(key.to_s)
          next unless defn.is_a?(Hash) && PARAM_TYPES.include?(defn["type"]) && defn.key?("default")

          problems << "module #{name}: parameter #{key} default must be #{defn['type']}" unless type_ok?(defn["type"], defn["default"])
        end
        Schema.validate("module", data.slice("schema", "name", "params")).each { |error| problems << "#{error.pointer} #{error.message}".strip }
        problems
      end

      def sample_params(data)
        declared = data["params"].is_a?(Hash) ? data["params"] : {}
        samples = { "string" => "x", "integer" => 1, "number" => 1, "boolean" => true, "list" => [] }
        declared.each_with_object({}) do |(key, defn), memo|
          next unless defn.is_a?(Hash) && !defn.key?("default") && samples.key?(defn["type"])

          memo[key] = deep_dup(samples[defn["type"]])
        end
      end

      def expand_detached(shelf, data, file, errors)
        name = data["name"].to_s
        raw = build_raw(name, data, File.read(file), :local)
        return note(errors, "module #{name}: #{raw}") if raw.is_a?(String)

        mod = instantiate(raw, sample_params(data), errors)
        return unless mod

        shelf.expand(mod.doc["includes"], errors, { mod.key => true }, [name])
      rescue SystemCallError => e
        note(errors, e.message)
      end

      def bind_params(name, declared, with)
        problems = []
        with.each_key do |key|
          if !PARAM_NAME.match?(key.to_s)
            problems << "module #{name}: parameter name #{key} is not valid"
          elsif !declared.key?(key)
            problems << "module #{name}: unknown parameter #{key}"
          end
        end
        bound = {}
        declared.each do |key, defn|
          defn = {} unless defn.is_a?(Hash)
          if with.key?(key)
            value = with[key]
          elsif defn.key?("default")
            value = deep_dup(defn["default"])
          else
            problems << "module #{name}: parameter #{key} is required"
            next
          end
          if type_ok?(defn["type"], value)
            bound[key] = value
          else
            problems << "module #{name}: parameter #{key} must be #{defn['type']}"
          end
        end
        [bound, problems]
      end

      def substitute(node, bound, name, issues, top = false)
        case node
        when Hash
          node.to_h do |key, value|
            [key, top && SUBSTITUTION_SKIP.include?(key) ? value : substitute(value, bound, name, issues)]
          end
        when Array
          node.map { |item| substitute(item, bound, name, issues) }
        when String
          substitute_text(node, bound, name, issues)
        else
          node
        end
      end

      def substitute_text(text, bound, name, issues)
        exact = PLACEHOLDER_EXACT.match(text)
        if exact
          key = exact[1]
          unless bound.key?(key)
            issues << "module #{name}: unresolved placeholder {{#{key}}}"
            return text
          end
          return deep_dup(bound[key])
        end
        text.gsub(PLACEHOLDER_INLINE) do
          key = Regexp.last_match(1)
          if !bound.key?(key)
            issues << "module #{name}: unresolved placeholder {{#{key}}}"
            Regexp.last_match(0)
          elsif bound[key].is_a?(Array)
            issues << "module #{name}: list parameter #{key} used inside text"
            Regexp.last_match(0)
          else
            bound[key].to_s
          end
        end
      end

      def duplicate_ids(layer_name, mods, errors)
        owners = {}
        mods.each do |mod|
          bucket_ids(mod.doc).each do |bucket, ids|
            ids.each do |id|
              slot = (owners[[bucket, id]] ||= [])
              slot << mod.label unless slot.include?(mod.label)
            end
          end
        end
        owners.each do |(_, id), labels|
          next if labels.length < 2

          note(errors, "layer #{layer_name}: id #{id} is defined by module #{labels[0]} and module #{labels[1]}")
        end
      end

      def bucket_ids(doc)
        {
          "rules" => ids_of(doc["rules"]),
          "to_test" => ids_of(doc.dig("gates", "to_test")),
          "to_stable" => ids_of(doc.dig("gates", "to_stable")),
          "preflight" => ids_of(doc["preflight"]),
          "freezes" => ids_of(doc["freezes"])
        }
      end

      def ids_of(items)
        Array(items).filter_map { |item| item["id"] if item.is_a?(Hash) }
      end

      def digest_with(base, mods)
        mods.empty? ? base : sha(([base] + mods.map(&:instance_text)).join("\n--\n"))
      end

      def taken_ids(layers, policy)
        taken = BUCKETS.to_h { |bucket| [bucket, {}] }
        layers.each do |layer|
          BUCKETS.each { |bucket| layer.extras[bucket].each { |item| taken[bucket][item["id"]] ||= layer.name } if layer.extras[bucket].is_a?(Array) }
        end
        own = {
          "freezes" => policy["freezes"],
          "to_test" => policy.dig("promotion", "to_test", "gates"),
          "to_stable" => policy.dig("promotion", "to_stable", "gates"),
          "preflight" => policy.dig("promotion", "to_stable", "preflight")
        }
        own.each { |bucket, items| Array(items).each { |item| taken[bucket][item["id"]] = "owner policy" if item.is_a?(Hash) } }
        taken
      end

      def filter_collisions(layer, taken, errors)
        kept = layer.extras.to_h { |key, value| [key, value] }
        BUCKETS.each do |bucket|
          kept[bucket] = Array(layer.extras[bucket]).select do |item|
            holder = taken[bucket][item["id"]]
            if holder
              note(errors, "id_collision: #{bucket} #{item['id']} from #{layer.name} already defined by #{holder}")
              false
            else
              taken[bucket][item["id"]] = layer.name
              true
            end
          end
        end
        kept
      end

      def child_extras_doc(policy)
        {
          "freezes" => policy["freezes"] || [],
          "hermetic" => policy["hermetic"] || {},
          "gates" => {
            "to_test" => policy.dig("promotion", "to_test", "gates") || [],
            "to_stable" => policy.dig("promotion", "to_stable", "gates") || []
          },
          "preflight" => policy.dig("promotion", "to_stable", "preflight") || []
        }
      end

      def relative_dir(owner, child)
        return nil unless owner

        Pathname.new(File.expand_path(child.repo)).relative_path_from(Pathname.new(File.expand_path(owner.repo))).to_s
      end

      def with_dir(extras, rel)
        return extras unless rel

        scoped = extras.dup
        %w[to_test to_stable preflight].each do |bucket|
          scoped[bucket] = Array(extras[bucket]).map do |gate|
            gate.is_a?(Hash) ? gate.merge("dir" => (gate["dir"] ? File.join(rel, gate["dir"]) : rel)) : gate
          end
        end
        scoped
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
        resolver = Shelf.new(nil, shelf)
        mods = resolver.expand(doc["includes"], errors, seen)
        mods += resolver.expand(shelf.profile_modules(profile), errors, seen)
        duplicate_ids("global", mods, errors)
        texts = [shelf.global_text] + mods.map(&:instance_text)
        texts << shelf.profiles_text if shelf.profiles_text && profile
        Layer.new(
          name: "global", source: shelf.source.describe, digest: sha(texts.join("\n--\n")),
          rules: mods.flat_map { |mod| Array(mod.doc["rules"]) } + Array(doc["rules"]),
          modules: mods.map(&:label), extras: extras_of(mods.map(&:doc) + [doc])
        )
      end

      def repo_layer(local, global, policy, digest, label, errors)
        mods = Shelf.new(local, global).expand(policy["includes"], errors)
        duplicate_ids("repo", mods, errors)
        raw_digest = policy.raw_digest if policy.is_a?(ComposedPolicy)
        base = raw_digest || digest || sha(JSON.generate(policy))
        Layer.new(
          name: "repo", source: label || "policy", digest: digest_with(base, mods),
          rules: mods.flat_map { |mod| Array(mod.doc["rules"]) } + Array(policy["rules"]),
          modules: mods.map(&:label), extras: extras_of(mods.map(&:doc))
        )
      end

      def child_layer(child, owner, ledger, global, errors)
        loaded = PolicySource.raw(child, ledger: ledger)
        return nil unless loaded

        policy = loaded.policy
        shelf = Shelf.new(local_store(local_source(child, loaded.source)), global)
        mods = shelf.expand(policy["includes"], errors)
        name = "child:#{child.id}"
        duplicate_ids(name, mods, errors)
        extras = with_dir(extras_of(mods.map(&:doc) + [child_extras_doc(policy)]), relative_dir(owner, child))
        Layer.new(
          name: name, source: loaded.source, digest: digest_with(loaded.digest, mods),
          rules: mods.flat_map { |mod| Array(mod.doc["rules"]) } + Array(policy["rules"]),
          modules: mods.map(&:label), extras: extras
        )
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
