#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "json"
require_relative "../predicates"

module Polispec
  class ExposureCommand
    USAGE = "usage: polispec exposure scan [<repo-dir>] [--remote R] [--ref REF] [--source SRC] [--json]"
    AUDIT_TIMEOUT = 600
    KILL_GRACE = 5
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

      from = tracking_tip(repo, options[:remote], ref) || Exposure.empty_tree(repo)
      run_audit(repo, url, remote_key, ref, from, to, argv)
    end

    def resolve_repo(path)
      Predicates.git_ok(File.expand_path(path || Dir.pwd), "rev-parse", "--show-toplevel")
    end

    def tracking_tip(repo, remote, ref)
      name = Visibility.remote_name(repo, remote)
      return nil if Visibility.url_like?(name)

      Predicates.git_ok(repo, "rev-parse", "-q", "--verify", "refs/remotes/#{name}/#{ref}^{commit}")
    end

    def run_audit(repo, url, remote_key, ref, from, to, argv)
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

      record = record_for(repo, url, remote_key, ref, from, to)
      Exposure.append(record["repo"], record)
      report({ "status" => "clean", "record" => record }, JSON.generate(record), 0)
    end

    def record_for(repo, url, remote_key, ref, from, to)
      {
        "repo" => Visibility.normalize(Predicates.repo_origin_url(repo) || url),
        "remote" => remote_key,
        "ref" => ref,
        "from" => from,
        "to" => to,
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
