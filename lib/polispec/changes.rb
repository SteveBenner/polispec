#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "etc"
require_relative "chain"
require_relative "effect"

module Polispec
  module Changes
    SCHEMA = "polispec.change/v1"
    PREFIX = "chg_"
    KINDS = %w[promote apply exceptions.add exceptions.promote exceptions.remove settings.set pin install register].freeze

    module_function

    def chain
      Chain.new(dir: State.home, file: "changes.jsonl", head: "changes.head.json", lock: "changes.lock", prefix: PREFIX, schema: "change")
    end

    def epoch
      Effect.epoch
    rescue StandardError
      nil
    end

    def actor
      explicit = ENV["POLISPEC_ACTOR"].to_s.strip
      return explicit unless explicit.empty?

      via = Delegate.via if defined?(Delegate) && Delegate.respond_to?(:via)
      return via.to_s unless via.to_s.empty?

      Etc.getpwuid(Process.uid).name
    rescue StandardError
      "unknown"
    end

    def record(kind:, subject:, epoch_before:, details: {}, actor: nil, effects: nil)
      Layers.reset!
      Exceptions.reset! if defined?(Exceptions) && Exceptions.respond_to?(:reset!)
      context = details.is_a?(Hash) && details["runtime_dir"] ? { runtime: Effect.release_material(details["runtime_dir"]) } : {}
      body = {
        "schema" => SCHEMA, "ts" => Time.now.utc.iso8601(3), "kind" => kind, "actor" => actor || self.actor, "subject" => subject,
        "epoch_before" => epoch_before, "epoch_after" => Effect.epoch(nil, context), "effects" => effects || Effect.classes(kind, details)
      }
      chain.append(body)
    rescue StandardError, ScriptError => error
      unrecorded(error)
    end

    def unrecorded(error)
      Events.emit("polispec.finding", project: nil, kind: "change_unrecorded", detail: "#{error.class}: #{error.message.to_s[0, 200]}", policy_source: nil)
      nil
    rescue StandardError
      nil
    end

    def records
      chain.records
    end

    def find(id)
      chain.find(id)
    end

    def latest_after(epoch)
      list = records
      return list.last if epoch.nil?

      index = list.rindex { |entry| entry["epoch_after"] == epoch }
      return list.last unless index
      list[(index + 1)..].to_a.last
    end

    def newest_for(epoch)
      records.reverse.find { |entry| entry["epoch_after"] == epoch }
    end
  end
end
