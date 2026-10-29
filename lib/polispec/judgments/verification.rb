#!/usr/bin/env ruby
# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "digest"
require "json"

module Polispec
  module Judgments
    VERIFIED = "judgments.verified.json"
    CHECKPOINT_VERSION = 1
    CHUNK_BYTES = 1024 * 1024

    module_function

    def verified_path
      File.join(State.home, VERIFIED)
    end

    def capture
      return capture_files unless File.file?(lock_path)

      File.open(lock_path, File::RDONLY) do |lock|
        lock.flock(File::LOCK_SH)
        capture_files
      end
    end

    def capture_files
      handles = []
      entries = files.filter_map do |file|
        handle = File.open(file, "rb")
        handles << handle
        stat = handle.stat
        { "name" => File.basename(file), "handle" => handle, "ino" => stat.ino, "size" => stat.size, "ctime" => "#{stat.ctime.tv_sec}.#{stat.ctime.tv_nsec}" }
      rescue Errno::ENOENT
        nil
      end
      { "handles" => handles, "files" => entries, "head" => head_file }
    rescue SystemCallError
      handles.each(&:close)
      raise
    end

    def take(walk, line, where, schema)
      entry, note = classify(line)
      case note
      when "malformed"
        walk["findings"] << finding("malformed_record", nil, "#{where} is not a JSON object; historical bytes were preserved")
        return
      when "torn"
        walk["interrupted"] << finding("torn_record", nil, "#{where} is a record cut off mid-write; it never advanced the head anchor and the chain continues past it")
        return
      when "torn_tail"
        walk["interrupted"] << finding("torn_tail", nil, "#{where} is a record cut off mid-write at the end of the stream; it never advanced the head anchor and the next append starts on a new line")
        return
      when "joined"
        walk["joined"] += 1
        walk["interrupted"] << finding("torn_record", entry["id"], "#{where} starts with a record cut off mid-write; the record appended after it on the same line is read from its own start and counted as unanchored")
      end
      walk["count"] += 1
      id = entry["id"]
      Schema.validate("judgment", entry).each { |error| walk["findings"] << finding("schema", id, "#{error.pointer.empty? ? '/' : error.pointer} #{error.message}") } if schema
      walk["findings"] << finding("digest_mismatch", id, "stored digest does not match the record") if entry["digest"] != Canonical.sha256(Canonical.json(entry.reject { |key, _| key == "digest" }))
      if entry["prev"] != walk["previous"]
        if entry["prev"] && entry["prev"] == walk["parent"]
          walk["interrupted"] << finding("interrupted_append", id, "chains from #{entry['prev'].to_s[0, 12]} like the record before it: an append was cut off before the head anchor moved")
        else
          walk["findings"] << finding("chain_broken", id, "prev #{entry['prev'].to_json} does not match #{walk['previous'].to_json}")
        end
      end
      walk["findings"] << finding("duplicate_id", id, "id appears more than once") if walk["ids"].key?(id)
      walk["ids"][id] = true
      walk["previous"] = entry["digest"]
      walk["parent"] = entry["prev"]
      walk["last"] = { "id" => id, "digest" => entry["digest"] }
    end

    def settled(walk)
      walk.except("ids").merge("findings" => walk["findings"].map(&:dup), "interrupted" => walk["interrupted"].map(&:dup), "ids" => walk["ids"].keys)
    end

    def each_line_in(handle, from, upto)
      offset = from
      pending = "".b
      while offset < upto
        chunk = handle.pread([CHUNK_BYTES, upto - offset].min, offset)
        offset += chunk.bytesize
        pending << chunk
        start = 0
        while (index = pending.index("\n", start))
          yield pending.byteslice(start, index - start + 1).force_encoding(Encoding::UTF_8)
          start = index + 1
        end
        pending = pending.byteslice(start, pending.bytesize - start)
      end
      yield pending.force_encoding(Encoding::UTF_8) unless pending.empty?
    end

    def prefix_digest(handle, size)
      digest = Digest::SHA256.new
      offset = 0
      while offset < size
        chunk = handle.pread([CHUNK_BYTES, size - offset].min, offset)
        digest << chunk
        offset += chunk.bytesize
      end
      digest.hexdigest
    end

    def resume(entries, schema)
      data = JSON.parse(File.read(verified_path))
      return nil unless data.is_a?(Hash) && data["version"] == CHECKPOINT_VERSION && (data["schema"] || !schema)

      complete = Array(data["complete"])
      part = data["partial"]
      state = data["state"]
      return nil unless part.is_a?(Hash) && state.is_a?(Hash) && entries.length > complete.length
      return nil unless complete.each_with_index.all? { |meta, index| entries[index].slice("name", "ino", "size", "ctime") == meta }

      entry = entries[complete.length]
      return nil unless entry["ino"] == part["ino"] && entry["size"] >= part["offset"].to_i && prefix_digest(entry["handle"], part["offset"].to_i) == part["sha256"]

      renamed = lambda do |item|
        detail = item["detail"].to_s
        detail.start_with?("#{part['name']}:") ? item.merge("detail" => "#{entry['name']}:#{detail.delete_prefix("#{part['name']}:")}") : item
      end
      findings = Array(state["findings"]).map(&renamed)
      findings = findings.reject { |item| item["kind"] == "schema" } unless schema
      Trace.info("judgment checkpoint resumed", records: state["count"], file: entry["name"], offset: part["offset"]) if Trace.on?
      state.slice("previous", "parent", "count", "joined", "last").merge(
        "findings" => findings, "interrupted" => Array(state["interrupted"]).map(&renamed),
        "ids" => Array(data["ids"]).to_h { |id| [id, true] }, "index" => complete.length, "offset" => part["offset"].to_i, "lines" => part["lines"].to_i
      )
    rescue JSON::ParserError, SystemCallError, EOFError
      nil
    end

    def save_checkpoint(walk, entries, schema)
      return if entries.empty?

      entry = entries[walk["index"]]
      data = {
        "version" => CHECKPOINT_VERSION, "schema" => schema,
        "complete" => entries.first(walk["index"]).map { |item| item.slice("name", "ino", "size", "ctime") },
        "partial" => { "name" => entry["name"], "ino" => entry["ino"], "offset" => walk["offset"], "lines" => walk["lines"], "sha256" => prefix_digest(entry["handle"], walk["offset"]) },
        "state" => walk.slice("previous", "parent", "count", "joined", "last", "findings", "interrupted"),
        "ids" => walk["ids"]
      }
      temp = "#{verified_path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
      File.write(temp, JSON.generate(data), perm: 0o600)
      File.rename(temp, verified_path)
    rescue SystemCallError, EOFError => error
      Trace.info("judgment checkpoint not written", error: "#{error.class}: #{error.message}") if Trace.on?
    end
  end
end
