#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "socket"
require "json"
require "digest"
require "securerandom"
require "fileutils"
require "open3"
require "time"
require "etc"
require "uri"
require "stringio"
require_relative "commands/hook"
require_relative "commands/code_hook"
require_relative "predicates"

module Polispec
  module Judge
    PROTOCOL = "POLISPEC/1"
    HEADER_LIMIT = 512
    HEADER_DEADLINE = 1.0
    PAYLOAD_DEADLINE = 3.0
    DEFAULT_IDLE = 1800
    IDLE_NEVER = 0
    WORKER_LIMIT = 32
    WORKER_MIN = 4
    WORKER_MAX = 16
    WORKER_DIVISOR = 4
    WORKER_REQUEST_CAP = 5000
    WORKER_RSS_CAP_MB = 512
    LISTEN_BACKLOG = 256
    RESPAWN_DELAY = 0.2
    RESPAWN_BACKOFF = 5.0
    EARLY_DEATH = 1.0
    EARLY_DEATH_LIMIT = 3
    RECYCLED_STATUS = 3
    SUPERVISED_NAME = "judge.supervised"
    LOG_LIMIT = 1_048_576
    LOG_ATTEMPTS = 3
    STATM_RESIDENT = 1
    BYTES_PER_MB = 1_048_576
    KEEP_MEMO = %i[ledger_load spec_policy prefetch_policies shipped_layer layers_fingerprint catalog_state catalog_modules catalog_delete_protected catalog_delete_backup].freeze
    JUDGE_MODES = %w[pretool session].freeze
    CODE_MODES = %w[code-pre code-post code-session code-stop].freeze
    HEADER = /\A#{Regexp.escape(PROTOCOL)} (\h{32}) (pretool|session|code-pre|code-post|code-session|code-stop) ([a-z]+) (\S.*?)(?: caller=(\d+))? (\d+)\z/.freeze
    PRELOAD = %w[
      Resolve PolicySource Engine Fastpath Canonical Judgments Journal Freeze Roster Controls Description Effect Editions
      Sessions Changes HookMemo Notice Chain Trace Exposure Ledger Catalog Layers Exceptions Events State NativeSettings
      Harness::Claude Harness::Codex Harness::Generic Harness::Hermes Harness::Antigravity
      HarnessControls::Plane HarnessControls::Lifecycle HarnessControls::Evaluate HarnessControls::Authorizations
      Code::Settings Code::Paths Code::GitSource Code::DirSource Code::Pack Code::Detector Code::Chain Code::Composer
      Code::Edit Code::Runner Code::Checker Code::Baseline Code::Waivers Code::Controls Code::Session Code::Hook
      Code::Telemetry Code::Repo
    ].freeze
    UNIT = <<~UNIT
      [Unit]
      Description=polispec resident judge

      [Service]
      Type=simple
      ExecStart=%h/.local/bin/polispec judge serve
      Environment=POLISPEC_JUDGE_IDLE=0
      Restart=always
      RestartSec=1
      Slice=polispec-guard.slice

      [Install]
      WantedBy=default.target
    UNIT

    module_function

    def state_path
      File.join(State.home, "judge.json")
    end

    def log_path
      File.join(State.home, "judge.log")
    end

    def supervised_path
      File.join(State.home, SUPERVISED_NAME)
    end

    def own_runtime
      forced = ENV["POLISPEC_JUDGE_RUNTIME"].to_s.strip
      return File.expand_path(forced) unless forced.empty?

      File.join(Polispec::ROOT, "bin")
    end

    def read_state
      data = JSON.parse(File.read(state_path))
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def listening?(state)
      return false unless state && state["port"].is_a?(Integer)

      Socket.tcp("127.0.0.1", state["port"], connect_timeout: 0.5) { true }
    rescue SystemCallError, IOError, SocketError
      false
    end

    def idle_seconds
      value = ENV["POLISPEC_JUDGE_IDLE"].to_s.strip
      value.match?(/\A\d+\z/) ? value.to_i : DEFAULT_IDLE
    end

    def worker_count
      [ENV["POLISPEC_JUDGE_WORKERS"], ENV["POLISPEC_JUDGE_THREADS"]].each do |raw|
        value = raw.to_s.strip
        return value.to_i if value.match?(/\A\d+\z/) && value.to_i.between?(1, WORKER_LIMIT)
      end
      (Etc.nprocessors / WORKER_DIVISOR).clamp(WORKER_MIN, WORKER_MAX)
    end

    def supervised?
      !ENV["INVOCATION_ID"].to_s.strip.empty?
    end

    def preload
      PRELOAD.each do |name|
        Polispec.const_get(name)
      rescue NameError, LoadError
        next
      end
      Classify::Registry.families
      Digest::SHA256
    end

    def append_log(record)
      path = log_path
      line = "#{JSON.generate(record)}\n"
      LOG_ATTEMPTS.times do
        file = File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600)
        begin
          if file.size > LOG_LIMIT
            rotate_log(file, path)
            next
          end
          file.syswrite(line)
          return true
        ensure
          file.close
        end
      end
      false
    rescue SystemCallError, IOError
      false
    end

    def rotate_log(file, path)
      file.flock(File::LOCK_EX)
      current = File.stat(path)
      File.rename(path, "#{path}.1") if current.ino == file.stat.ino && file.size > LOG_LIMIT
    rescue Errno::ENOENT
      nil
    end
  end
end

require_relative "judge/freshness"
require_relative "judge/worker"
require_relative "judge/server"
