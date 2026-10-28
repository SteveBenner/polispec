#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

module Polispec
  module Proof
    module Weakening
      module_function

      def diff(old, new)
        return [] if new.nil?

        old ||= Manifest.new("targets" => [], "features" => [])
        entries = []
        entries.concat(exception_entries(old, new))
        entries.concat(producer_entries(old, new))
        entries.concat(glob_entries(old, new))
        entries.concat(target_entries(old, new))
        entries.concat(feature_entries(old, new))
        entries
      end

      def between(git_dir, old_rev, new_rev)
        diff(Manifest.at(git_dir, old_rev), Manifest.at(git_dir, new_rev))
      end

      def between_worktree(git_dir, old_rev, root)
        diff(Manifest.at(git_dir, old_rev), Manifest.load(root: root))
      end

      def entry(kind, feature, target, detail)
        { "kind" => kind, "feature" => feature, "target" => target, "detail" => detail }
      end

      def describe(item)
        subject = [item["feature"], item["target"]].compact.join(" ")
        "#{item['kind']}#{subject.empty? ? '' : " #{subject}"}: #{item['detail']}"
      end

      def summary(entries)
        { "count" => entries.length, "kinds" => entries.map { |item| item["kind"] }.uniq.sort }
      end

      def expiry(value)
        Date.parse(value.to_s)
      rescue Date::Error
        Date.new(1970, 1, 1)
      end

      def scope(manifest, entry)
        feature = manifest.feature(entry["feature"])
        return Array(entry["targets"]) unless feature

        entry["targets"] || manifest.target_ids_for(feature)
      end

      def exception_entries(old, new)
        new.exceptions.flat_map do |current|
          targets = scope(new, current)
          added = []
          extended = []
          targets.each do |target|
            earlier = old.exceptions.select { |item| item["feature"] == current["feature"] && scope(old, item).include?(target) }
            if earlier.empty?
              added << target
            elsif earlier.map { |item| expiry(item["expires"]) }.max < expiry(current["expires"])
              extended << target
            end
          end
          list = []
          list << entry("exception_added", current["feature"], added.join(","), "expires #{current['expires']}: #{current['reason']}") unless added.empty?
          list << entry("exception_extended", current["feature"], extended.join(","), "now expires #{current['expires']}") unless extended.empty?
          list
        end
      end

      def producer_entries(old, new)
        known = old.trusted_producers.to_h { |item| [item["id"], item] }
        new.trusted_producers.filter_map do |item|
          before = known[item["id"]]
          if before.nil?
            entry("producer_added", nil, nil, "#{item['id']} (#{item['kind']})")
          elsif before["key"] != item["key"] || before["kind"] != item["kind"]
            entry("producer_changed", nil, nil, "#{item['id']} key or kind differs")
          end
        end
      end

      def glob_entries(old, new)
        list = []
        (new.ignore - old.ignore).each { |glob| list << entry("ignore_added", nil, nil, glob) }
        (old.shared - new.shared).each { |glob| list << entry("shared_removed", nil, nil, glob) }
        list
      end

      def target_entries(old, new)
        gone = old.targets.map { |item| item["id"] } - new.targets.map { |item| item["id"] }
        gone.map { |id| entry("target_removed", nil, id, "no longer declared") }
      end

      def feature_entries(old, new)
        old.features.flat_map do |before|
          current = new.feature(before["id"])
          next [entry("feature_removed", before["id"], nil, "no longer declared")] unless current

          feature_changes(old, new, before, current)
        end
      end

      def feature_changes(old, new, before, current)
        id = before["id"]
        list = []
        narrowed = old.target_ids_for(before) - new.target_ids_for(current)
        list << entry("targets_narrowed", id, narrowed.join(","), "no longer required") unless narrowed.empty?
        paths = Array(before["paths"]) - Array(current["paths"])
        list << entry("paths_changed", id, nil, "removed #{paths.join(', ')}") unless paths.empty?
        shared = Array(before["shared"]) - Array(current["shared"])
        list << entry("feature_shared_changed", id, nil, "removed #{shared.join(', ')}") unless shared.empty?
        list << entry("smoke_changed", id, nil, "run, rung or per_target differs") if before["smoke"] != current["smoke"]
        list << entry("min_rung_lowered", id, nil, "#{old.min_rung(before)} to #{new.min_rung(current)}") if new.min_rung(current) < old.min_rung(before)
        list
      end
    end
  end
end
