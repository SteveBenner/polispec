#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    class Session
      KEEP_DAYS = 7
      attr_reader :id, :data

      def self.load(id, cwd)
        new(id.to_s.empty? ? "default" : id.to_s, cwd)
      end

      def initialize(id, cwd)
        @id = id.gsub(/[^A-Za-z0-9_.-]/, "_")[0, 80]
        @data = read
        @data["cwd"] ||= cwd
        @data["created"] ||= Time.now.utc.iso8601
        @data["injected"] ||= {}
        @data["files"] ||= []
        @data["retry"] ||= []
      end

      def path
        File.join(Paths.sessions_dir, "#{id}.json")
      end

      def snapshot_dir
        File.join(Paths.sessions_dir, "#{id}.before")
      end

      def injected?(digest)
        data["injected"].key?(digest)
      end

      def mark_injected(digest)
        data["injected"][digest] = Time.now.utc.iso8601
      end

      def reset_injected
        data["injected"] = {}
        data["retry"] = []
      end

      def notice?
        data["notice"] == true
      end

      def notice!
        data["notice"] = true
      end

      def retry?(key)
        data["retry"].include?(key)
      end

      def remember_retry(key)
        data["retry"] << key
        data["retry"] = data["retry"].last(50)
      end

      def start_sha
        data["start_sha"]
      end

      def begin_tracking(root)
        return if data.key?("start_sha")

        data["start_sha"] = root ? Repo.head(root) : ""
        data["root"] = root
        data["dirty_at_start"] = root ? dirty(root) : []
      end

      def add_file(file)
        data["files"] << file unless data["files"].include?(file)
        data["files"] = data["files"].last(200)
      end

      def stop_blocked?
        data["stop_blocked"] == true
      end

      def stop_blocked!
        data["stop_blocked"] = true
      end

      def snapshot_key(file)
        Digest::SHA256.hexdigest(file)[0, 24]
      end

      def save_snapshot(file, text)
        Code.write_atomic(File.join(snapshot_dir, snapshot_key(file)), text.to_s)
      end

      def take_snapshot(file)
        target = File.join(snapshot_dir, snapshot_key(file))
        return nil unless File.file?(target)

        text = File.read(target)
        File.delete(target)
        text
      rescue SystemCallError
        nil
      end

      def save
        Code.write_atomic(path, JSON.generate(data))
        prune
      rescue SystemCallError
        nil
      end

      private

      def dirty(root)
        out = Code.git(root, "status", "--porcelain", "-z", "--untracked-files=all").to_s
        out.split("\0").map { |entry| entry[3..-1] }.compact
      end

      def read
        JSON.parse(File.read(path))
      rescue SystemCallError, JSON::ParserError
        {}
      end

      def prune
        return unless rand < 0.05

        cutoff = Time.now - KEEP_DAYS * 86_400
        Dir.glob(File.join(Paths.sessions_dir, "*")).each do |entry|
          next unless File.mtime(entry) < cutoff

          if File.directory?(entry)
            Dir.children(entry).each { |name| File.delete(File.join(entry, name)) }
            Dir.rmdir(entry)
          else
            File.delete(entry)
          end
        end
      rescue SystemCallError
        nil
      end
    end
  end
end
