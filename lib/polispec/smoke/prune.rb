#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "fileutils"
require "tmpdir"

module Polispec
  module Smoke
    module Prune
      ROOT_NAME = "polispec-smoke"
      RUN_NAME = /\A\d{8}T\d{6}Z-[0-9a-f]{6}\z/.freeze
      MAX_AGE = 24 * 60 * 60

      module_function

      def root
        File.join(Dir.tmpdir, ROOT_NAME)
      end

      def stale(base, current: nil, now: Time.now)
        return [] unless real_directory?(base)

        keep = current && File.expand_path(current)
        Dir.children(base).sort.filter_map do |name|
          next unless RUN_NAME.match?(name)

          path = File.join(base, name)
          next if keep && File.expand_path(path) == keep

          info = File.lstat(path)
          next unless info.directory? && !info.symlink? && now - info.mtime > MAX_AGE

          path
        rescue SystemCallError
          nil
        end
      end

      def run(base: root, current: nil)
        removed = stale(base, current: current).select do |path|
          Polispec::Trace.step("prune old run", path: Polispec::Trace.on? ? Polispec::Trace.path(path) : nil) { FileUtils.rm_rf(path, secure: true) }
          !File.exist?(path)
        end
        Polispec::Trace.info("pruned old runs", base: Polispec::Trace.path(base), count: removed.length) if Polispec::Trace.on?
        removed
      rescue SystemCallError => e
        Polispec::Trace.info("prune failed", reason: e.message) if Polispec::Trace.on?
        []
      end

      def real_directory?(path)
        info = File.lstat(path)
        info.directory? && !info.symlink?
      rescue SystemCallError
        false
      end

      def size(path)
        info = File.lstat(path)
        return info.size unless info.directory?

        Dir.children(path).sum { |name| size(File.join(path, name)) } + info.size
      rescue SystemCallError
        0
      end

      def human(bytes)
        units = %w[B KiB MiB GiB]
        value = bytes.to_f
        index = 0
        while value >= 1024 && index < units.length - 1
          value /= 1024
          index += 1
        end
        index.zero? ? "#{bytes} B" : format("%.1f %s", value, units[index])
      end
    end
  end
end
