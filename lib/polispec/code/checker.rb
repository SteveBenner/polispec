#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    Finding = Struct.new(:policy, :level, :severity, :line, :message, :enforcer, :baseline, :candidate, :klass, keyword_init: true) do
      def to_h
        data = { "policy" => policy, "level" => level, "severity" => severity, "line" => line, "message" => message, "enforcer" => enforcer, "baseline" => baseline }
        data["candidate"] = true if candidate
        data
      end

      def blocking?
        !baseline && !candidate && BLOCKING_LEVELS.include?(level)
      end
    end

    Verdict = Struct.new(:file, :language, :chain_digest, :findings, :blocked, :errors, :deferred, :notes, :duration_ms, keyword_init: true) do
      def to_h
        { "file" => file, "language" => language, "chain_digest" => chain_digest, "findings" => findings.map(&:to_h), "blocked" => blocked }
      end
    end

    class Checker
      CHECK_PHASES = %w[pre_write post_write].freeze
      RUNNABLE = %w[ripper grep rubocop script].freeze
      ASK_CACHE = {}

      attr_reader :pack, :detector, :runner

      def self.enforceable?(rule)
        enforcer = rule.enforcer
        %w[harness hybrid contextual].include?(rule.klass) && enforcer && RUNNABLE.include?(enforcer["kind"])
      end

      def initialize(pack)
        @pack = pack
        @detector = Detector.new(pack)
        @runner = Runner.new(pack)
      end

      def check(path, after, before: nil, changed: :auto, language: nil, phases: CHECK_PHASES, emit: true)
        started = Code.clock
        root = Repo.root(path)
        relative = Repo.relative(root, path)
        language ||= detector.detect(path, head: after)
        chain = Chain.for(pack, language)
        changed = before.nil? ? nil : Diff.changed_lines(before, after) if changed == :auto
        rules = chain.rules_for_path(relative).select { |rule| (rule.phases & phases).any? && rule.active? }
        deferred = []
        runnable = select_runnable(rules, path, after, changed, deferred)
        result = runner.run(runnable, after, path)
        waivers = Waivers.load(root)
        baseline = root ? Baseline.load(root) : nil
        notes = waivers.problems.dup
        findings = build_findings(result.hits, changed, waivers, relative, notes)
        findings.concat(ratchet_findings(result.hits, baseline, relative)) if baseline
        deferred.concat(rules.select { |rule| %w[agent hybrid].include?(rule.klass) })
        deferred.uniq!(&:id)
        blocked = Settings.tiered? && findings.any?(&:blocking?)
        verdict = Verdict.new(
          file: path, language: language, chain_digest: chain.digest, findings: findings, blocked: blocked,
          errors: result.errors, deferred: deferred, notes: notes, duration_ms: Code.elapsed_ms(started)
        )
        report(verdict) if emit
        verdict
      end

      def changed?(changed, line)
        changed.nil? || line.nil? || line.zero? || changed.include?(line)
      end

      private

      def select_runnable(rules, path, after, changed, deferred)
        runnable = []
        rules.each do |rule|
          if rule.klass == "contextual"
            outcome = contextual(rule, path, after, changed)
            if outcome == :applies
              self.class.enforceable?(rule) ? runnable << rule : deferred << rule
            elsif outcome == :defer
              deferred << rule
            end
          elsif self.class.enforceable?(rule)
            runnable << rule
          end
        end
        runnable
      end

      def contextual(rule, path, after, changed)
        question = rule.applies_if
        return :defer unless question

        options = Array(question["options"])
        options = ["applies", "does not apply"] if options.empty?
        hunk = hunk_text(after, changed)
        key = [rule.id, path, Digest::SHA256.hexdigest(hunk)]
        answer = ASK_CACHE.fetch(key) { ASK_CACHE[key] = Decide.ask(question: question["question"], options: options, context: { "path" => path, "hunk" => hunk }) }
        return :defer unless answer
        return :defer if answer["probability"] < pack.confidence_floor(rule)

        answer["choice"] == options.first ? :applies : :skip
      end

      def hunk_text(after, changed)
        lines = after.lines
        picked = changed.nil? ? lines.first(200) : changed.to_a.sort.first(200).map { |number| lines[number - 1] }
        picked.compact.join[0, 4000]
      end

      def build_findings(hits, changed, waivers, relative, notes)
        hits.each_with_object([]) do |hit, memo|
          rule = hit.rule
          if waivers.suppressed?(rule, relative)
            next
          end

          waivers.expired_for(rule.id, relative).each { |entry| notes << "waiver for #{entry.policy} expired #{entry.review_after}; it no longer suppresses" }
          level = waivers.tightened(rule, relative) || rule.level
          in_changed = !rule.ratchet? || changed?(changed, hit.line)
          memo << Finding.new(
            policy: rule.id, level: level, severity: rule.severity, line: hit.line, message: hit.message,
            enforcer: rule.enforcer["kind"], baseline: !in_changed, candidate: rule.klass == "hybrid", klass: rule.klass
          )
        end
      end

      def ratchet_findings(hits, baseline, relative)
        counts = hits.group_by { |hit| hit.rule.id }
        counts.each_with_object([]) do |(policy, list), memo|
          recorded = baseline.count(policy, relative)
          next unless recorded && list.length > recorded

          rule = list.first.rule
          memo << Finding.new(
            policy: policy, level: "SHOULD", severity: rule.severity, line: nil, enforcer: "ratchet", baseline: false, candidate: false, klass: rule.klass,
            message: "violations of #{policy} in #{relative} rose from #{recorded} to #{list.length}; the baseline may only shrink"
          )
        end
      end

      def report(verdict)
        blocking = verdict.findings.count(&:blocking?)
        Telemetry.emit(
          "polispec.code.verdict", file: verdict.file, language: verdict.language, chain_digest: verdict.chain_digest,
          findings: verdict.findings.length, blocking: blocking, baseline: verdict.findings.count(&:baseline), duration_ms: verdict.duration_ms
        )
        verdict.errors.each do |error|
          Telemetry.emit("polispec.code.finding", kind: "enforcer_error", policy: error["policy"], enforcer: error["enforcer"], detail: error["message"], file: verdict.file)
        end
      end
    end
  end
end
