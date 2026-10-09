#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Predicates
    NAMES = %w[lock_held live_binary supervised pin_regress tag_claimed base_unpushed].freeze
    BUDGET = 2.0
    LOCK_MANIFEST = "TMP_AGENT_FILE_LOCKS.yml".freeze
    UNOWNED_WINDOW = 600
    SUPERVISOR_TTL = 60
    SUPERVISOR_TIMEOUT = 1.0
    STALE_FETCH = 3600
    ZERO = /\A0+\z/.freeze

    Result = Struct.new(:match, :note, :finding)

    class Expired < StandardError; end

    module_function

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
      mine = ancestors
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
      reasons << existing_tag_note(repo, name, data["ref"]) if action.action_class == "git.tag"
      reasons << remote_version_note(repo, name)
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

    def remote_version_note(repo, name)
      text = git_ok(repo, "show", "refs/remotes/origin/main:VERSION")
      return nil unless text

      wanted = Gem::Version.new(name.delete_prefix("v"))
      current = Gem::Version.new(text.lines.first.to_s.strip)
      wanted <= current ? "#{name} is not greater than origin/main's version #{current}" : nil
    rescue ArgumentError
      nil
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
  end
end
