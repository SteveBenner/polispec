#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "open3"

module Polispec
  module Runtime
    RELEASE_FILE = ".rplugin-release.json"
    RELEASE_SCHEMA = "rplugin.release/v1"
    NATIVE_RELEASE_FILE = ".polispec-release.json"
    NATIVE_RELEASE_SCHEMA = "polispec.release/v1"
    RELEASE_FILES = [RELEASE_FILE, NATIVE_RELEASE_FILE].freeze
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

    def release_kind
      return nil unless release

      release_file == NATIVE_RELEASE_FILE ? "native" : "rplugin"
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
        next if File.basename(relative) == "." || File.basename(relative) == ".." || RELEASE_FILES.include?(relative)
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

    def release_file
      return @release_file if defined?(@release_file)

      load_release
      @release_file
    end

    def load_release
      @release_file = nil
      [[RELEASE_FILE, RELEASE_SCHEMA], [NATIVE_RELEASE_FILE, NATIVE_RELEASE_SCHEMA]].each do |name, schema|
        path = File.join(root, name)
        next unless File.file?(path) && !File.symlink?(path)

        data = JSON.parse(File.read(path))
        next unless data.is_a?(Hash) && data["schema"] == schema && data["commit"].to_s == File.basename(root)

        @release_file = name
        return data
      end
      nil
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
