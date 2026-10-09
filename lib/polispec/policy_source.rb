#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "layers"

module Polispec
  module PolicySource
    Loaded = Struct.new(:policy, :source, :digest, :finding, keyword_init: true)
    Blob = Struct.new(:sha, :digest, :data, :errors, :finding, keyword_init: true)
    FALLBACK_RULES = [
      { "match" => { "ref" => %w[stable test] }, "verdict" => "deny" },
      { "match" => { "class" => %w[service.control service.config deploy promote] }, "verdict" => "deny" },
      { "match" => { "class" => %w[data.write policy.edit] }, "verdict" => "warn" },
      { "match" => {}, "verdict" => "allow" }
    ].freeze
    GIT_ENV = { "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil, "GIT_OPTIONAL_LOCKS" => "0" }.freeze

    class << self
      def load(project, ledger: nil)
        found = resolve(project, ledger: ledger)
        [found.policy, found.source, found.digest]
      end

      def resolve(project, ledger: nil)
        ledger ||= Ledger.load
        outcome = lookup(project, project.policy, "policy")
        if outcome.is_a?(Blob) && outcome.errors.nil?
          remember_environments(project, outcome)
          policy, digest = Layers.compose(project, outcome.data, outcome.digest, ledger: ledger)
          return Loaded.new(policy: policy, source: "#{project.trust_ref}:#{outcome.sha}", digest: digest, finding: outcome.finding)
        end

        fallback(project, ledger, outcome)
      end

      def missing?(project)
        lookup(project, project.policy, "policy").nil?
      end

      def bootstrap(project, ref)
        outcome = lookup(project, project.policy, "policy", ref)
        return nil unless outcome.is_a?(Blob) && outcome.errors.nil?

        Events.emit("polispec.finding", project: project.id, kind: "policy_bootstrap", detail: "#{project.trust_ref} carries no policy; using #{ref}:#{project.policy}", policy_source: "bootstrap:#{ref}:#{outcome.sha}")
        Loaded.new(policy: outcome.data, source: "bootstrap:#{ref}:#{outcome.sha}", digest: outcome.digest, finding: outcome.finding)
      end

      def load_roster(project)
        outcome = lookup(project, project.roster, "roster")
        return nil unless outcome.is_a?(Blob)
        return outcome.data if outcome.errors.nil?

        Events.emit("polispec.finding", project: project.id, kind: "roster_invalid", detail: summarize(outcome.errors), policy_source: "#{project.trust_ref}:#{outcome.sha}")
        nil
      end

      def roster_digest(project)
        outcome = lookup(project, project.roster, "roster")
        outcome.is_a?(Blob) ? outcome.digest : nil
      end

      def defaults_policy(project, ledger)
        rules = Layers.fallback_rules || Array(ledger.defaults["rules"])
        rules = FALLBACK_RULES if rules.empty?
        {
          "schema" => "polispec.policy/v1", "project" => project.id, "defaults" => true,
          "environments" => last_good_environments(project) || synthesized_environments(project, ledger),
          "rules" => rules.each_with_index.map { |rule, index| rule.merge("id" => rule["id"] || "DEFAULT-#{index + 1}") },
          "promotion" => {}, "freezes" => [], "data_classes" => {}, "agents" => {}
        }
      end

      def clear_cache
        Dir.glob(File.join(State.cache_dir, "{policy,roster}-*.json")).each { |file| File.delete(file) }
      end

      private

      def fallback(project, ledger, outcome)
        kind, detail, source = describe(project, outcome)
        Events.emit("polispec.finding", project: project.id, kind: kind, detail: detail, policy_source: source)
        Loaded.new(
          policy: defaults_policy(project, ledger), source: "defaults",
          digest: "sha256:#{Digest::SHA256.hexdigest(JSON.generate(ledger.defaults))}",
          finding: { "kind" => kind, "detail" => detail }
        )
      end

      def describe(project, outcome)
        return ["policy_unreadable", "repository #{project.repo} is not readable", "defaults"] if outcome == :repo_missing
        return ["policy_missing", "#{project.trust_ref}:#{project.policy} not found in #{project.repo}", "defaults"] if outcome.nil?

        ["policy_invalid", summarize(outcome.errors), "#{project.trust_ref}:#{outcome.sha}"]
      end

      def summarize(errors)
        errors.first(3).map { |error| "#{error['pointer']} #{error['message']}".strip }.join("; ")
      end

      def last_good_path(project)
        File.join(State.cache_dir, "last-good-#{project.id}.json")
      end

      def remember_environments(project, blob)
        path = last_good_path(project)
        return if File.file?(path) && JSON.parse(File.read(path))["sha"] == blob.sha

        State.ensure_dirs
        temp = "#{path}.#{Process.pid}.tmp"
        File.write(temp, JSON.generate("sha" => blob.sha, "environments" => blob.data["environments"]), perm: 0o600)
        File.rename(temp, path)
      rescue SystemCallError, JSON::ParserError
        nil
      end

      def last_good_environments(project)
        envs = JSON.parse(File.read(last_good_path(project)))["environments"]
        envs.is_a?(Hash) && !envs.empty? ? envs : nil
      rescue SystemCallError, JSON::ParserError
        nil
      end

      def synthesized_environments(project, ledger)
        base = File.join(ledger.envs_root, project.id)
        {
          "dev" => { "branch" => "main", "checkout" => "repo", "tier" => "dev" },
          "test" => { "branch" => "test", "checkout" => File.join(base, "test"), "tier" => "test" },
          "prod" => { "branch" => project.trust_ref, "checkout" => File.join(base, "stable"), "tier" => "prod" }
        }
      end

      def lookup(project, path, kind, ref = project.trust_ref)
        repo = File.expand_path(project.repo)
        return :repo_missing unless File.directory?(repo)

        sha = blob_sha(repo, ref, path)
        return nil if sha.nil?

        env_sha = kind == "policy" ? blob_sha(repo, ref, Environments.path_for(path)) : nil
        key = env_sha ? "#{sha}-#{env_sha}" : sha
        cached = read_cache(kind, key)
        return cached if cached

        text = git(repo, "cat-file", "blob", sha)
        return nil if text.nil?

        env_text = env_sha ? git(repo, "cat-file", "blob", env_sha) : nil
        key = sha if env_text.nil?
        blob = build(kind, key, text, project, env_text, ref)
        write_cache(kind, blob)
        blob
      end

      def blob_sha(repo, ref, path)
        out = git(repo, "rev-parse", "--verify", "--quiet", "#{ref}:#{path}")
        sha = out.to_s.strip
        sha.match?(/\A[0-9a-f]{40,64}\z/) ? sha : nil
      end

      def git(repo, *args)
        out, status = Open3.capture2(GIT_ENV, "git", "-C", repo, *args, err: File::NULL)
        status.success? ? out : nil
      rescue SystemCallError
        nil
      end

      def build(kind, sha, text, project, env_text = nil, ref = project.trust_ref)
        return build_policy(sha, text, project, env_text, ref) if kind == "policy"

        digest = "sha256:#{Digest::SHA256.hexdigest(text)}"
        data = Schema::Document.parse(text, "#{ref}:#{kind}")
        errors = Schema.validate(kind, data).map(&:to_h)
        Blob.new(sha: sha, digest: digest, data: errors.empty? ? data : nil, errors: errors.empty? ? nil : errors)
      rescue Schema::Document::ParseError => e
        Blob.new(sha: sha, digest: digest, data: nil, errors: [{ "pointer" => "", "message" => e.message }])
      end

      def build_policy(sha, text, project, env_text, ref)
        combined = Environments.combine(text, env_text, "#{ref}:policy")
        errors = Array(combined.errors).dup
        errors << { "pointer" => "/project", "message" => "must equal ledger id #{project.id}" } if errors.empty? && combined.data["project"] != project.id
        finding = errors.empty? ? combined.finding : nil
        if finding
          Events.emit("polispec.finding", project: project.id, kind: finding["kind"], detail: finding["detail"], policy_source: "#{ref}:#{sha}")
        end
        Blob.new(sha: sha, digest: combined.digest, data: errors.empty? ? combined.data : nil, errors: errors.empty? ? nil : errors, finding: finding)
      end

      def cache_path(kind, sha)
        File.join(State.cache_dir, "#{kind}-#{Polispec.version}-#{sha}.json")
      end

      def read_cache(kind, sha)
        raw = JSON.parse(File.read(cache_path(kind, sha)))
        Blob.new(sha: sha, digest: raw["digest"], data: raw["data"], errors: raw["errors"], finding: raw["finding"])
      rescue SystemCallError, JSON::ParserError
        nil
      end

      def write_cache(kind, blob)
        State.ensure_dirs
        path = cache_path(kind, blob.sha)
        temp = "#{path}.#{Process.pid}.tmp"
        File.write(temp, JSON.generate("digest" => blob.digest, "data" => blob.data, "errors" => blob.errors, "finding" => blob.finding), perm: 0o600)
        File.rename(temp, path)
      rescue SystemCallError
        nil
      end
    end
  end
end
