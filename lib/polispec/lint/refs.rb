#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Lint
    module Refs
      VERSION_FILES = [
        ["polispec.rplugin.yml", %w[version]],
        ["specs/app.yml", %w[version]],
        ["plugin.json", %w[version]],
        [".codex-plugin/plugin.json", %w[version]],
        [".claude-plugin/plugin.json", %w[version]]
      ].freeze

      module_function

      def check(scope, only:, for_doctor:)
        return [] unless only.include?("refs")

        out = []
        out.concat(ledger_refs) if scope[:host] && !for_doctor
        out.concat(shipped_refs) if scope[:shipped]
        out
      end

      def finding(severity, code, path, pointer, message)
        Finding.new(severity, "refs", code, path, nil, pointer, message, nil)
      end

      def ledger_refs
        ledger = Ledger.load
        out = []
        ledger.projects.reject { |entry| entry.status == "retired" }.each do |entry|
          repo = File.expand_path(entry.repo)
          out << finding("warn", "ledger_repo_missing", repo, nil, "project #{entry.id} names a repository directory that does not exist") unless File.directory?(repo)
        end
        ledger.paths.reject { |entry| entry.status == "retired" }.each do |entry|
          path = File.expand_path(entry.path)
          out << finding("warn", "ledger_path_missing", path, nil, "path entry #{entry.id} names a path that does not exist") unless File.exist?(path)
        end
        out
      rescue StandardError
        []
      end

      def read_data(path)
        return nil unless File.file?(path)

        text = File.binread(path).force_encoding("UTF-8")
        File.extname(path) == ".json" ? JSON.parse(text) : Schema::Document.parse(text, path)
      rescue StandardError
        nil
      end

      def shipped_refs
        require_relative "../packages"
        root = Polispec::ROOT
        out = []
        out.concat(version_refs(root))
        out.concat(schema_file_refs(root))
        out.concat(schema_ref_refs(root))
        out.concat(package_refs(root))
        out
      end

      def version_refs(root)
        file = File.join(root, "VERSION")
        return [] unless File.file?(file)

        expected = File.read(file).strip
        out = []
        VERSION_FILES.each do |relative, keys|
          data = read_data(File.join(root, relative))
          next unless data.is_a?(Hash)

          found = data.dig(*keys).to_s
          out << finding("error", "version_disagree", File.join(root, relative), nil, "version #{found.empty? ? 'is missing' : found} but VERSION is #{expected}") unless found == expected
        end
        marketplace = read_data(File.join(root, ".claude-plugin", "marketplace.json"))
        if marketplace.is_a?(Hash)
          Array(marketplace["plugins"]).each_with_index do |plugin, index|
            found = plugin.is_a?(Hash) ? plugin["version"].to_s : ""
            next if found == expected

            out << finding("error", "version_disagree", File.join(root, ".claude-plugin", "marketplace.json"), "/plugins/#{index}/version", "version #{found.empty? ? 'is missing' : found} but VERSION is #{expected}")
          end
        end
        out
      end

      def schema_file_refs(root)
        Schema::KINDS.reject { |kind| File.file?(File.join(root, "schemas", "#{kind}.v1.yml")) }.map do |kind|
          finding("error", "schema_file_missing", File.join(root, "schemas", "#{kind}.v1.yml"), nil, "schema kind #{kind} has no schema file")
        end
      end

      def schema_ref_refs(root)
        out = []
        Dir.glob(File.join(root, "schemas", "*.yml")).sort.each do |file|
          data = read_data(file)
          next unless data.is_a?(Hash)

          walk_refs(data, data, [], file, out)
        end
        out
      end

      def walk_refs(node, root, trail, file, out)
        case node
        when Hash
          node.each do |key, value|
            if key == "$ref" && value.is_a?(String) && value.start_with?("#/")
              out << finding("error", "schema_ref_missing", file, pointer(trail + [key]), "#{value} does not resolve") unless resolves?(root, value)
            else
              walk_refs(value, root, trail + [key.to_s], file, out)
            end
          end
        when Array
          node.each_with_index { |value, index| walk_refs(value, root, trail + [index.to_s], file, out) }
        end
      end

      def pointer(trail)
        "/#{trail.map { |part| part.to_s.gsub('~', '~0').gsub('/', '~1') }.join('/')}"
      end

      def resolves?(root, ref)
        node = root
        ref.sub(%r{\A#/}, "").split("/").each do |part|
          key = part.gsub("~1", "/").gsub("~0", "~")
          if node.is_a?(Hash) && node.key?(key)
            node = node[key]
          elsif node.is_a?(Array) && key.match?(/\A\d+\z/) && key.to_i < node.length
            node = node[key.to_i]
          else
            return false
          end
        end
        true
      end

      def package_refs(root)
        out = []
        Dir.glob(File.join(root, "packages", "*", "package.yml")).sort.each do |file|
          data = read_data(file)
          next unless data.is_a?(Hash)

          dir = File.dirname(file)
          package = Packages::Package.new(data, "shipped", ->(relative) { Packages.read_file(File.join(dir, relative)) })
          maps = [package.file_map(nil)]
          package.variants.each_key { |name| maps << package.file_map(name) }
          missing = maps.flat_map(&:values).uniq.reject { |source| File.file?(File.join(dir, source.to_s)) }
          missing.each do |source|
            out << finding("error", "package_source_missing", file, nil, "source #{source} does not exist under #{File.basename(dir)}")
          end
        end
        out
      end
    end
  end
end
