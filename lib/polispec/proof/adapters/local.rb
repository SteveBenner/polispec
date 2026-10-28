#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "open3"
require "securerandom"
require "fileutils"
require "time"

module Polispec
  module Proof
    module Adapters
      class Local
        KILL_GRACE = 5

        def initialize
          @runs = {}
        end

        def submit(request)
          id = "run_#{SecureRandom.hex(6)}"
          @runs[id] = { status: "running", records: [] }
          begin
            @runs[id][:records] = execute(request)
            @runs[id][:status] = "done"
          rescue StandardError
            @runs[id][:status] = "failed"
            raise
          end
          id
        end

        def status(id)
          fetch_run(id)[:status]
        end

        def fetch(id)
          fetch_run(id)[:records]
        end

        private

        def fetch_run(id)
          @runs.fetch(id) { raise Polispec::Error, "run_unknown: no run #{id}" }
        end

        def execute(request)
          root = request[:root]
          key = Signer.key_path
          raise Polispec::Error, "key_missing: no producer key at #{key}; run polispec proof keygen" unless File.file?(key)

          manifest = Manifest.at(root, "HEAD")
          raise Polispec::Error, "manifest_missing: #{MANIFEST_PATH} is not committed at HEAD" unless manifest

          target = manifest.target(request[:target])
          raise Polispec::Error, "target_unmatched: no target #{request[:target]} in #{MANIFEST_PATH}" unless target

          commit = head_commit(root)
          FileUtils.mkdir_p(request[:out_dir], mode: 0o700)
          request[:features].map { |id| run_feature(root, manifest, manifest.feature(id), target, commit, request[:out_dir]) }
        end

        def head_commit(root)
          out, err, status = Trace.capture3("git", "-C", root, "rev-parse", "--verify", "HEAD^{commit}", trace: :silent)
          raise Polispec::Error, "no_commits: #{err.to_s.strip}" unless status.success?

          out.strip
        end

        def run_feature(root, manifest, feature, target, commit, out_dir)
          smoke = manifest.smoke_for(feature, target["id"])
          digest = Digest.cell(root, "HEAD", manifest, feature, target)
          log = File.join(out_dir, "#{feature['id']}.#{target['id']}.log")
          started = Time.now.utc
          began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          code, timed_out = launch(Array(smoke["run"]).map(&:to_s), root, log, smoke["timeout_s"].to_i)
          ended = Time.now.utc
          elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - began) * 1000).round
          verdict = timed_out ? "blocked" : (code == 0 ? "pass" : "fail")
          Signer.sign_record(
            "feature" => feature["id"], "target" => target["id"], "digest" => digest, "commit" => commit,
            "rung" => smoke["rung"], "verdict" => verdict, "started_at" => started.iso8601, "finished_at" => ended.iso8601,
            "duration_ms" => elapsed, "exit" => timed_out ? nil : code, "evidence" => [evidence(log)], "runtime" => Smoke.runtime
          )
        end

        def evidence(log)
          bytes = File.binread(log)
          { "name" => File.basename(log), "sha256" => Canonical.sha256(bytes), "bytes" => bytes.bytesize }
        end

        def launch(argv, root, log, timeout)
          Trace.command(argv, chdir: root)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          code = nil
          timed_out = false
          File.open(log, "wb") do |sink|
            Open3.popen2e(*argv, chdir: root, pgroup: true) do |stdin, out, waiter|
              stdin.close
              pump = Thread.new { IO.copy_stream(out, sink) }
              if waiter.join(timeout)
                code = waiter.value.exitstatus
              else
                timed_out = true
                begin
                  Process.kill("KILL", -waiter.pid)
                rescue SystemCallError
                  nil
                end
                waiter.join
              end
              pump.kill unless pump.join(KILL_GRACE)
            end
          rescue SystemCallError => e
            sink.write("could not start #{argv.first}: #{e.message}\n")
          end
          Trace.exit_line(code || -1, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000, timed_out: timed_out)
          [code, timed_out]
        end
      end
    end
  end
end
