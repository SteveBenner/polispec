#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "fileutils"

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
      File.write(tmp, ([ledger.digest.to_s] + needles(ledger)).join("\n") + "\n")
      File.rename(tmp, path)
    rescue SystemCallError
      nil
    end

    def stale?(ledger)
      return true unless File.file?(path)
      return true if ledger.path && File.file?(ledger.path) && File.mtime(ledger.path) > File.mtime(path)

      File.open(path, &:gets).to_s.chomp != ledger.digest.to_s
    end

    def needles(ledger)
      root = File.expand_path(ledger.envs_root)
      live = ledger.projects.select { |project| project.status == "live" }
      return [] if live.empty?

      list = [root, File.join(File.basename(File.dirname(root)), File.basename(root))]
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
