#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "yaml"
require "time"
require "open3"
require "fileutils"
require "find"

module Polispec
  module NativePin
    URL_PATTERN = %r{\A(https?|ssh|git)://|\A[^/]+@[^:]+:}
    REF_PATTERN = %r{\A[0-9A-Za-z][0-9A-Za-z._/-]*\z}

    module_function

    def data_home
      explicit = ENV["POLISPEC_DATA_HOME"].to_s
      return File.expand_path(explicit) unless explicit.empty?

      base = ENV["XDG_DATA_HOME"].to_s
      base = File.join(Dir.home, ".local", "share") if base.empty?
      File.join(File.expand_path(base), "polispec")
    end

    def releases_dir
      File.join(data_home, "releases")
    end

    def current_link
      File.join(data_home, "current")
    end

    def source_cache
      File.join(data_home, "source.git")
    end

    def bin_link
      File.join(Dir.home, ".local", "bin", "polispec")
    end

    def default_ref
      "v#{Polispec.version}"
    end

    def public_source
      manifest = YAML.safe_load(File.read(File.join(ROOT, "polispec.rplugin.yml")), permitted_classes: [], aliases: false)
      repository = manifest["repository"]
      remote = repository.is_a?(Hash) ? repository["remote"] : repository
      remote = remote.to_s
      raise Polispec::Error, "polispec.rplugin.yml names no repository" if remote.empty?

      remote.end_with?(".git") ? remote : "#{remote}.git"
    rescue SystemCallError, Psych::Exception, NoMethodError
      raise Polispec::Error, "cannot read the repository from polispec.rplugin.yml"
    end

    def default_source
      return Runtime.root if Runtime.kind == "clone"
      return Runtime.release["source"].to_s if Runtime.pinned? && !Runtime.release["source"].to_s.empty?

      public_source
    end

    def url?(value)
      URL_PATTERN.match?(value.to_s)
    end

    def git(*args)
      env = { "LC_ALL" => "C", "GIT_TERMINAL_PROMPT" => "0" }
      out, err, status = Open3.capture3(env, "git", *args)
      raise Polispec::Error, "git #{args.first(2).join(' ')} failed: #{(err.empty? ? out : err).strip.lines.last.to_s.strip}" unless status.success?

      out
    rescue SystemCallError => e
      raise Polispec::Error, "git is not available: #{e.message}"
    end

    def release_valid?(dir)
      Runtime::RELEASE_FILES.any? do |name|
        path = File.join(dir, name)
        next false unless File.file?(path) && !File.symlink?(path)

        data = JSON.parse(File.read(path))
        data.is_a?(Hash) && data["commit"].to_s == File.basename(dir)
      rescue JSON::ParserError, SystemCallError
        false
      end
    end

    def pin!(ref: nil, source: nil, dry_run: false)
      ref = (ref || default_ref).to_s
      raise Polispec::Error, "invalid ref #{ref.inspect}" unless REF_PATTERN.match?(ref)

      given = (source || default_source).to_s
      raise Polispec::Error, "no source to pin from" if given.empty?

      remote = url?(given)
      given = File.expand_path(given) unless remote
      steps = []
      fetched = nil
      path = given
      if remote
        path = source_cache
        if File.directory?(path)
          steps << "fetch tags from #{given} into #{path}"
          unless dry_run
            git("-C", path, "fetch", "--tags", "--force", "origin")
            fetched = "fetched #{given} into #{path}"
          end
        else
          steps << "clone #{given} into #{path} (bare)"
          unless dry_run
            FileUtils.mkdir_p(data_home)
            git("clone", "--bare", "--filter=blob:none", given, path)
            fetched = "cloned #{given} into #{path}"
          end
        end
      end

      result = { "ref" => ref, "commit" => nil, "release" => nil, "current" => current_link, "bin_link" => nil, "fetched" => fetched, "steps" => steps, "notes" => [] }
      unless File.directory?(path)
        raise Polispec::Error, "source #{path} is not a directory" unless dry_run

        steps << "resolve #{ref} to a commit after the fetch"
        steps << "extract the tagged tree into #{releases_dir}/<commit>, read-only"
        steps << "point #{current_link} at it"
        steps << "link #{bin_link} to #{current_link}/bin/polispec"
        return result
      end

      commit = resolve(path, ref)
      release = File.join(releases_dir, commit)
      result["commit"] = commit
      result["release"] = release

      if File.directory?(release) && release_valid?(release)
        steps << "keep existing release #{release}"
      else
        steps << "extract #{ref} (#{commit[0, 12]}) into #{release}, read-only"
        extract!(path, commit, ref, given, release) unless dry_run
      end

      steps << "point #{current_link} at releases/#{commit}"
      swap_current(commit) unless dry_run

      result["bin_link"] = link_bin!(result["notes"], steps, dry_run)
      record_deployment(result, given) unless dry_run
      result
    end

    def record_deployment(result, source)
      require_relative "deployments"
      version = begin
        JSON.parse(File.read(File.join(result["release"], Runtime::NATIVE_RELEASE_FILE)))["version"]
      rescue StandardError
        nil
      end
      Deployments.record(kind: "pin", target: current_link, details: { "commit" => result["commit"], "release" => result["release"], "ref" => result["ref"], "source" => source, "version" => version, "bin_link" => result["bin_link"] })
    end

    def resolve(path, ref)
      commit = git("-C", path, "rev-parse", "--verify", "#{ref}^{commit}").strip
      begin
        git("-C", path, "show-ref", "--verify", "--quiet", "refs/tags/#{ref}")
      rescue Polispec::Error
        raise Polispec::Error, "#{ref} is not a tag in #{path}; pin only a release tag"
      end
      version = git("-C", path, "show", "#{commit}:VERSION").strip
      expected = ref.sub(/\Av/, "")
      raise Polispec::Error, "tag #{ref} carries VERSION #{version.empty? ? 'none' : version}, not #{expected}" unless version == expected

      commit
    end

    def extract!(path, commit, ref, given, release)
      FileUtils.mkdir_p(releases_dir)
      tmp = "#{release}.tmp-#{Process.pid}"
      FileUtils.mkdir_p(tmp)
      begin
        statuses = Open3.pipeline(["git", "-C", path, "archive", "--format=tar", commit], ["tar", "-x", "-C", tmp])
        raise Polispec::Error, "could not extract #{commit[0, 12]} from #{path}" unless statuses.all?(&:success?)

        version = File.read(File.join(tmp, "VERSION")).strip
        make_read_only(tmp)
        previous = File.symlink?(current_link) ? File.readlink(current_link) : nil
        record = {
          "schema" => Runtime::NATIVE_RELEASE_SCHEMA,
          "id" => ID,
          "ref" => ref,
          "commit" => commit,
          "version" => version,
          "source" => given,
          "tree_digest" => Runtime.tree_digest(tmp),
          "installed_at" => Time.now.utc.iso8601,
          "previous_target" => previous
        }
        file = File.join(tmp, Runtime::NATIVE_RELEASE_FILE)
        File.write(file, "#{JSON.pretty_generate(record)}\n")
        File.chmod(0o444, file)
        File.chmod(File.stat(tmp).mode & ~0o222, tmp)
        File.rename(tmp, release)
      rescue StandardError
        restore_writable(tmp)
        raise
      end
    end

    def make_read_only(root)
      dirs = []
      Find.find(root) do |entry|
        stat = File.lstat(entry)
        next if stat.symlink?

        if stat.directory?
          dirs << entry unless entry == root
        else
          File.chmod(stat.mode & 0o7777 & ~0o222, entry)
        end
      end
      dirs.reverse_each { |dir| File.chmod(File.stat(dir).mode & 0o7777 & ~0o222, dir) }
    end

    def restore_writable(root)
      return unless File.directory?(root)

      Find.find(root) do |entry|
        stat = File.lstat(entry)
        File.chmod(stat.mode & 0o7777 | 0o200, entry) if stat.directory?
      end
    rescue SystemCallError
      nil
    end

    def swap_current(commit)
      FileUtils.mkdir_p(data_home)
      temporary = "#{current_link}.tmp-#{Process.pid}"
      File.symlink(File.join("releases", commit), temporary)
      File.rename(temporary, current_link)
    end

    def link_bin!(notes, steps, dry_run)
      link = bin_link
      target = File.join(current_link, "bin", "polispec")
      existing = File.symlink?(link)
      if File.exist?(link) || existing
        owned = existing && File.readlink(link).start_with?("#{data_home}/")
        unless owned
          shown = existing ? File.readlink(link) : "a regular file"
          notes << "kept #{link} (points at #{shown}); the native pin is at #{target}"
          return nil
        end
        return link if File.readlink(link) == target
      end
      steps << "link #{link} to #{target}"
      return link if dry_run

      FileUtils.mkdir_p(File.dirname(link))
      temporary = "#{link}.tmp-#{Process.pid}"
      File.symlink(target, temporary)
      File.rename(temporary, link)
      link
    end
  end
end
