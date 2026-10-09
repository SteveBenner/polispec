#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Environments
    Blob = Struct.new(:sha, :digest, :text, :data, :errors, keyword_init: true)
    Combined = Struct.new(:data, :digest, :errors, :finding, keyword_init: true)
    FILE = "environments.yml"
    DEFAULT_POLICY = "specs/polispec/policy.yml"
    GIT_ENV = { "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil, "GIT_OPTIONAL_LOCKS" => "0" }.freeze

    module_function

    def path_for(policy_path)
      named = File.basename(policy_path).match(/\Apolicy\.(.+)\.yml\z/)
      candidate = named && File.join(File.dirname(policy_path), "environments.#{named[1]}.yml")
      return candidate if candidate && File.file?(candidate)

      File.join(File.dirname(policy_path), FILE)
    end

    def policy_keys
      @policy_keys ||= begin
        props = Schema.definition("policy")["$defs"]["environment"]["properties"]
        { top: props.keys, data: props["data"]["properties"].keys }
      end
    end

    def project(env_spec)
      keys = policy_keys
      sliced = env_spec.select { |key, _| keys[:top].include?(key) }
      if sliced["data"].is_a?(Hash)
        data = sliced["data"].select { |key, _| keys[:data].include?(key) }
        data.empty? ? sliced.delete("data") : sliced["data"] = data
      end
      sliced
    end

    def merge(policy_data, environments_data)
      return [policy_data, nil] if environments_data.nil?

      if environments_data["project"] != policy_data["project"]
        detail = "environments.yml project #{environments_data['project']} does not match policy project #{policy_data['project']}"
        return [nil, { "kind" => "environments_invalid", "detail" => detail }]
      end

      merged = JSON.parse(JSON.generate(policy_data))
      merged["environments"] = environments_data["environments"].each_with_object({}) { |(name, spec), memo| memo[name] = project(spec) }
      finding = nil
      if policy_data.key?("environments")
        finding = { "kind" => "environments_duplicate", "detail" => "policy.yml and environments.yml both declare environments; environments.yml wins" }
      end
      [merged, finding]
    end

    def combine(policy_text, environments_text, label)
      digest = "sha256:#{Digest::SHA256.hexdigest(environments_text.nil? ? policy_text : "#{policy_text}\0#{environments_text}")}"
      policy = Schema::Document.parse(policy_text, label)
      unless policy.is_a?(Hash)
        errors = Schema.validate("policy", policy).map(&:to_h)
        return Combined.new(data: errors.empty? ? policy : nil, digest: digest, errors: errors.empty? ? nil : errors)
      end

      env_data = nil
      unless environments_text.nil?
        env_data = Schema::Document.parse(environments_text, "#{label}:#{FILE}")
        env_errors = env_data.is_a?(Hash) ? Schema.validate("environments", env_data).map(&:to_h) : [{ "pointer" => "", "message" => "must be object" }]
        return Combined.new(data: nil, digest: digest, errors: [{ "pointer" => "/#{FILE}", "message" => first_message(env_errors) }]) unless env_errors.empty?
      end

      merged, finding = merge(policy, env_data)
      return Combined.new(data: nil, digest: digest, errors: [{ "pointer" => "/#{FILE}", "message" => finding["detail"] }]) if merged.nil?

      errors = Schema.validate("policy", merged).map(&:to_h)
      Combined.new(data: errors.empty? ? merged : nil, digest: digest, errors: errors.empty? ? nil : errors, finding: finding)
    rescue Schema::Document::ParseError => e
      Combined.new(data: nil, digest: digest, errors: [{ "pointer" => "", "message" => e.message }])
    end

    def first_message(errors)
      first = errors.first
      "#{first['pointer']} #{first['message']}".strip
    end

    def load_policy_text(repo, ref, policy_path)
      policy_text = git(repo, "show", "#{ref}:#{policy_path}")
      return nil if policy_text.nil?

      env_text = git(repo, "show", "#{ref}:#{path_for(policy_path)}")
      combined = combine(policy_text, env_text, policy_path)
      sha = blob_sha(policy_text)
      sha = "#{sha}-#{blob_sha(env_text)}" if env_text
      [combined.data, sha, combined.digest, combined.errors, combined.finding]
    end

    def blob_sha(text)
      Digest::SHA1.hexdigest("blob #{text.bytesize}\0#{text.b}")
    end

    def read_ref(repo, ref, policy_path)
      path = path_for(policy_path)
      sha = git(repo, "rev-parse", "--verify", "--quiet", "#{ref}:#{path}").to_s.strip
      return nil unless sha.match?(/\A[0-9a-f]{40,64}\z/)

      text = git(repo, "cat-file", "blob", sha)
      text.nil? ? nil : build(sha, text, "#{ref}:#{path}")
    end

    def read_file(policy_file_path)
      path = path_for(File.expand_path(policy_file_path))
      return nil unless File.file?(path)

      text = File.read(path)
      build(blob_sha(text), text, path)
    rescue SystemCallError
      nil
    end

    def build(sha, text, label)
      digest = "sha256:#{Digest::SHA256.hexdigest(text)}"
      data = Schema::Document.parse(text, label)
      errors = data.is_a?(Hash) ? Schema.validate("environments", data).map(&:to_h) : [{ "pointer" => "", "message" => "must be object" }]
      Blob.new(sha: sha, digest: digest, text: text, data: errors.empty? ? data : nil, errors: errors.empty? ? nil : errors)
    rescue Schema::Document::ParseError => e
      Blob.new(sha: sha, digest: "sha256:#{Digest::SHA256.hexdigest(text)}", text: text, data: nil, errors: [{ "pointer" => "", "message" => e.message }])
    end

    def full(target, source: :trust_ref, ref: nil, policy_path: DEFAULT_POLICY)
      blob =
        if source == :worktree
          read_file(File.join(File.expand_path(target.to_s), policy_path))
        elsif target.is_a?(String)
          read_ref(File.expand_path(target), ref, policy_path)
        else
          read_ref(File.expand_path(target.repo), ref || target.trust_ref, target.policy)
        end
      blob && blob.errors.nil? ? blob.data : nil
    end

    def git(repo, *args)
      out, status = Open3.capture2(GIT_ENV, "git", "-C", repo, *args, err: File::NULL)
      status.success? ? out : nil
    rescue SystemCallError
      nil
    end
  end
end
