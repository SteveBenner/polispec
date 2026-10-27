#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "json"
require "time"
require_relative "judgments"

module Polispec
  module GuardHealth
    LAUNCHER = "launcher"
    WINDOW_BYTES = 262_144
    FILES = 2
    ERROR_CHARS = 160

    module_function

    def status
      ordered = (judged + denied).sort_by { |event| event[:at] }
      last_ok = ordered.reverse.find { |event| event[:ok] }
      bad = ordered.reject { |event| event[:ok] || (last_ok && event[:at] <= last_ok[:at]) }
      return nil if bad.empty?

      { "since" => bad.first[:ts], "error" => bad.last[:error], "last_ok" => last_ok && last_ok[:ts] }
    end

    def line
      current = status
      current ? "guard failing since #{current['since']}: #{current['error'].to_s[0, ERROR_CHARS]}" : nil
    rescue SystemCallError, Polispec::Error, TypeError, ArgumentError, NoMethodError
      nil
    end

    def judged
      Judgments.files.last(FILES).flat_map { |file| tail_rows(file) }.filter_map do |row|
        stamp = parse(row["ts"])
        next unless stamp

        outcome = row["outcome"].is_a?(Hash) ? row["outcome"] : {}
        internal = outcome["rule_id"] == Judgments::INTERNAL_RULE && outcome["verdict"] == "deny"
        { at: stamp, ts: row["ts"], ok: !internal && outcome["error"].nil?, error: outcome["error"] || "unrecorded error" }
      end
    end

    def denied
      file = State.log_path(LAUNCHER)
      return [] unless File.file?(file)

      tail_rows(file).filter_map do |row|
        next unless row["decision"] == "deny" && row["mode"] == "pretool"

        stamp = parse(row["ts"])
        stamp && { at: stamp, ts: row["ts"], ok: false, error: "launcher denied the call (#{row['cause'] || 'unknown cause'})" }
      end
    end

    def tail_rows(file)
      size = File.size(file)
      return [] if size.zero?

      chunk = File.open(file, "rb") do |handle|
        handle.seek([size - WINDOW_BYTES, 0].max)
        handle.read
      end
      lines = chunk.force_encoding("UTF-8").scrub.split("\n")
      lines.shift if size > WINDOW_BYTES
      lines.filter_map { |text| State.parse_line(text) }
    rescue SystemCallError
      []
    end

    def parse(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
