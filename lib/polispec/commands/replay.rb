#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "json"
require_relative "../replay"

module Polispec
  class ReplayCommand
    USAGE = "usage: polispec replay --runtime <tree> [--days N] [--json]"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      options = parse(args)
      return usage unless options

      result = Replay.run(runtime: options[:runtime], days: options[:days])
      options[:json] ? puts(JSON.generate(result.to_h)) : Replay.render(result)
      result.unexplained.empty? ? 0 : 1
    rescue Replay::Unavailable => e
      warn "polispec replay: #{e.message}"
      2
    end

    private

    def parse(args)
      options = { runtime: nil, days: Replay::DEFAULT_DAYS, json: false }
      queue = args.dup
      until queue.empty?
        arg = queue.shift
        name, inline = arg.start_with?("--") ? arg.split("=", 2) : [arg, nil]
        case name
        when "--json"
          return nil unless inline.nil?

          options[:json] = true
        when "--runtime"
          value = inline || queue.shift
          return nil if value.to_s.empty? || options[:runtime]

          options[:runtime] = value
        when "--days"
          value = inline || queue.shift
          return nil unless value.to_s.match?(/\A[1-9][0-9]{0,3}\z/)

          options[:days] = value.to_i
        else return nil
        end
      end
      options[:runtime] ? options : nil
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("replay", Polispec::ReplayCommand, summary: "replay the recorded judgment corpus through a candidate runtime tree and list every verdict that changes, explained or not by its changelog")
