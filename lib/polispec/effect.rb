#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "digest"
require "json"
require_relative "canonical"
require_relative "hook_memo"

module Polispec
  module Effect
    EPOCH_PATTERN = /\Aep_[0-9a-f]{16}\z/
    CACHE_FILE = "epoch.json"
    SESSION_TEXT_FILES = %w[policy.yml roster.yml environments.yml].freeze
    LAUNCHER_GLOBS = ["bin/polispec-guard", "hooks/*.json", ".claude-plugin/**/*"].freeze
    CODEX_HOOK_PATTERN = %r{(\A|/)\.codex/(config\.toml|hooks\.json)\z|(\A|/)codex/bridge\.py\z}
    SEMVER = /\A\d+\.\d+\.\d+\z/

    module_function

    def epoch(ledger = nil, context = {})
      context = {} unless context.is_a?(Hash)
      ledger ||= Ledger.load
      return epoch_uncached(ledger, context) unless context.empty?

      HookMemo.fetch(:epoch, ledger.object_id) { epoch_uncached(ledger, context) }
    end

    def epoch_uncached(ledger, context)
      material = material_for(ledger, context)
      key = Digest::SHA256.hexdigest(material.map(&:to_s).join("\0"))
      epoch = "ep_#{key[0, 16]}"
      remember(key, epoch)
      epoch
    rescue StandardError, ScriptError
      nil
    end

    def material_for(ledger, context)
      require_relative "harness_controls/plane"
      plane = context[:plane] || HarnessControls::Plane.resolve
      raise Polispec::Error, "sealed authority is broken" if plane["status"] == "broken"

      list = [runtime_material(context), ledger.digest, Layers.fingerprint, shelf_material]
      live = ledger.projects.select { |project| project.status == "live" }.sort_by(&:id)
      live.each do |project|
        list.concat([project.id, project.trust_ref, ref_commit(project.repo, project.trust_ref), project.policy, project.roster])
      end
      list << control_material(plane)
      list << plane["status"]
      list << plane["generation"]
      list << edition
      list << Engine::Settings.enforce_mode
      list << Engine::Settings.relax_dev?
      list << Engine::Settings.exceptions?
      list
    end

    def runtime_material(context = {})
      return context[:runtime] if context[:runtime]

      release = Runtime.release
      (release && release["tree_digest"]) || Runtime.commit
    end

    def release_material(dir)
      [Runtime::RELEASE_FILE, Runtime::NATIVE_RELEASE_FILE].each do |name|
        path = File.join(dir, name)
        next unless File.file?(path)

        data = JSON.parse(File.read(path))
        return data["tree_digest"] || data["commit"] if data.is_a?(Hash)
      end
      nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def edition
      HarnessControls::Plane.requested_edition
    rescue StandardError
      nil
    end

    def control_material(plane)
      return nil unless plane["status"] == "active"

      paths = plane["controls"].is_a?(Hash) ? plane["controls"].sort_by { |name, _| name.to_s }.map(&:last) : []
      paths.map { |path| path.is_a?(String) && File.file?(path) ? Digest::SHA256.file(path).hexdigest : "-" }.join(",")
    end

    def shelf_material
      source = Layers.source
      return nil unless source
      return ref_commit(source.repo, source.ref) if source.kind == :repo

      file = File.join(source.root, "exceptions.yml")
      File.file?(file) ? Digest::SHA256.file(file).hexdigest : nil
    end

    def ref_commit(repo, ref)
      return nil if repo.to_s.empty? || ref.to_s.empty?

      common = common_dir(File.expand_path(repo))
      return nil unless common

      [ref.to_s, "refs/heads/#{ref}"].uniq.each do |name|
        file = File.join(common, name.start_with?("refs/") ? name : "refs/heads/#{name}")
        if File.file?(file)
          sha = File.read(file).strip
          return sha if sha.match?(/\A[0-9a-f]{40,64}\z/)
        end
      end
      packed = File.join(common, "packed-refs")
      return nil unless File.file?(packed)

      File.foreach(packed) do |line|
        sha, name = line.strip.split(" ", 2)
        return sha if name == "refs/heads/#{ref}" && sha.to_s.match?(/\A[0-9a-f]{40,64}\z/)
      end
      nil
    rescue SystemCallError
      nil
    end

    def common_dir(repo)
      dot = File.join(repo, ".git")
      git = if File.directory?(dot)
              dot
            elsif File.file?(dot)
              target = File.read(dot)[/\Agitdir:\s*(.+)$/, 1]
              target ? File.expand_path(target.strip, repo) : nil
            elsif File.file?(File.join(repo, "HEAD")) && File.directory?(File.join(repo, "refs"))
              repo
            end
      return nil unless git

      pointer = File.join(git, "commondir")
      File.file?(pointer) ? File.expand_path(File.read(pointer).strip, git) : git
    end

    def remember(key, epoch)
      path = File.join(State.home, CACHE_FILE)
      stored = File.file?(path) ? JSON.parse(File.read(path)) : nil
      return if stored.is_a?(Hash) && stored["key"] == key

      FileUtils.mkdir_p(State.home, mode: 0o700)
      temp = "#{path}.#{Process.pid}.tmp"
      File.write(temp, JSON.generate("key" => key, "epoch" => epoch, "at" => Time.now.utc.iso8601), perm: 0o600)
      File.rename(temp, path)
    rescue StandardError
      nil
    end

    def classes(kind, details = {})
      details = {} unless details.is_a?(Hash)
      kind = kind.to_s
      list = []
      case kind
      when "promote", "apply"
        list << entry("next_call", "host")
        project = details["project"]
        list << entry("new_session", project ? "project:#{project}" : "host") if touches_session_text?(details)
      when "pin"
        list << entry("next_call", "host")
        list << entry("reload", "host") if launcher_differs?(details["old_release"], details["new_release"])
      when "install", "uninstall"
        list << entry("reload", "host")
      else
        list << entry("next_call", "host") if kind.start_with?("exceptions.") || %w[settings.set register].include?(kind)
      end
      list << entry("trust", "host") if Array(details["files"]).any? { |path| path.to_s.match?(CODEX_HOOK_PATTERN) }
      list.uniq
    end

    def entry(name, scope)
      { "class" => name, "scope" => scope }
    end

    def touches_session_text?(details)
      return true if details["session_text"] == true

      Array(details["files"]).any? { |path| SESSION_TEXT_FILES.include?(File.basename(path.to_s)) }
    end

    def launcher_differs?(old_dir, new_dir)
      return false if old_dir.to_s.empty? || new_dir.to_s.empty? || old_dir == new_dir

      launcher_digest(old_dir) != launcher_digest(new_dir)
    rescue StandardError
      false
    end

    def launcher_digest(dir)
      rows = LAUNCHER_GLOBS.flat_map { |glob| Dir.glob(File.join(dir, glob), File::FNM_DOTMATCH).select { |path| File.file?(path) } }.uniq.sort
      Digest::SHA256.hexdigest(rows.map { |path| [path.sub("#{dir}/", ""), Digest::SHA256.file(path).hexdigest].join(":") }.join("\n"))
    end

    def describe(effects, label_scope: true)
      names = { "next_call" => "next call", "new_session" => "new session", "reload" => "reload", "trust" => "trust review" }
      Array(effects).map do |item|
        scope = item["scope"].to_s.sub(":", " ")
        label_scope ? "#{names.fetch(item['class'], item['class'])} (#{scope})" : names.fetch(item["class"], item["class"])
      end.join(", ")
    end

    def launcher_version(launcher)
      version = launcher.is_a?(Hash) ? launcher["version"].to_s : ""
      version.match?(SEMVER) ? version : nil
    end

    def version_less?(left, right)
      (left.split(".").map(&:to_i) <=> right.split(".").map(&:to_i)) == -1
    end

    def doctor_findings(window: 3600)
      require_relative "sessions"
      findings = []
      current = Polispec.version
      Sessions.active(window).each do |session|
        version = launcher_version(session["launcher"])
        next unless version && current.match?(SEMVER) && version_less?(version, current)

        findings << { "project" => nil, "kind" => "launcher_stale", "severity" => "warn",
                      "detail" => "session #{session['session_id']} (#{session['harness']}) runs a launcher from #{version}; the installed release is #{current}; run /reload-plugins in that session or start a new one" }
      end
      findings.concat(codex_findings)
      findings
    rescue StandardError
      []
    end

    def codex_findings
      CodexWiring.findings
    rescue StandardError
      []
    end

    module CodexWiring
      EVENTS = %w[PreToolUse SessionStart].freeze
      READ_LIMIT = 1_048_576
      TIMEOUT = 5.0
      NEEDLES = ["polispec-guard", "polispec hook"].freeze

      module_function

      def config_path
        home = ENV["CODEX_HOME"].to_s
        File.join(home.empty? ? File.join(Dir.home, ".codex") : File.expand_path(home), "config.toml")
      end

      def snake(name)
        name.gsub(/([a-z0-9])([A-Z])/, '\\1_\\2').downcase
      end

      def parse(text, path)
        hooks = []
        trusted = {}
        counts = Hash.new(0)
        group = nil
        handler = nil
        table = nil
        text.each_line do |raw|
          line = raw.strip
          if (match = line.match(/\A\[\[hooks\.([A-Za-z]+)\]\]\z/))
            index = counts[match[1]]
            counts[match[1]] += 1
            group = { event: match[1], index: index, handlers: 0 }
            handler = nil
            table = :group
          elsif (match = line.match(/\A\[\[hooks\.([A-Za-z]+)\.hooks\]\]\z/))
            if group && group[:event] == match[1]
              handler = { event: match[1], group: group[:index], handler: group[:handlers], type: nil, command: nil }
              group[:handlers] += 1
              hooks << handler
              table = :handler
            else
              table = nil
            end
          elsif (match = line.match(/\A\[hooks\.state\."(.+)"\]\z/))
            table = [:state, match[1]]
          elsif line.start_with?("[")
            table = nil
          elsif table == :handler && handler
            handler[:type] = unquote(line) if line.start_with?("type")
            handler[:command] = unquote(line) if line.start_with?("command")
          elsif table.is_a?(Array) && line.start_with?("trusted_hash")
            trusted[table[1]] = unquote(line)
          end
        end
        hooks.each { |item| item[:key] = "#{path}:#{snake(item[:event])}:#{item[:group]}:#{item[:handler]}" }
        [hooks, trusted]
      end

      def unquote(line)
        value = line.split("=", 2)[1].to_s.strip
        value.match(/\A"(.*)"\z/) ? Regexp.last_match(1).gsub('\\"', '"') : value
      end

      def reaches?(command)
        text = command.to_s
        return true if NEEDLES.any? { |needle| text.include?(needle) }

        token = text.split(/\s+/).find { |part| part.start_with?("/", "~/") }
        return false unless token

        file = File.expand_path(token)
        File.file?(file) && File.size(file) <= READ_LIMIT && (NEEDLES + ["polispec-guard.sh"]).any? { |needle| File.read(file).include?(needle) }
      rescue SystemCallError
        false
      end

      def codex_bin
        explicit = ENV["POLISPEC_CODEX_BIN"].to_s
        return explicit if !explicit.empty? && File.executable?(explicit)

        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "codex") }.find { |path| File.file?(path) && File.executable?(path) }
      end

      def statuses(bin, home)
        require "open3"
        found = {}
        Open3.popen3({ "CODEX_HOME" => home }, bin, "app-server", chdir: Dir.home) do |stdin, stdout, stderr, wait|
          begin
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT
            send_line(stdin, "jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => { "clientInfo" => { "name" => "polispec-doctor", "title" => "polispec doctor", "version" => Polispec.version } })
            return nil unless await_reply(stdout, 1, deadline)

            send_line(stdin, "jsonrpc" => "2.0", "method" => "initialized")
            send_line(stdin, "jsonrpc" => "2.0", "id" => 2, "method" => "hooks/list", "params" => { "cwds" => [Dir.home] })
            reply = await_reply(stdout, 2, deadline)
            return nil unless reply

            collect(reply["result"], found)
          ensure
            begin
              Process.kill("KILL", wait.pid)
            rescue SystemCallError
              nil
            end
            stderr.close unless stderr.closed?
          end
        end
        found
      rescue StandardError
        nil
      end

      def send_line(io, message)
        io.write("#{JSON.generate(message)}\n")
        io.flush
      end

      def await_reply(io, id, deadline)
        buffer = +""
        loop do
          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return nil if left <= 0
          return nil unless IO.select([io], nil, nil, left)

          chunk = io.read_nonblock(65_536, exception: false)
          return nil if chunk.nil?
          next if chunk == :wait_readable

          buffer << chunk
          while (newline = buffer.index("\n"))
            line = buffer.slice!(0, newline + 1)
            message = State.parse_line(line)
            return message if message && message["id"] == id
          end
        end
      end

      def collect(result, found)
        walk(result) do |item|
          key = item["key"] || item["id"]
          status = item["trustStatus"] || item["trust_status"]
          found[key] = status if key.is_a?(String) && status.is_a?(String)
        end
      end

      def walk(value, &block)
        case value
        when Hash
          yield value
          value.each_value { |item| walk(item, &block) }
        when Array
          value.each { |item| walk(item, &block) }
        end
      end

      def findings
        path = config_path
        return [] unless File.file?(path)

        hooks, trusted = parse(File.read(path), path)
        matching = hooks.select { |item| item[:type] == "command" && EVENTS.include?(item[:event]) && reaches?(item[:command]) }
        return [{ "project" => nil, "kind" => "codex_not_wired", "severity" => "info", "detail" => "Codex is installed for this user but no PreToolUse or SessionStart hook in #{path} reaches polispec, so Codex calls are not guarded" }] if matching.empty?

        live = (bin = codex_bin) ? statuses(bin, File.dirname(path)) : nil
        limits = "A running Codex session keeps the hooks it loaded at start, so a trust given now takes effect in new sessions; this check cannot see which sessions are running, and it does not say whether the guard launcher script is current."
        matching.filter_map do |item|
          status = live ? live[item[:key]] : nil
          source = live && status ? "app-server" : "config"
          status ||= trusted.key?(item[:key]) ? "unverified" : "untrusted"
          next if %w[trusted managed].include?(status)

          if status == "unverified"
            { "project" => nil, "kind" => "codex_hook_unverified", "severity" => "info",
              "detail" => "Codex hook #{item[:key]} (#{item[:event]}) reaches polispec and has a recorded trusted_hash that cannot be checked offline (source #{source}, #{path}). #{limits}" }
          else
            { "project" => nil, "kind" => "codex_hook_untrusted", "severity" => "warn",
              "detail" => "Codex hook #{item[:key]} (#{item[:event]}) reaches polispec and is #{status} (source #{source}, #{path}); open /hooks in Codex, review the definition, trust it, and start a new Codex session. #{limits}" }
          end
        end
      end
    end
  end
end
