#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    class Baseline
      MAX_BYTES = 512 * 1024
      attr_reader :key, :path, :counts

      def self.load(root)
        new(Repo.key(root))
      end

      def self.scan(root, pack, force: false, io: $stdout)
        baseline = load(root)
        detector = Detector.new(pack)
        runner = Runner.new(pack)
        found = Hash.new(0)
        files = 0
        Repo.tracked(root).each do |relative|
          file = File.join(root, relative)
          next unless File.file?(file) && File.size(file) <= MAX_BYTES

          text = File.read(file).force_encoding(Encoding::UTF_8)
          next if text.include?("\0") || !text.valid_encoding?

          chain = Chain.for(pack, detector.detect(file, head: text))
          rules = chain.rules_for_path(relative).select { |rule| Checker.enforceable?(rule) }
          next if rules.empty?

          files += 1
          runner.run(rules, text, file).hits.each { |hit| found["#{hit.rule.id}\t#{relative}"] += 1 }
        end
        baseline.record(found, force: force, repo: root, pack: pack.source.label)
        io.puts "baseline #{baseline.key}: scanned #{files} files, #{found.length} policy/path entries, #{found.values.sum} violations"
        baseline
      end

      def initialize(key)
        @key = key
        @path = File.join(Paths.baselines_dir, "#{key}.json")
        @counts = read
      end

      def exist?
        File.file?(path)
      end

      def count(policy, relative)
        counts["#{policy}\t#{relative}"]
      end

      def record(found, force:, repo:, pack:)
        merged =
          if exist? && !force
            counts.each_with_object({}) { |(entry, old), memo| memo[entry] = [old, found.fetch(entry, 0)].min }
          else
            found.dup
          end
        merged.delete_if { |_entry, value| value <= 0 }
        write(merged, repo, pack)
      end

      def lower(policy, relative, value)
        entry = "#{policy}\t#{relative}"
        old = counts[entry]
        return false unless old && value < old

        updated = counts.dup
        value.zero? ? updated.delete(entry) : updated[entry] = value
        write(updated, nil, nil)
        true
      end

      private

      def read
        data = JSON.parse(File.read(path))
        Array(data["entries"]).each_with_object({}) { |item, memo| memo["#{item['policy']}\t#{item['path']}"] = item["count"].to_i }
      rescue SystemCallError, JSON::ParserError
        {}
      end

      def write(entries, repo, pack)
        previous = begin
          JSON.parse(File.read(path))
        rescue SystemCallError, JSON::ParserError
          {}
        end
        list = entries.map do |entry, count|
          policy, file = entry.split("\t", 2)
          { "policy" => policy, "path" => file, "count" => count }
        end
        document = {
          "repo_key" => key, "repo" => repo || previous["repo"], "pack" => pack || previous["pack"],
          "recorded" => previous["recorded"] || Time.now.utc.iso8601, "updated" => Time.now.utc.iso8601, "entries" => list.sort_by { |item| [item["policy"], item["path"]] }
        }
        Code.write_atomic(path, JSON.pretty_generate(document))
        @counts = entries
      end
    end
  end
end
