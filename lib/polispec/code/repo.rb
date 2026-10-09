#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    module Repo
      module_function

      def root(path)
        dir = File.directory?(path) ? path : File.dirname(path)
        dir = File.dirname(dir) until File.directory?(dir) || dir == File.dirname(dir)
        out = Code.git(dir, "rev-parse", "--show-toplevel").to_s.strip
        out.empty? ? nil : out
      end

      def key(root)
        remote = Code.git(root, "config", "--get", "remote.origin.url").to_s.strip
        seed = remote.empty? ? File.realpath(root) : remote
        Digest::SHA256.hexdigest(seed)[0, 24]
      end

      def relative(root, path)
        return File.basename(path) unless root

        path.start_with?("#{root}/") ? path.sub("#{root}/", "") : File.basename(path)
      end

      def head(root)
        Code.git(root, "rev-parse", "--verify", "--quiet", "HEAD").to_s.strip
      end

      def tracked(root)
        Code.git(root, "ls-files", "-z").to_s.split("\0")
      end
    end
  end
end
