#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

module Polispec
  module Exposure
    DIRECTORY = "exposure"
    EMPTY_TREE_ARGS = ["hash-object", "-t", "tree", "/dev/null"].freeze

    module_function

    def audit_argv
      Engine::Settings.argv(Engine::Settings::EXPOSURE_AUDIT_KEY)
    end

    def command_digest(argv = audit_argv)
      Digest::SHA256.hexdigest(argv.join("\0"))
    end

    def repo_id(normalized)
      normalized.to_s.gsub(/[^A-Za-z0-9._-]/, "_")
    end

    def log_name(normalized)
      File.join(DIRECTORY, repo_id(normalized))
    end

    def empty_tree(dir)
      Predicates.git_ok(dir, *EMPTY_TREE_ARGS)
    end

    def records(normalized)
      State.read_jsonl(log_name(normalized))
    end

    def append(normalized, record)
      path = State.log_path(log_name(normalized))
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |file| file.syswrite("#{JSON.generate(record)}\n") }
      end
      record
    end

    def current(normalized)
      digest = command_digest
      records(normalized).select { |record| record["command_digest"] == digest }
    end

    def covers_branch?(normalized, remote, ref, from, to)
      latest = current(normalized).select { |record| record["remote"] == remote && record["ref"] == ref }.last
      !latest.nil? && latest["from"] == from && latest["to"] == to
    end

    def covers_commit?(normalized, commit)
      current(normalized).any? { |record| record["to"] == commit }
    end
  end
end
