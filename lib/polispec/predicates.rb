#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "editions"

module Polispec
  module Predicates
    NAMES = %w[lock_held live_binary delete_protected delete_protected_file delete_unbacked supervised pin_regress tag_claimed base_unpushed public_remote public_path push_unscanned in_development].freeze
    BUDGET = 2.0
    CONTENTS_LEAVES = %w[* .* .[!.]* ..?* .??*].freeze
    LOCK_MANIFEST = "TMP_AGENT_FILE_LOCKS.yml".freeze
    UNOWNED_WINDOW = 600
    CALLER = :polispec_caller_pid
    SUPERVISOR_TTL = 60
    SUPERVISOR_TIMEOUT = 1.0
    STALE_FETCH = 3600
    ZERO = /\A0+\z/.freeze
    BLUEPRINT_NAMES = %w[*.impl.yml DECISIONS.md TOKENS.jsonl WIP.md NOTES.md].freeze
    BLUEPRINT_DIRS = %w[.rproject .scratch .specstory].freeze

    Result = Struct.new(:match, :note, :finding)

    class Expired < StandardError; end

    module_function

    def check_in_development(action, ctx)
      return no unless Engine::Settings.relax_dev?
      return no unless Editions.allowed?("relax.dev", HarnessControls::Plane.requested_edition)

      ledger = ctx[:ledger] || Ledger.load
      data = hint(action)
      ids = ledger.development(data["path"].to_s)
      return no unless ids

      Array(data["cwds"]).each do |dir|
        more = ledger.development(dir)
        next if more.nil? && ledger.locate(dir).nil?
        return no unless more

        ids |= more
      end
      yes("in development: #{ids.join(', ')}")
    end

    def evaluate(name, action, ctx)
      memo = ctx[:predicate_memo]
      return compute(name, action, ctx) unless memo

      key = [name, action.__id__]
      return memo[key] if memo.key?(key)

      memo[key] = compute(name, action, ctx).tap { |result| record(result, ctx) }
    end

    def notes(match, action, ctx)
      memo = ctx[:predicate_memo] || {}
      NAMES.filter_map { |name| memo[[name, action.__id__]]&.note if match.is_a?(Hash) && !match[name].nil? }
    end

    def record(result, ctx)
      findings = ctx[:findings]
      findings << result.finding if findings && result.finding && !findings.include?(result.finding)
    end

    def compute(name, action, ctx)
      deadline_for do
        send("check_#{name}", action, ctx)
      end
    rescue Expired
      Result.new(false, nil, "#{name} exceeded its #{BUDGET.to_i} s budget")
    rescue StandardError => e
      Result.new(false, nil, "#{name} failed: #{e.class}: #{e.message}")
    end

    def deadline_for
      Thread.current[:polispec_deadline] = monotonic + BUDGET
      yield
    ensure
      Thread.current[:polispec_deadline] = nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def remaining
      left = (Thread.current[:polispec_deadline] || (monotonic + BUDGET)) - monotonic
      raise Expired if left <= 0

      left
    end

    def hint(action)
      Engine::Envs.hint_of(action)
    end

    def shapes(action)
      hint(action)["shape"].to_a.map(&:to_s)
    end

    def yes(note = nil)
      Result.new(true, note, nil)
    end

    def no(finding = nil)
      Result.new(false, nil, finding)
    end

    def capture(argv, dir: nil, env: {}, timeout: nil)
      limit = [remaining, timeout || BUDGET].min
      options = dir ? { chdir: dir } : {}
      Open3.popen3(env, *argv, **options) do |stdin, stdout, stderr, thread|
        stdin.close
        reader = Thread.new { stdout.read }
        drain = Thread.new { stderr.read }
        [reader, drain].each { |worker| worker.report_on_exception = false }
        unless thread.join(limit)
          Process.kill("TERM", thread.pid)
          thread.join(0.5) || Process.kill("KILL", thread.pid)
          [reader, drain].each(&:kill)
          raise Expired
        end
        [reader.value.to_s, thread.value, drain.value.to_s]
      end
    rescue Errno::ENOENT, Errno::EACCES => e
      raise StandardError, e.message
    end

    def git(dir, *args)
      out, status, = capture(["git", "-C", dir.to_s, *args], env: PolicySource::GIT_ENV)
      [out, status]
    end

    def git_ok(dir, *args)
      out, status = git(dir, *args)
      status.success? ? out.strip : nil
    end

    def toplevel(path)
      dir = File.expand_path(path.to_s)
      dir = File.dirname(dir) until File.directory?(dir) || dir == "/"
      loop do
        return dir if File.exist?(File.join(dir, ".git"))

        parent = File.dirname(dir)
        return nil if parent == dir

        dir = parent
      end
    end

    def proc_start(pid)
      text = File.read("/proc/#{pid}/stat")
      text[(text.rindex(")") + 1)..].split[19].to_i
    rescue SystemCallError, NoMethodError
      nil
    end

    def proc_parent(pid)
      text = File.read("/proc/#{pid}/stat")
      text[(text.rindex(")") + 1)..].split[1].to_i
    rescue SystemCallError, NoMethodError
      nil
    end

    def boot_id
      File.read("/proc/sys/kernel/random/boot_id").strip
    rescue SystemCallError
      nil
    end

    def ancestors(pid = Process.pid)
      chain = []
      64.times do
        chain << pid
        pid = proc_parent(pid)
        break if pid.nil? || pid <= 0 || chain.include?(pid)
      end
      chain
    end

    def check_lock_held(action, _ctx)
      path = hint(action)["path"]
      return no if path.to_s.empty? || Engine.store_ref?(path)

      target = File.expand_path(path)
      top = toplevel(target)
      return no unless top

      manifest = File.join(top, LOCK_MANIFEST)
      return no unless File.file?(manifest)

      holder = live_holder(manifest, [target, Engine::Envs.canonical(target)].uniq)
      holder ? yes("#{target} is locked by #{holder}") : no
    end

    def live_holder(manifest, targets)
      doc = YAML.safe_load(File.read(manifest), permitted_classes: [Time, Date], aliases: false)
      entries = doc.is_a?(Hash) ? Array(doc["locks"]) : []
      mtime = File.mtime(manifest)
      mine = ancestors(Thread.current[CALLER] || Process.pid)
      entries.each do |entry|
        next unless entry.is_a?(Hash) && entry["path"].is_a?(String) && entry["agent_id"].is_a?(String)
        next unless targets.include?(File.expand_path(entry["path"])) || targets.include?(Engine::Envs.canonical(File.expand_path(entry["path"])))

        who = entry_holder(entry, mine, mtime)
        return who if who
      end
      nil
    end

    def entry_holder(entry, mine, mtime)
      label = "agent #{entry['agent_id']}"
      return owned_holder(entry, mine, label) if entry["owner_pid"] && entry["owner_start"] && entry["owner_boot"]

      stamp = entry["acquired_at"]
      acquired = stamp.is_a?(Time) ? stamp : (Time.parse(stamp.to_s) rescue mtime)
      Time.now - acquired < UNOWNED_WINDOW ? "#{label} (no owner recorded, acquired #{acquired.utc.iso8601})" : nil
    end

    def owned_holder(entry, mine, label)
      pid = Integer(entry["owner_pid"])
      return nil if mine.include?(pid)
      return nil unless entry["owner_boot"].to_s == boot_id
      return nil unless proc_start(pid) == Integer(entry["owner_start"])

      "#{label} (pid #{pid})"
    end

    def check_live_binary(action, _ctx)
      target = binary_target(action)
      return no unless target

      root = Engine::Envs.canonical(File.expand_path(target))
      uid = Process.uid
      Dir.children("/proc").each do |name|
        next unless name.match?(/\A\d+\z/)

        remaining
        found = running_from(name, uid, root)
        return yes("pid #{name} is running #{found}") if found
      end
      no
    end

    def binary_target(action)
      data = hint(action)
      return data["target_dir"] if shapes(action).include?("cargo_clean") && data["target_dir"]

      action.action_class == "fs.delete" ? data["path"] : nil
    end

    def running_from(pid, uid, root)
      return nil unless File.stat("/proc/#{pid}").uid == uid

      exe = File.readlink("/proc/#{pid}/exe").sub(/ \(deleted\)\z/, "")
      Engine::Envs.under?(exe, root) ? exe : nil
    rescue SystemCallError
      nil
    end

    def check_delete_protected(action, ctx)
      kind, note = delete_verdict(action, ctx)
      kind == :deny ? yes(note) : no
    end

    def check_delete_protected_file(action, ctx)
      kind, note = delete_verdict(action, ctx)
      kind == :file ? yes(note) : no
    end

    def check_delete_unbacked(action, _ctx)
      return no unless action.action_class == "fs.delete"

      data = hint(action)
      target = data["path"]
      return no unless data["command"] == "rm" && data["recursive"] == true && data["unresolved"] != true
      return no unless target.is_a?(String) && !target.empty?

      lexical = File.expand_path(target)
      name = File.basename(lexical)
      return no if CONTENTS_LEAVES.include?(File.basename(target))
      return no unless File.directory?(lexical) && !File.symlink?(lexical)
      return no if backup_path?(lexical)

      return no if Layers.shipped_delete_backup.include?(name) && git_ignored?(File.dirname(lexical), lexical)

      yes("recursive delete of the directory #{lexical}; confirm this exact path with the user, and make no copy of it beside the original")
    end

    def backup_path?(lexical)
      File.basename(lexical) == "backups" || lexical.split("/").include?(".backup")
    end

    def git_ignored?(parent, lexical)
      _out, status = git(parent, "check-ignore", "-q", "--", lexical)
      status.success?
    end

    def delete_verdict(action, ctx)
      return nil unless action.action_class == "fs.delete"

      target = hint(action)["path"]
      return nil unless target.is_a?(String) && !target.empty?

      contents = CONTENTS_LEAVES.include?(File.basename(target))
      recursive = hint(action)["recursive"] == true
      base = contents ? File.dirname(target) : target
      lexical = File.expand_path(base)
      forms = [lexical, Engine::Envs.canonical(lexical)]
      found = delete_entries(ctx).filter_map { |kind, entry| delete_entry_verdict(forms, entry, kind, contents, recursive) }
      found.find { |verdict| verdict.first == :deny } || found.first
    end

    def delete_entry_verdict(forms, entry, kind, contents, recursive)
      lexical = File.expand_path(entry)
      pairs = forms.zip([lexical, Engine::Envs.canonical(lexical)])
      equal = pairs.any? { |base, root| base == root }
      real = lexical == pairs.last.last
      under = Engine::Envs.under?(*pairs.first) || (real && Engine::Envs.under?(*pairs.last))
      ancestor = pairs.any? { |base, root| base != root && Engine::Envs.under?(root, base) }
      tree = kind == :tree
      label = "#{entry} (#{kind})"
      return [:deny, "reaches protected #{label}"] if equal && kind == :exact
      return [:deny, "reaches protected #{label}"] if contents && (equal || ancestor || (tree && under))
      return [:deny, "reaches protected #{label}"] if !contents && recursive && ((tree && (equal || under)) || ancestor)
      return [:file, "lies under protected #{label}"] if !contents && !recursive && tree && (equal || under)

      nil
    end

    def delete_entries(ctx)
      docs = []
      shelf = ctx[:global]
      if shelf.is_a?(Hash)
        docs << shelf
        docs.concat(shelf["modules"].values) if shelf["modules"].is_a?(Hash)
      end
      union = Layers.delete_protected_union(docs)
      shipped = Layers.shipped_delete_protected
      %w[exact tree].flat_map { |kind| (shipped[kind] + union[kind]).uniq.map { |path| [kind.to_sym, path] } }
    end

    def check_supervised(action, _ctx)
      return no unless action.action_class == "service.control"

      data = hint(action)
      pattern = shapes(action).include?("pattern_kill")
      status = supervisor_status
      unless status[:ok]
        return pattern ? Result.new(true, "supervisor status unavailable, treated as supervised", status[:finding]) : no(status[:finding])
      end

      supervised_target?(data, status) ? yes("#{describe_target(data)} belongs to a supervised component") : no
    end

    def describe_target(data)
      data["pid"] ? "pid #{data['pid']}" : "unit #{data['unit']}"
    end

    def supervised_target?(data, status)
      return status[:pids].include?(data["pid"].to_i) if data["pid"]

      name = Engine::Envs.unit_name(data["unit"])
      return false if name.nil?

      units = status[:units]
      data["fuzzy"] ? units.any? { |unit| unit == name || unit.include?(name) } : units.include?(name)
    end

    def supervisor_status
      argv = Engine::Settings.argv(Engine::Settings::SUPERVISOR_KEY)
      return { ok: false, finding: "polispec.supervisor.status_command is not set; supervised is unavailable" } if argv.empty?

      cached = read_status_cache(argv)
      return cached if cached

      fresh_status(argv)
    end

    def fresh_status(argv)
      out, status, = capture(argv, timeout: SUPERVISOR_TIMEOUT)
      return { ok: false, finding: "supervisor status command exited #{status.exitstatus}" } unless status.success?

      parsed = parse_status(out)
      return { ok: false, finding: "supervisor status command printed unparseable output" } unless parsed

      write_status_cache(argv, parsed)
      parsed.merge(ok: true)
    rescue Expired
      { ok: false, finding: "supervisor status command exceeded #{SUPERVISOR_TIMEOUT} s" }
    rescue StandardError => e
      { ok: false, finding: "supervisor status command failed: #{e.message}" }
    end

    def parse_status(text)
      data = JSON.parse(text)
      return nil unless data.is_a?(Hash) && data["units"].is_a?(Array) && data["pids"].is_a?(Array)

      { units: data["units"].map { |unit| Engine::Envs.unit_name(unit) }.compact, pids: data["pids"].map(&:to_i) }
    rescue JSON::ParserError
      nil
    end

    def cache_dir
      home = ENV["POLISPEC_HOME"].to_s
      home.empty? ? State.cache_dir : File.join(File.expand_path(home), "cache")
    end

    def cache_file
      File.join(cache_dir, "supervisor-status.json")
    end

    def read_status_cache(argv)
      data = JSON.parse(File.read(cache_file))
      return nil unless data["argv"] == argv && Time.now.to_f - data["fetched_at"].to_f < SUPERVISOR_TTL

      { ok: true, units: Array(data["units"]), pids: Array(data["pids"]).map(&:to_i) }
    rescue SystemCallError, JSON::ParserError, TypeError
      nil
    end

    def write_status_cache(argv, parsed)
      FileUtils.mkdir_p(cache_dir, mode: 0o700)
      tmp = "#{cache_file}.#{Process.pid}"
      File.write(tmp, JSON.generate("argv" => argv, "fetched_at" => Time.now.to_f, "units" => parsed[:units], "pids" => parsed[:pids]), perm: 0o600)
      File.rename(tmp, cache_file)
    rescue SystemCallError
      nil
    end

    def check_pin_regress(action, _ctx)
      return no unless action.action_class == "git.commit"

      repo = hint(action)["path"]
      return no if repo.to_s.empty?

      top = git_ok(repo, "rev-parse", "--show-toplevel")
      return no unless top

      scopes = [%w[diff --cached]]
      scopes << %w[diff] if shapes(action).include?("bulk_stage")
      scopes.each do |scope|
        gitlink_changes(top, scope).each do |sub, old, new|
          verdict = regressed(top, sub, old, new)
          return yes(verdict) if verdict
        end
      end
      no
    end

    def gitlink_changes(top, scope)
      out, status = git(top, *scope, "--raw", "--no-renames", "-z", "--ignore-submodules=none")
      return [] unless status.success?

      out.split("\0").each_slice(2).filter_map do |meta, path|
        match = meta.to_s.match(/\A:(\d{6}) (\d{6}) ([0-9a-f]+) ([0-9a-f]+) /)
        next unless match && (match[1] == "160000" || match[2] == "160000") && match[1] == match[2]

        [path, match[3], match[4]]
      end
    end

    def regressed(top, sub, old, new)
      return nil if old.match?(ZERO)

      dir = File.join(top, sub)
      new = git_ok(dir, "rev-parse", "HEAD").to_s if new.match?(ZERO)
      return nil if new.empty? || old == new

      _, status = git(dir, "merge-base", "--is-ancestor", old, new)
      return nil if status.success?
      return "submodule #{sub} would move from #{old[0, 9]} to #{new[0, 9]}, which is not a descendant" if status.exitstatus == 1

      "submodule #{sub}: #{old[0, 9]} or #{new[0, 9]} is not in the local clone; fetch the submodule (git -C #{dir} fetch) and retry"
    end

    def check_tag_claimed(action, _ctx)
      data = hint(action)
      return no unless %w[git.tag git.push].include?(action.action_class) && !data["delete"]

      name = data["tag"] || (data["ref"].to_s.match?(/\Av\d+(?:\.\d+)+\z/) ? data["ref"] : nil)
      return no unless name.to_s.match?(/\Av?\d+(?:\.\d+)*\z/)

      repo = data["path"]
      return no if repo.to_s.empty?

      reasons = []
      target = action.action_class == "git.tag" ? data["at"] || data["ref"] : data["ref"]
      reasons << existing_tag_note(repo, name, target) if action.action_class == "git.tag"
      reasons << remote_version_note(repo, name, target)
      reasons = reasons.compact
      reasons.empty? ? no : yes([reasons.join("; "), fetch_note(repo)].compact.join("; "))
    end

    def existing_tag_note(repo, name, ref)
      existing = git_ok(repo, "rev-parse", "-q", "--verify", "refs/tags/#{name}^{commit}")
      return nil unless existing

      target = git_ok(repo, "rev-parse", "-q", "--verify", "#{ref || 'HEAD'}^{commit}")
      return nil if target == existing

      "tag #{name} already exists at #{existing[0, 9]}"
    end

    def remote_version_note(repo, name, ref)
      text = git_ok(repo, "show", "refs/remotes/origin/main:VERSION")
      return nil unless text

      wanted = Gem::Version.new(name.delete_prefix("v"))
      current = Gem::Version.new(text.lines.first.to_s.strip)
      return nil if wanted > current
      return nil if wanted == current && carries_version?(repo, ref, wanted)

      return "#{name} is not on origin/main's release commit for version #{current}" if wanted == current

      "#{name} is not greater than origin/main's version #{current}"
    rescue ArgumentError
      nil
    end

    def carries_version?(repo, ref, wanted)
      target = git_ok(repo, "rev-parse", "-q", "--verify", "#{ref || 'HEAD'}^{commit}")
      return false unless target

      _, status = git(repo, "merge-base", "--is-ancestor", target, "refs/remotes/origin/main")
      return false unless status.success?

      text = git_ok(repo, "show", "#{target}:VERSION")
      !text.nil? && Gem::Version.new(text.lines.first.to_s.strip) == wanted
    rescue ArgumentError
      false
    end

    def fetch_note(repo)
      common = git_ok(repo, "rev-parse", "--git-common-dir")
      return nil unless common

      file = File.expand_path(File.join(common, "FETCH_HEAD"), repo)
      age = File.file?(file) ? Time.now - File.mtime(file) : nil
      return nil if age && age < STALE_FETCH

      "the last fetch was #{age ? "#{(age / 3600).round(1)} h ago" : 'never recorded'}; fetch before trusting origin/main"
    end

    def check_base_unpushed(action, _ctx)
      data = hint(action)
      return no unless action.action_class == "git.branch" && data["base"]

      repo = data["path"]
      base = data["base"].to_s
      branch = base == "HEAD" ? git_ok(repo, "symbolic-ref", "-q", "--short", "HEAD") : base
      return no if branch.to_s.empty?

      _, status = git(repo, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}")
      return no unless status.success?

      upstream = git_ok(repo, "rev-parse", "--abbrev-ref", "#{branch}@{upstream}")
      return no unless upstream

      ahead = git_ok(repo, "rev-list", "--count", "#{upstream}..#{branch}").to_i
      ahead.positive? ? yes("#{branch} has #{ahead} commit#{'s' unless ahead == 1} not on #{upstream}") : no
    end

    def check_public_remote(action, _ctx)
      klass = action.action_class
      return no unless klass.start_with?("git.", "fs.")

      data = hint(action)
      url = klass == "git.push" ? push_target_url(data) : repo_origin_url(data["path"])
      return no if url.nil? && klass != "git.push"

      return no unless Visibility.public?(url)

      norm = Visibility.normalize(url)
      yes(norm.empty? ? "the remote of this push is unknown and treated as public" : "the remote #{norm} is public")
    end

    def check_public_path(action, _ctx)
      return no unless action.action_class == "fs.write"

      path = hint(action)["path"]
      return no if path.to_s.empty?

      top = toplevel(path)
      return no unless top

      target = File.expand_path(path)
      relative = target.delete_prefix("#{top}/")
      reason = blueprint_reason(relative)
      return no unless reason

      url = repo_origin_url(top)
      return no unless url && Visibility.public?(url)

      _, status = git(top, "check-ignore", "-q", "--", target)
      return no if status.success?

      yes("#{relative} is #{reason} in a repository whose origin is public, and it is not ignored")
    end

    def blueprint_reason(relative)
      segments = relative.split("/")
      name = segments.last.to_s
      return "a design note (#{name})" if BLUEPRINT_NAMES.any? { |glob| File.fnmatch(glob, name) }

      dir = (segments[0...-1] & BLUEPRINT_DIRS).first
      dir ? "under #{dir}, a working directory" : nil
    end

    def check_push_unscanned(action, _ctx)
      data = hint(action)
      case action.action_class
      when "git.push" then unscanned_push(data)
      when "git.commit" then data["contents"] ? unscanned_contents(data) : no
      else no
      end
    end

    def repo_origin_url(path)
      return nil if path.to_s.empty?

      top = toplevel(path)
      top ? Visibility.remote_url(top, "origin") : nil
    end

    def push_target_url(data)
      return Visibility.remote_url(data["path"], data["remote"]) unless data["remote"].to_s.empty? && data["repo"]

      "github.com/#{data['repo']}"
    end

    def unscanned_contents(data)
      url = data["repo"] ? "github.com/#{data['repo']}" : repo_origin_url(data["path"])
      return no unless url && Visibility.public?(url)

      yes("a contents API write to a public repository bypasses the exposure scan; commit locally and push after #{scan_hint(data['path'], nil, data['ref'])}")
    end

    def scan_hint(repo, remote, ref, source = nil)
      parts = ["polispec exposure scan #{repo}"]
      parts << "--remote #{remote}" unless remote.to_s.empty?
      parts << "--ref #{ref}" unless ref.to_s.empty?
      parts << "--source #{source}" unless source.to_s.empty?
      parts.join(" ")
    end

    def unscanned_push(data)
      return no if data["delete"] || data["deleting"]

      dir = data["path"]
      return no if dir.to_s.empty?

      url = push_target_url(data)
      return no unless Visibility.public?(url)

      name = Visibility.remote_name(dir, data["remote"])
      return yes("a push of every ref to a public remote cannot be scanned as one; push each ref by name after #{scan_hint(dir, name, '<ref>')}") if data["ref"] == "*" || data["tag"] == "*"

      ref = data["tag"] || data["ref"]
      return no if ref.to_s.empty?

      repo_key = Visibility.normalize(repo_origin_url(dir) || url)
      if data["tag"] || tag_only?(dir, ref)
        unscanned_tag(dir, repo_key, ref, name)
      else
        unscanned_branch(dir, repo_key, Visibility.normalize(url), name, ref, data["source"])
      end
    end

    def tag_only?(dir, ref)
      _, heads = git(dir, "show-ref", "--verify", "--quiet", "refs/heads/#{ref}")
      return false if heads.success?

      _, tags = git(dir, "show-ref", "--verify", "--quiet", "refs/tags/#{ref}")
      tags.success?
    end

    def unscanned_tag(dir, repo_key, tag, name)
      commit = git_ok(dir, "rev-parse", "-q", "--verify", "refs/tags/#{tag}^{commit}")
      return no unless commit
      return no if Exposure.covers_commit?(repo_key, commit)

      yes("tag #{tag} (#{commit[0, 9]}) has no exposure scan for this repository; run #{scan_hint(dir, name, tag)}")
    end

    def unscanned_branch(dir, repo_key, remote_key, name, ref, source = nil)
      local = source ? push_source_commit(dir, source) : git_ok(dir, "rev-parse", "-q", "--verify", "refs/heads/#{ref}^{commit}") || git_ok(dir, "rev-parse", "-q", "--verify", "HEAD^{commit}")
      return no unless local

      tip = Visibility.url_like?(name) ? nil : git_ok(dir, "rev-parse", "-q", "--verify", "refs/remotes/#{name}/#{ref}^{commit}")
      return no if tip == local

      from = tip || Exposure.empty_tree(dir)
      return no if Exposure.covers_branch?(repo_key, remote_key, ref, from, local)

      pushed = source ? "#{source} pushed to #{ref}" : ref
      yes("#{pushed} at #{local[0, 9]} has no exposure scan against #{tip ? tip[0, 9] : 'an empty remote'}; run #{scan_hint(dir, name, ref, source)}")
    end

    def push_source_commit(dir, source)
      git_ok(dir, "rev-parse", "-q", "--verify", "refs/heads/#{source}^{commit}") || git_ok(dir, "rev-parse", "-q", "--verify", "#{source}^{commit}")
    end
  end
end
