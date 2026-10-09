#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "fileutils"
require_relative "layers"
require_relative "harness/base"
require_relative "classify/tool"

module Polispec
  module Fastpath
    module_function

    def path
      File.join(State.home, "fastpath.txt")
    end

    def refresh(ledger)
      return unless stale?(ledger)

      FileUtils.mkdir_p(State.home, mode: 0o700)
      tmp = "#{path}.#{Process.pid}"
      File.write(tmp, ([key(ledger)] + needles(ledger)).join("\n") + "\n")
      File.rename(tmp, path)
    rescue SystemCallError
      nil
    end

    def stale?(ledger)
      return true unless File.file?(path)
      return true if ledger.path && File.file?(ledger.path) && File.mtime(ledger.path) > File.mtime(path)

      File.open(path, &:gets).to_s.chomp != key(ledger)
    end

    def key(ledger)
      global = Layers.fingerprint
      global.empty? ? ledger.digest.to_s : "#{ledger.digest}+#{global}"
    end

    def tool_needles
      names = Harness::Base::SHELL_TOOLS + Harness::Base::EDIT_TOOLS + Harness::Base::WRITE_TOOLS + Harness::Base::PATCH_TOOLS + Classify::Tool::WRITE_TOOLS + Classify::Tool::PATCH_TOOLS
      names.map { |name| "\"#{name}\"" }
    end

    def needles(ledger)
      root = File.expand_path(ledger.envs_root)
      live = ledger.projects.select { |project| project.status == "live" }
      baseline = Layers.baseline?
      return [] if live.empty? && !baseline

      list = [root, File.join(File.basename(File.dirname(root)), File.basename(root))]
      list.concat(tool_needles) if baseline
      live.each do |project|
        list << project.id << File.basename(project.repo.to_s)
        list.concat(roots(project.repo))
        list.concat(Array(project.worktree_globs).map { |glob| File.expand_path(glob).split("*").first.to_s })
      end
      list.map { |needle| needle.to_s.downcase }.reject(&:empty?).uniq
    end

    def roots(repo)
      expanded = File.expand_path(repo.to_s)
      real = File.exist?(expanded) ? File.realpath(expanded) : nil
      [expanded, real].compact.uniq
    end
  end
end
