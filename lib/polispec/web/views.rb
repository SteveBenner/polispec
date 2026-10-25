#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "open3"
require "time"
require "yaml"
require_relative "../changes"
require_relative "../sessions"
require_relative "../judgments"
require_relative "../manifest"
require_relative "../exceptions"
require_relative "../packages"
require_relative "../probes"
require_relative "../plan"
require_relative "../description"
require_relative "../freeze"
require_relative "../commands/doctor"

module Polispec
  module Web
    module Views
      class NotFound < Polispec::Error; end

      class Unavailable < Polispec::Error; end

      class Invalid < Polispec::Error
        attr_reader :findings

        def initialize(message, findings = [])
          super(message)
          @findings = findings
        end
      end

      MAP_WINDOWS = { "1h" => 3600, "24h" => 86_400, "7d" => 604_800 }.freeze
      SESSION_WINDOWS = { "1h" => 3600, "6h" => 21_600, "24h" => 86_400 }.freeze
      HEAT_WINDOWS = { "7d" => 604_800, "14d" => 1_209_600, "30d" => 2_592_000 }.freeze
      UNITS = { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.freeze
      ENVS = %w[dev test prod].freeze
      KINDS = %w[project path global module].freeze
      GIT_ENV = { "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil, "GIT_OPTIONAL_LOCKS" => "0" }.freeze
      REF_FORMAT = %r{\A[A-Za-z0-9][A-Za-z0-9._/-]{0,99}\z}.freeze
      LAYER_LABELS = { "catalog" => "Catalog", "shipped" => "Shipped", "global" => "Global shelf", "repo" => "Project" }.freeze
      CHIP_BANDS = { "catalog" => "shipped", "global" => "global" }.freeze
      JUDGMENT_LIMIT = 1000
      QUIET = Mutex.new

      @memo = {}
      @memo_lock = Mutex.new

      module_function

      def cached(name, ttl, *parts)
        key = [name, *parts]
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        hit = @memo_lock.synchronize { @memo[key] }
        return hit[1] if hit && now - hit[0] < ttl

        value = yield
        @memo_lock.synchronize do
          @memo.shift while @memo.length >= 128
          @memo[key] = [now, value]
        end
        value
      end

      def ledger
        Ledger.load
      rescue Polispec::Error => e
        raise Unavailable, e.message
      end

      def epoch(current = nil)
        cached("epoch", 2) { Effect.epoch(current) }
      end

      def seconds_of(text, allowed = nil, default = nil)
        label = text.to_s.empty? ? default : text.to_s
        return [label, allowed.fetch(label)] if allowed && allowed.key?(label)
        raise Invalid.new("the window must be one of #{allowed.keys.join(', ')}") if allowed

        match = label.to_s.match(/\A(\d+)([smhd]?)\z/)
        raise Invalid.new("#{label.inspect} is not a duration such as 30d") unless match

        [label, match[1].to_i * UNITS.fetch(match[2].empty? ? "s" : match[2])]
      end

      def time_param(text, default_seconds)
        return Time.now - default_seconds if text.to_s.empty?

        if text.to_s.match?(/\A\d+[smhd]?\z/)
          return Time.now - seconds_of(text)[1]
        end
        Time.iso8601(text.to_s)
      rescue ArgumentError
        raise Invalid.new("#{text.inspect} is not an ISO 8601 time or a duration")
      end

      def sha_text(text)
        "sha256:#{Digest::SHA256.hexdigest(text.to_s)}"
      end

      def git(repo, *args)
        out, status = Open3.capture2(GIT_ENV, "git", "-C", repo, *args, err: File::NULL)
        status.success? ? out : nil
      rescue SystemCallError
        nil
      end

      def stripped(record)
        action = record["action"]
        return record unless action.is_a?(Hash) && action.key?("raw")

        record.merge("action" => action.reject { |key, _| key == "raw" })
      end

      def recent_judgments(cutoff)
        Sessions.tail_judgments(cutoff).sort_by { |row| row["ts"].to_s }
      end

      def module_name(label)
        return Catalog.module_name(label) if label.to_s.start_with?("catalog:")

        label.to_s[/\A[a-z0-9][a-z0-9-]*/].to_s
      end

      def catalog_module(name)
        entry = Catalog.entry_named(name)
        entry && Layers::Mod.new(name, entry["doc"], entry["text"], {}, :catalog)
      end

      def module_source(name)
        entry = Catalog.entry_named(name)
        entry ? entry["label"] : "modules/#{name}.yml"
      end

      def module_params(label)
        rest = label.to_s[module_name(label).length..].to_s
        parsed = rest.empty? ? {} : JSON.parse(rest)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      def layer_id(name)
        name.to_s == "repo" ? "project" : name.to_s
      end

      def layer_label(name)
        return LAYER_LABELS[name] if LAYER_LABELS.key?(name)
        return "Path #{name.delete_prefix('path:')}" if name.start_with?("path:")
        return "Child #{name.delete_prefix('child:')}" if name.start_with?("child:")

        name
      end

      def owner_summary(entry, policy_doc)
        text = policy_doc.is_a?(Hash) ? policy_doc["summary"].to_s : ""
        text.empty? ? Manifest.summary_of(entry.description) : text
      end

      def side_for(project, current)
        Probes.resolved(project, current)
      end

      def entries_ids(current)
        current.projects.reject { |p| p.status == "retired" }.map(&:id) + current.paths.reject { |p| p.status == "retired" }.map(&:id)
      end

      def judgment_counts(window)
        counts = Hash.new { |hash, key| hash[key] = { "allow" => 0, "warn" => 0, "deny" => 0 } }
        recent_judgments(Time.now - window).each do |row|
          Array(row["targets"]).each do |target|
            project = target["project"]
            level = target["verdict"].to_s
            counts[project][level] += 1 if project && counts[project].key?(level)
          end
        end
        counts
      end

      def map(window_text)
        label, seconds = seconds_of(window_text, MAP_WINDOWS, "24h")
        current = ledger
        stamp = epoch(current)
        body = cached("map", 5, stamp, current.digest, label) { build_map(current, label, seconds, stamp) }
        [body, stamp ? "#{stamp}:#{label}" : nil]
      end

      def build_map(current, label, seconds, stamp)
        counts = judgment_counts(seconds)
        entries = []
        chips = { "shipped" => {}, "global" => {}, "exceptions" => {} }
        live_ids = []
        path_chain = begin
          Layers.load(nil, nil, ledger: current)
        rescue StandardError
          nil
        end
        seed_shipped_chips(chips, path_chain)
        current.projects.each do |project|
          entries << project_entry(current, project, counts)
          next if project.status == "retired"

          live_ids << project.id
          collect_chips(chips, project_chain(current, project), project.id)
        end
        current.paths.each do |entry|
          entries << path_entry(current, entry, counts, path_chain)
          next if entry.status == "retired"

          live_ids << entry.id
          collect_path_chips(chips, path_chain, entry)
        end
        add_exception_chips(chips, current, live_ids)
        layers = chips.transform_values { |list| list.values.map { |chip| { "id" => chip["id"], "name" => chip["name"], "reaches" => chip["reaches"].uniq } } }
        { "epoch" => stamp, "window" => label, "layers" => layers, "entries" => entries }
      end

      def seed_shipped_chips(chips, chain)
        layer = chain&.layers&.find { |entry| entry.name == "catalog" }
        layer ||= begin
          Layers.shipped_layer([])
        rescue StandardError
          nil
        end
        return unless layer

        layer.modules.each do |mod|
          name = module_name(mod)
          chips["shipped"][name] ||= { "id" => name, "name" => name, "reaches" => [] }
        end
      end

      def project_chain(current, project)
        return nil if project.status == "retired"

        Probes.resolved(project, current).chain
      rescue StandardError
        nil
      end

      def collect_chips(chips, chain, id)
        return unless chain

        chain.layers.each do |layer|
          band = CHIP_BANDS[layer.name]
          next unless band

          layer.modules.each do |mod|
            name = module_name(mod)
            chip = (chips[band][name] ||= { "id" => name, "name" => name, "reaches" => [] })
            chip["reaches"] << id
          end
        end
      end

      def collect_path_chips(chips, chain, entry)
        return unless chain

        chain.layers.each do |layer|
          if CHIP_BANDS.key?(layer.name)
            layer.modules.each do |mod|
              name = module_name(mod)
              (chips[CHIP_BANDS[layer.name]][name] ||= { "id" => name, "name" => name, "reaches" => [] })["reaches"] << entry.id
            end
          elsif layer.name == "path:#{entry.id}"
            layer.modules.each do |mod|
              name = module_name(mod)
              (chips["global"]["#{name}@#{entry.id}"] ||= { "id" => name, "name" => name, "reaches" => [] })["reaches"] << entry.id
            end
          end
        end
      end

      def add_exception_chips(chips, current, live_ids)
        return unless Exceptions.enabled?

        Exceptions.load.entries.each do |item|
          scope = item["scope"].is_a?(Hash) ? item["scope"] : {}
          reaches = if scope["global"] == true
                      live_ids
                    else
                      located = scope["project"] ? current.locate(scope["project"].to_s, paths: true) : nil
                      located ? [located.project ? located.project.id : located.entry.id] : []
                    end
          chips["exceptions"][item["id"]] = { "id" => item["id"], "name" => item["id"], "reaches" => reaches }
        end
      end

      def project_entry(current, project, counts)
        base = { "id" => project.id, "kind" => "project", "status" => project.status, "owner" => Manifest.owner_of(project),
                 "counts" => counts[project.id].dup, "description" => project.description.to_s, "summary" => Manifest.summary_of(project.description).to_s,
                 "digest" => nil, "globs" => globs_of(project), "error" => nil }
        return base if project.status == "retired"

        loaded = PolicySource.resolve(project, ledger: current)
        raw = PolicySource.raw(project, ledger: current)
        doc = raw && raw.policy
        base["digest"] = loaded.digest
        base["error"] = "#{loaded.finding['kind']}: #{loaded.finding['detail']}" if loaded.finding
        base["summary"] = owner_summary(project, doc)
        base["description"] = doc["description"].to_s if base["description"].empty? && doc.is_a?(Hash) && doc["description"]
        base
      rescue StandardError => e
        base.merge("error" => "#{e.class}: #{e.message}"[0, 300])
      end

      def globs_of(project)
        project.worktree_globs.map { |glob| { "glob" => glob, "matched" => Dir.glob(File.expand_path(glob)).length } }
      end

      def path_entry(current, entry, counts, chain)
        layer = chain && chain.layers.find { |item| item.name == "path:#{entry.id}" }
        { "id" => entry.id, "kind" => "path", "status" => entry.status, "owner" => Manifest.owner_of(entry), "counts" => counts[entry.id].dup,
          "description" => entry.description.to_s, "summary" => Manifest.summary_of(entry.description).to_s, "digest" => layer&.digest, "globs" => [],
          "error" => entry.status == "live" && chain && layer.nil? ? "the path policy #{entry.policy} did not load" : nil }
      end

      NO_POLICY_NOTE = "no policy file yet; the baseline applies".freeze

      def shelf_file(relative, missing_ok: false)
        store = Layers.store
        raise NotFound, "no global shelf is configured" unless store

        text = store.read(relative)
        note = nil
        if text.nil?
          raise NotFound, "#{relative} is not in the global shelf" unless missing_ok

          text = ""
          note = NO_POLICY_NOTE
        end

        src = store.source
        ref = if src.kind == :repo
                git(src.repo, "rev-parse", "--verify", "--quiet", "#{src.ref}^{commit}").to_s.strip
              else
                "dir"
              end
        { text: text, ref: ref.empty? ? src.ref.to_s : ref, repo: src.kind == :repo ? src.repo : nil, branch: src.kind == :repo ? src.ref : nil,
          file: src.kind == :repo && !src.path.to_s.empty? ? "#{src.path}/#{relative}" : relative, note: note }
      end

      def project_ahead(project, repo)
        trust = project.trust_ref.to_s
        trust_sha = git(repo, "rev-parse", "--verify", "--quiet", "#{trust}^{commit}").to_s.strip
        info = { "trust_ref" => trust_sha.empty? ? trust : "#{trust}@#{trust_sha}", "ahead" => 0, "ahead_files" => [] }
        return info if trust_sha.empty? || trust == "main"

        dir = File.dirname(project.policy)
        scope = dir == "." ? [] : ["--", dir]
        count = git(repo, "rev-list", "--count", "#{trust_sha}..main", *scope)
        files = git(repo, "diff", "--name-only", trust_sha, "main", *scope)
        info["ahead"] = count.to_i
        info["ahead_files"] = files.to_s.lines.map(&:chomp).reject(&:empty?)
        info
      end

      def rulebook_source_file(current, kind, id)
        case kind
        when "project"
          project = current.project(id)
          raise NotFound, "no project #{id}" unless project

          repo = File.expand_path(project.repo)
          ["main", project.trust_ref].uniq.each do |branch|
            text = git(repo, "show", "#{branch}:#{project.policy}")
            next if text.nil?

            sha = git(repo, "rev-parse", "--verify", "--quiet", "#{branch}^{commit}").to_s.strip
            return { text: text, ref: "#{branch}@#{sha}", repo: repo, branch: branch, file: project.policy, project: project }
          end
          raise NotFound, "#{project.policy} is not on main or #{project.trust_ref} in #{project.repo}"
        when "path"
          entry = current.path_entry(id)
          raise NotFound, "no path entry #{id}" unless entry

          shelf_file(entry.policy, missing_ok: true)
        when "global"
          raise NotFound, "the only global rulebook is global" unless id == "global"

          shelf_file("global.yml")
        when "module"
          raise NotFound, "#{id} is not a module name" unless Layers::MODULE_NAME.match?(id.to_s)

          shelf_file("modules/#{id}.yml")
        else raise NotFound, "no rulebook kind #{kind}"
        end
      end

      def source(kind, id)
        current = ledger
        found = rulebook_source_file(current, kind, id)
        doc = begin
          YAML.safe_load(found[:text], permitted_classes: [], aliases: false)
        rescue StandardError
          nil
        end
        out = { "yaml" => found[:text], "schema_id" => doc.is_a?(Hash) ? doc["schema"] : nil, "digest" => sha_text(found[:text]), "ref" => found[:ref] }
        out.merge!(project_ahead(found[:project], found[:repo])) if found[:project]
        out["note"] = found[:note] if found[:note]
        out
      end

      def catalog
        current = ledger
        cached("catalog", 30, epoch(current), current.digest) { build_catalog(current) }
      end

      def build_catalog(current)
        rulebooks = current.projects.reject { |p| p.status == "retired" }.map { |p| { "kind" => "project", "id" => p.id, "scope" => "project" } }
        rulebooks += current.paths.reject { |p| p.status == "retired" }.map { |p| { "kind" => "path", "id" => p.id, "scope" => "path" } }
        store = Layers.store
        rulebooks << { "kind" => "global", "id" => "global", "scope" => "global" } if store && store.global_doc
        usage = module_usage(current)
        modules = shelf_modules(store).map { |row| row.merge(usage_of(usage[row["name"]])) }
        packages = package_rows.map { |row| row.merge(usage_of(current.projects.select { |p| p.packages.any? { |item| item["name"] == row["name"] } }.map(&:id))) }
        { "rulebooks" => rulebooks, "modules" => modules, "packages" => packages, "examples" => example_rows }
      end

      def usage_of(ids)
        list = Array(ids).uniq.sort
        { "used_by" => list, "used_by_count" => list.length }
      end

      def module_usage(current)
        usage = Hash.new { |hash, key| hash[key] = [] }
        current.projects.reject { |p| p.status == "retired" }.each do |project|
          chain = project_chain(current, project)
          next unless chain

          chain.layers.each { |layer| layer.modules.each { |label| usage[module_name(label)] << project.id } }
        end
        usage
      end

      def example_rows
        files = Dir.glob(File.join(ROOT, "examples", "policy.*.yml")) + Dir.glob(File.join(ROOT, "examples", "*", "policy.yml"))
        files.sort.filter_map do |file|
          name = File.basename(file) == "policy.yml" ? File.basename(File.dirname(file)) : File.basename(file)[/\Apolicy\.(.+)\.yml\z/, 1]
          doc = YAML.safe_load(File.read(file), permitted_classes: [], aliases: false)
          next nil unless doc.is_a?(Hash)

          { "name" => name, "summary" => doc["summary"].to_s, "description" => doc["description"].to_s, "params" => {}, "used_by" => [], "used_by_count" => 0 }
        rescue StandardError
          nil
        end
      end

      def shelf_list(src, subdir, dirs: false)
        if src.kind == :dir
          base = File.join(src.root, subdir)
          return [] unless File.directory?(base)

          Dir.children(base).select { |name| File.directory?(File.join(base, name)) == dirs }.sort
        else
          path = [src.path, subdir].reject { |part| part.to_s.empty? }.join("/")
          out = git(src.repo, "ls-tree", dirs ? "-d" : "-r", "--name-only", "#{src.ref}:#{path}")
          out ? out.lines.map(&:chomp).reject(&:empty?).sort : []
        end
      end

      def shelf_modules(store)
        return [] unless store

        shelf_list(store.source, "modules").filter_map do |file|
          name = file.sub(/\.yml\z/, "")
          mod = store.find_module(name)
          next nil unless mod.respond_to?(:doc)

          params = (mod.doc["params"].is_a?(Hash) ? mod.doc["params"] : {}).transform_values do |spec|
            spec = spec.is_a?(Hash) ? spec : {}
            spec.merge("required" => !spec.key?("default"))
          end
          { "name" => name, "summary" => mod.doc["summary"].to_s, "description" => mod.doc["description"].to_s, "params" => params }
        end
      end

      def package_rows
        names = Dir.children(Packages::SHIPPED).select { |name| File.file?(File.join(Packages::SHIPPED, name, "package.yml")) }
        store = Layers.store
        names |= shelf_list(store.source, "packages", dirs: true) if store
        names.sort.filter_map do |name|
          package = Packages.find(name)
          { "name" => package.name, "version" => package.version, "summary" => package.summary.to_s, "description" => package.data["description"].to_s, "params" => package.params,
            "variants" => package.variants.keys, "default_variant" => package.default_variant, "origin" => package.origin }
        rescue Polispec::Error
          nil
        end
      end

      def composition(kind, id, action, path)
        raise NotFound, "no rulebook kind #{kind}" unless KINDS.include?(kind)
        raise Invalid.new("#{action.inspect} is not an action class") if action && !ACTION_CLASSES.include?(action)

        current = ledger
        base = cached("composition", 30, epoch(current), current.digest, kind, id) { build_composition(current, kind, id) }
        return base unless action

        base.merge("winners" => winners(base["__side"], action, path))
      end

      def build_composition(current, kind, id)
        ctx = composition_context(current, kind, id)
        chain = ctx[:chain]
        policy = ctx[:policy]
        layers = chain.layers
        mods = layers.map { |layer| layer_modules(layer, ctx[:stores]) }
        rules = []
        layers.each_with_index do |layer, index|
          lookup = mods[index].each_with_object({}) { |row, memo| row[:ids].each { |rid| memo[rid] = row[:name] } }
          Array(layer.rules).each do |rule|
            rules << rule_row(layer, rule, lookup[rule["id"]], chain, index)
          end
        end
        own = ctx[:own]
        {
          "name" => id, "kind" => kind, "status" => ctx[:status], "digest" => ctx[:digest], "description" => ctx[:description].to_s,
          "action_classes" => ACTION_CLASSES, "own_rules" => own ? Array(own.rules).length : 0,
          "layers" => layers.each_with_index.map { |layer, index| layer_row(layer, mods[index]) },
          "rules" => rules, "gates" => gate_rows(ctx), "freezes" => freeze_rows(ctx[:project], policy),
          "winners" => nil, "__side" => ctx[:side]
        }.tap { |body| body["note"] = ctx[:note] if ctx[:note] }
      end

      def composition_context(current, kind, id)
        case kind
        when "project"
          project = current.project(id)
          raise NotFound, "no project #{id}" unless project
          raise Invalid.new("project #{id} is retired") if project.status == "retired"

          side = Probes.resolved(project, current)
          loaded = PolicySource.resolve(project, ledger: current)
          if loaded.source == "defaults"
            finding = loaded.finding || { "kind" => "policy_missing", "detail" => "no policy loaded" }
            raise Invalid.new("the policy of #{id} did not load", [{ "code" => finding["kind"], "path" => project.policy, "message" => finding["detail"] }])
          end
          raise Invalid.new("the layers of #{id} did not compose", [{ "code" => "layers_invalid", "path" => "", "message" => "no layer chain" }]) unless side.chain

          raw = PolicySource.raw(project, ledger: current)
          src = Layers.local_source(project, loaded.source)
          { chain: side.chain, policy: side.policy, project: project, status: project.status, digest: loaded.digest, side: side,
            description: (raw && raw.policy["description"]) || project.description, own: side.chain.layers.find { |l| l.name == "repo" },
            stores: [Layers.local_store(src), Layers.store, Layers.shipped_store] }
        when "path"
          entry = current.path_entry(id)
          raise NotFound, "no path entry #{id}" unless entry

          shelf_chain(current, "path:#{id}", entry)
        when "global"
          raise NotFound, "the only global rulebook is global" unless id == "global"

          shelf_chain(current, "global", nil)
        else module_context(id)
        end
      end

      def shelf_chain(current, own_name, entry)
        full = Layers.load(nil, nil, ledger: current)
        errors = []
        layers = full.layers.reject { |l| l.name.start_with?("path:") }
        note = nil
        if entry
          if Layers.store.read(entry.policy).nil?
            note = NO_POLICY_NOTE
          else
            layer = Layers.path_layer(Layers.store, entry, errors)
            unless layer
              raise Invalid.new("the path policy did not load", errors.map { |m| { "code" => "path_invalid", "path" => entry.policy, "message" => m } })
            end
            layers << layer
          end
        end
        chain = Layers::Chain.new(layers: layers, errors: full.errors, profile: nil, applied: full.applied)
        own = layers.find { |l| l.name == own_name }
        extras = own ? own.extras : { "freezes" => [], "to_test" => [], "to_stable" => [] }
        policy = { "freezes" => extras["freezes"], "promotion" => { "to_test" => { "gates" => extras["to_test"] }, "to_stable" => { "gates" => extras["to_stable"] } } }
        doc = entry ? nil : Layers.store&.global_doc
        { chain: chain, policy: policy, project: nil, status: entry ? entry.status : "live", digest: own&.digest, side: nil,
          description: entry ? entry.description : (doc && doc["description"]), own: own, stores: [Layers.store, Layers.shipped_store], note: note }
      end

      def module_context(id)
        name = id.to_s == "global" ? "global" : id
        found = catalog_module(name) || Layers.store&.find_module(name)
        raise NotFound, "no module #{id}" unless found.respond_to?(:doc)

        layer = Layers::Layer.new(name: "module", source: module_source(name), digest: sha_text(found.text), rules: Array(found.doc["rules"]), modules: [name],
                                  extras: Layers.send(:extras_of, [found.doc]))
        extras = layer.extras
        policy = { "freezes" => extras["freezes"], "promotion" => { "to_test" => { "gates" => extras["to_test"] }, "to_stable" => { "gates" => extras["to_stable"] } } }
        { chain: Layers::Chain.new(layers: [layer], errors: [], profile: nil, applied: []), policy: policy, project: nil, status: "live", digest: layer.digest,
          side: nil, description: found.doc["description"] || found.doc["summary"], own: layer, stores: [Layers.store, Layers.shipped_store] }
      end

      def layer_modules(layer, stores)
        Array(layer.modules).map do |label|
          name = module_name(label)
          found = label.to_s.start_with?("catalog:") ? catalog_module(name) : stores.compact.map { |store| store.find_module(name) }.find { |item| item.respond_to?(:doc) }
          { label: label, name: name, kind: found ? found.origin.to_s : "unknown", params: module_params(label),
            ids: found ? Array(found.doc["rules"]).map { |rule| rule["id"] } : [], rules: found ? Array(found.doc["rules"]).length : 0 }
        end
      end

      def layer_row(layer, mods)
        { "id" => layer_id(layer.name), "name" => layer_label(layer.name), "rule_count" => Array(layer.rules).length, "module_count" => mods.length,
          "modules" => mods.map { |row| { "name" => row[:name], "kind" => row[:kind], "params" => row[:params], "rules" => row[:rules] } } }
      end

      def rule_row(layer, rule, module_name, chain, index)
        match = rule["match"].is_a?(Hash) ? rule["match"] : {}
        env = match["env"]
        overrider = chain.applied.find { |upper, rid, _| upper == index && rid == rule["id"] }
        {
          "id" => rule["id"].to_s, "layer" => layer_id(layer.name), "module" => module_name,
          "verdicts" => ENVS.to_h { |name| [name, env.nil? || env == name ? rule["verdict"] : nil] },
          "applies_to" => applies_to(match), "overrides" => rule["overrides"] ? [rule["overrides"]] : [],
          "overridden_by" => overrider ? overrider[2]["id"] : nil, "description" => rule["reason"].to_s,
          "source" => [layer.source, module_name ? module_source(module_name) : nil].compact.join(" "),
          "yaml" => YAML.dump(rule).sub(/\A---\n/, "")
        }
      end

      def applies_to(match)
        list = Array(match["class"]).map(&:to_s)
        %w[tool path ref server operation domain role].each { |key| list << "#{key} #{match[key]}" if match[key] }
        Array(match["shape"]).each { |shape| list << "shape #{shape}" }
        list << "crosses #{match['crosses']}" if match["crosses"]
        list << "destructive" if match["destructive"]
        list
      end

      def winners(side, action_class, path)
        return nil unless side

        ENVS.each_with_object({}) do |env, memo|
          hint = { "env" => env }
          hint["path"] = path if path && !path.empty?
          action = Action.new(class: action_class, env_hint: hint, raw: "web composition")
          context = { cwd: side.cwd, ledger: side.ledger, global: side.global, tool: "web", policies: { side.id => side.policy } }
          verdict = Engine.explain([action], side.target, context).verdict
          rule_id = verdict.rule_id.to_s
          if rule_id.empty? || rule_id == "NO-RULE"
            memo[env] = nil
            next
          end
          layer = side.chain && side.chain.layers.find { |item| Array(item.rules).any? { |rule| rule["id"] == rule_id } }
          rule = layer && layer.rules.find { |item| item["id"] == rule_id }
          memo[env] = { "verdict" => verdict.level.to_s, "rule" => rule_id, "layer" => layer ? layer_id(layer.name) : nil,
                        "overrides" => rule && rule["overrides"] ? [rule["overrides"]] : [] }
        rescue StandardError
          memo[env] = nil
        end
      end

      def gate_label(gate)
        gate["builtin"] ? gate["builtin"].to_s : "runs #{gate['run']}"
      end

      def gate_met(project, gate, transition, policy, shas)
        sha = shas[transition]
        case gate["builtin"]
        when "sha_ran_on_test" then sha ? Operator::Gates.ran_on?(project.id, sha, "test") : nil
        when "sha_ran_on" then sha ? Operator::Gates.ran_on?(project.id, sha, Operator::Gates.row_env(gate["env"] || "test")) : nil
        when "not_frozen" then Freeze.active(policy, "promote.#{transition}", project: project).empty?
        when "requires_live" then project.status == "live"
        when "health_required" then Operator::Gates.health_required_errors(policy).empty?
        when "clean_tree" then !Operator::Git.new(File.expand_path(project.repo)).dirty?
        end
      rescue StandardError
        nil
      end

      def promotion_shas(project, policy)
        git = Operator::Git.new(File.expand_path(project.repo))
        branches = ref_branches(project, policy)
        { "to_test" => git.rev(branches["main"]), "to_stable" => git.rev(branches["test"]) }
      rescue StandardError
        {}
      end

      def gate_rows(ctx)
        policy = ctx[:policy]
        project = ctx[:project]
        promotion = policy["promotion"].is_a?(Hash) ? policy["promotion"] : {}
        shas = project ? promotion_shas(project, policy) : {}
        %w[to_test to_stable].flat_map do |transition|
          section = promotion[transition].is_a?(Hash) ? promotion[transition] : {}
          (Array(section["preflight"]) + Array(section["gates"])).map do |gate|
            met = project ? gate_met(project, gate, transition, policy, shas) : nil
            { "id" => gate["id"].to_s, "transition" => transition, "requirement" => gate_label(gate),
              "status" => met.nil? ? "not_evaluated" : (met ? "passing" : "failing") }
          end
        end
      end

      def freeze_rows(project, policy)
        Array(policy["freezes"]).map do |freeze|
          scopes = Array(freeze["applies_to"])
          windows = scopes.flat_map { |scope| Freeze.active(policy, scope, project: project).select { |w| w.id == freeze["id"] } }
          window = windows.first
          env = scopes.map { |scope| scope.sub("promote.to_", "") }.join(", ")
          { "id" => freeze["id"].to_s, "env" => env, "start" => window&.from&.utc&.iso8601 || freeze["from"], "end" => window&.until_at&.utc&.iso8601 || freeze["until"],
            "reason" => (freeze["reason"] || freeze["source"] || freeze["kind"]).to_s, "active" => !windows.empty? }
        end
      rescue StandardError
        []
      end

      def tags_by_commit(repo)
        out = git(repo, "for-each-ref", "refs/tags", "--format=%(refname:short)\t%(objectname)\t%(*objectname)")
        return {} unless out

        out.lines.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |line, memo|
          name, plain, peeled = line.chomp.split("\t", 3)
          memo[peeled.to_s.empty? ? plain : peeled] << name
        end
      end

      def history(kind, id, from, to)
        current = ledger
        found = rulebook_source_file(current, kind, id)
        repo = found[:repo]
        unless from.to_s.empty? && to.to_s.empty?
          raise Invalid.new("history needs both from and to") if from.to_s.empty? || to.to_s.empty?
          raise Invalid.new("from and to must be commits or tags") unless [from, to].all? { |ref| ref.match?(REF_FORMAT) && !ref.include?("..") }
          raise NotFound, "#{id} has no git history to compare" unless repo

          return QUIET.synchronize { Plan.compare_refs(repo, found[:file], from, to) }
        end
        return { "commits" => [] } unless repo

        out = git(repo, "log", "--follow", "-n", "200", "--format=%H%x1f%aI%x1f%an%x1f%s", found[:branch], "--", found[:file])
        tags = tags_by_commit(repo)
        commits = out.to_s.lines.map do |line|
          sha, date, author, subject = line.chomp.split("\u001f", 4)
          { "sha" => sha, "date" => date, "author" => author, "subject" => subject.to_s, "tags" => tags.key?(sha) ? tags[sha] : [] }
        end
        { "commits" => commits }
      rescue Operator::Failure => e
        raise Invalid.new(e.message, Array(e.payload["problems"]).map { |text| { "code" => e.code.to_s, "path" => "", "message" => text } })
      end

      def ref_branches(project, policy)
        envs = policy.is_a?(Hash) && policy["environments"].is_a?(Hash) ? policy["environments"] : {}
        branch = lambda do |name, fallback|
          spec = envs[name]
          spec.is_a?(Hash) && spec["branch"] ? spec["branch"].to_s : fallback
        end
        { "main" => branch.call("dev", "main"), "test" => branch.call("test", "test"), "stable" => branch.call("prod", project.trust_ref) }
      end

      def ref_digest(current, project, repo, branch)
        data, sha, digest, errors = Environments.load_policy_text(repo, branch, project.policy)
        return nil unless data.is_a?(Hash) && errors.nil?

        _, effective = Layers.compose(project, data, digest, ledger: current, local: Layers.local_source(project, "#{branch}:#{sha}"))
        effective
      rescue StandardError
        nil
      end

      PIPELINE_THREADS = 4
      PIPELINE_ROW_TTL = 60

      @rows = {}
      @rows_lock = Mutex.new

      def pipeline
        current = ledger
        stamp = [epoch(current), current.digest]
        projects = current.projects.reject { |p| p.status == "retired" }
        findings = Lazy.new { Description.doctor_findings(current).group_by { |item| item["project"] } }
        keyed = pipeline_map(projects) { |project| pipeline_lookup(project, stamp) }
        misses = keyed.each_index.select { |index| keyed[index][:row].nil? }
        unless misses.empty?
          QUIET.synchronize do
            computed = pipeline_map(misses) { |index| pipeline_store(current, projects[index], keyed[index], findings) }
            misses.each_with_index { |index, at| keyed[index][:row] = computed[at] }
          end
        end
        rows = keyed.map { |item| item[:row] }
        @rows_lock.synchronize { @rows.keep_if { |id, _| projects.any? { |project| project.id == id } } }
        { "projects" => rows }
      end

      class Lazy
        def initialize(&block)
          @block = block
          @lock = Mutex.new
          @done = false
        end

        def value
          @lock.synchronize do
            unless @done
              @value = @block.call
              @done = true
            end
            @value
          end
        end
      end

      def pipeline_map(items)
        results = Array.new(items.length)
        queue = Queue.new
        items.each_index { |index| queue << index }
        workers = Array.new([PIPELINE_THREADS, items.length].min) do
          Thread.new do
            PolicySource.memoize do
              loop do
                index = begin
                  queue.pop(true)
                rescue ThreadError
                  break
                end
                results[index] = yield(items[index])
              end
            end
          end
        end
        workers.each(&:join)
        results
      end

      def pipeline_fingerprint(project)
        repo = File.expand_path(project.repo)
        return "missing" unless File.directory?(repo)

        listing = git(repo, "for-each-ref", "--format=%(objectname) %(refname)", "refs/heads", "refs/tags")
        Digest::SHA256.hexdigest(listing.to_s)
      end

      def pipeline_lookup(project, stamp)
        key = [project.id, project.repo, project.trust_ref, project.policy, pipeline_fingerprint(project), *stamp]
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        hit = @rows_lock.synchronize { @rows[project.id] }
        row = hit && hit[:key] == key && now - hit[:at] < PIPELINE_ROW_TTL ? hit[:row] : nil
        { key: key, at: now, row: row }
      end

      def pipeline_store(current, project, item, findings)
        row = pipeline_row(current, project, findings)
        @rows_lock.synchronize { @rows[project.id] = { key: item[:key], at: item[:at], row: row } }
        row
      end

      def pipeline_row(current, project, findings = nil)
        repo = File.expand_path(project.repo)
        loaded = PolicySource.resolve(project, ledger: current)
        policy = loaded.policy
        branches = ref_branches(project, policy)
        git = Operator::Git.new(repo)
        refs = {}
        missing = []
        if File.directory?(repo)
          branches.each do |name, branch|
            sha = git.rev(branch)
            if sha
              refs[name] = { "sha" => sha, "policy_digest" => ref_digest(current, project, repo, branch) }
            else
              refs[name] = nil
              missing << "#{branch} (#{name})"
            end
          end
        else
          branches.each_key { |name| refs[name] = nil }
          missing << "repository #{project.repo}"
        end
        row = { "id" => project.id, "repo" => project.repo, "refs" => refs, "drift" => { "packages" => 0 },
                "doctor" => { "error" => 0, "warning" => 0, "info" => 0, "findings" => [] }, "freezes" => { "active" => 0 },
                "gate" => { "status" => "passing", "requirements" => [] } }
        row["refs_error"] = "missing: #{missing.join(', ')}" unless missing.empty?
        fill_doctor(row, current, project, findings)
        fill_freezes(row, project, policy)
        fill_gate(row, project, policy, refs)
        row
      rescue StandardError => e
        { "id" => project.id, "repo" => project.repo, "refs" => { "main" => nil, "test" => nil, "stable" => nil }, "refs_error" => "#{e.class}: #{e.message}"[0, 300],
          "drift" => { "packages" => 0 }, "doctor" => { "error" => 0, "warning" => 0, "info" => 0, "findings" => [] }, "freezes" => { "active" => 0 },
          "gate" => { "status" => "failing", "requirements" => [] } }
      end

      def fill_doctor(row, current, project, findings = nil)
        list = []
        DoctorCommand.new.send(:check_project, current, project, list)
        described = findings ? Array(findings.value[project.id]) : Description.doctor_findings(current).select { |item| item["project"] == project.id }
        list.concat(described)
        row["drift"]["packages"] = list.count { |item| %w[package_upgrade_available package_file_drift].include?(item["kind"]) }
        list.each do |item|
          severity = { "warn" => "warning", "info" => "info" }.fetch(item["severity"].to_s, "error")
          row["doctor"][severity] += 1
          row["doctor"]["findings"] << { "severity" => severity, "code" => item["kind"].to_s, "message" => item["detail"].to_s }
        end
      rescue StandardError
        nil
      end

      def fill_freezes(row, project, policy)
        ids = %w[promote.to_test promote.to_stable desk.dispatch].flat_map { |scope| Freeze.active(policy, scope, project: project).map(&:id) }
        row["freezes"]["active"] = ids.uniq.length
      rescue StandardError
        nil
      end

      def fill_gate(row, project, policy, refs)
        section = policy["promotion"].is_a?(Hash) ? policy["promotion"]["to_test"] : nil
        gates = section.is_a?(Hash) ? Array(section["preflight"]) + Array(section["gates"]) : []
        shas = { "to_test" => refs["main"] && refs["main"]["sha"] }
        failing = false
        gates.each do |gate|
          met = gate_met(project, gate, "to_test", policy, shas)
          failing = true if met == false
          label = met.nil? ? "#{gate['id']}: #{gate_label(gate)} (not evaluated here)" : "#{gate['id']}: #{gate_label(gate)}"
          row["gate"]["requirements"] << { "id" => gate["id"].to_s, "label" => label, "met" => met == true }
        end
        row["gate"]["status"] = failing ? "failing" : "passing"
      rescue StandardError
        nil
      end

      def rule_index(current)
        index = {}
        current.projects.reject { |p| p.status == "retired" }.each do |project|
          chain = project_chain(current, project)
          next unless chain

          chain.layers.each do |layer|
            Array(layer.rules).each do |rule|
              entry = (index[rule["id"]] ||= { layer: layer_id(layer.name), projects: [] })
              entry[:projects] << project.id unless entry[:projects].include?(project.id)
            end
          end
        end
        index
      end

      def last_fired
        cached("last_fired", 60) do
          latest = {}
          Judgments.each_record do |row, _|
            Array(row["targets"]).each do |target|
              ids = Array(target["rows"]).map { |item| item["rule_id"] } << target["rule_id"]
              ids.compact.each { |rid| latest[rid] = row["ts"] if latest[rid].nil? || row["ts"].to_s > latest[rid] }
            end
          end
          latest
        end
      end

      def action_label(row)
        parts = row["path"].to_s.split("/").reject(&:empty?).first(2)
        prefix = row["path"].to_s.start_with?("/") ? "/" : ""
        [row["action_class"], parts.empty? ? nil : "#{prefix}#{parts.join('/')}"].compact.join(" ")
      end

      def heatmap(window_text)
        label, seconds = seconds_of(window_text, HEAT_WINDOWS, "14d")
        current = ledger
        cached("heatmap", 5, epoch(current), current.digest, label) { build_heatmap(current, label, seconds) }
      end

      def build_heatmap(current, label, seconds)
        index = rule_index(current)
        projects = current.projects.reject { |p| p.status == "retired" }
        known = projects.map(&:id)
        hits = Hash.new { |hash, key| hash[key] = Hash.new(0) }
        none = Hash.new { |hash, key| hash[key] = { "count" => 0, "actions" => Hash.new(0) } }
        recent_judgments(Time.now - seconds).each do |record|
          Array(record["targets"]).each do |target|
            next unless known.include?(target["project"])

            rows = Array(target["rows"])
            rows = [{ "rule_id" => target["rule_id"], "env" => target["env"], "action_class" => nil }] if rows.empty?
            rows.each do |row|
              key = "#{target['project']}/#{row['env'] || target['env']}"
              rule_id = row["rule_id"].to_s
              next if rule_id.empty?

              if rule_id == "NO-RULE"
                none[key]["count"] += 1
                none[key]["actions"][action_label(row)] += 1
              else
                hits[rule_id][key] += 1
              end
            end
          end
        end
        rules = hits.map { |rid, map| { "rule_id" => rid, "layer" => index.key?(rid) ? index[rid][:layer] : "engine", "hits" => map } }.sort_by { |row| row["rule_id"] }
        dead_ids = index.keys - hits.keys
        fired = dead_ids.empty? ? {} : last_fired
        dead = dead_ids.sort.map do |rid|
          { "rule_id" => rid, "layer" => index[rid][:layer], "projects" => index[rid][:projects].length, "last_fired" => fired[rid], "added" => nil }
        end
        no_rule = none.transform_values { |value| { "count" => value["count"], "top_action" => value["actions"].max_by { |_, count| count }&.first.to_s } }
        { "window" => label, "projects" => projects.map { |p| { "id" => p.id, "envs" => ENVS } }, "rules" => rules, "no_rule" => no_rule, "dead" => dead }
      end

      def changes_for(sessions, change)
        at = Sessions.stamp(change["ts"])
        classes = Array(change["effects"]).map { |item| item["class"] }
        sessions.map do |session|
          status = :pending
          crossed = session["epochs"].any? do |stamp, ep|
            ep == change["epoch_after"] || (Sessions.stamp(stamp) && at && Sessions.stamp(stamp) > at && ep != change["epoch_before"])
          end
          version = Effect.launcher_version(session["launcher"])
          stale = version && Effect.version_less?(version, Polispec.version)
          if classes.include?("reload") && stale then status = :flagged
          elsif classes.include?("trust") && session["harness"] == "codex" then status = :flagged
          elsif crossed then status = :crossed
          end
          [status, { "id" => session["session_id"], "harness" => session["harness"], "badges" => session_badges(session, epoch(nil), Changes.records) }]
        end
      end

      def changes(since_text)
        _, seconds = seconds_of(since_text, nil, "24h")
        cutoff = Time.now - seconds
        records = Changes.records.select { |entry| (at = Sessions.stamp(entry["ts"])) && at >= cutoff }
        sessions = cached("active_sessions", 5) { Sessions.active(86_400) }
        rows = records.reverse.map do |entry|
          grouped = changes_for(sessions, entry)
          entry.reject { |key, _| %w[schema prev digest].include?(key) }.merge(
            "crossed" => grouped.select { |s, _| s == :crossed }.map(&:last), "pending" => grouped.select { |s, _| s == :pending }.map(&:last),
            "flagged" => grouped.select { |s, _| s == :flagged }.map(&:last)
          )
        end
        { "changes" => rows }
      end

      def session_badges(item, now_epoch, all_changes)
        list = []
        list << (item["epoch"] == now_epoch ? "current" : "pending") if item["epoch"] && now_epoch
        version = Effect.launcher_version(item["launcher"])
        list << "reload_needed" if version && Effect.version_less?(version, Polispec.version)
        started = Sessions.stamp(item["last_session_event"] || item["first_seen"])
        later = all_changes.select { |change| (at = Sessions.stamp(change["ts"])) && started && at > started }
        list << "stale_briefing" if later.any? { |change| Array(change["effects"]).any? { |e| e["class"] == "new_session" } }
        list << "untrusted_hook" if item["harness"] == "codex" && later.any? { |change| Array(change["effects"]).any? { |e| e["class"] == "trust" } }
        list
      end

      def sessions(window_text)
        label, seconds = seconds_of(window_text, SESSION_WINDOWS, "1h")
        current = ledger
        now_epoch = epoch(current)
        cached("sessions", 3, now_epoch, label) do
          meta = Sessions.records.each_with_object({}) { |row, memo| memo[row["session_id"]] = row if row["session_id"] }
          all_changes = Changes.records
          digests = {}
          rows = Sessions.active(seconds).map do |item|
            record = meta[item["session_id"]] || {}
            projects = item["projects"].map do |pid, seen|
              project = current.project(pid)
              digests[pid] ||= project && project.status != "retired" ? PolicySource.resolve(project, ledger: current).digest : nil
              { "id" => pid, "policy_digest_seen" => seen, "current_digest" => digests[pid], "in_step" => !seen.nil? && seen == digests[pid] }
            end
            { "id" => item["session_id"], "harness" => item["harness"], "agent_type" => record["agent_type"], "started" => item["first_seen"],
              "last_call" => item["last_call"], "runtime_version" => Effect.launcher_version(item["launcher"]), "epoch" => item["epoch"],
              "badges" => session_badges(item, now_epoch, all_changes), "projects" => projects }
          end
          { "epoch" => now_epoch, "window" => label, "sessions" => rows.sort_by { |row| row["last_call"].to_s }.reverse }
        end
      end

      def judgments(since, session, project, rule, limit)
        count = limit.to_s.empty? ? 200 : Integer(limit, 10)
        raise Invalid.new("limit must be between 1 and #{JUDGMENT_LIMIT}") unless count.between?(1, JUDGMENT_LIMIT)

        floor = Time.now - Judgments::WINDOW_SECONDS
        cutoff = [time_param(since, 3600), floor].max
        rows = recent_judgments(cutoff).select { |row| row["ts"].to_s > cutoff.utc.iso8601(3) || since.to_s.empty? }
        rows = rows.select { |row| judgment_match?(row, session, project, rule) }
        { "judgments" => rows.last(count).map { |row| stripped(row) } }
      rescue ArgumentError
        raise Invalid.new("limit must be an integer")
      end

      def judgment_match?(row, session, project, rule)
        return false if session.to_s != "" && row.dig("action", "session_id") != session
        targets = Array(row["targets"])
        return false if project.to_s != "" && targets.none? { |target| target["project"] == project }
        return false if rule.to_s != "" && targets.none? { |target| target["rule_id"] == rule || Array(target["rows"]).any? { |item| item["rule_id"] == rule } }

        true
      end

      def manifest_index
        document = Manifest.validate!("index", Manifest.index(ledger: ledger))
        document.merge("published" => published_indexes(document["user"]))
      rescue Operator::Failure => e
        raise Unavailable, e.message
      end

      def published_indexes(own)
        dir = Manifest.index_dir
        return [] unless File.directory?(dir)

        Dir.glob(File.join(dir, "*.json")).sort.filter_map do |file|
          next nil if File.basename(file, ".json") == own
          next { "user" => File.basename(file, ".json"), "host" => nil, "generated_at" => nil, "entries" => [], "error" => "the index file is larger than 1 MiB" } if File.size(file) > 1_048_576

          data = JSON.parse(File.read(file))
          problems = Schema.validate("index", data)
          next data if problems.empty?

          { "user" => File.basename(file, ".json"), "host" => nil, "generated_at" => nil, "entries" => [], "error" => problems.first(3).map { |e| "#{e.pointer} #{e.message}".strip }.join("; ") }
        rescue StandardError => e
          { "user" => File.basename(file, ".json"), "host" => nil, "generated_at" => nil, "entries" => [], "error" => "#{e.class}: #{e.message}"[0, 200] }
        end
      end

      def manifest(id)
        current = ledger
        generated = Manifest.validate!("manifest", Manifest.for(id, ledger: current))
        project = current.project(id)
        { "root" => project ? project.repo : (current.path_entry(id)&.path), "generated" => manifest_view(generated), "authored" => project ? authored_app(project) : nil }
      rescue Operator::Failure => e
        raise NotFound, e.message if e.code == "unknown_entry"

        raise Unavailable, e.message
      end

      def manifest_view(doc)
        view = doc.dup
        promotions = doc["promotions"].is_a?(Hash) ? doc["promotions"] : {}
        view["environments"] = doc["environments"].to_h.to_h do |name, spec|
          stamp = promotions[name] || promotions[name == "prod" ? "stable" : name]
          [name, { "ref" => spec["branch"], "policy_digest" => spec["policy_digest"], "last_promotion" => stamp && stamp["at"] }]
        end
        layers = doc.dig("layers", "layers").to_a
        packages = doc.dig("layers", "packages").to_a.map { |item| item["name"] }
        view["layers"] = layers.map { |row| { "name" => row["layer"], "kind" => row["layer"].to_s.split(":").first, "modules" => row["modules"], "packages" => row["layer"] == "repo" ? packages : [] } }
        view["roster"] = doc["roster"].to_h.map { |role, slot| { "role" => role }.merge(slot) }
        groups = doc["findings"].is_a?(Hash) ? doc["findings"] : {}
        findings = groups.flat_map { |severity, list| list.map { |item| { "severity" => severity == "warn" ? "warning" : severity, "code" => item["kind"], "message" => item["detail"] } } }
        view["doctor"] = { "error" => groups["error"].to_a.length, "warning" => groups["warn"].to_a.length, "info" => groups["info"].to_a.length, "findings" => findings }
        view
      end

      def authored_app(project)
        return nil if project.status == "retired"

        text = git(File.expand_path(project.repo), "show", "#{project.trust_ref}:#{Manifest::APP_FILE}")
        return nil if text.nil?

        findings = []
        begin
          data = Schema::Document.parse(text, Manifest::APP_FILE)
          Schema.validate("app", data).each { |e| findings << { "severity" => "error", "code" => "schema", "message" => "#{e.pointer} #{e.message}".strip } }
        rescue Schema::Document::ParseError => e
          findings << { "severity" => "error", "code" => "parse", "message" => e.message }
        end
        { "path" => Manifest::APP_FILE, "text" => text, "valid" => findings.empty?, "findings" => findings }
      end

      def layout_path
        File.join(Web.dir, "layout.json")
      end

      def layout
        data = JSON.parse(File.read(layout_path))
        { "positions" => data.is_a?(Hash) && data["positions"].is_a?(Hash) ? data["positions"] : {} }
      rescue SystemCallError, JSON::ParserError
        { "positions" => {} }
      end
    end
  end
end
