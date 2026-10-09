#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "set"
require "timeout"
require "tmpdir"

module Polispec
  module Code
    DIR = File.join(LIB, "code")
    LEVELS = %w[MUST MUST_NOT SHOULD SHOULD_NOT MAY].freeze
    BLOCKING_LEVELS = %w[MUST MUST_NOT].freeze
    SEVERITIES = %w[critical high medium low].freeze
    CLASSES = %w[harness agent hybrid contextual].freeze
    DEFAULT_REF = "stable"
    AUTHORING_REF = "worktree"
    INJECT_CAP = 9500

    class Error < Polispec::Error; end
    class PackMissing < Error; end
    class PackInvalid < Error; end

    autoload :Settings, File.join(DIR, "settings")
    autoload :Paths, File.join(DIR, "paths")
    autoload :GitSource, File.join(DIR, "source")
    autoload :DirSource, File.join(DIR, "source")
    autoload :Pack, File.join(DIR, "pack")
    autoload :Node, File.join(DIR, "pack")
    autoload :Spec, File.join(DIR, "pack")
    autoload :Detector, File.join(DIR, "detect")
    autoload :Chain, File.join(DIR, "chain")
    autoload :Composer, File.join(DIR, "composer")
    autoload :Validator, File.join(DIR, "validator")
    autoload :Edit, File.join(DIR, "edit")
    autoload :Diff, File.join(DIR, "edit")
    autoload :Runner, File.join(DIR, "runner")
    autoload :Hit, File.join(DIR, "runner")
    autoload :Checker, File.join(DIR, "checker")
    autoload :Verdict, File.join(DIR, "checker")
    autoload :Finding, File.join(DIR, "checker")
    autoload :Baseline, File.join(DIR, "baseline")
    autoload :Waivers, File.join(DIR, "waivers")
    autoload :Controls, File.join(DIR, "controls")
    autoload :Generate, File.join(DIR, "generate")
    autoload :Classify, File.join(DIR, "classify")
    autoload :Decide, File.join(DIR, "decide")
    autoload :Session, File.join(DIR, "session")
    autoload :Hook, File.join(DIR, "hook")
    autoload :Admin, File.join(DIR, "admin")
    autoload :Telemetry, File.join(DIR, "telemetry")
    autoload :Repo, File.join(DIR, "repo")

    module_function

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started)
      ((clock - started) * 1000).round(2)
    end

    def git(repo, *args, stdin: nil)
      out, status = Open3.capture2(PolicySource::GIT_ENV, "git", "-C", repo, *args, stdin_data: stdin.to_s, err: File::NULL)
      status.success? ? out : nil
    rescue SystemCallError
      nil
    end

    def squash(text)
      text.to_s.gsub(/\s+/, " ").strip
    end

    def write_atomic(path, text, mode = 0o600)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      temp = "#{path}.#{Process.pid}.#{rand(1_000_000)}.tmp"
      File.write(temp, text, perm: mode)
      File.rename(temp, path)
      path
    end
  end
end
