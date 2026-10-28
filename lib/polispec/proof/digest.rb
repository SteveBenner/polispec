#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Proof
    module Digest
      module_function

      def cell(git_dir, rev, manifest, feature, target)
        feature = manifest.feature(feature) if feature.is_a?(String)
        target = manifest.target(target) if target.is_a?(String)
        raise Polispec::Error, "digest_unknown_cell: no such feature or target" unless feature && target

        files = tree(git_dir, rev).select { |path, _| manifest.covers?(feature, path) }.sort_by(&:first).map { |path, blob| [path, blob] }
        Canonical.sha256(Canonical.json("feature" => feature, "target" => target, "files" => files, "spec" => spec_digest(git_dir, rev, feature["spec"])))
      end

      def tree(git_dir, rev)
        @trees ||= {}
        @trees[[git_dir.to_s, rev.to_s]] ||= read_tree(git_dir, rev)
      end

      def reset!
        @trees = {}
      end

      def read_tree(git_dir, rev)
        out, err, status = Trace.capture3("git", "-C", git_dir.to_s, "ls-tree", "-r", "--full-tree", "-z", rev.to_s, trace: :silent)
        raise Polispec::Error, "digest_tree_unreadable: #{err.to_s.strip}" unless status.success?

        out.split("\0").reject(&:empty?).to_h do |entry|
          meta, path = entry.split("\t", 2)
          [path, meta.split(" ")[2]]
        end
      end

      def spec_digest(git_dir, rev, anchor)
        return nil unless anchor

        text, _err, status = Trace.capture3("git", "-C", git_dir.to_s, "show", "#{rev}:#{anchor['file']}", trace: :silent)
        return nil unless status.success?

        data = YAML.safe_load(text, permitted_classes: [Date, Time], aliases: false)
        Smoke.node_digest(Smoke.resolve_node(data, anchor["file"], anchor["at"]))
      rescue Psych::Exception, Polispec::Error
        nil
      end
    end
  end
end
