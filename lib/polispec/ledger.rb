#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "hook_memo"

module Polispec
  class Ledger
    class Invalid < Polispec::Error; end

    DEFAULT_PATH = "~/.config/polispec/ledger.yml"
    Project = Struct.new(:id, :status, :repo, :remote, :worktree_globs, :trust_ref, :policy, :roster, :related, :onboarded, :profile, :packages, :owner, :registered_by, :description, keyword_init: true) do
      def to_h
        members.each_with_object({}) { |member, memo| memo[member.to_s] = self[member] }
      end
    end
    PathEntry = Struct.new(:id, :kind, :path, :status, :owner, :registered_by, :description, :policy, keyword_init: true) do
      def to_h
        members.each_with_object({}) { |member, memo| memo[member.to_s] = self[member] }
      end
    end
    Location = Struct.new(:project, :kind, :env, :entry, keyword_init: true)

    attr_reader :path, :host, :envs_root, :digest

    def self.default_path
      require_relative "harness_controls/plane"
      if defined?(HarnessControls::Plane) && HarnessControls::Plane.respond_to?(:path)
        protected_path = HarnessControls::Plane.path("ledger")
        return File.expand_path(protected_path) if protected_path
      end
      override = ENV["POLISPEC_LEDGER"].to_s
      return File.expand_path(override) unless override.empty?

      configured = Engine::Settings.ledger_path
      return File.expand_path(configured) if configured

      config = ENV["XDG_CONFIG_HOME"].to_s
      config.empty? ? File.expand_path(DEFAULT_PATH) : File.join(File.expand_path(config), "polispec", "ledger.yml")
    end

    STARTER = File.join(Polispec::ROOT, "config", "ledger.starter.yml")

    def self.starter_text
      require "socket"
      host = begin
        Socket.gethostname.to_s.split(".").first.to_s
      rescue StandardError
        ""
      end
      host = "workstation" if host.empty?
      File.read(STARTER).gsub("{{host}}", host)
    end

    def self.sealed_ledger?
      require_relative "harness_controls/plane"
      defined?(HarnessControls::Plane) && HarnessControls::Plane.respond_to?(:path) && !HarnessControls::Plane.path("ledger").nil?
    end

    def self.create_starter!(path = default_path, dry: false)
      require_relative "operator/git"
      raise Operator::Failure.new("ledger_sealed", "the sealed plane owns the ledger at #{path}; ask the operator") if sealed_ledger?
      return { "path" => path, "created" => false } if File.exist?(path)

      text = starter_text
      data = Schema::Document.parse(text, path)
      errors = Schema.validate("ledger", data)
      raise Operator::Failure.new("ledger_invalid", "the starter ledger template does not validate", "problems" => errors.map { |error| "#{error.pointer} #{error.message}".strip }) unless errors.empty?
      return { "path" => path, "created" => true } if dry

      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      temp = "#{path}.#{Process.pid}.tmp"
      File.write(temp, text)
      File.chmod(0o600, temp)
      if File.exist?(path)
        File.rename(temp, "#{path}.starter-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}")
        return { "path" => path, "created" => false }
      end
      File.rename(temp, path)
      { "path" => path, "created" => true }
    end

    def self.load(path = nil)
      path = File.expand_path(path || default_path)
      HookMemo.fetch(:ledger_load, path) { load_uncached(path) }
    end

    def self.load_uncached(path)
      return new({}, path: path, digest: nil) unless File.file?(path)

      bytes = File.read(path)
      data = Schema::Document.parse(bytes, path)
      raise Invalid, "#{path}: ledger must be a mapping" unless data.is_a?(Hash)

      if defined?(HarnessControls::Plane) && HarnessControls::Plane.respond_to?(:activation_overrides)
        overrides = HarnessControls::Plane.activation_overrides
        Array(data["projects"]).each { |entry| entry["status"] = overrides[entry["id"].to_s] if overrides.key?(entry["id"].to_s) }
      end
      new(data, path: path, digest: "sha256:#{Digest::SHA256.hexdigest(bytes)}")
    rescue Schema::Document::ParseError => e
      raise Invalid, e.message
    end

    def initialize(data, path: nil, digest: nil)
      @data = data
      @path = path
      @digest = digest
      @host = data["host"].to_s
      @envs_root = File.expand_path(data["envs_root"] || "~/.polispec/envs")
    end

    def projects
      @projects ||= Array(@data["projects"]).map { |entry| build_project(entry) }
    end

    def project(id)
      projects.find { |entry| entry.id == id.to_s }
    end

    def paths
      @paths ||= Array(@data["paths"]).map { |entry| build_path(entry) }
    end

    def path_entry(id)
      paths.find { |entry| entry.id == id.to_s }
    end

    def entry(id)
      project(id) || path_entry(id)
    end

    def defaults
      @data["defaults"].is_a?(Hash) ? @data["defaults"] : { "rules" => [] }
    end

    def pauses_log
      File.expand_path(@data["pauses_log"] || State.pauses_log)
    end

    def allow_once_log
      File.expand_path(@data["allow_once_log"] || State.allow_once_log)
    end

    def project_for(path)
      locate(path)&.project
    end

    def locate(path, paths: false)
      real = canonical(path)
      return nil if real.nil?

      found = locate_project(real)
      return found if found || !paths

      locate_path(real)
    end

    def locate_path(path)
      real = canonical(path)
      return nil if real.nil?

      candidates = paths.reject { |entry| entry.status == "retired" }.filter_map do |entry|
        root = roots(entry.path).find { |candidate| under?(real, candidate) }
        root ? [root.length, entry] : nil
      end
      best = candidates.max_by(&:first)&.last
      best && Location.new(project: nil, kind: :path, env: nil, entry: best)
    end

    def development(path)
      real = canonical(path)
      return nil if real.nil?

      live = projects.reject { |entry| entry.status == "retired" }
      return nil if live.any? { |entry| env_checkout(entry, real) }

      owners = live.select { |entry| roots(entry.repo).any? { |root| under?(real, root) } || worktree_root(entry, real) }
      return nil if owners.empty? || !owners.all? { |entry| entry.status == "onboarding" }

      owners.map(&:id)
    end

    private

    def locate_project(real)
      live = projects.reject { |entry| entry.status == "retired" }
      live.each do |entry|
        env = env_checkout(entry, real)
        return Location.new(project: entry, kind: :env_checkout, env: env) if env
      end
      candidates = []
      live.each_with_index do |entry, index|
        root = roots(entry.repo).find { |candidate| under?(real, candidate) }
        candidates << [root.length, index, Location.new(project: entry, kind: :repo, env: "dev")] if root
        shelter = worktree_root(entry, real)
        candidates << [shelter.length, index, Location.new(project: entry, kind: :worktree, env: "dev")] if shelter
      end
      candidates.min_by { |length, index, _| [length, index] }&.last
    end

    def build_path(entry)
      PathEntry.new(
        id: entry["id"].to_s, kind: entry["kind"].to_s, path: entry["path"].to_s, status: entry["status"].to_s,
        owner: entry["owner"], registered_by: entry["registered_by"], description: entry["description"],
        policy: (entry["policy"] || "paths/#{entry['id']}.yml").to_s
      )
    end

    def build_project(entry)
      Project.new(
        id: entry["id"].to_s, status: entry["status"].to_s, repo: entry["repo"].to_s, remote: entry["remote"],
        worktree_globs: Array(entry["worktree_globs"]), trust_ref: entry["trust_ref"].to_s,
        policy: entry["policy"].to_s, roster: entry["roster"].to_s, related: Array(entry["related"]),
        onboarded: entry["onboarded"], profile: entry["profile"], packages: Array(entry["packages"]),
        owner: entry["owner"], registered_by: entry["registered_by"], description: entry["description"]
      )
    end

    def worktree_root(entry, real)
      patterns = entry.worktree_globs.map { |glob| File.expand_path(glob) }
      return nil if patterns.empty?

      ancestors(real).select { |dir| patterns.any? { |glob| File.fnmatch?(glob, dir, File::FNM_PATHNAME | File::FNM_DOTMATCH) } }.last
    end

    def env_checkout(entry, real)
      base = File.join(envs_root, entry.id)
      return nil unless under?(real, base)

      real.sub(%r{\A#{Regexp.escape(base)}/?}, "").split("/").first
    end

    def ancestors(real)
      list = []
      dir = real
      until list.last == dir
        list << dir
        dir = File.dirname(dir)
      end
      list
    end

    def roots(repo)
      expanded = File.expand_path(repo)
      [expanded, real_or_nil(expanded)].compact.uniq
    end

    def under?(path, root)
      path == root || path.start_with?("#{root}/")
    end

    def canonical(path)
      return nil if path.nil? || path.to_s.empty?

      expanded = File.expand_path(path.to_s)
      real_or_nil(expanded) || expanded
    end

    def real_or_nil(path)
      existing = path
      existing = File.dirname(existing) until File.exist?(existing) || existing == "/"
      tail = path[existing.length..]
      joined = File.join(File.realpath(existing), tail).sub(%r{/+\z}, "")
      joined.empty? ? "/" : joined
    rescue SystemCallError
      nil
    end
  end
end
