#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "digest"
require "json"
require "open3"
require "yaml"
require_relative "stat_cache"
require_relative "../harness_controls/plane"

module Polispec
  module Judge
    class Freshness
      MODE_ENV = "POLISPEC_JUDGE_FRESHNESS"
      MODES = %w[stat content].freeze
      DEFAULT_MODE = "stat"
      SHELF_FILE_CAP = 2000
      REF_SAFE = %r{\A[A-Za-z0-9][A-Za-z0-9._/@+-]*\z}.freeze
      REF_DEPTH_LIMIT = 5
      REF_BYTES = 256
      GITDIR_BYTES = 512
      REF_ENTRY_CAP = 256
      REF_DIRS = %w[refs refs/heads refs/tags refs/remotes].freeze
      SHA_PATTERN = /\A\h{40,64}\z/.freeze
      RECOVERABLE = [Polispec::Error, SystemCallError, IOError, JSON::ParserError, Psych::Exception, ArgumentError, TypeError, KeyError].freeze
      RefEntry = Struct.new(:files, :dirs, :value, :racy, keyword_init: true)

      attr_reader :mode

      def self.mode
        value = ENV[MODE_ENV].to_s.strip.downcase
        MODES.include?(value) ? value : DEFAULT_MODE
      end

      def initialize(stat_cache:, mode: self.class.mode)
        raise ArgumentError, "unknown freshness mode #{mode.inspect}" unless MODES.include?(mode)

        @stat_cache = stat_cache
        @mode = mode
        @ledger_digest = nil
        @repos = []
        @refs = {}
        @watch = nil
      end

      def key
        return compute_key unless stat?

        saved = Thread.current[HookMemo::SLOT]
        Thread.current[HookMemo::SLOT] = {}
        begin
          compute_key
        ensure
          Thread.current[HookMemo::SLOT] = saved
        end
      end

      private

      def compute_key
        parts = []
        ledger_path = safely { Ledger.default_path }.to_s
        ledger_digest = file_digest(ledger_path)
        parts << ledger_path << ledger_digest
        parts << file_digest(rplugin_settings)
        parts << file_digest(safely { NativeSettings.path }.to_s)
        parts << file_digest(resolved_settings)
        parts << file_digest(HarnessControls::Plane::ACTIVE_PATH)
        parts << Polispec.version
        parts << shelf
        parts << catalog
        parts << project_refs(ledger_digest, ledger_path)
        Digest::SHA256.hexdigest(parts.join("\0"))
      end

      def stat?
        @mode == "stat"
      end

      def safely
        yield
      rescue *RECOVERABLE
        nil
      end

      def fileread(path)
        return nil if path.to_s.empty?

        File.file?(path) ? File.binread(path) : nil
      rescue SystemCallError
        nil
      end

      def file_digest(path)
        return "-" if path.to_s.empty?
        return @stat_cache.digest(path) if stat?

        bytes = fileread(path)
        bytes.nil? ? "-" : Digest::SHA256.hexdigest(bytes)
      end

      def rplugin_settings
        base = ENV["XDG_CONFIG_HOME"].to_s
        base = File.join(Dir.home, ".config") if base.empty?
        File.join(base, "rplugin", "polispec", "settings.yml")
      end

      def resolved_settings
        base = ENV["XDG_STATE_HOME"].to_s
        base = File.join(Dir.home, ".local", "state") if base.empty?
        File.join(base, "rplugin", "polispec", "settings.resolved.json")
      end

      def catalog
        dir = Catalog.state_dir
        files = [Catalog.state_path] + Dir.glob(File.join(dir, Catalog::PROVISION_DIR, "**", "*.yml")).sort
        Digest::SHA256.hexdigest(files.map { |file| "#{file}\0#{file_digest(file)}" }.join("\n"))
      rescue StandardError, ScriptError => error
        "catalog:#{error.class}"
      end

      def shelf
        source = Layers.source
        return "none" unless source

        if source.kind == :dir
          root = File.expand_path(source.root)
          body = shelf_files(root).map { |file, digest| "#{file.delete_prefix(root)}\0#{digest}" }
          Digest::SHA256.hexdigest(["dir", root, *body].join("\n"))
        else
          Digest::SHA256.hexdigest(["repo", source.repo, source.ref, source.path, commit_of(source.repo, source.ref)].join("\n"))
        end
      rescue StandardError, ScriptError => error
        "shelf:#{error.class}"
      end

      def shelf_files(root)
        paths = Dir.glob(File.join(root, "**", "*")).sort
        if stat?
          paths.lazy.map { |file| [file, @stat_cache.file_digest(file)] }.reject { |_, digest| digest.nil? }.first(SHELF_FILE_CAP)
        else
          paths.select { |file| File.file?(file) }.first(SHELF_FILE_CAP).map { |file| [file, file_digest(file)] }
        end
      end

      def project_refs(digest, ledger_path)
        if digest != @ledger_digest
          @ledger_digest = digest
          @repos = begin
            Ledger.load_uncached(ledger_path).projects.select { |project| project.status == "live" && !project.repo.to_s.empty? && !project.trust_ref.to_s.empty? }.map { |project| [project.id, File.expand_path(project.repo), project.trust_ref.to_s] }
          rescue *RECOVERABLE
            []
          end
        end
        Digest::SHA256.hexdigest(@repos.map { |id, repo, ref| [id, repo, ref, commit_of(repo, ref)].join("\0") }.join("\n"))
      end

      def commit_of(repo, ref)
        ref = ref.to_s
        return resolve_commit(repo, ref) unless stat?

        slot = [repo, ref]
        entry = @refs[slot]
        return entry.value if entry && ref_current?(entry)

        taken = @stat_cache.clock
        @watch = { files: {}, dirs: {} }
        value = resolve_commit(repo, ref)
        tuples = @watch[:files].values + @watch[:dirs].values
        @refs.clear if @refs.size >= REF_ENTRY_CAP && !@refs.key?(slot)
        @refs[slot] = RefEntry.new(files: @watch[:files], dirs: @watch[:dirs], value: value, racy: @stat_cache.racy_any?(tuples, taken))
        value
      ensure
        @watch = nil
      end

      def ref_current?(entry)
        return false if entry.racy

        entry.files.all? { |path, tuple| @stat_cache.tuple(path) == tuple } &&
          entry.dirs.all? { |path, stamp| @stat_cache.stamp(path) == stamp }
      end

      def resolve_commit(repo, ref)
        found = REF_SAFE.match?(ref) && !ref.include?("..") ? file_ref(repo, ref) : nil
        return found if found

        watch_ref_state(repo)
        rev_parse(repo, ref)
      end

      def touch(path)
        return unless @watch

        @watch[:files][path] = @stat_cache.tuple(path) unless @watch[:files].key?(path)
      end

      def touch_dir(path)
        return unless @watch

        @watch[:dirs][path] = @stat_cache.stamp(path) unless @watch[:dirs].key?(path)
      end

      def watch_ref_state(repo)
        return unless @watch

        git_dirs(repo).each do |dir|
          touch(File.join(dir, "HEAD"))
          touch(File.join(dir, "packed-refs"))
          REF_DIRS.each { |name| touch_dir(File.join(dir, name)) }
        end
      end

      def git_dirs(repo)
        dotgit = File.join(repo, ".git")
        touch(dotgit)
        touch(File.join(dotgit, "HEAD"))
        touch(File.join(repo, "HEAD"))
        dir = nil
        if File.directory?(dotgit)
          dir = dotgit
        elsif File.file?(dotgit)
          line = File.read(dotgit, GITDIR_BYTES).to_s[/\Agitdir:\s*(.+?)\s*$/, 1]
          dir = File.expand_path(line, repo) if line
        elsif File.file?(File.join(repo, "HEAD"))
          dir = repo
        end
        return [] unless dir

        common = File.join(dir, "commondir")
        touch(common)
        shared = File.file?(common) ? File.expand_path(File.read(common).strip, dir) : nil
        [dir, shared].compact.uniq
      rescue SystemCallError
        []
      end

      def file_ref(repo, ref)
        dirs = git_dirs(repo)
        return nil if dirs.empty?

        names = [ref, "refs/#{ref}", "refs/heads/#{ref}", "refs/tags/#{ref}", "refs/remotes/#{ref}"]
        names.each do |name|
          dirs.each do |dir|
            value = follow(dirs, dir, name, 0)
            return value if value
          end
        end
        nil
      rescue SystemCallError
        nil
      end

      def follow(dirs, dir, name, depth)
        return nil if depth > REF_DEPTH_LIMIT

        path = File.join(dir, name)
        touch(path)
        if File.file?(path)
          text = File.read(path, REF_BYTES).to_s.strip
          return text if text.match?(SHA_PATTERN)
          return follow(dirs, dir, text.delete_prefix("ref: ").strip, depth + 1) if text.start_with?("ref: ")

          return nil
        end
        dirs.each do |base|
          packed = File.join(base, "packed-refs")
          touch(packed)
          next unless File.file?(packed)

          File.foreach(packed) do |line|
            sha, packed_ref = line.chomp.split(" ", 2)
            return sha if packed_ref == name && sha.to_s.match?(SHA_PATTERN)
          end
        end
        nil
      end

      def rev_parse(repo, ref)
        out, status = Open3.capture2(PolicySource::GIT_ENV, "git", "-C", repo, "rev-parse", "--verify", "-q", "#{ref}^{commit}", err: File::NULL)
        status.success? ? out.strip : "-"
      rescue SystemCallError
        "-"
      end
    end
  end
end
