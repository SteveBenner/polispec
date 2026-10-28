#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

module Polispec
  module Visibility
    DEFAULT_FILE = "~/.config/release-gate/visibility.yml"
    GH_TIMEOUT = 1.0
    CACHE_TTL = 3600
    CACHE_NAME = "visibility.json"
    GITHUB = "github.com"
    PUBLIC_ANSWERS = %w[PUBLIC INTERNAL].freeze
    SCHEME = %r{\A[a-z][a-z0-9+.-]*://}i.freeze
    SCP_FORM = %r{\A(?:[^@/\s]+@)?([^:/\s]+):(?!\d+(?:/|\z))(.+)\z}.freeze
    EMPTY_LISTS = { "public_remotes" => [], "private_remotes" => [] }.freeze

    module_function

    def normalize(url)
      text = url.to_s.strip
      return "" if text.empty?

      path = if text.match?(SCHEME)
               rest = text.sub(SCHEME, "")
               authority, tail = rest.split("/", 2)
               host = authority.to_s.sub(/\A.*@/, "").sub(/:\d+\z/, "")
               "#{host}/#{tail}"
             elsif (scp = text.match(SCP_FORM))
               "#{scp[1]}/#{scp[2]}"
             else
               text
             end
      path.sub(%r{/+\z}, "").sub(/\.git\z/, "").sub(%r{/+\z}, "")
    end

    def url_like?(text)
      text.to_s.include?("://") || text.to_s.match?(/@[^:\/\s]+:/)
    end

    def branch_of(dir)
      Predicates.git_ok(dir, "symbolic-ref", "-q", "--short", "HEAD")
    end

    def remote_name(dir, name)
      return name.to_s unless name.to_s.empty?

      branch = branch_of(dir)
      configured = branch ? Predicates.git_ok(dir, "config", "--get", "branch.#{branch}.remote") : nil
      configured.to_s.empty? || configured == "." ? "origin" : configured
    end

    def remote_url(dir, name = nil)
      return name.to_s if url_like?(name)

      Predicates.git_ok(dir, "remote", "get-url", remote_name(dir, name))
    end

    def read_lists
      path = File.expand_path(Engine::Settings.text(Engine::Settings::EXPOSURE_VISIBILITY_KEY, DEFAULT_FILE))
      data = YAML.safe_load(File.read(path), aliases: false)
      return EMPTY_LISTS unless data.is_a?(Hash)

      %w[public_remotes private_remotes].to_h { |key| [key, Array(data[key]).map(&:to_s)] }
    rescue SystemCallError, Psych::SyntaxError, Psych::DisallowedClass
      EMPTY_LISTS
    end

    def listed?(globs, norm)
      globs.any? { |glob| File.fnmatch(glob, norm, File::FNM_CASEFOLD) }
    end

    def of(url)
      norm = normalize(url)
      return :public if norm.empty?

      lists = read_lists
      return :public if listed?(lists["public_remotes"], norm)
      return :private if listed?(lists["private_remotes"], norm)

      slug = github_slug(norm)
      slug ? from_github(slug) : :public
    end

    def public?(url)
      of(url) == :public
    end

    def github_slug(norm)
      host, owner, repo = norm.split("/", 4)
      return nil unless host.to_s.casecmp?(GITHUB) && !owner.to_s.empty? && !repo.to_s.empty?

      "#{owner}/#{repo}"
    end

    def from_github(slug)
      cached = cache_read(slug)
      return cached if cached

      out, status, = Predicates.capture(["gh", "repo", "view", slug, "--json", "visibility", "--jq", ".visibility"], timeout: GH_TIMEOUT)
      return :public unless status.success?

      answer = out.strip.upcase
      verdict = if PUBLIC_ANSWERS.include?(answer)
                  :public
                elsif answer == "PRIVATE"
                  :private
                end
      return :public unless verdict

      cache_write(slug, verdict)
      verdict
    rescue Predicates::Expired
      :public
    rescue StandardError
      :public
    end

    def cache_file
      File.join(Predicates.cache_dir, CACHE_NAME)
    end

    def cache_read(slug)
      entry = JSON.parse(File.read(cache_file)).dig("entries", slug.downcase)
      return nil unless entry.is_a?(Hash) && Time.now.to_f - entry["at"].to_f < CACHE_TTL

      %w[public private].include?(entry["visibility"]) ? entry["visibility"].to_sym : nil
    rescue SystemCallError, JSON::ParserError, TypeError, NoMethodError
      nil
    end

    def cache_write(slug, verdict)
      entries = cache_entries
      entries[slug.downcase] = { "visibility" => verdict.to_s, "at" => Time.now.to_f }
      FileUtils.mkdir_p(Predicates.cache_dir, mode: 0o700)
      tmp = "#{cache_file}.#{Process.pid}"
      File.write(tmp, JSON.generate("entries" => entries), perm: 0o600)
      File.rename(tmp, cache_file)
    rescue SystemCallError
      nil
    end

    def cache_entries
      entries = JSON.parse(File.read(cache_file))["entries"]
      entries.is_a?(Hash) ? entries : {}
    rescue SystemCallError, JSON::ParserError, TypeError
      {}
    end
  end
end
