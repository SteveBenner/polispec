#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Operator
    class Failure < Polispec::Error
      attr_reader :code, :payload

      def initialize(code, message, payload = {})
        super(message)
        @code = code.to_s
        @payload = payload
      end

      def with_payload(extra)
        Failure.new(code, message, payload.merge(extra))
      end

      def to_h
        { "code" => code, "message" => message, "payload" => payload }
      end

      def report(json:, out: $stdout, err: $stderr)
        if json
          out.puts JSON.generate("ok" => false, "error" => to_h)
          return
        end

        err.puts "polispec: #{code}: #{message}"
        payload.each do |key, value|
          next if value.nil? || key == "output_tail"

          err.puts "  #{key}: #{value.is_a?(String) ? value : JSON.generate(value)}"
        end
        tail = payload["output_tail"].to_s
        return if tail.empty?

        err.puts "  output (last lines):"
        tail.each_line { |line| err.puts "    #{line.chomp}" }
      end
    end

    class Git
      Result = Struct.new(:out, :err, :code) do
        def ok?
          code.zero?
        end

        def tail
          Polispec::Operator::Git.tail([err, out].reject(&:empty?).join("\n"))
        end
      end

      ZEROS = ("0" * 40).freeze
      TAG_PATTERN = /\Av\d+(\.\d+)*([.-][0-9A-Za-z.-]+)?\z/
      BLOCKED = %w[reset --hard --no-ff --mirror --prune-tags].freeze
      TAIL_LINES = 40

      attr_reader :dir

      def self.tail(text, lines = TAIL_LINES)
        text.to_s.lines.last(lines).join.rstrip
      end

      def self.guard!(argv)
        argv.each do |arg|
          blocked = BLOCKED.include?(arg) || arg == "-f" || arg.start_with?("--force") || arg.start_with?("+")
          raise Failure.new("forbidden_git", "refused git #{argv.join(' ')}: history is never rewritten or force-moved") if blocked
        end
      end

      def self.clone(source, dest)
        argv = ["git", "clone", "--quiet", source, dest]
        out, err, status = Open3.capture3(env, *argv)
        return if status.success?

        raise Failure.new("clone_failed", "git clone #{source} failed", "output_tail" => tail([err, out].join("\n")))
      rescue SystemCallError => e
        raise Failure.new("clone_failed", "git clone #{source} failed: #{e.message}")
      end

      def self.env
        { "GIT_TERMINAL_PROMPT" => "0", "LC_ALL" => "C", "GIT_PAGER" => "cat", "POLISPEC_OPERATOR" => "1" }
      end

      def initialize(dir)
        @dir = File.expand_path(dir)
      end

      def run(*argv)
        self.class.guard!(argv)
        out, err, status = Open3.capture3(self.class.env, "git", "-C", dir, *argv)
        Result.new(out, err, status.exitstatus || 1)
      rescue SystemCallError => e
        raise Failure.new("git_unavailable", "git could not run in #{dir}: #{e.message}")
      end

      def run!(*argv, code: "git_failed")
        result = run(*argv)
        return result if result.ok?

        raise Failure.new(code, "git #{argv.join(' ')} failed in #{dir}", "output_tail" => result.tail)
      end

      def fetch(remote = "origin")
        run!("fetch", "--quiet", "--prune", "--tags", remote, code: "fetch_failed")
      end

      def rev(ref)
        result = run("rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
        result.ok? ? result.out.strip : nil
      end

      def ancestor?(older, newer)
        result = run("merge-base", "--is-ancestor", older, newer)
        return true if result.code.zero?
        return false if result.code == 1

        raise Failure.new("git_failed", "git merge-base --is-ancestor #{older} #{newer} failed", "output_tail" => result.tail)
      end

      def show(sha, path)
        result = run("show", "#{sha}:#{path}")
        result.ok? ? result.out : nil
      end

      def root_entries(sha)
        run!("ls-tree", "--name-only", sha).out.lines.map(&:chomp)
      end

      def tags
        run!("tag", "--list", "v*").out.lines.map(&:strip).select { |name| TAG_PATTERN.match?(name) }
      end

      def latest_tag(names = tags)
        names.max_by { |name| tag_version(name) }
      end

      def tag_version(name)
        Gem::Version.new(name.sub(/\Av/, ""))
      rescue ArgumentError
        Gem::Version.new("0")
      end

      def tags_at(sha)
        run!("tag", "--points-at", sha, "--list", "v*").out.lines.map(&:strip).select { |name| TAG_PATTERN.match?(name) }
      end

      def tag_commit(name)
        rev("refs/tags/#{name}")
      end

      def create_tag(name, sha)
        run!("tag", name, sha, code: "tag_failed")
      end

      def drop_tag(name, sha)
        run("update-ref", "-d", "refs/tags/#{name}", sha)
      end

      def dirty?
        !run!("status", "--porcelain", "--untracked-files=no").out.strip.empty?
      end

      def current_branch
        result = run("symbolic-ref", "--quiet", "--short", "HEAD")
        result.ok? ? result.out.strip : nil
      end

      def remote_url(remote = "origin")
        result = run("remote", "get-url", remote)
        result.ok? ? result.out.strip : nil
      end

      def push_atomic(remote, refspecs)
        result = run("push", "--atomic", remote, *refspecs)
        return result if result.ok?

        raise Failure.new("push_rejected", "git push #{remote} #{refspecs.join(' ')} was rejected", "output_tail" => result.tail)
      end

      def branch_elsewhere?(branch)
        listing = run("worktree", "list", "--porcelain").out
        here = File.realpath(dir)
        current = nil
        listing.each_line do |line|
          current = File.realpath(line.sub("worktree ", "").strip) if line.start_with?("worktree ")
          return true if line.strip == "branch refs/heads/#{branch}" && current != here
        end
        false
      rescue SystemCallError
        false
      end

      def advance_branch(branch, sha)
        old = rev("refs/heads/#{branch}")
        return :skipped if old && branch_elsewhere?(branch)
        return :unchanged if old == sha

        if old.nil?
          run!("update-ref", "refs/heads/#{branch}", sha, ZEROS)
          :created
        elsif !ancestor?(old, sha)
          :diverged
        elsif current_branch == branch
          run!("merge", "--ff-only", "--quiet", sha)
          :advanced
        else
          run!("update-ref", "refs/heads/#{branch}", sha, old)
          :advanced
        end
      end

      def checkout_tracking(branch, remote = "origin")
        if rev("refs/heads/#{branch}")
          run!("checkout", "--quiet", branch, code: "checkout_failed")
        else
          run!("checkout", "--quiet", "-b", branch, "--track", "#{remote}/#{branch}", code: "checkout_failed")
        end
        run!("merge", "--ff-only", "--quiet", "#{remote}/#{branch}", code: "checkout_failed")
      end

      def checkout_detached(ref)
        run!("checkout", "--quiet", "--detach", ref, code: "checkout_failed")
      end

      def head
        rev("HEAD")
      end
    end
  end
end
