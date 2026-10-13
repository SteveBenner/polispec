#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module HarnessControls
    module Schedule
      CALENDAR_LIMIT = 256
      INSTALLATION_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/.freeze

      module_function

      def plan(document, receipt, context = {})
        validate_document!(document)
        receipt = stringify(receipt.respond_to?(:to_h) ? receipt.to_h : receipt)
        context = stringify(context)
        installation_id = receipt["installation_id"].to_s
        raise Polispec::Error, "schedule requires a valid installation_id" unless installation_id.match?(INSTALLATION_PATTERN)
        control_digest = receipt["control_digest"].to_s
        unless control_digest.match?(/\A[0-9a-f]{64}\z/) && control_digest == Digest::SHA256.hexdigest(JSON.generate(canonical_value(document)))
          raise Polispec::Error, "schedule document does not match the installation receipt control_digest"
        end

        runtime = runtime_argv(context)
        jobs = Array(document["controls"]).each_with_object([]) do |control, result|
          next unless control["trigger"] == "schedule"

          calendar = bounded_calendar!(control["calendar"])
          target = control["target_control_id"].to_s
          argv = runtime + ["harness", "verify", installation_id, "--json"]
          job_id = job_id_for(installation_id, control["id"])
          job = schedule_job(
            id: job_id,
            calendar: calendar,
            command: Shellwords.join(argv),
            description: "Verify polispec installation #{installation_id} containing #{target}"
          )
          result << {
            "job_id" => job_id,
            "target_control_id" => target,
            "argv" => argv,
            "job" => job.to_h
          }
        end
        {
          "schema" => "polispec.schedule.plan/v1",
          "installation_id" => installation_id,
          "control_digest" => control_digest,
          "jobs" => jobs,
          "findings" => []
        }
      end

      def install(document, receipt, context = {}, port_set: nil)
        schedule_plan = plan(document, receipt, context)
        ports = port_set || sdk_ports!
        rows = []
        findings = []
        schedule_plan["jobs"].each do |entry|
          job = schedule_job_from(entry["job"])
          begin
            response = ports.schedule.install(job)
            status, status_error = schedule_status(ports, job.id)
            installed = status && status["installed"] == true
            rows << entry.merge(
              "port_accepted" => true,
              "port_response" => json_value(response),
              "status" => status,
              "execution_verified" => false,
              "disposition" => installed ? "installed_unverified" : "accepted_unverified"
            )
            if status_error
              findings << finding("schedule_status_unavailable", "Schedule port accepted #{job.id}, but status inspection failed: #{status_error}", entry["target_control_id"], "Inspect the scheduler adapter and retry verification.")
            elsif !installed
              findings << finding("schedule_not_observed_installed", "Schedule port accepted #{job.id}, but status did not report an installed timer.", entry["target_control_id"], "Treat the timer as uninstalled until the adapter reports installed status.")
            end
          rescue StandardError => error
            rows << entry.merge(
              "port_accepted" => false,
              "port_response" => nil,
              "status" => nil,
              "execution_verified" => false,
              "disposition" => "failed"
            )
            findings << finding("schedule_install_failed", "Schedule port rejected #{job.id}: #{error.class}: #{error.message}", entry["target_control_id"], "Recover previously accepted job IDs from this result before retrying.")
            break
          end
        end
        schedule_plan.merge("schema" => "polispec.schedule.install/v1", "installed" => rows, "findings" => findings)
      end

      def uninstall(job_ids, port_set: nil)
        load_sdk!
        ports = port_set || sdk_ports!
        rows = []
        findings = []
        Array(job_ids).each do |job_id|
          id = job_id.to_s
          raise Polispec::Error, "invalid schedule job id #{id.inspect}" unless id.match?(Rplugin::ScheduleJob::ID_PATTERN)

          begin
            response = ports.schedule.uninstall(id)
            status, status_error = schedule_status(ports, id)
            absent = status && status["installed"] == false
            rows << {
              "job_id" => id,
              "port_accepted" => true,
              "port_response" => json_value(response),
              "status" => status,
              "absence_verified" => absent,
              "disposition" => absent ? "uninstalled" : "accepted_unverified"
            }
            if status_error
              findings << finding("schedule_status_unavailable", "Schedule port accepted uninstall for #{id}, but status inspection failed: #{status_error}", nil, "Inspect the scheduler adapter before completing rollback.")
            elsif !absent
              findings << finding("schedule_uninstall_unverified", "Schedule port accepted uninstall for #{id}, but absence was not verified.", nil, "Keep rollback incomplete until status reports the timer absent.")
            end
          rescue StandardError => error
            rows << { "job_id" => id, "port_accepted" => false, "port_response" => nil, "status" => nil, "absence_verified" => false, "disposition" => "failed" }
            findings << finding("schedule_uninstall_failed", "Schedule port rejected uninstall for #{id}: #{error.class}: #{error.message}", nil, "Retain the job ID for authenticated recovery.")
          end
        end
        { "schema" => "polispec.schedule.uninstall/v1", "uninstalled" => rows, "findings" => findings }
      end

      def validate_document!(document)
        raise Polispec::Error, "control document must be a JSON object" unless document.is_a?(Hash)
        errors = Polispec::Controls.validate(document)
        return if errors.empty?

        first = errors.first
        raise Polispec::Error, "invalid control document at #{first['pointer']}: #{first['message']}"
      end
      private_class_method :validate_document!

      def runtime_argv(context)
        runtime = context["runtime_argv"]
        if runtime
          valid = runtime.is_a?(Array) && !runtime.empty? && runtime.all? { |item| item.is_a?(String) && !item.empty? && !item.include?("\0") } && absolute_path?(runtime.first)
          raise Polispec::Error, "runtime_argv must be a nonempty absolute-executable argv prefix" unless valid

          return runtime.dup
        end

        path = context["runtime_path"].to_s
        path = File.join(ROOT, "bin", "polispec") if path.empty? && context["scope"].to_s != "managed"
        raise Polispec::Error, "schedule requires a verified absolute runtime argv" if path.empty?
        raise Polispec::Error, "runtime_path must be absolute" unless absolute_path?(path)

        [path]
      end
      private_class_method :runtime_argv

      def bounded_calendar!(value)
        calendar = value.to_s
        valid = !calendar.empty? && calendar.bytesize <= CALENDAR_LIMIT && !calendar.match?(/[\0\r\n]/)
        raise Polispec::Error, "schedule calendar must be a bounded single-line OnCalendar expression" unless valid

        calendar
      end
      private_class_method :bounded_calendar!

      def job_id_for(installation_id, control_id)
        "polispec-#{Digest::SHA256.hexdigest("#{installation_id}\0#{control_id}")[0, 24]}"
      end
      private_class_method :job_id_for

      def schedule_job(id:, calendar:, command:, description:)
        load_sdk!
        Rplugin::ScheduleJob.new(id: id, on_calendar: calendar, command: command, description: description, kill_switch: "POLISPEC_SCHEDULE_DISABLED")
      end
      private_class_method :schedule_job

      def schedule_job_from(data)
        load_sdk!
        Rplugin::ScheduleJob.from_h(data)
      end
      private_class_method :schedule_job_from

      def schedule_status(ports, job_id)
        [json_value(ports.schedule.status(job_id)), nil]
      rescue StandardError => error
        [nil, "#{error.class}: #{error.message}"]
      end
      private_class_method :schedule_status

      def sdk_ports!
        load_sdk!
        Rplugin::Ports.for(ID, root: ROOT)
      end
      private_class_method :sdk_ports!

      def load_sdk!
        return true if defined?(::Rplugin::Ports) && defined?(::Rplugin::ScheduleJob)

        home = ENV["RPLUGIN_HOME"]
        home = File.expand_path(home && !home.empty? ? home : "~/.rplugin")
        entry = File.join(home, "lib", "rplugin.rb")
        raise Polispec::Error, "rplugin SDK is unavailable" unless File.file?(entry)

        require entry
        raise Polispec::Error, "rplugin schedule port is unavailable" unless defined?(::Rplugin::Ports) && defined?(::Rplugin::ScheduleJob)

        true
      rescue LoadError => error
        raise Polispec::Error, "rplugin SDK is unavailable: #{error.message}"
      end
      private_class_method :load_sdk!

      def finding(code, detail, control_id, next_step)
        { "code" => code, "detail" => detail, "control_id" => control_id, "harness" => "os", "capability" => "schedule", "next_step" => next_step }
      end
      private_class_method :finding

      def stringify(value)
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
      end
      private_class_method :stringify

      def json_value(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), result| result[key.to_s] = json_value(item) }
        when Array
          value.map { |item| json_value(item) }
        when String, Numeric, TrueClass, FalseClass, NilClass
          value
        else
          value.to_s
        end
      end
      private_class_method :json_value

      def canonical_value(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
            source = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
            result[key] = canonical_value(value[source])
          end
        when Array
          value.map { |item| canonical_value(item) }
        else
          value
        end
      end
      private_class_method :canonical_value

      def absolute_path?(path)
        path.is_a?(String) && path.start_with?(File::SEPARATOR) && !path.include?("\0")
      end
      private_class_method :absolute_path?
    end
  end
end
