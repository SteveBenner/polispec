#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Events
    FIELDS = {
      "polispec.verdict" => %w[project env action_class verdict rule_id tool harness session_id cwd policy_digest policy_source duration_ms],
      "polispec.promote" => %w[project to from_sha to_sha tag actor gates result duration_ms],
      "polispec.deploy" => %w[project env sha tag steps health pinned_behind actor result],
      "polispec.pause" => %w[project minutes reason expires_at actor],
      "polispec.allow_once" => %w[project id action_class rule_id redeemed_at consumed_by_session],
      "polispec.finding" => %w[project kind detail policy_source]
    }.freeze

    module_function

    def emit(type, fields = {})
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
      ports = port_set
      return false unless ports

      ports.events.emit(type, payload)
      true
    rescue StandardError
      false
    end

    def port_set
      return @port_set unless @port_set.nil?

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
