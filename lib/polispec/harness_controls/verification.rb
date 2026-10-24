require "timeout"
require "tmpdir"
require_relative "../editions"

module Polispec
  module HarnessControls
    module VerificationRunner
      TIMEOUT = 60
      LIMIT = 65_536

      module_function

      def call(argv, timeout: TIMEOUT, max_output: LIMIT)
        raise Polispec::Error, "probe argv must be a bounded array" unless argv.is_a?(Array) && !argv.empty? && argv.length <= 256 && argv.all? { |item| item.is_a?(String) && !item.include?("\0") }
        Trace.command(argv)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        input, stdout_io, stderr_io, waiter = Open3.popen3(*argv, pgroup: true)
        input.close
        stdout = reader(stdout_io, max_output)
        stderr = reader(stderr_io, max_output)
        unless waiter.join([timeout.to_i, TIMEOUT].min)
          terminate(waiter)
          stdout.join(0.5)
          stderr.join(0.5)
          Trace.exit_line(-1, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000, timed_out: true) if Trace.on?
          return { "stdout" => stdout[:content].to_s, "stderr" => stderr[:content].to_s, "exit_status" => nil, "timed_out" => true, "output_complete" => false }
        end
        stdout.join(0.5)
        stderr.join(0.5)
        complete = !stdout.alive? && !stderr.alive?
        Trace.exit_line(waiter.value.exitstatus || -1, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000) if Trace.on?
        unless complete
          terminate_group(waiter.pid)
          [stdout_io, stderr_io].each { |io| io.close unless io.closed? }
          stdout.join(0.5)
          stderr.join(0.5)
        end
        { "stdout" => stdout[:content].to_s, "stderr" => stderr[:content].to_s, "exit_status" => complete ? waiter.value.exitstatus : nil, "timed_out" => !complete, "output_complete" => complete }
      rescue SystemCallError => error
        { "stdout" => "", "stderr" => "#{error.class}: #{error.message}", "exit_status" => nil, "timed_out" => false, "output_complete" => false }
      ensure
        [stdout_io, stderr_io].compact.each { |io| io.close unless io.closed? }
      end

      def reader(io, limit)
        Thread.new do
          content = +""
          loop do
            chunk = io.readpartial(4096)
            remaining = limit - content.bytesize
            content << chunk.byteslice(0, remaining) if remaining.positive?
          end
        rescue EOFError, IOError
          Thread.current[:content] = content
        end
      end
      private_class_method :reader

      def terminate(waiter)
        Process.kill("TERM", -waiter.pid)
        return if waiter.join(0.5)
        Process.kill("KILL", -waiter.pid)
        waiter.join(0.5)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      private_class_method :terminate

      def terminate_group(pid)
        Process.kill("TERM", -pid)
        sleep(0.1)
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
      private_class_method :terminate_group
    end

    module Verifier
      module_function

      def verify(installation_id, port_set: nil, runner: nil)
        require_relative "lifecycle" unless Lifecycle.respond_to?(:receipt)
        receipt = Trace.step("read receipt", installation: installation_id) { Lifecycle.receipt(installation_id, port_set: port_set) }
        raise Lifecycle::Failure.new("installation_not_found", "installation #{installation_id} was not found") unless receipt
        files = Trace.step("check artifacts", harness: receipt["harness"]) do
          checked = Files.verify_receipt(receipt)
          Trace.info("artifact check", integrity: checked["integrity"], ownership: checked["ownership"], findings: Array(checked["findings"]).length)
          checked
        end
        backend = Backends.fetch(receipt["harness"])
        probe_context = receipt.merge("probe_root" => probe_root(receipt))
        probes = Trace.step("native probes", harness: receipt["harness"]) do
          rows = Array(backend.probe(probe_context, runner || VerificationRunner.method(:call))).map { |row| stringify(row) }
          rows.each { |row| Trace.info("probe", axis: row["axis"], status: row["status"]) } if Trace.on?
          rows
        end
        plane = Trace.step("resolve plane") { resolve_plane }
        environment = Trace.step("scan environment") { Environment.scan({ "read_only" => true, "requested_edition" => receipt["edition"] }) }
        findings = Array(files["findings"])
        findings.concat(Array(receipt["plan_findings"]))
        findings.concat(probe_findings(probes, receipt["harness"]))
        findings.concat(Array(plane["findings"]))
        findings.concat(Array(environment["findings"]))
        plane_ok = plane["status"] == "active" && plane["generation"].to_s == receipt.dig("plane", "generation").to_s && !plane["generation"].to_s.empty?
        native_ok = !probes.empty? && probes.all? { |row| row["status"] == "supported" }
        capability_ok = Array(receipt["capabilities"]).all? { |row| %w[supported generated].include?(row["disposition"]) }
        certified = receipt["protected"] == true && files["integrity"] && files["ownership"] && plane_ok && native_ok && capability_ok && environment["lock_eligible"] == true
        requested = receipt["edition"]
        effective = Editions.lock?(requested) && !certified ? "standard" : requested
        if Editions.lock?(requested) && !certified
          findings << finding("lock_inactive", "Lock was requested but required protected and native evidence is incomplete; standard enforcement remains active and root_guard is forced.", receipt["harness"], "lock", "Resolve every unavailable or unverified axis and verify again.")
        end
        {
          "schema" => "polispec.harness.verification/v1", "installation_id" => installation_id,
          "actual_version" => installed_version(receipt["harness"]),
          "integrity" => files["integrity"], "ownership" => files["ownership"], "probes" => probes,
          "requested_edition" => requested, "effective_edition" => effective,
          "root_guard" => environment["root_guard"] == true || !Editions.allowed?("root_guard.optional", requested),
          "plane" => { "status" => plane["status"], "generation" => plane["generation"] },
          "certified" => certified, "findings" => findings, "checked_at" => Time.now.utc.iso8601
        }
      end

      def probe_root(receipt)
        return nil unless receipt["harness"] == "os"
        root = Dir.mktmpdir("polispec-harness-verify-")
        FileUtils.mkdir_p(File.join(root, "outside"), mode: 0o700)
        root
      end
      private_class_method :probe_root

      def probe_findings(probes, harness)
        probes.each_with_object([]) do |row, result|
          next if row["status"] == "supported"
          result << finding("native_axis_#{row['status']}", "#{row['axis']}: #{row['detail']}", harness, row["axis"], "Obtain bounded evidence from the installed native runtime before certification.")
        end
      end
      private_class_method :probe_findings

      def resolve_plane
        path = File.join(LIB, "harness_controls", "plane.rb")
        require path if File.file?(path)
        return stringify(Plane.resolve) if Plane.respond_to?(:resolve)
        { "status" => "unsealed", "findings" => [finding("plane_api_unavailable", "Protected plane verification is unavailable.", nil, "plane", "Install and verify the plane implementation.")] }
      rescue StandardError => error
        { "status" => "broken", "findings" => [finding("plane_resolution_failed", "#{error.class}: #{error.message}", nil, "plane", "Repair the protected plane before certification.")] }
      end
      private_class_method :resolve_plane

      def installed_version(harness)
        executable = { "claude-code" => "claude", "codex" => "codex", "hermes" => "hermes", "antigravity" => "agy", "os" => "bwrap" }[harness]
        path = executable_path(executable)
        return nil unless path
        result = VerificationRunner.call([path, "--version"], timeout: 5, max_output: 65_536)
        return nil unless result["exit_status"] == 0
        "#{result['stdout']}\n#{result['stderr']}"[/\d+(?:\.\d+){1,3}/]
      end
      private_class_method :installed_version

      def executable_path(name)
        return nil unless name
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
          path = File.join(directory, name)
          return File.realpath(path) if File.file?(path) && File.executable?(path)
        end
        nil
      rescue SystemCallError
        nil
      end
      private_class_method :executable_path

      def stringify(value)
        return {} unless value.is_a?(Hash)
        value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
      end
      private_class_method :stringify

      def finding(code, detail, harness, capability, next_step)
        { "code" => code, "detail" => detail, "control_id" => nil, "harness" => harness, "capability" => capability, "next_step" => next_step }
      end
      private_class_method :finding
    end
  end
end
