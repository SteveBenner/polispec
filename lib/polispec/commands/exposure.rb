#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "json"
require_relative "../predicates"
require_relative "../git_safe"

module Polispec
  class ExposureCommand
    USAGE = "usage: polispec exposure scan [<repo-dir>] [--remote R] [--ref REF] [--source SRC] [--json]"
    AUDIT_TIMEOUT = 600
    KILL_GRACE = 5
    LS_REMOTE_TIMEOUT = 30
    HISTORY_TIMEOUT = 60
    VALUE_FLAGS = %w[--remote --ref --source].freeze

    def self.run(args)
      new.run(args)
    end

    def run(args)
      args = args.dup
      @json = !args.delete("--json").nil?
      return usage unless args.shift == "scan"

      options = parse(args)
      return usage unless options

      scan(options)
    rescue Predicates::Expired
      fail_with("a git call exceeded its time budget", "error")
    rescue Polispec::Error => e
      fail_with(e.message.sub(/\Apolispec: /, ""), "error")
    end

    private

    def usage
      warn USAGE
      2
    end

    def parse(args)
      options = { repo: nil, remote: nil, ref: nil, source: nil }
      until args.empty?
        arg = args.shift
        flag, inline = arg.split("=", 2)
        if VALUE_FLAGS.include?(flag)
          value = inline || args.shift
          return nil if value.to_s.empty? || value.start_with?("--")

          options[flag.delete_prefix("--").to_sym] = value
        elsif arg.start_with?("-") || options[:repo]
          return nil
        else
          options[:repo] = arg
        end
      end
      options
    end

    def scan(options)
      repo = resolve_repo(options[:repo])
      return fail_with("#{options[:repo] || Dir.pwd} is not inside a git repository", "error") unless repo

      url = Visibility.remote_url(repo, options[:remote])
      return fail_with("remote #{Visibility.remote_name(repo, options[:remote])} is not defined in #{repo}", "error") if url.nil? || url.empty?

      remote_key = Visibility.normalize(url)
      return report({ "status" => "private", "remote" => remote_key }, "no scan is needed: #{remote_key} is private", 0) if Visibility.of(url) == :private

      argv = Exposure.audit_argv
      return fail_with("#{Engine::Settings::EXPOSURE_AUDIT_KEY} is not set; set it to the audit command (argv, no shell) before scanning", "unconfigured", 2) if argv.empty?

      ref = options[:ref] || Visibility.branch_of(repo)
      return fail_with("no branch is checked out; pass --ref", "error") if ref.to_s.empty?

      local = options[:source] || ref
      to = Predicates.git_ok(repo, "rev-parse", "-q", "--verify", "refs/heads/#{local}^{commit}") || Predicates.git_ok(repo, "rev-parse", "-q", "--verify", "#{local}^{commit}")
      return fail_with("#{local} does not name a commit in #{repo}", "error") unless to

      return fail_with("#{Engine::Settings::EXPOSURE_AUDIT_KEY} holds a NUL byte; nothing was recorded", "error") if argv.any? { |arg| arg.to_s.include?("\0") }

      resolved = Exposure.resolved_command(argv)
      return fail_with("the audit command #{resolved} is not readable, so its digest cannot be recorded; nothing was recorded", "error") if resolved && !File.readable?(resolved)
      return fail_with("the audit command #{argv.first} was not found or is not executable in #{Exposure.program_dirs.join(', ')}; set #{Engine::Settings::EXPOSURE_AUDIT_KEY} to an absolute path; nothing was recorded", "error") unless resolved

      tip = remote_tip(repo, url, ref)
      return fail_with("the remote #{remote_key} could not be read for #{ref}; a scan needs the remote tip and nothing was recorded", "error") if tip.nil?

      found = dev_history(repo, tip, to)
      return fail_with("the commits from #{tip.empty? ? 'the root' : tip[0, 12]} to #{to[0, 12]} could not be listed; fetch #{Visibility.remote_name(repo, options[:remote])} so the remote tip is in this clone, then scan again; nothing was recorded", "error") if found.nil?
      return blocked(found) unless found.empty?

      from = tip.empty? ? Exposure.empty_tree(repo) : tip
      run_audit(repo, url, remote_key, ref, from, to, [resolved, *argv.drop(1)], tip)
    end

    def dev_history(repo, tip, to)
      Thread.current[:polispec_deadline] = Predicates.monotonic + HISTORY_TIMEOUT + 1
      range = tip.empty? ? to : "#{tip}..#{to}"
      out, status, = Predicates.capture(GitSafe.argv(repo, "log", "--no-renames", "--name-only", "--diff-filter=AMT", "--format=", "-z", range, "--"), env: GitSafe.env, timeout: HISTORY_TIMEOUT)
      return nil unless status.success?

      out.split("\0").map { |path| path.delete_prefix("\n") }.reject(&:empty?).uniq.filter_map do |path|
        reason = Predicates.dev_history_reason(path)
        [path, reason] if reason
      end
    rescue Predicates::Expired
      nil
    ensure
      Thread.current[:polispec_deadline] = nil
    end

    def blocked(found)
      message = "the commits add development history, which never goes to a public remote; remove it from every unpushed commit and scan again; nothing was recorded"
      if @json
        puts JSON.generate("status" => "dev_history", "error" => message, "paths" => found.map { |path, reason| { "path" => path, "reason" => reason } })
      else
        warn "polispec: #{message}"
        found.each { |path, reason| warn "  #{path}: #{reason}" }
      end
      1
    end

    def remote_tip(repo, url, ref)
      Thread.current[:polispec_deadline] = Predicates.monotonic + LS_REMOTE_TIMEOUT + 1
      out, status, = Predicates.capture(GitSafe.argv(repo, "ls-remote", "--", url, "refs/heads/#{ref}"), env: GitSafe.env("GIT_TERMINAL_PROMPT" => "0"), timeout: LS_REMOTE_TIMEOUT)
      return nil unless status.success?

      line = out.lines.map { |text| text.chomp.split("\t", 2) }.find { |_sha, name| name == "refs/heads/#{ref}" }
      line ? line.first.to_s : ""
    rescue Predicates::Expired, StandardError
      nil
    ensure
      Thread.current[:polispec_deadline] = nil
    end

    def resolve_repo(path)
      Predicates.git_ok(File.expand_path(path || Dir.pwd), "rev-parse", "--show-toplevel")
    end

    def run_audit(repo, url, remote_key, ref, from, to, argv, tip)
      env = {
        "POLISPEC_EXPOSURE_REPO" => repo,
        "POLISPEC_EXPOSURE_FROM" => from,
        "POLISPEC_EXPOSURE_TO" => to,
        "POLISPEC_EXPOSURE_REMOTE" => remote_key
      }
      outcome = execute(argv, env, repo)
      return fail_with("the audit command exceeded #{AUDIT_TIMEOUT} s and was killed; nothing was recorded", "timeout") if outcome == :timeout
      return fail_with("the audit command could not start: #{outcome[1]}; nothing was recorded", "error") if outcome.first == :error
      return fail_with("the audit command exited #{outcome[1]}; nothing was recorded", "failed") unless outcome[1].zero?

      record = record_for(repo, url, remote_key, ref, from, to, tip)
      Exposure.append(record["repo"], record)
      report({ "status" => "clean", "record" => record }, JSON.generate(record), 0)
    end

    def record_for(repo, url, remote_key, ref, from, to, tip)
      {
        "repo" => Visibility.normalize(Predicates.repo_origin_url(repo) || url),
        "remote" => remote_key,
        "ref" => ref,
        "from" => from,
        "to" => to,
        "remote_tip" => tip,
        "tree" => Predicates.git_ok(repo, "rev-parse", "-q", "--verify", "#{to}^{tree}").to_s,
        "command_digest" => Exposure.command_digest,
        "at" => Time.now.utc.iso8601
      }
    end

    def execute(argv, env, repo)
      out = @json ? $stderr : $stdout
      pid = Process.spawn(env, *argv, chdir: repo, in: File::NULL, out: out, err: $stderr, pgroup: true)
      waiter = Process.detach(pid)
      return [:exit, waiter.value.exitstatus || -1] if waiter.join(AUDIT_TIMEOUT)

      terminate(pid, waiter)
      :timeout
    rescue SystemCallError => e
      [:error, e.message]
    end

    def terminate(pid, waiter)
      Process.kill("TERM", -pid)
      return if waiter.join(KILL_GRACE)

      Process.kill("KILL", -pid)
      waiter.join
    rescue Errno::ESRCH
      nil
    end

    def report(result, text, status)
      @json ? puts(JSON.generate(result)) : puts(text)
      status
    end

    def fail_with(message, kind, status = 1)
      if @json
        puts JSON.generate("status" => kind, "error" => message)
      else
        warn "polispec: #{message}"
      end
      status
    end
  end
end

Polispec::CLI.register("exposure", Polispec::ExposureCommand, summary: "scan a branch before it is pushed to a public remote; exposure scan [<repo-dir>] [--remote R] [--ref REF] [--source SRC] [--json]")
