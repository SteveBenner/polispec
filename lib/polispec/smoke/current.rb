#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "../smoke"

module Polispec
  module Smoke
    module Current
      GATE_ID = "smoke_current"
      LEDGERS = [Smoke::MARKDOWN_NAME, Smoke::LEGACY_NAME].freeze
      PROOFS_DIR = "proofs"
      LIMIT = 50

      module_function

      def gate(git, base, candidate)
        return nil unless Smoke.promote_warn?

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        base = nil if base.to_s.empty? || base.to_s.count("0") == base.to_s.length
        changed = changed_paths(git, base, candidate)
        return nil if changed.empty?

        commits = range_commits(git, base, candidate)
        return nil if covered?(git, candidate, commits)

        {
          "id" => GATE_ID, "result" => "warn", "duration_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
          "since" => (base || root_commit(git, candidate)).to_s[0, 12], "count" => changed.length,
          "findings" => changed.first(LIMIT).map { |path| { "kind" => "unsmoked_file", "path" => path } }
        }
      rescue StandardError
        nil
      end

      def changed_paths(git, base, candidate)
        listing = base ? git.run!("diff", "--name-only", "-z", "#{base}..#{candidate}") : git.run!("ls-tree", "-r", "--name-only", "-z", candidate)
        listing.out.split("\0").reject(&:empty?)
      end

      def range_commits(git, base, candidate)
        range = base ? "#{base}..#{candidate}" : candidate
        git.run!("rev-list", range).out.split("\n").map(&:strip).reject(&:empty?)
      end

      def root_commit(git, candidate)
        git.run!("rev-list", "--max-parents=0", candidate).out.lines.first.to_s.strip
      end

      def covered?(git, candidate, commits)
        known = commits.to_h { |sha| [sha, true] }
        ledger_commits(git, candidate).any? { |sha| known[sha] } || proof_commits(git, candidate).any? { |sha| known[sha] }
      end

      def ledger_commits(git, candidate)
        LEDGERS.flat_map do |name|
          text = git.show(candidate, name)
          next [] if text.nil?

          Smoke.entries_of(Smoke.parse_document(text, name)).map { |entry| entry.dig("target", "commit").to_s }
        rescue Polispec::Error
          []
        end
      end

      def proof_commits(git, candidate)
        listing = git.run("ls-tree", "-r", "--name-only", "-z", candidate, "#{PROOFS_DIR}/")
        return [] unless listing.ok?

        listing.out.split("\0").select { |path| path.end_with?(".jsonl") }.flat_map do |path|
          text = git.show(candidate, path).to_s
          text.each_line.flat_map { |line| proof_line_commits(line) }
        end
      end

      def proof_line_commits(line)
        record = JSON.parse(line)
        return [] unless record.is_a?(Hash)

        target = record["target"]
        [record["commit"], target.is_a?(Hash) ? target["commit"] : nil].compact.map(&:to_s)
      rescue JSON::ParserError
        []
      end
    end
  end
end
