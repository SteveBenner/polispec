#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Events
    FIELDS = {
      "polispec.judgment" => %w[schema id ts action targets control engine outcome prev digest],
      "polispec.promote" => %w[project to from_sha to_sha tag actor gates waived result duration_ms via],
      "polispec.deploy" => %w[project env sha tag steps health pinned_behind actor result via],
      "polispec.pause" => %w[project minutes reason expires_at actor],
      "polispec.allow_once" => %w[project id action_class rule_id redeemed_at consumed_by_session],
      "polispec.finding" => %w[project kind detail policy_source],
      "polispec.delegate" => %w[app run_id by argv result exit_code duration_ms],
      "polispec.smoke" => %w[project id spec at verdict]
    }.freeze

    module_function

    def emit(type, fields = {})
      Trace.info("emit event", type: type.to_s) if Trace.on?
      payload = shape(type.to_s, fields)
      return nil if through_port(type.to_s, payload)

      State.append_jsonl("events", { "ts" => Time.now.utc.iso8601, "kind" => type.to_s, "plugin" => ID, "payload" => payload })
      nil
    rescue StandardError
      nil
    end

    def shape(type, fields)
      data = fields.each_with_object({}) { |(key, value), memo| memo[key.to_s] = value }
      allowed = FIELDS[type]
      allowed ? data.select { |key, _| allowed.include?(key) } : data
    end

    def through_port(type, payload)
      return false if State.redirected

      ports = port_set
      return false unless ports

      ports.events.emit(type, payload)
      true
    rescue StandardError
      false
    end

    def port_set
      return @port_set unless @port_set.nil?

      require_relative "harness_controls/plane"
      if defined?(HarnessControls::Plane) && HarnessControls::Plane.respond_to?(:resolve)
        plane = HarnessControls::Plane.resolve
        return @port_set = false if plane["status"] == "broken"
        return @port_set = (defined?(::Rplugin::Ports) ? ::Rplugin::Ports.for(ID, root: ROOT) : false) if plane["status"] == "active"
      end

      @port_set = load_sdk && defined?(::Rplugin::Ports) ? ::Rplugin::Ports.for(ID, root: ROOT) : false
    rescue StandardError, LoadError
      @port_set = false
    end

    def load_sdk
      return true if defined?(::Rplugin::Ports)

      home = ENV["RPLUGIN_HOME"]
      home = File.expand_path(home && !home.empty? ? home : "~/.rplugin")
      entry = File.join(home, "lib", "rplugin.rb")
      return false unless File.file?(entry)

      require entry
      true
    end
  end
end
