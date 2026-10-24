#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "canonical"

module Polispec
  class Chain
    TAIL_BYTES = 262_144

    attr_reader :path, :head_path, :lock_path

    def self.link(body, previous)
      linked = body.merge("prev" => previous)
      linked.merge("hash" => Canonical.sha256(Canonical.json(linked)))
    end

    def self.broken_at(entries)
      previous = nil
      entries.each_with_index do |entry, index|
        return index unless entry.is_a?(Hash) && entry["prev"] == previous && entry["hash"] == Canonical.sha256(Canonical.json(entry.reject { |key, _| key == "hash" }))

        previous = entry["hash"]
      end
      nil
    end

    def initialize(dir:, file:, head:, lock:, prefix:, schema:)
      @dir = dir
      @path = File.join(dir, file)
      @head_path = File.join(dir, head)
      @lock_path = File.join(dir, lock)
      @prefix = prefix
      @schema = schema
    end

    def append(body)
      FileUtils.mkdir_p(@dir, mode: 0o700)
      File.open(@lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        head = current_head
        entry = seal(body.merge("prev" => head && head["digest"]))
        File.open(@path, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |file| file.syswrite("#{JSON.generate(entry)}\n") }
        write_head("digest" => entry["digest"], "count" => (head ? head["count"].to_i : 0) + 1, "file" => File.basename(@path))
        entry
      end
    end

    def each
      return unless File.file?(@path)

      File.foreach(@path) do |line|
        parsed = State.parse_line(line)
        yield parsed if parsed
      end
    end

    def records
      list = []
      each { |entry| list << entry }
      list
    end

    def find(id)
      each { |entry| return entry if entry["id"] == id }
      nil
    end

    def last
      tail_record
    end

    def verify
      findings = []
      interrupted = []
      previous = nil
      parent = nil
      seen = {}
      count = 0
      last_entry = nil
      each do |entry|
        count += 1
        id = entry["id"]
        Schema::Validator.new(definition).call(entry).each { |error| findings << finding("schema", id, "#{error.pointer.empty? ? '/' : error.pointer} #{error.message}") } if @schema
        findings << finding("digest_mismatch", id, "stored digest does not match the record") if entry["digest"] != Canonical.sha256(Canonical.json(entry.reject { |key, _| key == "digest" }))
        if entry["prev"] != previous
          if entry["prev"] && entry["prev"] == parent
            interrupted << finding("interrupted_append", id, "chains from #{entry['prev'].to_s[0, 12]} like the record before it: an append was cut off before the head anchor moved")
          else
            findings << finding("chain_broken", id, "prev #{entry['prev'].to_json} does not match #{previous.to_json}")
          end
        end
        findings << finding("duplicate_id", id, "id appears more than once") if seen[id]
        seen[id] = true
        previous = entry["digest"]
        parent = entry["prev"]
        last_entry = entry
      end
      head = stored_head
      anchored = count - interrupted.length
      if last_entry && head.nil?
        findings << finding("truncated", last_entry["id"], "the head anchor #{File.basename(@head_path)} is missing")
      elsif last_entry && (head["digest"] != last_entry["digest"] || head["count"].to_i != anchored)
        findings << finding("truncated", last_entry["id"], "the head anchor records #{head['count']} records ending #{head['digest'].to_s[0, 12]}; the stream has #{anchored} ending #{last_entry['digest'].to_s[0, 12]}")
      elsif last_entry.nil? && head
        findings << finding("truncated", nil, "the head anchor records #{head['count']} records but the stream is empty")
      end
      { "ok" => findings.empty?, "records" => count, "findings" => findings, "interrupted" => interrupted }
    end

    private

    def definition
      Schema::Document.load(File.join(Schema::DIR, "#{@schema}.v1.yml"))
    end

    def finding(kind, id, detail)
      { "kind" => kind, "id" => id, "detail" => detail }
    end

    def seal(body)
      core = body.reject { |key, _| %w[id digest].include?(key) }
      withid = { "schema" => body["schema"], "id" => "#{@prefix}#{Canonical.sha256(Canonical.json(core))[0, 12]}" }.merge(core)
      withid.merge("digest" => Canonical.sha256(Canonical.json(withid)))
    end

    def current_head
      stored = stored_head
      tail = tail_record
      return stored if tail.nil? && stored.nil?
      return { "digest" => tail["digest"], "count" => count_records, "file" => File.basename(@path) } if stored.nil?
      return stored if tail.nil? || tail["digest"] == stored["digest"]

      { "digest" => tail["digest"], "count" => count_records, "file" => File.basename(@path) }
    end

    def count_records
      total = 0
      each { total += 1 }
      total
    end

    def stored_head
      return nil unless File.file?(@head_path)

      data = JSON.parse(File.read(@head_path))
      data.is_a?(Hash) && data["digest"].is_a?(String) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def write_head(data)
      temp = "#{@head_path}.#{Process.pid}.tmp"
      File.write(temp, JSON.generate(data), perm: 0o600)
      File.rename(temp, @head_path)
    end

    def tail_record
      return nil unless File.file?(@path)

      size = File.size(@path)
      return nil if size.zero?

      chunk = File.open(@path, "rb") do |handle|
        handle.seek([size - TAIL_BYTES, 0].max)
        handle.read
      end
      chunk.split("\n").reverse_each do |line|
        parsed = State.parse_line(line)
        return parsed if parsed && parsed["digest"].is_a?(String)
      end
      nil
    rescue SystemCallError
      nil
    end
  end
end
