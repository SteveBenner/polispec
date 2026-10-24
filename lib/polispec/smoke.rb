#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "pathname"

module Polispec
  module Smoke
    SCHEMA = "polispec.smoke/v1"
    VERDICTS = %w[pass fail partial blocked inconclusive].freeze
    BLOCKING = %w[schema digest_mismatch chain_broken duplicate_id truncated].freeze
    DEFAULT_SPEC = "specs/app.yml"
    DEFAULT_UNITS = ["commands/*"].freeze
    COMMAND_TIMEOUT = 2

    module_function

    def canonical(value)
      Canonical.value(value)
    end

    def canonical_json(value)
      Canonical.json(value)
    end

    def sha256(text)
      Canonical.sha256(text)
    end

    def command(argv, chdir: nil)
      options = { err: File::NULL }
      options[:chdir] = chdir if chdir
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Trace.command(argv, chdir: chdir)
      Open3.popen2(*argv, **options) do |stdin, stdout, thread|
        stdin.close
        reader = Thread.new { stdout.read }
        unless thread.join(COMMAND_TIMEOUT)
          begin
            Process.kill("KILL", thread.pid)
          rescue SystemCallError
            nil
          end
          return nil
        end
        status = thread.value
        Trace.exit_line(status.exitstatus || -1, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000)
        return nil unless status.success?

        reader.value.to_s.strip
      end
    rescue SystemCallError, IOError
      nil
    end

    def git(dir, *args)
      command(["git", *args], chdir: dir)
    end

    def toplevel
      top = git(Dir.pwd, "rev-parse", "--show-toplevel")
      top.nil? || top.empty? ? nil : top
    end

    def ledger_path(top = toplevel)
      override = ENV["POLISPEC_SMOKE"].to_s.strip
      return File.expand_path(override) unless override.empty?

      configured = Engine::Settings.smoke_path
      return File.expand_path(configured) if configured

      raise Polispec::Error, "not in a git repository; set POLISPEC_SMOKE" unless top

      File.join(top, "smoke.yml")
    end

    def display_path(path, top)
      return File.basename(path) unless top

      prefix = top.end_with?("/") ? top : "#{top}/"
      path.start_with?(prefix) ? path.delete_prefix(prefix) : File.basename(path)
    end

    def relative_spec(spec, top)
      text = spec.to_s
      raise Polispec::Error, "spec must be a relative path inside the repository" if text.empty? || text.include?("\0") || Pathname.new(text).absolute?
      raise Polispec::Error, "not in a git repository" unless top

      clean = Pathname.new(text).cleanpath.to_s
      raise Polispec::Error, "spec must be a relative path inside the repository" if clean == ".." || clean.start_with?("../") || clean == "."

      full = File.join(top, clean)
      raise Polispec::Error, "#{clean} is not a regular file" unless File.file?(full)

      real = File.realpath(full)
      root = File.realpath(top)
      raise Polispec::Error, "spec must be a relative path inside the repository" unless real.start_with?("#{root}/")

      [clean, full]
    end

    def load_spec(clean, full)
      bytes = File.binread(full)
      data = YAML.safe_load(bytes, permitted_classes: [Date, Time], aliases: false)
      raise Polispec::Error, "#{clean} is not a YAML mapping or list" unless data.is_a?(Hash) || data.is_a?(Array)

      [bytes, data]
    rescue Psych::Exception => e
      raise Polispec::Error, "#{clean}: #{e.message.lines.first.to_s.strip}"
    end

    def segments(at)
      at.to_s.empty? ? [] : at.to_s.split("/", -1).map { |part| part.gsub("~1", "/").gsub("~0", "~") }
    end

    def child(node, segment)
      case node
      when Hash
        pair = node.find { |key, _| key.to_s == segment }
        pair ? [true, pair[1]] : [false, nil]
      when Array
        item = node.find { |entry| entry.is_a?(Hash) && %w[name id].any? { |field| entry.key?(field) && entry[field].to_s == segment } }
        item.nil? ? [false, nil] : [true, item]
      else
        [false, nil]
      end
    end

    def resolve_node(data, spec, at)
      segments(at).reduce(data) do |node, segment|
        found, value = child(node, segment)
        raise Polispec::Error, "#{spec}##{at} does not resolve at #{segment}" unless found

        value
      end
    end

    def node_digest(node)
      sha256(canonical_json(node))
    end

    def escape(segment)
      segment.to_s.gsub("~", "~0").gsub("/", "~1")
    end

    def expand(data, pattern)
      return [pattern] unless pattern == "*" || pattern.end_with?("/*")

      prefix = pattern == "*" ? "" : pattern.delete_suffix("/*")
      node = begin
        resolve_node(data, "", prefix)
      rescue Polispec::Error
        return []
      end
      names = case node
              when Hash then node.keys.map(&:to_s)
              when Array then node.select { |item| item.is_a?(Hash) && (item["name"] || item["id"]) }.map { |item| (item["name"] || item["id"]).to_s }
              else []
              end
      names.map { |name| prefix.empty? ? escape(name) : "#{prefix}/#{escape(name)}" }
    end

    def scrub(text, top)
      return text unless text.is_a?(String)

      out = text.dup
      out = out.gsub(%r{#{Regexp.escape(top)}(?=/|\z|[^\w.\-])}, ".") if top && !top.empty? && top != "/"
      home = begin
        Dir.home
      rescue ArgumentError, SystemCallError
        nil
      end
      out = out.gsub(%r{#{Regexp.escape(home)}(?=/|\z|[^\w.\-])}, "~") if home && !home.empty? && home != "/"
      out
    end

    def read(path)
      return { "schema" => SCHEMA, "entries" => [] } unless File.file?(path)

      data = Schema::Document.parse(File.read(path), path)
      data.is_a?(Hash) ? data : raise(Polispec::Error, "#{path}: smoke ledger must be a mapping")
    end

    def entries_of(data)
      list = data.is_a?(Hash) ? data["entries"] : nil
      list.is_a?(Array) ? list.select { |entry| entry.is_a?(Hash) } : []
    end

    def body_of(entry)
      entry.reject { |key, _| key == "digest" }
    end

    def seal(entry)
      body = entry.reject { |key, _| %w[id digest].include?(key) }
      withid = { "id" => "smk_#{sha256(canonical_json(body))[0, 12]}" }.merge(body)
      withid.merge("digest" => sha256(canonical_json(withid)))
    end

    def append(path, top, build)
      parent = File.dirname(path)
      unless File.directory?(parent)
        raise Polispec::Error, "#{display_path(parent, top)} does not exist" unless top && File.expand_path(parent) == File.expand_path(top)

        FileUtils.mkdir_p(parent)
      end
      lock = File.open(lock_path(path, parent), File::RDWR | File::CREAT, 0o600)
      begin
        lock.flock(File::LOCK_EX)
        data = read(path)
        existing = data["entries"]
        raise Polispec::Error, "#{display_path(path, top)}: entries must be a list" unless existing.is_a?(Array)

        last = existing.reverse.find { |entry| entry.is_a?(Hash) }
        entry = seal(build.call(last && last["digest"]))
        errors = Schema.validate("smoke", { "schema" => SCHEMA, "entries" => [entry] })
        raise Polispec::Error, "entry is invalid: #{errors.map { |item| "#{item.pointer} #{item.message}" }.join('; ')}" unless errors.empty?

        tmp = "#{path}.tmp.#{Process.pid}"
        File.write(tmp, YAML.dump({ "schema" => SCHEMA, "entries" => existing + [entry] }))
        File.rename(tmp, path)
        anchor(path, entry, existing.length + 1)
        entry
      ensure
        lock.flock(File::LOCK_UN)
        lock.close
      end
    end

    def ledger_key(path)
      File.join(File.realpath(File.dirname(path)), File.basename(path))
    rescue SystemCallError
      File.expand_path(path)
    end

    def heads_path
      File.join(State.home, "smoke-heads.json")
    end

    def read_heads
      data = JSON.parse(File.read(heads_path))
      data.is_a?(Hash) ? data : {}
    rescue SystemCallError, JSON::ParserError
      {}
    end

    def anchor(path, entry, count)
      FileUtils.mkdir_p(State.home, mode: 0o700)
      File.open("#{heads_path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        heads = read_heads
        heads[ledger_key(path)] = { "digest" => entry["digest"], "count" => count, "recorded_at" => entry["recorded_at"] }
        tmp = "#{heads_path}.tmp.#{Process.pid}"
        File.write(tmp, JSON.generate(heads), perm: 0o600)
        File.rename(tmp, heads_path)
      end
    rescue SystemCallError, IOError
      nil
    end

    def truncation(path, entries)
      head = read_heads[ledger_key(path)]
      return [] unless head.is_a?(Hash)

      present = entries.any? { |entry| entry["digest"] == head["digest"] }
      return [] if present && entries.length >= head["count"].to_i

      [{ "kind" => "truncated", "id" => nil, "detail" => "anchored head #{head['digest']} (#{head['count']} entries, #{head['recorded_at']}) is missing or the ledger holds fewer entries" }]
    end

    def lock_path(path, parent)
      common = git(parent, "rev-parse", "--git-common-dir")
      return "#{path}.lock" if common.nil? || common.empty?

      File.join(File.expand_path(common, parent), "polispec-smoke.lock")
    end

    def os_release
      fields = {}
      File.readlines("/etc/os-release").each do |line|
        key, value = line.strip.split("=", 2)
        fields[key] = value.to_s.delete_prefix('"').delete_suffix('"').delete_prefix("'").delete_suffix("'") if key
      end
      { "id" => fields["ID"], "name" => fields["NAME"], "version" => fields["VERSION_ID"] }
    rescue SystemCallError
      { "id" => nil, "name" => nil, "version" => nil }
    end

    def os_info
      if RUBY_PLATFORM.include?("darwin")
        { "id" => "macos", "name" => command(%w[sw_vers -productName]), "version" => command(%w[sw_vers -productVersion]) }
      elsif File.file?("/etc/os-release")
        os_release
      else
        { "id" => nil, "name" => nil, "version" => nil }
      end
    end

    def container?
      return true if File.exist?("/.dockerenv") || File.exist?("/run/.containerenv")

      File.read("/proc/1/cgroup").match?(/docker|kubepods|containerd/)
    rescue SystemCallError
      false
    end

    def rplugin_version
      return ::Rplugin::VERSION.to_s if defined?(::Rplugin::VERSION)

      [["rplugin", "version"], [File.expand_path("~/.rplugin/bin/rplugin"), "version"]].each do |argv|
        out = command(argv)
        return out.lines.first.to_s.strip unless out.nil? || out.empty?
      end
      nil
    end

    def polispec_info
      pinned = Runtime.pinned?
      dirty = pinned ? "" : git(ROOT, "status", "--porcelain")
      repo = File.exist?(File.join(ROOT, ".git"))
      edition = begin
        File.read(File.join(ROOT, "EDITION")).strip
      rescue SystemCallError
        nil
      end
      {
        "version" => Polispec.version, "edition" => edition,
        "commit" => Runtime.commit,
        "dirty" => dirty.nil? ? nil : !dirty.empty?,
        "install" => pinned ? "pinned" : (repo ? "clone" : "package")
      }
    end

    def runtime
      kernel = command(%w[uname -r])
      {
        "os" => os_info, "kernel" => kernel, "arch" => command(%w[uname -m]), "platform" => RUBY_PLATFORM,
        "container" => container?, "wsl" => kernel.to_s.match?(/microsoft/i),
        "tz" => ENV["TZ"].to_s.empty? ? Time.now.zone : ENV["TZ"],
        "locale" => ENV["LC_ALL"].to_s.empty? ? (ENV["LANG"].to_s.empty? ? nil : ENV["LANG"]) : ENV["LC_ALL"],
        "ruby" => { "engine" => RUBY_ENGINE, "version" => RUBY_VERSION, "platform" => RUBY_PLATFORM },
        "polispec" => polispec_info, "rplugin" => rplugin_version,
        "enforce" => Engine::Settings.enforce_mode
      }
    end

    def target(top, ledger = nil)
      relative = ledger && ledger.start_with?("#{top}/") ? ledger.delete_prefix("#{top}/") : nil
      dirty = relative ? git(top, "status", "--porcelain", "--", ".", ":(exclude)#{relative}") : git(top, "status", "--porcelain")
      info = { "project" => nil, "env" => nil, "policy_digest" => nil }
      begin
        described = Resolve::Resolver.new(Ledger.load).describe(top)
        info = { "project" => described["project"], "env" => described["env"], "policy_digest" => described["policy_digest"] }
      rescue StandardError
        nil
      end
      branch = git(top, "symbolic-ref", "--short", "-q", "HEAD")
      {
        "commit" => git(top, "rev-parse", "HEAD"),
        "branch" => branch.nil? || branch.empty? ? nil : branch,
        "dirty" => dirty.nil? ? nil : !dirty.empty?
      }.merge(info)
    end

    def runner(options)
      agent = !ENV["CLAUDECODE"].to_s.empty? || !ENV["CODEX_SANDBOX"].to_s.empty? || !ENV["CODEX_THREAD_ID"].to_s.empty?
      codex = ENV.keys.any? { |key| key.start_with?("CODEX_") && !ENV[key].to_s.empty? }
      kind = options[:runner] || (agent ? "agent" : "human")
      default_harness = !ENV["CLAUDECODE"].to_s.empty? ? "claude-code" : (codex ? "codex" : nil)
      harness = options[:harness] || default_harness
      version = case harness
                when "claude-code" then command(%w[claude --version])&.split&.first
                when "codex" then command(%w[codex --version])&.split&.last
                end
      model = options[:model] || [ENV["ANTHROPIC_MODEL"], ENV["CLAUDE_MODEL"]].find { |value| !value.to_s.empty? }
      { "kind" => kind, "harness" => harness, "harness_version" => version, "model" => model, "effort" => options[:effort] }
    end

    def evidence(item, top)
      path, kind = item, "file"
      head, sep, tail = item.rpartition(":")
      if !sep.empty? && !head.empty? && tail.match?(/\A[a-z][a-z0-9_-]*\z/)
        path = head
        kind = tail
      end
      full = File.expand_path(path)
      raise Polispec::Error, "evidence #{scrub(path, top)} is not a regular file" unless File.file?(full)

      bytes = File.binread(full)
      { "path" => scrub(display_path(full, top), top), "sha256" => sha256(bytes), "bytes" => bytes.bytesize, "kind" => kind }
    end

    def record(top:, path:, spec:, at:, verdict:, summary:, steps:, evidence:, runner:, started: nil, finished: nil)
      clean, full = relative_spec(spec, top)
      bytes, data = load_spec(clean, full)
      node = resolve_node(data, clean, at.to_s)
      raise Polispec::Error, "#{clean}##{at} resolves to an empty node" if node.nil?

      captured = self.runtime
      subject = self.target(top, path)
      proves = { "spec" => clean, "at" => at.to_s, "spec_digest" => sha256(bytes), "at_digest" => node_digest(node) }
      recorded = Time.now.utc.iso8601
      entry = append(path, top, lambda { |prev|
        base = { "recorded_at" => recorded }
        base["started_at"] = started if started
        base["finished_at"] = finished if finished
        base.merge(
          "proves" => proves, "verdict" => verdict, "summary" => scrub(summary, top),
          "steps" => steps, "evidence" => evidence, "runner" => runner, "runtime" => captured,
          "target" => subject, "prev" => prev
        )
      })
      Events.emit("polispec.smoke", project: subject["project"], id: entry["id"], spec: clean, at: at.to_s, verdict: verdict)
      entry
    end

    def verify(path, top)
      data = read(path)
      findings = Schema.validate("smoke", data).map { |error| { "kind" => "schema", "id" => nil, "detail" => "#{error.pointer.empty? ? '/' : error.pointer} #{error.message}" } }
      entries = entries_of(data)
      findings.concat(truncation(path, entries))
      seen = {}
      previous = nil
      specs = {}
      entries.each do |entry|
        id = entry["id"]
        findings << { "kind" => "digest_mismatch", "id" => id, "detail" => "stored digest does not match entry content" } if entry["digest"] != sha256(canonical_json(body_of(entry)))
        findings << { "kind" => "chain_broken", "id" => id, "detail" => "prev #{entry['prev'].to_json} does not match #{previous.to_json}" } if entry["prev"] != previous
        findings << { "kind" => "duplicate_id", "id" => id, "detail" => "id appears more than once" } if seen[id]
        seen[id] = true
        previous = entry["digest"]
        findings.concat(proof_findings(entry, top, specs)) if top
      end
      findings
    end

    def proof_findings(entry, top, specs)
      proves = entry["proves"]
      return [] unless proves.is_a?(Hash) && proves["spec"].is_a?(String)

      spec = proves["spec"]
      specs[spec] ||= begin
        clean, full = relative_spec(spec, top)
        load_spec(clean, full).last
      rescue Polispec::Error => e
        e
      end
      loaded = specs[spec]
      return [{ "kind" => "unresolved", "id" => entry["id"], "detail" => loaded.message }] if loaded.is_a?(Polispec::Error)

      node = resolve_node(loaded, spec, proves["at"].to_s)
      return [] if node_digest(node) == proves["at_digest"]

      [{ "kind" => "stale", "id" => entry["id"], "detail" => "#{spec}##{proves['at']} changed since it was recorded" }]
    rescue Polispec::Error => e
      [{ "kind" => "unresolved", "id" => entry["id"], "detail" => e.message }]
    end

    def coverage(data, spec, entries, patterns)
      units = patterns.flat_map { |pattern| expand(data, pattern) }.uniq
      rows = units.map do |unit|
        current = begin
          node_digest(resolve_node(data, spec, unit))
        rescue Polispec::Error
          nil
        end
        matching = entries.each_with_index.select { |entry, _| entry.dig("proves", "spec") == spec && entry.dig("proves", "at") == unit && entry["verdict"] != "inconclusive" }
        latest = matching.max_by { |entry, index| [entry["recorded_at"].to_s, index] }&.first
        status = if latest.nil? then "none"
                 elsif latest["verdict"] == "pass" then current && latest.dig("proves", "at_digest") == current ? "proven" : "stale"
                 else { "fail" => "failing", "blocked" => "blocked", "partial" => "partial" }.fetch(latest["verdict"], "none")
                 end
        { "unit" => unit, "status" => status, "current_digest" => current, "latest" => latest && latest["id"] }
      end
      { "spec" => spec, "units" => rows, "proven" => rows.count { |row| row["status"] == "proven" }, "total" => rows.length }
    end
  end
end
