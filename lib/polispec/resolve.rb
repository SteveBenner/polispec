#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "classify/commands/support"

module Polispec
  module Resolve
    Entry = Struct.new(:policy, :source, :digest)

    TIERS = %w[dev test prod].freeze
    SKIP_PREFIXES = %w[/tmp/ /dev/ /proc/ /sys/ /var/tmp/].freeze
    GIT_ENV = { "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil, "GIT_CEILING_DIRECTORIES" => nil }.freeze
    SUPPORT = Classify::Support
    REPO = Classify::Support::Repo

    class Resolver
      attr_reader :ledger

      def initialize(ledger, policy = nil)
        @ledger = ledger
        @policy = policy
        @entries = {}
        @file_policy = :unread
      end

      def same?(ledger, policy)
        @ledger.equal?(ledger) && @policy.equal?(policy)
      end

      def call(action)
        hint = action.env_hint || {}
        klass = action.action_class
        return copy_target(hint) if klass == "data.copy"

        found = attribute(klass, hint)
        found && build(found[0], found[1])
      end

      def describe(path)
        loc = ledger.locate(path)
        return { "project" => nil, "env" => nil, "branch" => nil, "policy_source" => nil, "policy_digest" => nil } unless loc

        env = location_env(loc.project, loc)
        info = entry(loc.project)
        { "project" => loc.project.id, "env" => env, "branch" => env_branches(loc.project)[env], "policy_source" => info.source, "policy_digest" => info.digest }
      end

      def entry(project)
        @entries[project.id] ||= given(project) || from_file(project) || from_trust_ref(project) || fallback
      end

      def env_branches(project)
        policy = entry(project).policy
        spec = policy.is_a?(Hash) ? policy["environments"] : nil
        base = { "dev" => "main", "test" => "test", "prod" => project.trust_ref }
        return base unless spec.is_a?(Hash)

        spec.each_with_object(base.dup) { |(name, body), memo| memo[name] = body["branch"] if body.is_a?(Hash) && body["branch"] }
      end

      private

      def build(project, env)
        return Target.new(project: nil, env: env, policy: nil, roster: nil, policy_source: "ledger", digest: ledger.digest) unless project

        info = entry(project)
        Target.new(project: project.id, env: env, policy: info.policy, roster: nil, policy_source: info.source, digest: info.digest)
      end

      def attribute(klass, hint)
        return explicit(hint) if hint["project"]
        return channel(klass, hint) if hint["channel"]
        return by_ref(klass, hint) if hint["ref"]
        return by_unit(hint) if hint["unit"]
        return by_database(hint["db"]) if hint["db"]

        by_path(klass, hint)
      end

      def explicit(hint)
        project = ledger.project(hint["project"])
        project && [project, hint["env"] || "prod"]
      end

      def channel(klass, hint)
        project, = project_of(klass, hint)
        project && [project, hint["channel"] == "prerelease" ? "test" : "prod"]
      end

      def by_ref(klass, hint)
        project, = project_of(klass, hint)
        project && [project, env_for_ref(project, hint["ref"])]
      end

      def env_for_ref(project, ref)
        return "prod" if ref == "*"

        env_branches(project).key(ref) || "dev"
      end

      def project_of(klass, hint)
        loc = hint["path"] ? ledger.locate(hint["path"]) : nil
        return [loc.project, loc] if loc

        project = remote_project(klass, hint)
        project ? [project, nil] : nil
      end

      def remote_project(klass, hint)
        return nil unless klass.start_with?("git.", "release.")

        if hint["repo"]
          suffix = "/#{hint['repo'].to_s.downcase}"
          return live_projects.find { |project| project.remote && SUPPORT.normalize_remote(project.remote).end_with?(suffix) }
        end
        url = remote_url(hint)
        url && live_projects.find { |project| project.remote && SUPPORT.normalize_remote(project.remote) == SUPPORT.normalize_remote(url) }
      end

      def remote_url(hint)
        remote = hint["remote"] || "origin"
        return remote if SUPPORT.url?(remote)

        hint["path"] ? REPO.remote_url(hint["path"], remote) : nil
      end

      def by_path(klass, hint)
        path = hint["path"]
        return nil if path.nil? || path.empty?
        return [nil, "dev"] if ledger_file?(path)
        return by_secret(path) if klass == "secrets.read" && hint["candidate"]

        project, loc = project_of(klass, hint)
        return [project, location_env(project, loc)] if project

        bound = binding_for(path)
        bound && bound.first(2)
      end

      def ledger_file?(path)
        full = File.expand_path(path)
        full == ledger.path || full == Ledger.default_path
      end

      def by_secret(path)
        return nil if ledger.locate(path)

        bound = binding_for(path)
        bound && bound[2] == :secrets ? bound.first(2) : nil
      end

      def location_env(project, loc)
        return "dev" unless loc && loc.kind == :env_checkout

        env_branches(project).key(loc.env) || (ENVIRONMENTS.include?(loc.env) ? loc.env : "dev")
      end

      def by_unit(hint)
        unit = hint["unit"].to_s
        fuzzy = hint["fuzzy"]
        best(environment_specs.select do |_, _, spec|
          Array(spec["services"]).any? { |service| File.fnmatch?(unit, service) || (fuzzy && (service.include?(unit) || File.fnmatch?(service, unit))) }
        end)
      end

      def by_database(name)
        best(environment_specs.select do |_, _, spec|
          Array(spec.dig("data", "databases")).any? { |db| name == "*" || File.fnmatch?(name.to_s, db) }
        end)
      end

      def binding_for(path)
        full = canonical(path)
        return nil if skipped?(full)

        matches = environment_specs.filter_map do |project, env, spec|
          kind = binding_kind(spec, full)
          [project, env, kind] if kind
        end
        matches.max_by { |match| TIERS.index(match[1]).to_i }
      end

      def skipped?(full)
        return false if inside?(full, File.expand_path("~"))

        SKIP_PREFIXES.any? { |prefix| full.start_with?(prefix) }
      end

      def binding_kind(spec, full)
        return :secrets if Array(spec["secrets"]).any? { |glob| path_glob?(glob, full) }
        return :unit if (Array(spec["unit_files"]) + Array(spec["env_files"])).any? { |glob| path_glob?(glob, full) }
        return :data if Array(spec.dig("data", "dirs")).any? { |dir| inside?(full, File.expand_path(dir)) }
        return :checkout if spec["checkout"] && spec["checkout"] != "repo" && inside?(full, File.expand_path(spec["checkout"]))

        nil
      end

      def path_glob?(glob, full)
        return false if glob.to_s.include?(":") && !glob.to_s.start_with?("~", "/")

        pattern = File.expand_path(glob)
        return inside?(full, pattern.delete_suffix("/**")) if pattern.end_with?("/**")

        File.fnmatch?(pattern, full, File::FNM_PATHNAME | File::FNM_DOTMATCH | File::FNM_EXTGLOB)
      end

      def inside?(path, root)
        path == root || path.start_with?("#{root}/")
      end

      def canonical(path)
        expanded = File.expand_path(path.to_s)
        existing = expanded
        existing = File.dirname(existing) until File.exist?(existing) || existing == "/"
        File.join(File.realpath(existing), expanded[existing.length..].to_s).sub(%r{/+\z}, "")
      rescue SystemCallError
        File.expand_path(path.to_s)
      end

      def copy_target(hint)
        source = side(hint["from"])
        dest = side(hint["to"])
        hint["from_env"] = source && source[1]
        hint["to_env"] = dest ? dest[1] : "dev"
        hint["from_project"] = source && source[0]&.id
        hint["to_project"] = dest && dest[0]&.id
        project = (dest || source)&.first
        return nil unless project || source || dest

        build(project, hint["to_env"])
      end

      def side(part)
        return nil unless part.is_a?(Hash)
        return by_database(part["db"]) if part["db"]
        return by_path("fs.write", "path" => part["path"]) if part["path"]

        nil
      end

      def best(matches)
        pick = matches.max_by { |_, env, _| TIERS.index(env).to_i }
        pick && pick.first(2)
      end

      def live_projects
        ledger.projects.reject { |project| project.status == "retired" }
      end

      def environment_specs
        live_projects.flat_map do |project|
          envs = entry(project).policy.is_a?(Hash) ? entry(project).policy["environments"] : nil
          next [] unless envs.is_a?(Hash)

          envs.select { |_, spec| spec.is_a?(Hash) }.map { |env, spec| [project, env, spec] }
        end
      end

      def given(project)
        case @policy
        when nil then nil
        when Proc, Method then wrap(@policy.call(project.id))
        when Hash
          @policy.key?("schema") ? single(@policy, project, "given") : wrap(@policy[project.id])
        end
      end

      def single(doc, project, source)
        return nil unless doc["project"].to_s == project.id

        Entry.new(doc, source, "sha256:#{Digest::SHA256.hexdigest(JSON.generate(doc))}")
      end

      def wrap(result)
        case result
        when Array then Entry.new(result[0], result[1] || "given", result[2])
        when Hash then Entry.new(result, "given", "sha256:#{Digest::SHA256.hexdigest(JSON.generate(result))}")
        end
      end

      def from_file(project)
        path = ENV["POLISPEC_POLICY"]
        return nil if path.nil? || path.empty?

        doc = file_policy(path)
        doc && single(doc[:data], project, "file:#{path}")&.tap { |info| info.digest = doc[:digest] }
      end

      def file_policy(path)
        @file_policy = read_policy(path) if @file_policy == :unread
        @file_policy
      end

      def read_policy(path)
        full = File.expand_path(path)
        bytes = File.read(full)
        env_blob = Environments.read_file(full)
        return nil if env_blob && env_blob.errors

        combined = Environments.combine(bytes, env_blob && env_blob.text, path)
        return nil unless combined.data.is_a?(Hash) && combined.errors.nil?

        { data: combined.data, digest: combined.digest }
      rescue SystemCallError, Schema::Document::ParseError
        nil
      end

      def from_trust_ref(project)
        repo = File.expand_path(project.repo)
        return nil unless File.directory?(repo) && !project.trust_ref.empty? && !project.policy.empty?

        data, sha, digest, errors = Environments.load_policy_text(repo, project.trust_ref, project.policy)
        return nil unless data.is_a?(Hash) && errors.nil?

        Entry.new(data, "#{project.trust_ref}:#{sha}", digest)
      rescue SystemCallError, Schema::Document::ParseError
        nil
      end

      def fallback
        Entry.new(nil, "defaults", ledger.digest)
      end
    end

    module_function

    def call(action, ledger, policy = nil)
      resolver(ledger, policy).call(action)
    end

    def resolver(ledger, policy = nil)
      @resolver = Resolver.new(ledger, policy) unless @resolver&.same?(ledger, policy)
      @resolver
    end
  end
end
