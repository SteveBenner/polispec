#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "fileutils"
require "open3"
require "rbconfig"
require "securerandom"
require_relative "prune"

module Polispec
  module Smoke
    module Sandbox
      BWRAP = "/usr/bin/bwrap"
      ENTERED = "POLISPEC_SMOKE_SANDBOXED"
      HIDDEN = %w[/tmp /run /etc/polispec].freeze
      ISOLATION = %w[--die-with-parent --new-session --unshare-user --unshare-pid --unshare-net --unshare-ipc --ro-bind / / --dev /dev --proc /proc].freeze

      module_function

      def needed?(live:, host_copy:)
        return false if ENV[ENTERED] || !live.empty? || host_copy

        require_relative "../harness_controls/plane"
        HarnessControls::Plane.resolve["status"] == "active"
      end

      def unavailable
        return "#{BWRAP} is not installed" unless File.executable?(BWRAP)

        _out, err, status = Open3.capture3(*command([], []), "true")
        status.success? ? nil : err.lines.first.to_s.strip
      end

      def run(options, tree: ROOT)
        if options.record
          raise Polispec::Error, "smoke_record_sealed: recording is unavailable inside the sealed smoke sandbox; pass --no-record"
        end

        out = prepare_out(options.out)
        readable = [tree, options.against, options.scenarios].compact.map { |path| File.expand_path(path) }
        argv = command(readable, [out]) + ["--chdir", Dir.pwd.start_with?("/tmp", "/run") ? File.expand_path(tree) : Dir.pwd]
        argv += [RbConfig.ruby, File.join(File.expand_path(tree), "bin", "polispec"), *inner_args(options, out)]
        env = { ENTERED => "1", "POLISPEC_STATE_HOME" => File.join(out, ".runner-state"), "TMPDIR" => "/tmp", "SSH_AUTH_SOCK" => nil }
        $stderr.puts "smoke: a sealed plane is active; scenarios run in a read-only sandbox without network, writing only to #{out}"
        Process.wait(Process.spawn(env, *argv))
        Process.last_status.exitstatus || 1
      end

      def command(readable, writable)
        argv = [BWRAP, *ISOLATION]
        HIDDEN.each { |path| argv.push("--tmpfs", path) if File.directory?(path) }
        readable.each { |path| argv.push("--ro-bind", path, path) }
        writable.each { |path| argv.push("--bind", path, path) }
        argv
      end

      def prepare_out(requested)
        out = File.expand_path(requested || File.join(Prune.root, "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(3)}"))
        if File.exist?(out) || File.symlink?(out)
          raise Polispec::Error, "smoke_out_exists: under a sealed plane --out must name a directory that does not exist yet"
        end

        Prune.run(current: out) unless requested
        FileUtils.mkdir_p(File.dirname(out))
        Dir.mkdir(out, 0o700)
        out
      end

      def inner_args(options, out)
        args = %w[smoke run --no-record]
        options.units.each { |unit| args.push("--unit", unit) }
        args.push("--scenarios", File.expand_path(options.scenarios)) if options.scenarios
        args.push("--against", File.expand_path(options.against)) if options.against
        args.push("--out", out)
        args << "--accept-changes" if options.accept
        args << "--strict" if options.strict
        args << "--json" if options.json
        args
      end
    end
  end
end
