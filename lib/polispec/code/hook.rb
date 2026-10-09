#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    class Hook
      HARNESSES = %w[claude claude-code codex hermes pi deepseek antigravity].freeze
      MODES = %w[pre post stop session].freeze
      USAGE = "usage: polispec code-hook pre|post|stop|session --harness <claude|codex|hermes|pi|deepseek|antigravity>".freeze
      MAX_STOP_FILES = 50
      MAX_FINDINGS = 25
      MAX_OUTPUT = 9800

      def self.run(args)
        new.run(args)
      end

      def run(args)
        mode = args.shift
        index = args.index("--harness")
        harness = index ? args[index + 1].to_s : ""
        return usage unless MODES.include?(mode) && HARNESSES.include?(harness) && !$stdin.tty?

        Telemetry.defer!
        @harness = harness
        @adapter = adapter_for(harness)
        raw = $stdin.read.to_s
        @raw = JSON.parse(raw)
        @input = @adapter.parse(raw)
        @session_cwd = @input.cwd.to_s.empty? ? Dir.pwd : @input.cwd.to_s
        output = send("handle_#{mode}")
        $stdout.write(output) if output
        0
      rescue Errno::EPIPE, IOError
        0
      rescue StandardError, ScriptError => e
        Telemetry.emit("polispec.code.finding", kind: "hook_error", detail: "#{e.class}: #{e.message.to_s[0, 200]}")
        0
      ensure
        Telemetry.flush
      end

      private

      def usage
        warn USAGE
        1
      end

      def adapter_for(harness)
        case harness
        when "claude", "claude-code" then Harness::Claude.new("claude")
        when "codex" then Harness::Codex.new("codex")
        else Harness::Generic.new(harness)
        end
      end

      def context?
        Settings.context_on_pre?(@adapter.name)
      end

      def handle_session
        source = @raw["source"].to_s
        return nil unless %w[compact clear].include?(source)

        session = Session.load(@input.session_id, @session_cwd)
        session.reset_injected
        session.save
        nil
      end

      def handle_pre
        return nil unless Edit.tool?(@input.tool_name)

        changes = Edit.simulate(@input.tool_name, @input.tool_input, @session_cwd).reject { |change| change.path.nil? }
        return nil if changes.empty?

        session = Session.load(@input.session_id, @session_cwd)
        session.begin_tracking(Repo.root(changes.first.path) || Repo.root(@session_cwd))
        pack = load_pack(session)
        unless pack
          session.save
          return @unavailable_text && context? ? context_json("PreToolUse", @unavailable_text) : nil
        end

        checker = Checker.new(pack)
        injections = []
        blockers = []
        warnings = []
        changes.each do |change|
          language = change.language_hint || checker.detector.detect(change.path, head: change.after)
          chain = Chain.for(pack, language)
          next if chain.rules_for_path(Repo.relative(Repo.root(change.path), change.path)).empty?

          if (Settings.inject == "every_write" || !session.injected?(chain.digest)) && !chain.rules.empty?
            text = Composer.compose(pack, chain)
            injections << text unless injections.include?(text)
            session.mark_injected(chain.digest)
            Telemetry.emit("polispec.code.inject", file: change.path, language: language, chain_digest: chain.digest, specs: chain.specs.length, rules: chain.rules.length, chars: text.length)
          end
          next if change.skip || change.after.nil?

          session.add_file(change.path)
          session.save_snapshot(change.path, change.before) if File.file?(change.path)
          next unless Settings.check_at == "pre_write"

          verdict = checker.check(change.path, change.after, before: change.before, changed: change.lines, language: language)
          verdict.findings.each do |finding|
            if finding.blocking? && Settings.tiered?
              blockers << [change, finding]
            elsif finding.blocking?
              warnings << [change, finding]
            end
          end
        end
        session.save
        render_pre(session, injections, blockers, warnings)
      end

      def render_pre(session, injections, blockers, warnings)
        advise = warnings.map { |change, finding| finding_line(change.path, finding) }
        unless blockers.empty?
          reason = ["[POLISPEC code] blocked: the edit adds MUST violations on changed lines. Fix them and retry."]
          reason += blockers.first(MAX_FINDINGS).map { |change, finding| finding_line(change.path, finding) }
          reason += injections
          return @adapter.render_deny(cap(reason.join("\n")))
        end
        return nil if injections.empty? && advise.empty?

        text = (injections + (advise.empty? ? [] : ["Findings on this edit (SHOULD, post-write review):"] + advise.first(MAX_FINDINGS))).join("\n")
        return context_json("PreToolUse", cap(text)) if context?
        return nil if injections.empty?

        key = Digest::SHA256.hexdigest("#{@input.tool_name}#{JSON.generate(@input.tool_input)}")
        return nil if session.retry?(key)

        session.remember_retry(key)
        session.save
        @adapter.render_deny(cap("[POLISPEC code] the code specs for this language are below. Read them, then retry the same call unchanged or adjusted.\n#{injections.join("\n")}"))
      end

      def handle_post
        return nil unless Edit.tool?(@input.tool_name)

        paths = Edit.target_paths(@input.tool_name, @input.tool_input, @session_cwd)
        return nil if paths.empty?

        session = Session.load(@input.session_id, @session_cwd)
        session.begin_tracking(Repo.root(paths.first) || Repo.root(@session_cwd))
        pack = load_pack(session)
        unless pack
          session.save
          return nil
        end

        checker = Checker.new(pack)
        blockers = []
        warnings = []
        paths.each do |path|
          session.add_file(path)
          snapshot = session.take_snapshot(path)
          next unless File.file?(path) && File.size(path) <= Edit::MAX_BYTES

          after = File.read(path).force_encoding(Encoding::UTF_8)
          next if after.include?("\0")

          before = snapshot || head_text(path)
          verdict = checker.check(path, after, before: before, phases: %w[pre_write post_write])
          lower_baseline(path, verdict)
          verdict.findings.each do |finding|
            next if finding.baseline || finding.candidate || finding.level == "MAY"

            if finding.blocking? && Settings.tiered? && Settings.check_at == "post_write"
              blockers << [path, finding]
            elsif finding.blocking? || %w[SHOULD SHOULD_NOT].include?(finding.level)
              warnings << [path, finding]
            end
          end
        end
        session.save
        render_post(blockers, warnings)
      end

      def render_post(blockers, warnings)
        unless blockers.empty?
          lines = ["[POLISPEC code] the write landed with MUST violations on changed lines. Fix them now."]
          lines += blockers.first(MAX_FINDINGS).map { |path, finding| finding_line(path, finding) }
          return JSON.generate("decision" => "block", "reason" => cap(lines.join("\n")))
        end
        return nil if warnings.empty?

        lines = ["[POLISPEC code] findings on the lines you changed:"]
        lines += warnings.first(MAX_FINDINGS).map { |path, finding| finding_line(path, finding) }
        context_json("PostToolUse", cap(lines.join("\n")))
      end

      def handle_stop
        return nil unless Settings.tiered?
        return nil if @raw["stop_hook_active"] == true

        session = Session.load(@input.session_id, @session_cwd)
        return nil if session.stop_blocked? || !session.data.key?("start_sha")

        pack = load_pack(session)
        return nil unless pack

        files = session_files(session)
        return nil if files.empty?

        checker = Checker.new(pack)
        blockers = []
        review = {}
        files.first(MAX_STOP_FILES).each do |path|
          text = File.read(path).force_encoding(Encoding::UTF_8)
          next if text.include?("\0") || !text.valid_encoding?

          verdict = checker.check(path, text, before: base_text(session, path), phases: %w[pre_write post_write task_end])
          verdict.findings.each { |finding| blockers << [path, finding] if finding.blocking? }
          verdict.deferred.each { |rule| (review[rule.id] ||= { rule: rule, files: [] })[:files] << path }
        end
        return nil if blockers.empty? && review.empty?

        session.stop_blocked!
        session.save
        JSON.generate("decision" => "block", "reason" => cap(stop_text(blockers, review)))
      end

      def stop_text(blockers, review)
        lines = []
        unless blockers.empty?
          lines << "[POLISPEC code] files changed this session still carry MUST violations on changed lines:"
          lines += blockers.first(MAX_FINDINGS).map { |path, finding| finding_line(path, finding) }
        end
        unless review.empty?
          files = review.values.flat_map { |entry| entry[:files] }.uniq
          lines << "[POLISPEC code] before finishing, run the polispec-reviewer subagent on these files against the policies below, then fix every violation it reports. It reads each lens with `polispec code show <spec>`."
          lines << "Files: #{files.first(MAX_STOP_FILES).join(', ')}"
          review.values.each { |entry| lines << "- #{entry[:rule].id} (#{entry[:rule].level}) #{Code.squash(entry[:rule].title)}" }
        end
        lines.join("\n")
      end

      def session_files(session)
        root = session.data["root"]
        files = session.data["files"].dup
        if root
          start = session.start_sha.to_s
          changed = start.empty? ? [] : Code.git(root, "diff", "--name-only", "-z", start).to_s.split("\0")
          untracked = Code.git(root, "ls-files", "-o", "--exclude-standard", "-z").to_s.split("\0")
          extra = (changed + untracked) - Array(session.data["dirty_at_start"])
          files += extra.map { |relative| File.join(root, relative) }
        end
        files.uniq.select { |file| File.file?(file) && File.size(file) <= Edit::MAX_BYTES }
      end

      def base_text(session, path)
        root = session.data["root"]
        start = session.start_sha.to_s
        return nil if root.nil? || start.empty?

        relative = Repo.relative(root, path)
        Code.git(root, "show", "#{start}:#{relative}") || ""
      end

      def head_text(path)
        root = Repo.root(path)
        return "" unless root

        Code.git(root, "show", "HEAD:#{Repo.relative(root, path)}") || ""
      end

      def lower_baseline(path, verdict)
        root = Repo.root(path)
        return unless root

        baseline = Baseline.load(root)
        return unless baseline.exist?

        relative = Repo.relative(root, path)
        counts = verdict.findings.reject { |finding| finding.enforcer == "ratchet" }.group_by(&:policy).transform_values(&:length)
        baseline.counts.keys.select { |entry| entry.end_with?("\t#{relative}") }.each do |entry|
          policy = entry.split("\t", 2).first
          baseline.lower(policy, relative, counts.fetch(policy, 0))
        end
      end

      def load_pack(session)
        pack = Pack.load(ref: ENV["POLISPEC_CODE_REF"])
        raise PackInvalid, "no specs found at #{pack.source.label}" if pack.specs.empty?

        pack.load_errors.each { |file, message| Telemetry.emit("polispec.code.finding", kind: "spec_invalid", detail: "#{file}: #{message}"[0, 300]) }
        pack
      rescue Error, SystemCallError => e
        Telemetry.emit("polispec.code.finding", kind: "pack_unavailable", detail: e.message[0, 300])
        unless session.notice?
          session.notice!
          @unavailable_text = "POLISPEC code specs are unavailable (#{e.message[0, 160]}); this session's writes are not spec-checked."
        end
        nil
      end

      def finding_line(path, finding)
        place = finding.line ? "#{path}:#{finding.line}" : path
        "- #{place} [#{finding.policy}] #{finding.level} #{Code.squash(finding.message)}"
      end

      def context_json(event, text)
        JSON.generate("hookSpecificOutput" => { "hookEventName" => event, "additionalContext" => text })
      end

      def cap(text)
        text.length > MAX_OUTPUT ? "#{text[0, MAX_OUTPUT - 3]}..." : text
      end
    end
  end
end
