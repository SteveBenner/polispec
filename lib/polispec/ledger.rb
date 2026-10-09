#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  class Ledger
    class Invalid < Polispec::Error; end

    DEFAULT_PATH = "~/.config/polispec/ledger.yml"
    Project = Struct.new(:id, :status, :repo, :remote, :worktree_globs, :trust_ref, :policy, :roster, :related, :onboarded, :profile, keyword_init: true) do
      def to_h
        members.each_with_object({}) { |member, memo| memo[member.to_s] = self[member] }
      end
    end
    Location = Struct.new(:project, :kind, :env, keyword_init: true)

    attr_reader :path, :host, :envs_root, :digest

    def self.default_path
      override = ENV["POLISPEC_LEDGER"].to_s
      return File.expand_path(override) unless override.empty?

      configured = Engine::Settings.ledger_path
      return File.expand_path(configured) if configured

      config = ENV["XDG_CONFIG_HOME"].to_s
      config.empty? ? File.expand_path(DEFAULT_PATH) : File.join(File.expand_path(config), "polispec", "ledger.yml")
    end

    def self.load(path = nil)
      path = File.expand_path(path || default_path)
      return new({}, path: path, digest: nil) unless File.file?(path)

      bytes = File.read(path)
      data = Schema::Document.parse(bytes, path)
      raise Invalid, "#{path}: ledger must be a mapping" unless data.is_a?(Hash)

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

    def locate(path)
      real = canonical(path)
      return nil if real.nil?

      projects.each do |entry|
        next if entry.status == "retired"

        found = locate_in(entry, real)
        return found if found
      end
      nil
    end

    private

    def build_project(entry)
      Project.new(
        id: entry["id"].to_s, status: entry["status"].to_s, repo: entry["repo"].to_s, remote: entry["remote"],
        worktree_globs: Array(entry["worktree_globs"]), trust_ref: entry["trust_ref"].to_s,
        policy: entry["policy"].to_s, roster: entry["roster"].to_s, related: Array(entry["related"]),
        onboarded: entry["onboarded"], profile: entry["profile"]
      )
    end

    def locate_in(entry, real)
      env = env_checkout(entry, real)
      return Location.new(project: entry, kind: :env_checkout, env: env) if env
      return Location.new(project: entry, kind: :repo, env: "dev") if roots(entry.repo).any? { |root| under?(real, root) }
      return Location.new(project: entry, kind: :worktree, env: "dev") if worktree?(entry, real)

      nil
    end

    def env_checkout(entry, real)
      base = File.join(envs_root, entry.id)
      return nil unless under?(real, base)

      real.sub(%r{\A#{Regexp.escape(base)}/?}, "").split("/").first
    end

    def worktree?(entry, real)
      patterns = entry.worktree_globs.map { |glob| File.expand_path(glob) }
      return false if patterns.empty?

      ancestors(real).any? { |dir| patterns.any? { |glob| File.fnmatch?(glob, dir, File::FNM_PATHNAME | File::FNM_DOTMATCH) } }
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
