#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "open3"

module Polispec
  module Runtime
    RELEASE_FILE = ".rplugin-release.json"
    RELEASE_SCHEMA = "rplugin.release/v1"
    SEALED_PATH = "/usr/local/lib/polispec"

    module_function

    def root
      @root ||= File.realpath(ROOT)
    end

    def release
      return @release if defined?(@release)

      @release = load_release
    end

    def kind
      @kind ||= if release
        "pinned"
      elsif sealed?
        "sealed"
      elsif File.exist?(File.join(root, ".git"))
        "clone"
      else
        "unknown"
      end
    end

    def commit
      return release["commit"] if release
      return @commit if defined?(@commit)

      @commit = git_head
    end

    def pinned?
      kind == "pinned"
    end

    def tree_digest(dir)
      entries = []
      Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).each do |relative|
        next if File.basename(relative) == "." || File.basename(relative) == ".." || relative == RELEASE_FILE
        path = File.join(dir, relative)
        stat = File.lstat(path)
        if stat.symlink?
          entries << [relative, "symlink", Digest::SHA256.hexdigest(File.readlink(path))]
        elsif stat.file?
          entries << [relative, format("%04o", stat.mode & 0o7777), Digest::SHA256.file(path).hexdigest]
        end
      end
      Digest::SHA256.hexdigest(JSON.generate(entries.sort_by(&:first)))
    end

    def load_release
      path = File.join(root, RELEASE_FILE)
      return nil unless File.file?(path) && !File.symlink?(path)

      data = JSON.parse(File.read(path))
      return nil unless data.is_a?(Hash) && data["schema"] == RELEASE_SCHEMA && data["commit"].to_s == File.basename(root)

      data
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def sealed?
      return false unless root == SEALED_PATH || root.start_with?("#{SEALED_PATH}/")

      require_relative "harness_controls/plane"
      HarnessControls::Plane.resolve["status"] == "active"
    rescue StandardError
      false
    end

    def git_head
      out, status = Open3.capture2({ "GIT_OPTIONAL_LOCKS" => "0" }, "git", "-C", root, "rev-parse", "HEAD", err: File::NULL)
      status.success? ? out.strip : nil
    rescue SystemCallError
      nil
    end
  end
end
