#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "yaml"
require "time"
require "open3"
require "fileutils"
require "find"
require "digest"
require_relative "git_safe"
require_relative "operator/git"

module Polispec
  module NativePin
    URL_PATTERN = %r{\A(https?|ssh|git)://|\A[^/]+@[^:]+:}
    REF_PATTERN = %r{\A[0-9A-Za-z][0-9A-Za-z._/-]*\z}
    READ_VERBS = %w[rev-parse show-ref show verify-tag cat-file].freeze
    SIGNERS_KEY = "polispec.pin.allowed_signers"
    VERIFY_CONFIG = ["-c", "gpg.format=ssh", "-c", "gpg.program=/usr/bin/gpg", "-c", "gpg.ssh.program=/usr/bin/ssh-keygen", "-c", "gpg.x509.program=/usr/bin/gpgsm"].freeze
    PINNED_TAGS = "pinned-tags.json"
    TRANSPORTS = "https:http:ssh:git"

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

    def source_cache(source)
      File.join(data_home, "source-#{Digest::SHA256.hexdigest(source.to_s)[0, 16]}.git")
    end

    def pinned_tags_path
      File.join(State.home, PINNED_TAGS)
    end

    def pinned_tags
      data = JSON.parse(File.read(pinned_tags_path))
      data.is_a?(Hash) ? data : {}
    rescue SystemCallError, JSON::ParserError
      {}
    end

    def record_tag(ref, commit)
      tags = pinned_tags.merge(ref => commit)
      FileUtils.mkdir_p(State.home, mode: 0o700)
      temporary = "#{pinned_tags_path}.#{Process.pid}.tmp"
      File.write(temporary, "#{JSON.pretty_generate(tags)}\n", perm: 0o600)
      File.rename(temporary, pinned_tags_path)
    end

    def check_moved!(ref, commit, accept, dry_run, notes)
      known = pinned_tags[ref]
      return if known.nil? || known == commit

      failure = Operator::Failure.new("pin_tag_moved", "tag #{ref} was pinned at #{known} and now resolves to #{commit}; a moved tag is refused unless the operator passes --accept-moved-tag from a terminal and types the phrase", "recorded" => known, "now" => commit)
      raise failure unless accept

      if dry_run
        notes << "tag #{ref} moved from #{known[0, 12]} to #{commit[0, 12]}; the pin would ask for the phrase accept moved tag #{ref}"
        return
      end
      begin
        Operator::Tty.confirm!("accept moved tag #{ref}", prompt: "tag #{ref} moved from #{known} to #{commit}")
      rescue Operator::Tty::NotTty, Operator::Tty::PhraseMismatch
        raise failure
      end
    end

    def signed_tag?(path, ref)
      body = git("-C", path, "cat-file", "tag", "refs/tags/#{ref}")
      body.match?(/-----BEGIN (PGP|SSH) SIGNATURE-----/)
    rescue Polispec::Error
      false
    end

    def ssh_signed_tag?(path, ref)
      body = git("-C", path, "cat-file", "tag", "refs/tags/#{ref}")
      body.include?("-----BEGIN SSH SIGNATURE-----") && !body.match?(/-----BEGIN (PGP|SIGNED MESSAGE)/)
    rescue Polispec::Error
      false
    end

    def verify_tag!(path, ref, notes)
      signers = Engine::Settings.text(SIGNERS_KEY, "")
      if signers.empty?
        notes << "tag #{ref} is #{signed_tag?(path, ref) ? 'signed but' : 'unsigned and'} was not signature-checked; set #{SIGNERS_KEY} to a signers file to require a verified tag"
        return
      end
      file = File.expand_path(signers)
      raise Operator::Failure.new("pin_tag_unverified", "#{SIGNERS_KEY} names #{file}, which is not a file") unless File.file?(file)

      unless ssh_signed_tag?(path, ref)
        raise Operator::Failure.new("pin_tag_unverified", "tag #{ref} does not carry an SSH signature, so it cannot be checked against #{file}")
      end

      begin
        git("-C", path, *VERIFY_CONFIG, "-c", "gpg.ssh.allowedSignersFile=#{file}", "verify-tag", ref)
      rescue Polispec::Error => e
        raise Operator::Failure.new("pin_tag_unverified", "tag #{ref} is unsigned or does not verify against #{file}: #{e.message}")
      end
      notes << "tag #{ref} verified against #{file}"
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
      env = GitSafe.env("LC_ALL" => "C", "GIT_TERMINAL_PROMPT" => "0", "GIT_ALLOW_PROTOCOL" => TRANSPORTS)
      rest = args.dup
      rest.shift(2) while %w[-C -c].include?(rest.first)
      verb = rest.first
      mode = READ_VERBS.include?(verb) ? :quiet : nil
      out, err, status = Trace.capture3(env, *GitSafe.argv_bare(*args), trace: mode)
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

    def pin!(ref: nil, source: nil, dry_run: false, gate: nil, accept_moved: false)
      ref = (ref || default_ref).to_s
      raise Polispec::Error, "invalid ref #{ref.inspect}" unless REF_PATTERN.match?(ref)

      given = (source || default_source).to_s
      raise Polispec::Error, "no source to pin from" if given.empty?

      remote = url?(given)
      given = File.expand_path(given) unless remote
      Trace.info("pin source", ref: ref, source: given, remote: remote, dry_run: dry_run)
      steps = []
      fetched = nil
      path = given
      if remote
        path = source_cache(given)
        if File.directory?(path)
          steps << "fetch tags from #{given} into #{path}"
          unless dry_run
            Trace.step("fetch tags", source: given, into: Trace.path(path)) do
              git("-C", path, "fetch", "--tags", "--force", "origin")
            end
            fetched = "fetched #{given} into #{path}"
          end
        else
          steps << "clone #{given} into #{path} (bare)"
          unless dry_run
            FileUtils.mkdir_p(data_home)
            Trace.step("clone source", source: given, into: Trace.path(path)) do
              git("clone", "--bare", "--filter=blob:none", "--", given, path)
            end
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

      commit = Trace.step("resolve ref", ref: ref, source: Trace.path(path)) do
        found = resolve(path, ref)
        Trace.info("resolved", ref: ref, commit: found)
        found
      end
      verify_tag!(path, ref, result["notes"])
      check_moved!(ref, commit, accept_moved, dry_run, result["notes"])
      release = File.join(releases_dir, commit)
      result["commit"] = commit
      result["release"] = release

      if File.directory?(release) && release_valid?(release)
        steps << "keep existing release #{release}"
        Trace.info("release already present and valid, nothing to extract", release: Trace.path(release))
      else
        steps << "extract #{ref} (#{commit[0, 12]}) into #{release}, read-only"
        Trace.step("archive release", commit: commit[0, 12], into: Trace.path(release)) { extract!(path, commit, ref, given, release) } unless dry_run
      end

      Trace.step("gate the pin") { gate.call(result) } if gate && !dry_run
      steps << "point #{current_link} at releases/#{commit}"
      Trace.step("swap current link", link: Trace.path(current_link), target: "releases/#{commit}") { swap_current(commit) } unless dry_run
      record_tag(ref, commit) unless dry_run

      result["bin_link"] = Trace.step("link ~/.local/bin/polispec") { link_bin!(result["notes"], steps, dry_run) }
      Trace.step("record deployment") { record_deployment(result, given) } unless dry_run
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
        if Trace.on?
          Trace.command(GitSafe.argv_bare("-C", path, "archive", "--format=tar", commit))
          Trace.command(["tar", "-x", "-C", tmp])
          archive_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
        statuses = Open3.pipeline(GitSafe.argv_bare("-C", path, "archive", "--format=tar", commit), ["tar", "-x", "-C", tmp])
        if Trace.on?
          statuses.each { |item| Trace.exit_line(item.exitstatus || -1, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - archive_started) * 1000) }
        end
        raise Polispec::Error, "could not extract #{commit[0, 12]} from #{path}" unless statuses.all?(&:success?)

        version = File.read(File.join(tmp, "VERSION")).strip
        Trace.step("make tree read-only") { make_read_only(tmp) }
        previous = File.symlink?(current_link) ? File.readlink(current_link) : nil
        record = {
          "schema" => Runtime::NATIVE_RELEASE_SCHEMA,
          "id" => ID,
          "ref" => ref,
          "commit" => commit,
          "version" => version,
          "source" => given,
          "tree_digest" => Trace.step("verify tree digest") { Runtime.tree_digest(tmp) },
          "installed_at" => Time.now.utc.iso8601,
          "previous_target" => previous
        }
        file = File.join(tmp, Runtime::NATIVE_RELEASE_FILE)
        File.write(file, "#{JSON.pretty_generate(record)}\n")
        File.chmod(0o444, file)
        File.chmod(File.stat(tmp).mode & ~0o222, tmp)
        File.rename(tmp, release)
        Trace.info("release written", release: Trace.path(release), version: version, tree_digest: record["tree_digest"])
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
          Trace.info("link left in place", link: Trace.path(link), points_at: shown)
          notes << "kept #{link} (points at #{shown}); the native pin is at #{target}"
          return nil
        end
        if File.readlink(link) == target
          Trace.info("link already current", link: Trace.path(link))
          return link
        end
      end
      steps << "link #{link} to #{target}"
      return link if dry_run

      Trace.info("linking", link: Trace.path(link), target: Trace.path(target))

      FileUtils.mkdir_p(File.dirname(link))
      temporary = "#{link}.tmp-#{Process.pid}"
      File.symlink(target, temporary)
      File.rename(temporary, link)
      link
    end
  end
end
