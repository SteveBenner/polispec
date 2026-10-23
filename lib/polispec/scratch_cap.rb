#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "fileutils"
require "json"
require "securerandom"
require_relative "predicates"
require_relative "state"

module Polispec
  module ScratchCap
    KEYS = %w[bytes_over fsize_unset fsize_above tree_over].freeze
    CACHE = "scratch-sizes.json".freeze
    FRESH = 60
    TIMEOUT = 0.8

    module_function

    def holds?(match, action, ctx)
      return true unless KEYS.any? { |key| match.key?(key) }

      hint = Predicates.hint(action)
      bytes_over?(match["bytes_over"], hint) && fsize_unset?(match["fsize_unset"], hint) && fsize_above?(match["fsize_above"], hint) && tree_over?(match["tree_over"], hint, ctx)
    end

    def bytes_over?(limit, hint)
      return true if limit.nil?

      limit.is_a?(Integer) && hint["bytes"].is_a?(Integer) && hint["bytes"] > limit
    end

    def fsize_unset?(flag, hint)
      return true if flag.nil?

      flag == true && hint["fsize_blocks"] == "unlimited"
    end

    def fsize_above?(limit, hint)
      return true if limit.nil?

      limit.is_a?(Integer) && hint["fsize_blocks"].is_a?(Integer) && hint["fsize_blocks"] * 1024 > limit
    end

    def tree_over?(spec, hint, ctx)
      return true if spec.nil?
      return false unless spec.is_a?(Hash) && spec["marker"].is_a?(String) && spec["bytes"].is_a?(Integer) && hint["path"].is_a?(String)

      root = marker_root(hint["path"], spec["marker"])
      return false unless root

      size = tree_size(root)
      if size.nil?
        Predicates.record(Predicates::Result.new(false, nil, "tree_over: #{root} could not be measured"), ctx)
        return false
      end
      size > spec["bytes"]
    end

    def marker_root(path, marker)
      dir = path
      loop do
        return dir if File.basename(dir) == marker

        parent = File.dirname(dir)
        return nil if parent == dir

        dir = parent
      end
    end

    def tree_size(dir)
      return 0 unless File.exist?(dir)

      key = cache_key(dir)
      now = Time.now.to_i
      cache = read_cache
      entry = cache[key]
      return entry["bytes"] if entry.is_a?(Hash) && entry["bytes"].is_a?(Integer) && entry["at"].is_a?(Integer) && now - entry["at"] < FRESH && now >= entry["at"]

      bytes = measure(dir)
      return nil if bytes.nil?

      cache[key] = { "bytes" => bytes, "at" => now }
      write_cache(cache)
      bytes
    end

    def cache_key(dir)
      File.realpath(dir)
    rescue SystemCallError
      File.expand_path(dir)
    end

    def measure(dir)
      Predicates.deadline_for do
        out, status, = Predicates.capture(["du", "-sb", "--", dir], timeout: TIMEOUT)
        status.success? ? Integer(out[/\A\s*(\d+)/, 1], 10) : nil
      end
    rescue StandardError
      nil
    end

    def cache_path
      File.join(State.home, CACHE)
    end

    def read_cache
      data = JSON.parse(File.read(cache_path))
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    def write_cache(cache)
      path = cache_path
      FileUtils.mkdir_p(File.dirname(path))
      temp = File.join(File.dirname(path), ".#{CACHE}.#{Process.pid}.#{SecureRandom.hex(4)}")
      File.write(temp, JSON.generate(cache))
      File.rename(temp, path)
    rescue StandardError
      nil
    ensure
      File.delete(temp) if temp && File.exist?(temp)
    end
  end
end
