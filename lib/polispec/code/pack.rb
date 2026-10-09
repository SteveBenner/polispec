#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    class Node
      INACTIVE = %w[draft deprecated rejected].freeze
      attr_reader :id, :spec, :data, :parent, :items

      def initialize(spec, data, parent)
        @spec = spec
        @data = data
        @parent = parent
        @id = data["id"].to_s
        @items = []
      end

      def composite?
        data.key?("subpolicies")
      end

      def rule?
        !composite?
      end

      def title
        data["title"].to_s
      end

      def statement
        data["statement"].to_s
      end

      def level
        data["level"].to_s
      end

      def severity
        data["severity"].to_s
      end

      def lifecycle
        data["lifecycle"]
      end

      def execution
        data["execution"].is_a?(Hash) ? data["execution"] : {}
      end

      def klass
        execution["class"].to_s
      end

      def phases
        Array(execution["phases"])
      end

      def enforcer
        execution["enforcer"].is_a?(Hash) ? execution["enforcer"] : nil
      end

      def lens
        execution["lens"].is_a?(Hash) ? execution["lens"] : nil
      end

      def applies_if
        execution["applies_if"].is_a?(Hash) ? execution["applies_if"] : nil
      end

      def control
        data["control"].is_a?(Hash) ? data["control"] : nil
      end

      def blocking_level?
        BLOCKING_LEVELS.include?(level)
      end

      def ratchet?
        data["ratchet"] != false
      end

      def active?
        node = self
        while node
          return false if INACTIVE.include?(node.lifecycle)

          node = node.parent
        end
        true
      end

      def effective_scope
        node = self
        while node
          return node.data["scope"] if node.data["scope"].is_a?(Hash)

          node = node.parent
        end
        {}
      end

      def effective_models(defaults)
        chain = []
        node = self
        while node
          chain.unshift(node.data["models"]) if node.data["models"].is_a?(Hash)
          node = node.parent
        end
        chain.reduce(defaults || {}) { |memo, item| memo.merge(item) }
      end

      def each_rule(&block)
        return enum_for(:each_rule) unless block

        yield self if rule?
        items.each { |kind, item| item.each_rule(&block) if kind == :node }
      end

      def each_node(&block)
        return enum_for(:each_node) unless block

        yield self
        items.each { |kind, item| item.each_node(&block) if kind == :node }
      end

      def line
        "[#{id}] #{level} #{statement}"
      end
    end

    class Spec
      attr_reader :path, :file, :data, :root

      def initialize(path, file, data)
        @path = path
        @file = file
        @data = data
        @root = nil
      end

      def attach(root)
        @root = root
      end

      def languages
        activation = data["activation"]
        activation.is_a?(Hash) ? Array(activation["languages"]) : []
      end

      def detection
        data["detection"].is_a?(Hash) ? data["detection"] : {}
      end

      def version
        data["version"].to_s
      end

      def parent_path
        data["parent"]
      end

      def defaults
        data["defaults"].is_a?(Hash) ? data["defaults"] : {}
      end

      def depth
        path.count("/")
      end

      def refs
        found = []
        walk = lambda do |node|
          node.items.each do |kind, item|
            if kind == :ref
              found << item
            else
              walk.call(item)
            end
          end
        end
        walk.call(root) if root
        found
      end
    end

    class Pack
      SPEC_FILE = %r{\Aspecs/(.+)/spec\.yml\z}.freeze
      attr_reader :source, :specs, :nodes, :duplicates, :load_errors, :repo

      def self.load(ref: nil, repo: nil)
        repo ||= Paths.specs_repo
        ref = ref.to_s.empty? ? DEFAULT_REF : ref.to_s
        source = ref == "worktree" ? DirSource.new(repo) : GitSource.new(repo, ref)
        new(source, repo)
      end

      def initialize(source, repo)
        @source = source
        @repo = repo
        @specs = {}
        @nodes = {}
        @duplicates = []
        @load_errors = []
        build(parsed_documents)
      end

      def digest_for(spec_paths)
        "sha256:#{Digest::SHA256.hexdigest([source.tree_id, *spec_paths].join("\0"))}"
      end

      def spec_for_node(node)
        specs[node.spec]
      end

      def inherited_defaults(path)
        parts = path.split("/")
        merged = {}
        parts.each_index do |index|
          spec = specs[parts[0..index].join("/")]
          next unless spec

          merged = deep_merge(merged, spec.defaults)
        end
        merged
      end

      def budget_lines(path)
        value = inherited_defaults(path).dig("inject", "budget_lines")
        value.is_a?(Integer) ? value : 60
      end

      def models_for(node)
        node.effective_models(inherited_defaults(node.spec)["models"])
      end

      def confidence_floor(node)
        floor = models_for(node)["confidence_floor"]
        floor.is_a?(Numeric) ? floor : 0.7
      end

      def rules
        nodes.values.select(&:rule?)
      end

      def read(path)
        source.read(path)
      end

      def exist?(path)
        source.exist?(path)
      end

      private

      def deep_merge(base, other)
        base.merge(other) { |_key, left, right| left.is_a?(Hash) && right.is_a?(Hash) ? deep_merge(left, right) : right }
      end

      def parsed_documents
        cache = cache_path
        if cache && File.file?(cache)
          begin
            raw = JSON.parse(File.read(cache))
            return [raw["docs"], raw["errors"]] if raw["docs"].is_a?(Hash)
          rescue SystemCallError, JSON::ParserError
            nil
          end
        end
        docs, errors = parse_sources
        store_cache(cache, docs, errors)
        [docs, errors]
      end

      def cache_path
        return nil unless source.kind == :git

        File.join(Paths.pack_cache_dir, "pack-#{Polispec.version}-#{source.tree_id}.json")
      end

      def store_cache(cache, docs, errors)
        return unless cache

        Code.write_atomic(cache, JSON.generate("docs" => docs, "errors" => errors))
      rescue SystemCallError
        nil
      end

      def parse_sources
        files = source.paths.select { |path| path.match?(SPEC_FILE) }
        texts = source.read_many(files)
        docs = {}
        errors = []
        files.each do |file|
          begin
            data = Schema::Document.parse(texts[file].to_s, file)
            docs[file] = data
          rescue Schema::Document::ParseError => e
            errors << [file, e.message]
          end
        end
        [docs, errors]
      end

      def build(parsed)
        docs, errors = parsed
        @load_errors = errors.map { |file, message| [file, message] }
        docs.keys.sort.each do |file|
          data = docs[file]
          unless data.is_a?(Hash)
            @load_errors << [file, "spec document is not a mapping"]
            next
          end
          path = file.match(SPEC_FILE)[1]
          spec = Spec.new(path, file, data)
          @specs[path] = spec
          policy = data["policy"]
          next unless policy.is_a?(Hash)

          spec.attach(build_node(spec, policy, nil))
        end
      end

      def build_node(spec, data, parent)
        node = Node.new(spec.path, data, parent)
        register(node, spec)
        Array(data["subpolicies"]).each do |item|
          if item.is_a?(Hash) && item.keys == ["ref"]
            node.items << [:ref, item["ref"].to_s]
          elsif item.is_a?(Hash)
            node.items << [:node, build_node(spec, item, node)]
          end
        end
        node
      end

      def register(node, _spec)
        if @nodes.key?(node.id)
          @duplicates << [node.id, @nodes[node.id].spec, node.spec]
        else
          @nodes[node.id] = node
        end
      end
    end
  end
end
