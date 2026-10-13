#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "etc"
require "socket"
require "timeout"

module Polispec
  module HarnessControls
    module Environment
      STREAM = "harness_scans".freeze
      PROBE_TIMEOUT = 2
      OUTPUT_LIMIT = 16 * 1024
      ROOTFUL_DOCKER_SOCKETS = ["/var/run/docker.sock", "/run/docker.sock"].freeze
      LXD_SOCKETS = ["/var/snap/lxd/common/lxd/unix.socket", "/var/lib/lxd/unix.socket", "/var/lib/incus/unix.socket"].freeze

      class LocalProbe
        def groups
          ([Process.gid] + Process.groups).uniq.map do |gid|
            Etc.getgrgid(gid).name
          rescue ArgumentError
            nil
          end.compact.uniq.sort
        end

        def euid
          Process.euid
        end

        def executable(name)
          ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
            path = File.join(directory, name)
            File.file?(path) && File.executable?(path)
          end
        end

        def socket(path)
          return "absent" unless File.socket?(path)

          Timeout.timeout(0.5) do
            client = UNIXSocket.new(path)
            client.close
          end
          "reachable"
        rescue Errno::EACCES, Errno::EPERM
          "denied"
        rescue StandardError
          "unreachable"
        end

        def run(argv)
          stdin, stdout_io, stderr_io, waiter = Open3.popen3(*argv, pgroup: true)
          stdin.close
          stdout_reader = bounded_reader(stdout_io)
          stderr_reader = bounded_reader(stderr_io)
          unless waiter.join(PROBE_TIMEOUT)
            terminate(waiter)
            stdout_reader.join(0.5)
            stderr_reader.join(0.5)
            return { "status" => "timeout", "exit_status" => nil, "stdout" => stdout_reader[:content].to_s, "stderr" => stderr_reader[:content].to_s }
          end
          stdout_reader.join(0.5)
          stderr_reader.join(0.5)
          status = waiter.value
          {
            "status" => status.success? ? "success" : "failed",
            "exit_status" => status.exitstatus,
            "stdout" => stdout_reader[:content].to_s,
            "stderr" => stderr_reader[:content].to_s
          }
        rescue SystemCallError
          { "status" => "unavailable", "exit_status" => nil, "stdout" => "", "stderr" => "" }
        ensure
          [stdout_io, stderr_io].compact.each { |io| io.close unless io.closed? }
        end

        def bounded_reader(io)
          Thread.new do
            content = +""
            loop do
              chunk = io.readpartial(4096)
              remaining = OUTPUT_LIMIT - content.bytesize
              content << chunk.byteslice(0, remaining) if remaining.positive?
            end
          rescue EOFError, IOError
            Thread.current[:content] = content
          end
        end

        def terminate(waiter)
          Process.kill("TERM", -waiter.pid)
          return if waiter.join(0.2)

          Process.kill("KILL", -waiter.pid)
          waiter.join(0.2)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
      end

      module_function

      def scan(context)
        scan_with(context, probe: LocalProbe.new, ports: port_set, development: false)
      rescue StandardError => error
        failure_result(context, error)
      end

      def scan_with(context, probe:, ports:, development:)
        values = stringify(context)
        read_only = values["read_only"] == true
        observations = observations(probe)
        exposure_fingerprint = Digest::SHA256.hexdigest(JSON.generate(observations))
        state = ports && ports.state
        history = state ? state.read(STREAM) : []
        history = [] unless history.is_a?(Array)
        previous = history.reverse.find { |item| item.is_a?(Hash) }
        sequence = previous ? previous.fetch("sequence", 0).to_i + 1 : 1
        continuing = continuing_exposure?(previous, observations)
        continuing_transition = continuing && !read_only
        previously_armed = previous && previous["root_guard"] == true
        requested_lock = values["edition"].to_s == "lock" || values["requested_edition"].to_s == "lock"
        root_guard = previously_armed == true || requested_lock || continuing_transition
        unknown = observations.values.any? { |item| item["status"] == "unknown" || item["access"] == "unknown" }
        root_equivalent = observations.values.any? { |item| item["root_equivalent"] == true }
        potential_root_equivalent = observations.values.any? { |item| item["potential_root_equivalent"] == true }
        lock_eligible = !root_equivalent && !potential_root_equivalent && !unknown && !development && !state.nil?
        findings = build_findings(observations, continuing_transition, requested_lock, lock_eligible, development)

        result = {
          "exposures" => observations,
          "sequence" => read_only ? (previous && previous["sequence"]) : sequence,
          "root_guard" => root_guard,
          "lock_eligible" => lock_eligible,
          "findings" => findings
        }
        return result if read_only

        unless state
          result["sequence"] = nil
          result["findings"] << finding("state_unavailable", "The rplugin state port is unavailable; this scan was not recorded.", "Restore the required state port and scan again.")
          return result
        end

        record = {
          "sequence" => sequence,
          "fingerprint" => exposure_fingerprint,
          "detected" => detected_categories(observations),
          "root_guard" => root_guard,
          "lock_eligible" => lock_eligible,
          "scanned_at" => Time.now.utc.iso8601
        }
        state.append(STREAM, record)
        emit_notices(ports, findings) unless development
        result
      rescue StandardError => error
        failure_result(context, error)
      end
      private_class_method :scan_with

      def observations(probe)
        groups = probe.groups
        docker = docker_observation(probe, groups)
        lxd = lxd_observation(probe, groups)
        privilege = privilege_observation(probe)
        identity = {
          "status" => probe.euid == 0 ? "detected" : "clear",
          "presence" => probe.euid == 0,
          "access" => probe.euid == 0 ? "reachable" : "unreachable",
          "rootless" => false,
          "root_equivalent" => probe.euid == 0,
          "potential_root_equivalent" => false,
          "evidence" => probe.euid == 0 ? ["effective_uid_root"] : ["effective_uid_unprivileged"]
        }
        { "effective_identity" => identity, "docker" => docker, "lxd_incus" => lxd, "privilege_path" => privilege }
      end
      private_class_method :observations

      def docker_observation(probe, groups)
        installed = probe.executable("docker")
        rootful = socket_summary(probe, ROOTFUL_DOCKER_SOCKETS)
        rootless_path = "/run/user/#{probe.euid}/docker.sock"
        rootless_socket = probe.socket(rootless_path)
        info = installed ? probe.run(["docker", "info", "--format", "{{json .SecurityOptions}}"] ) : nil
        context = installed ? probe.run(["docker", "context", "inspect", "--format", "{{json .Endpoints.docker.Host}}"] ) : nil
        rootless_info = info && info["status"] == "success" && info["stdout"].downcase.include?("rootless")
        context_host = context && context["status"] == "success" ? context["stdout"].strip.delete_prefix('"').delete_suffix('"') : ""
        rootless_context = context_host.start_with?("unix:///run/user/")
        rootless = rootless_socket == "reachable" || rootless_info == true || rootless_context
        daemon_reachable = info && info["status"] == "success"
        reachable_rootful = rootful["access"] == "reachable" || (daemon_reachable && !rootless)
        group_authority = groups.include?("docker")
        evidence = []
        evidence << "docker_group" if groups.include?("docker")
        evidence << "rootful_socket_#{rootful['access']}" unless rootful["access"] == "absent"
        evidence << "rootless_socket_#{rootless_socket}" unless rootless_socket == "absent"
        evidence << "docker_cli_#{info['status']}" if info
        evidence << "docker_context_#{context['status']}" if context
        evidence << "active_context_rootless" if rootless_context
        {
          "status" => installed || rootful["presence"] || rootless_socket != "absent" || groups.include?("docker") ? "detected" : "unknown",
          "presence" => installed || rootful["presence"] || rootless_socket != "absent" || groups.include?("docker"),
          "access" => reachable_rootful || rootless ? "reachable" : (installed ? "unreachable" : "unknown"),
          "rootless" => rootless,
          "root_equivalent" => reachable_rootful,
          "potential_root_equivalent" => group_authority && !reachable_rootful,
          "evidence" => evidence.empty? ? ["docker_scanner_unavailable"] : evidence
        }
      end
      private_class_method :docker_observation

      def lxd_observation(probe, groups)
        scanners = %w[lxc incus].select { |name| probe.executable(name) }
        sockets = socket_summary(probe, LXD_SOCKETS)
        group_access = !(groups & %w[lxd incus]).empty?
        reachable = sockets["access"] == "reachable"
        evidence = (groups & %w[lxd incus]).map { |name| "#{name}_group" }
        evidence << "daemon_socket_#{sockets['access']}" unless sockets["access"] == "absent"
        scanners.each { |name| evidence << "#{name}_cli_present" }
        {
          "status" => scanners.empty? && !sockets["presence"] && !group_access ? "unknown" : "detected",
          "presence" => !scanners.empty? || sockets["presence"] || group_access,
          "access" => reachable ? "reachable" : (scanners.empty? ? "unknown" : "unreachable"),
          "rootless" => false,
          "root_equivalent" => reachable,
          "potential_root_equivalent" => group_access && !reachable,
          "evidence" => evidence.empty? ? ["lxd_incus_scanner_unavailable"] : evidence
        }
      end
      private_class_method :lxd_observation

      def privilege_observation(probe)
        unless probe.executable("sudo")
          return { "status" => "unknown", "presence" => false, "access" => "unknown", "rootless" => false, "root_equivalent" => false, "potential_root_equivalent" => false, "evidence" => ["sudo_scanner_unavailable"] }
        end

        result = probe.run(["sudo", "-n", "true"])
        if %w[timeout unavailable].include?(result["status"])
          return { "status" => "unknown", "presence" => true, "access" => "unknown", "rootless" => false, "root_equivalent" => false, "potential_root_equivalent" => false, "evidence" => ["sudo_probe_#{result['status']}"] }
        end
        reachable = result["status"] == "success"
        {
          "status" => "detected",
          "presence" => true,
          "access" => reachable ? "reachable" : "denied",
          "rootless" => false,
          "root_equivalent" => reachable,
          "potential_root_equivalent" => false,
          "evidence" => [reachable ? "noninteractive_sudo_reachable" : "sudo_present_not_noninteractive"]
        }
      end
      private_class_method :privilege_observation

      def socket_summary(probe, paths)
        results = paths.map { |path| [path, probe.socket(path)] }
        access = if results.any? { |_, value| value == "reachable" }
                   "reachable"
                 elsif results.any? { |_, value| value == "denied" }
                   "denied"
                 elsif results.any? { |_, value| value == "unreachable" }
                   "unreachable"
                 else
                   "absent"
                 end
        { "presence" => access != "absent", "access" => access }
      end
      private_class_method :socket_summary

      def detected_categories(observations)
        observations.select do |_, item|
          item["root_equivalent"] == true || item["potential_root_equivalent"] == true || item["rootless"] == true
        end.keys.sort
      end
      private_class_method :detected_categories

      def continuing_exposure?(previous, observations)
        return false unless previous

        prior = Array(previous["detected"])
        current = detected_categories(observations)
        !(prior & current).empty?
      end
      private_class_method :continuing_exposure?

      def build_findings(observations, continuing, requested_lock, lock_eligible, development)
        findings = []
        root_equivalent = observations.select { |_, item| item["root_equivalent"] == true }.keys
        potential_root_equivalent = observations.select { |_, item| item["potential_root_equivalent"] == true }.keys
        rootless = observations.select { |_, item| item["rootless"] == true }.keys
        unknown = observations.select { |_, item| item["status"] == "unknown" || item["access"] == "unknown" }.keys
        unless root_equivalent.empty?
          findings << finding("root_equivalent_access", "Root-equivalent access is reachable through #{root_equivalent.join(', ')}.", "Remove the reachable privilege path before lock certification.")
        end
        unless rootless.empty?
          findings << finding("rootless_container_access", "Rootless container access is reachable through #{rootless.join(', ')}.", "Review the rootless container boundary; it is not classified as host-root authority.")
        end
        unless potential_root_equivalent.empty?
          findings << finding("potential_root_equivalent_access", "Group authority may permit root-equivalent access through #{potential_root_equivalent.join(', ')}.", "Remove the risky group authority or restore a conclusive bounded access probe.")
        end
        unless unknown.empty?
          findings << finding("exposure_unknown", "Exposure status is unknown for #{unknown.join(', ')}.", "Install or restore the bounded scanner and repeat the scan.")
        end
        if continuing
          findings << finding("root_guard_armed", "A continuing exposure was observed in a distinct follow-up scan; root_guard is armed.", "Remediate the exposure and have the operator review the armed guard.")
        elsif detected_categories(observations).any?
          findings << finding("exposure_advisory", "An exposure was observed; this first recorded scan advises remediation.", "Remediate the exposure and run a distinct follow-up scan.")
        end
        if requested_lock && !lock_eligible
          findings << finding("lock_environment_ineligible", "The requested lock environment has root-equivalent or unknown prerequisites.", "Resolve every exposure finding before requesting lock certification.")
        end
        if development
          findings << finding("development_probe", "This result uses an internal development probe and cannot establish lock eligibility.", "Use bounded host probes for certification evidence.")
        end
        findings
      end
      private_class_method :build_findings

      def finding(code, detail, next_step)
        { "code" => code, "detail" => detail, "control_id" => nil, "harness" => nil, "capability" => "environment_scan", "next_step" => next_step }
      end
      private_class_method :finding

      def emit_notices(ports, findings)
        return unless ports.respond_to?(:events)

        findings.select { |item| %w[exposure_advisory root_guard_armed].include?(item["code"]) }.each do |item|
          ports.events.emit("polispec.finding", { "project" => nil, "kind" => item["code"], "detail" => item["detail"], "policy_source" => "harness_environment" })
        end
      rescue StandardError
        nil
      end
      private_class_method :emit_notices

      def port_set
        load_sdk
        return nil unless defined?(::Rplugin::Ports)

        ::Rplugin::Ports.for(ID, root: ROOT)
      rescue StandardError, LoadError
        nil
      end
      private_class_method :port_set

      def load_sdk
        return true if defined?(::Rplugin::Ports)

        home = ENV["RPLUGIN_HOME"]
        home = File.expand_path(home && !home.empty? ? home : "~/.rplugin")
        entry = File.join(home, "lib", "rplugin.rb")
        return false unless File.file?(entry)

        require entry
        true
      end
      private_class_method :load_sdk

      def stringify(value)
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) { |(key, item), memo| memo[key.to_s] = item }
      end
      private_class_method :stringify

      def failure_result(context, error)
        values = stringify(context)
        {
          "exposures" => {},
          "sequence" => nil,
          "root_guard" => values["edition"].to_s == "lock" || values["requested_edition"].to_s == "lock",
          "lock_eligible" => false,
          "findings" => [finding("environment_scan_failed", "The bounded environment scan failed: #{error.class}.", "Restore the scanner prerequisites and repeat the scan.")]
        }
      end
      private_class_method :failure_result
    end
  end
end
