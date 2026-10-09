#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    class GitSource
      attr_reader :repo, :ref, :tree

      def initialize(repo, ref)
        @repo = repo
        @ref = ref
        raise PackMissing, "specs repository #{repo} is not readable" unless File.directory?(File.join(repo, ".git")) || File.file?(File.join(repo, ".git")) || File.file?(File.join(repo, "HEAD"))

        tree = Code.git(repo, "rev-parse", "--verify", "--quiet", "#{ref}^{tree}").to_s.strip
        raise PackMissing, "ref #{ref} not found in #{repo}" unless tree.match?(/\A[0-9a-f]{40,64}\z/)

        @tree = tree
      end

      def kind
        :git
      end

      def label
        "#{ref}:#{tree[0, 12]}"
      end

      def tree_id
        tree
      end

      def entries
        @entries ||= begin
          out = Code.git(repo, "ls-tree", "-r", "-z", tree).to_s
          out.split("\0").each_with_object({}) do |line, memo|
            meta, path = line.split("\t", 2)
            next unless path

            memo[path] = meta.split(" ")[2]
          end
        end
      end

      def paths
        entries.keys
      end

      def exist?(path)
        entries.key?(path)
      end

      def blob_id(path)
        entries[path]
      end

      def read(path)
        sha = entries[path]
        return nil unless sha

        Code.git(repo, "cat-file", "blob", sha)
      end

      def read_many(wanted)
        out = {}
        wanted.each_slice(400) do |slice|
          shas = slice.map { |path| entries[path] }.compact
          next if shas.empty?

          Open3.popen2(PolicySource::GIT_ENV, "git", "-C", repo, "cat-file", "--batch") do |stdin, stdout, _wait|
            stdin.write(shas.map { |sha| "#{sha}\n" }.join)
            stdin.close
            slice.each do |path|
              sha = entries[path]
              next unless sha

              header = stdout.gets.to_s.split(" ")
              size = header[2].to_i
              data = stdout.read(size).to_s
              stdout.read(1)
              out[path] = data.force_encoding(Encoding::UTF_8)
            end
          end
        end
        out
      end

      def materialize(path)
        sha = entries[path]
        return nil unless sha

        target = File.join(Paths.materialized_dir, "#{sha}-#{File.basename(path)}")
        return target if File.file?(target)

        text = read(path)
        return nil unless text

        Code.write_atomic(target, text, 0o700)
      end
    end

    class DirSource
      SKIP = %w[.git vendor .bundle node_modules].freeze
      attr_reader :root

      def initialize(root)
        @root = File.expand_path(root)
        raise PackMissing, "specs directory #{@root} does not exist" unless File.directory?(@root)
      end

      def kind
        :dir
      end

      def ref
        "worktree"
      end

      def label
        "worktree:#{root}"
      end

      def tree_id
        @tree_id ||= begin
          digest = Digest::SHA256.new
          paths.each do |path|
            next unless path.start_with?("specs/", "enforcers/")

            digest << path << "\0" << File.binread(File.join(root, path)) << "\0"
          end
          "worktree-#{digest.hexdigest[0, 40]}"
        end
      end

      def paths
        @paths ||= Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).select { |file| File.file?(file) }.map { |file| file.sub("#{root}/", "") }.reject { |path| SKIP.include?(path.split("/").first) }.sort
      end

      def exist?(path)
        File.file?(File.join(root, path))
      end

      def blob_id(path)
        Digest::SHA256.file(File.join(root, path)).hexdigest
      end

      def read(path)
        File.read(File.join(root, path))
      rescue SystemCallError
        nil
      end

      def read_many(wanted)
        wanted.each_with_object({}) { |path, memo| memo[path] = read(path) }
      end

      def materialize(path)
        file = File.join(root, path)
        File.file?(file) ? file : nil
      end
    end
  end
end
