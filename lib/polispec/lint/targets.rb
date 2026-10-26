#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "open3"
require "tmpdir"
require_relative "shipped"

module Polispec
  module Lint
    module Targets
      CANDIDATE_CAP = 5000
      HEAD_BYTES = 4096
      CANDIDATE_BYTES = 2 * 1024 * 1024
      SCHEMA_LINE = /^\s*"?schema"?\s*:\s*"?polispec\./.freeze
      EXTENSIONS = %w[.yml .yaml .json].freeze
      SKIPPED_DIRS = %w[vendor node_modules].freeze
      ALLOWED_DOT_DIRS = %w[.agents .polispec].freeze
      SHIPPED_DOT_DIRS = %w[.claude-plugin .codex-plugin .agents].freeze
      SHELF_NAMES = %w[global.yml profiles.yml exceptions.yml].freeze
      SHELF_PATTERNS = [
        [%r{\Amodules/[^/]+\.yml\z}, "module"],
        [%r{\Apackages/[^/]+/package\.yml\z}, "package"],
        [%r{\Apaths/[^/]+\.yml\z}, "policy"]
      ].freeze
      SHELF_KINDS = { "global.yml" => "global", "profiles.yml" => "profiles", "exceptions.yml" => "exceptions" }.freeze
      EXPECTATIONS = {
        "specs/polispec/environments.yml" => "environments",
        "specs/polispec/policy.yml" => "policy",
        "specs/polispec/roster.yml" => "roster",
        "specs/polispec/code-waivers.yml" => "waivers",
        "specs/polispec/contracts/vocabulary.yml" => "contract-vocabulary"
      }.freeze
      SHIPPED_DESCRIBED = %w[policy environments roster global module package spec].freeze

      module_function

      def target(**fields)
        defaults = { text: nil, format: nil, kind: nil, expect: nil, unrecognized: false, allow: [], project: nil, descriptions: false }
        merged = defaults.merge(fields)
        merged[:format] ||= Lint.format_for(merged[:path])
        Target.new(**merged)
      end

      def git_files(root)
        out, status = Trace.capture2(Layers::GIT_ENV, "git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard", err: File::NULL, trace: :quiet)
        return nil unless status.success?

        out.split("\0").reject(&:empty?).sort.uniq
      rescue SystemCallError
        nil
      end

      def walk_files(root, dot_dirs)
        found = []
        pending = [""]
        until pending.empty?
          relative = pending.shift
          dir = relative.empty? ? root : File.join(root, relative)
          Dir.children(dir).sort.each do |name|
            child = relative.empty? ? name : File.join(relative, name)
            full = File.join(root, child)
            if File.symlink?(full)
              next
            elsif File.directory?(full)
              next if name.start_with?(".") && !dot_dirs.include?(name)

              pending << child
            elsif File.file?(full)
              found << child
            end
          end
        end
        found.sort
      rescue SystemCallError
        found
      end

      def candidates(root)
        files = File.exist?(File.join(root, ".git")) ? git_files(root) : nil
        files || walk_files(root, ALLOWED_DOT_DIRS)
      end

      def eligible?(relative)
        return false unless EXTENSIONS.include?(File.extname(relative).downcase)

        dirs = relative.split("/")[0...-1]
        return false if dirs.any? { |part| SKIPPED_DIRS.include?(part) }

        dirs.none? { |part| part.start_with?(".") && !ALLOWED_DOT_DIRS.include?(part) }
      end

      def schema_declared?(file)
        return false if File.size(file) > CANDIDATE_BYTES

        head = File.binread(file, HEAD_BYTES).to_s
        SCHEMA_LINE.match?(head)
      rescue SystemCallError
        false
      end

      def ledger_project(ledger, root)
        return nil unless ledger

        ledger.locate(root)&.project&.id
      rescue StandardError
        nil
      end

      def load_ledger
        Ledger.load
      rescue StandardError
        nil
      end

      def template?(root, relative)
        return false if File.basename(relative) == "package.yml" && File.file?(File.join(root, relative))

        parts = relative.split("/")[0...-1]
        until parts.empty?
          return true if File.file?(File.join(root, *parts, "package.yml"))

          parts.pop
        end
        false
      end

      def project(root, notes: [], descriptions: true, ref: nil, scratch: [], rewrites: {}, strict: true)
        root = File.expand_path(root)
        id = ledger_project(load_ledger, root)
        return project_tree(root, id, notes, descriptions) if ref.nil?

        dir = materialize(root, ref, id, notes, scratch, strict)
        return [] unless dir

        rewrites[dir] = "#{File.basename(root)}@#{ref}:"
        project_tree(dir, id, notes, descriptions)
      end

      def materialize(root, ref, id, notes, scratch, strict)
        ref = ref.to_s
        commit = ref.empty? || ref.start_with?("-") ? nil : Environments.git(root, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
        if commit.to_s.strip.empty?
          raise Polispec::Error, "ref #{ref} not found in #{root}" if strict

          notes << Finding.new("info", "refs", "ref_missing", root, nil, nil, "ref #{ref} not found; not linted", id)
          return nil
        end
        listing = Environments.git(root, "ls-tree", "-r", "-z", "--name-only", commit.strip)
        raise Polispec::Error, "cannot list #{ref} in #{root}" if listing.nil?

        names = listing.split("\0").select { |relative| !relative.include?("\n") && eligible?(relative) }
        if names.length > CANDIDATE_CAP
          notes << Finding.new("info", "refs", "too_many_files", root, nil, nil, "#{names.length} candidate files at #{ref}; only the first #{CANDIDATE_CAP} were examined", id)
          names = names.first(CANDIDATE_CAP)
        end
        dir = Dir.mktmpdir("polispec-lint-")
        scratch << dir
        read_blobs(root, commit.strip, names) do |relative, text|
          path = File.join(dir, relative)
          FileUtils.mkdir_p(File.dirname(path))
          File.binwrite(path, text)
        end
        dir
      end

      def read_blobs(root, commit, names)
        Open3.popen2(Layers::GIT_ENV, "git", "-C", root, "cat-file", "--batch", err: File::NULL) do |input, output, _thread|
          input.binmode
          output.binmode
          names.each do |relative|
            input.write("#{commit}:#{relative}\n")
            input.flush
            header = output.gets
            break if header.nil?

            fields = header.split
            next unless fields.length == 3 && fields[1] == "blob"

            size = fields[2].to_i
            body = output.read(size)
            output.read(1)
            yield relative, body if body && size <= CANDIDATE_BYTES
          end
        end
      rescue SystemCallError, IOError
        nil
      end

      def project_tree(root, id, notes, descriptions)
        listed = candidates(root).select { |relative| eligible?(relative) }
        if listed.length > CANDIDATE_CAP
          notes << Finding.new("info", "refs", "too_many_files", root, nil, nil, "#{listed.length} candidate files; only the first #{CANDIDATE_CAP} were examined", id)
          listed = listed.first(CANDIDATE_CAP)
        end
        chosen = listed.select { |relative| File.file?(File.join(root, relative)) && schema_declared?(File.join(root, relative)) }
        always = %w[polispec.app.yml polispec.manifest.json].select { |relative| File.file?(File.join(root, relative)) }
        always.concat(Dir.glob(File.join(root, "specs", "polispec", "**", "*.yml")).map { |file| file.sub("#{root}/", "") }.sort)
        (chosen + always).uniq.map { |relative| project_target(root, relative, id, descriptions) }.compact
      end

      def project_target(root, relative, id, descriptions)
        path = File.join(root, relative)
        return nil unless File.file?(path)

        described = descriptions && %w[.yml .yaml].include?(File.extname(relative).downcase)
        if template?(root, relative)
          return target(path: path, kind: nil, project: id, descriptions: false)
        end

        fields = { path: path, kind: "auto", project: id, descriptions: described, unrecognized: relative.start_with?("specs/polispec/") }
        fields[:expect] = EXPECTATIONS[relative]
        fields[:expect] = "module" if relative.start_with?("specs/polispec/modules/") && relative.end_with?(".yml")
        fields[:expect] = "contract" if relative.start_with?("specs/polispec/contracts/") && relative.end_with?(".yml") && File.basename(relative) != "vocabulary.yml"
        if relative == "polispec.app.yml"
          fields[:kind] = "app"
        elsif relative == "polispec.manifest.json"
          fields[:kind] = "manifest"
          fields[:format] = :json
        end
        target(**fields)
      end

      def host(for_doctor: false, notes: [], roots: [], labels: {}, scratch: [], ref: nil, rewrites: {})
        require_relative "../deployments"
        require_relative "../native_settings"
        out = []
        ledger = load_ledger
        ledger_path = Ledger.default_path
        out << target(path: ledger_path, kind: "ledger", descriptions: !for_doctor) if !for_doctor && File.file?(ledger_path)
        out.concat(shelf(for_doctor, labels, scratch))
        deployments = Deployments.path
        out << target(path: deployments, kind: "deployments", format: :json) if File.file?(deployments)
        grants = File.join(State.home, "delegate", "grants.yml")
        out << target(path: grants, kind: "delegate_grants") if File.file?(grants)
        settings = NativeSettings.path
        out << target(path: settings, kind: nil) if File.file?(settings)
        index = index_file
        out << target(path: index, kind: "index", format: :json) if index && File.file?(index)
        if ledger
          ledger.projects.reject { |entry| entry.status == "retired" }.each do |entry|
            repo = File.expand_path(entry.repo)
            next unless File.directory?(repo)

            at = ref == :trust ? entry.trust_ref.to_s : ref.to_s
            if at.empty?
              roots << repo
              out.concat(project(repo, notes: notes, descriptions: !for_doctor))
            else
              before = rewrites.keys
              out.concat(project(repo, notes: notes, descriptions: !for_doctor, ref: at, scratch: scratch, rewrites: rewrites, strict: false))
              roots.concat(rewrites.keys - before)
            end
          end
        end
        out
      end

      def index_file
        require_relative "../manifest"
        Manifest.index_path
      rescue StandardError
        nil
      end

      def shelf(for_doctor, labels, scratch)
        source = begin
          Layers.source
        rescue StandardError
          nil
        end
        return [] unless source

        names = source.kind == :dir ? shelf_dir_names(source) : shelf_repo_names(source)
        store = source.kind == :dir ? nil : Layers.store
        base = source.kind == :dir ? source.root : nil
        if base.nil?
          base = Dir.mktmpdir("polispec-lint-")
          scratch << base
        end
        names.sort.filter_map do |relative|
          kind = shelf_kind(relative)
          next if kind.nil? || (for_doctor && kind == "exceptions")

          path = File.join(base, relative)
          if source.kind != :dir
            text = store && store.read(relative)
            next if text.nil?

            FileUtils.mkdir_p(File.dirname(path))
            File.binwrite(path, text)
          end
          next unless File.file?(path)

          labels[path] = "<shelf>/#{relative}"
          target(path: path, kind: kind, descriptions: true, format: :yaml)
        end
      end

      def read_text(file)
        File.file?(file) ? File.binread(file).force_encoding("UTF-8") : nil
      rescue SystemCallError
        nil
      end

      def shelf_kind(relative)
        return SHELF_KINDS[relative] if SHELF_KINDS.key?(relative)

        SHELF_PATTERNS.each { |pattern, kind| return kind if pattern.match?(relative) }
        nil
      end

      def shelf_dir_names(source)
        return [] unless File.directory?(source.root)

        Dir.glob(File.join(source.root, "**", "*.yml")).map { |file| file.sub("#{source.root}/", "") }.select { |relative| shelf_kind(relative) }
      end

      def shelf_repo_names(source)
        args = ["git", "-C", source.repo, "ls-tree", "-r", "--name-only", source.ref]
        args.concat(["--", source.path]) unless source.path.to_s.empty?
        out, status = Trace.capture2(Layers::GIT_ENV, *args, err: File::NULL, trace: :quiet)
        return [] unless status.success?

        prefix = source.path.to_s.empty? ? "" : "#{source.path}/"
        out.lines.map(&:chomp).select { |name| name.start_with?(prefix) }.map { |name| name[prefix.length..] }.select { |relative| shelf_kind(relative) }
      rescue SystemCallError
        []
      end

      def shipped(notes: [])
        root = Polispec::ROOT
        listed = File.exist?(File.join(root, ".git")) ? git_files(root) : nil
        listed ||= walk_files(root, SHIPPED_DOT_DIRS)
        listed = listed.select { |relative| EXTENSIONS.include?(File.extname(relative).downcase) && File.file?(File.join(root, relative)) }
        matched = {}
        targets = []
        listed.each do |relative|
          row = Shipped.claim(relative)
          if row.nil?
            notes << Finding.new("warn", "refs", "shipped_unclaimed", File.join(root, relative), nil, nil, "no row of the shipped table claims this file", nil)
            next
          end
          matched[row[:glob]] = true
          targets << shipped_target(root, relative, row[:kind])
        end
        Shipped::TABLE.each do |row|
          next if matched[row[:glob]]

          notes << Finding.new("warn", "refs", "shipped_row_unmatched", File.join(root, "lib/polispec/lint/shipped.rb"), nil, nil, "the shipped table row #{row[:glob]} claims no file", nil)
        end
        targets
      end

      def shipped_target(root, relative, kind)
        path = File.join(root, relative)
        described = SHIPPED_DESCRIBED.include?(kind) && %w[.yml .yaml].include?(File.extname(relative).downcase)
        target(path: path, kind: kind, descriptions: described, unrecognized: kind == "auto")
      end
    end
  end
end
