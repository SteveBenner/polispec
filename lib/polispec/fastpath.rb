#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "fileutils"
require_relative "layers"
require_relative "harness/base"
require_relative "classify/tool"
require_relative "classify/benign"

module Polispec
  module Fastpath
    module_function

    def path
      File.join(State.home, "fastpath.txt")
    end

    WATCH_CAP = 200

    def watch_path
      File.join(State.home, "fastpath.watch")
    end

    def tools_path
      File.join(State.home, "fastpath.tools")
    end

    def refresh(ledger, context = {})
      return unless stale?(ledger, context)

      FileUtils.mkdir_p(State.home, mode: 0o700)
      watch_tmp = "#{watch_path}.#{Process.pid}"
      File.write(watch_tmp, watched(ledger).join("\n") + "\n")
      File.rename(watch_tmp, watch_path)
      tools_tmp = "#{tools_path}.#{Process.pid}"
      File.write(tools_tmp, skippable.join("\n") + "\n")
      File.rename(tools_tmp, tools_path)
      tmp = "#{path}.#{Process.pid}"
      File.write(tmp, ([key(ledger, context)] + needles(ledger)).join("\n") + "\n")
      File.rename(tmp, path)
    rescue SystemCallError
      nil
    end

    def watched(ledger)
      list = [ledger.path.to_s]
      list.concat(global_files)
      config = ENV["XDG_CONFIG_HOME"].to_s
      config = File.join(Dir.home, ".config") if config.empty?
      list << File.join(config, "rplugin", "polispec", "settings.yml")
      list << "/etc/polispec/active.json"
      list.reject(&:empty?).map { |file| File.expand_path(file) }.select { |file| File.file?(file) }.uniq
    end

    def global_files
      source = Layers.source
      return [] unless source

      if source.kind == :dir
        Dir.glob(File.join(source.root, "**", "*")).sort.select { |file| File.file?(file) }.first(WATCH_CAP)
      else
        git = File.join(source.repo, ".git")
        git = source.repo unless File.directory?(git)
        [File.join(git, "refs", "heads", source.ref.to_s), File.join(git, "packed-refs")]
      end
    rescue StandardError
      []
    end

    def stale?(ledger, context = {})
      return true unless File.file?(path) && File.file?(tools_path)
      return true if ledger.path && File.file?(ledger.path) && File.mtime(ledger.path) > File.mtime(path)

      File.open(path, &:gets).to_s.chomp != key(ledger, context)
    end

    def key(ledger, context = {})
      global = Layers.fingerprint
      plane = context["plane"].is_a?(Hash) ? context["plane"] : { "status" => "unsealed" }
      material = [ledger.digest.to_s, global, plane["status"], plane["generation"], context["control_digest"], context["edition"], context["fail_mode"], context["root_guard"], context["mcp_default"]]
      Digest::SHA256.hexdigest(material.map(&:to_s).join("\0"))
    end

    def skippable
      return ["*"] unless Layers.baseline?

      (Harness::Base::READ_TOOLS + Classify::Benign::INTERNAL_TOOLS).map(&:downcase).uniq
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
