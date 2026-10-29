#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "digest"
require_relative "canonical"
require_relative "runtime"
require_relative "judgments/verification"

module Polispec
  module Judgments
    SCHEMA = "polispec.judgment/v1"
    EVENT = "polispec.judgment"
    STREAM = "judgments"
    SKIPS = "skips"
    HEAD = "judgments.head.json"
    LOCK = "judgments.lock"
    STALLED = "judgments.stalled.json".freeze
    ACKNOWLEDGED = "judgments.acknowledged.json".freeze
    RECORD_START = "{\"schema\":\"#{SCHEMA}\"".freeze
    ROTATE_BYTES = 16 * 1024 * 1024
    TAIL_BYTES = 262_144
    RAW_KEY = "polispec.records.raw"
    RAW_LIMIT = 2048
    WINDOW_SECONDS = 14 * 24 * 3600
    RENDERED = %w[allow ask deny context none].freeze
    INTERNAL_RULE = "POLISPEC-INTERNAL"

    module_function

    def path
      State.log_path(STREAM)
    end

    def head_path
      File.join(State.home, HEAD)
    end

    def lock_path
      File.join(State.home, LOCK)
    end

    def stalled_path
      File.join(State.home, STALLED)
    end

    def acknowledged_path
      File.join(State.home, ACKNOWLEDGED)
    end

    def acknowledged
      return {} unless File.file?(acknowledged_path)

      data = JSON.parse(File.read(acknowledged_path))
      data.is_a?(Hash) ? data.select { |id, entry| id.is_a?(String) && entry.is_a?(Hash) && entry["kind"].is_a?(String) } : {}
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def acknowledge!(id, kind:, detail:, reason:, actor:)
      State.ensure_dirs
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        entry = { "kind" => kind, "detail" => detail, "reason" => reason, "at" => Time.now.utc.iso8601, "by" => actor }
        data = acknowledged.merge(id => entry)
        temp = "#{acknowledged_path}.#{Process.pid}.tmp"
        File.write(temp, "#{JSON.pretty_generate(data)}\n", perm: 0o600)
        File.rename(temp, acknowledged_path)
        entry
      end
    end

    def skips_path
      State.log_path(SKIPS)
    end

    def raw?
      Engine::Settings.text(RAW_KEY, "off") == "on"
    rescue StandardError
      false
    end

    def home_relative(value)
      return nil unless value.is_a?(String) && !value.empty?

      home = Dir.home
      value == home || value.start_with?("#{home}/") ? value.sub(home, "~") : value
    end

    def call_digest(tool, arguments, cwd)
      Canonical.sha256(Canonical.json("tool" => tool.to_s, "arguments" => arguments, "cwd" => cwd.to_s))
    end

    def text_or_nil(value)
      text = value.to_s
      text.empty? ? nil : text
    end

    def action(tool:, harness:, event:, session_id:, agent_type:, cwd:, arguments:, raw: nil)
      row = {
        "tool" => text_or_nil(tool), "harness" => harness.to_s, "event" => text_or_nil(event), "session_id" => text_or_nil(session_id),
        "agent_type" => text_or_nil(agent_type), "cwd" => home_relative(cwd.to_s), "call_digest" => call_digest(tool, arguments, cwd)
      }
      text = raw.to_s
      row["raw"] = text.dup.force_encoding(Encoding::UTF_8).byteslice(0, RAW_LIMIT).scrub("?") if raw? && !text.empty?
      row
    end

    def target(target, outcome, ctx)
      verdict = outcome.verdict
      {
        "project" => target.project, "env" => outcome.env, "policy_source" => target.policy_source, "policy_digest" => target.digest,
        "verdict" => verdict.level.to_s, "rule_id" => verdict.rule_id, "rows" => rows_for(outcome, target, ctx)
      }
    end

    def rows_for(outcome, target, ctx)
      Array(outcome.rows).map { |row| row_for(row, target, ctx) }
    rescue StandardError
      []
    end

    def row_for(row, target, ctx)
      action = row.action
      hint = Engine::Envs.hint_of(action)
      {
        "action_class" => action.action_class, "env" => row.env, "ref" => hint["ref"].is_a?(String) ? hint["ref"] : nil,
        "path" => home_relative(hint["path"]), "crosses" => crosses(action, target, ctx),
        "destructive" => destructive?(action, ctx), "shape" => Array(hint["shape"]).map(&:to_s),
        "verdict" => row.verdict.level.to_s, "rule_id" => row.verdict.rule_id
      }
    end

    def destructive?(action, ctx)
      Engine::Destructive.of?(action, ctx) ? true : false
    rescue StandardError
      false
    end

    def crosses(action, target, ctx)
      return "data_classes" if action.action_class == "data.copy" && !Engine::Envs.crossing(action, target, ctx).empty?
      return "location" if Engine::Locations.crossing(action, target, ctx)

      nil
    rescue StandardError
      nil
    end

    def engine(mode, plane: nil, fastpath_key: nil)
      require_relative "harness_controls/plane"
      plane ||= HarnessControls::Plane.resolve
      release = Runtime.release
      {
        "version" => Polispec.version, "runtime" => Runtime.kind, "commit" => Runtime.commit, "tree_digest" => release ? release["tree_digest"] : nil,
        "edition" => edition, "enforce" => text_or_nil(mode),
        "plane" => { "status" => plane.is_a?(Hash) ? plane["status"].to_s : "unknown", "generation" => plane.is_a?(Hash) ? plane["generation"] : nil },
        "fastpath_key" => fastpath_key
      }
    rescue StandardError
      {
        "version" => Polispec.version, "runtime" => "unknown", "commit" => nil, "tree_digest" => nil, "edition" => nil, "enforce" => text_or_nil(mode),
        "plane" => { "status" => "unknown", "generation" => nil }, "fastpath_key" => fastpath_key
      }
    end

    def edition
      HarnessControls::Plane.requested_edition
    rescue StandardError
      nil
    end

    def outcome(verdict, enforced:, rendered:, governed:, error: nil, duration_ms: nil)
      {
        "verdict" => verdict ? verdict.level.to_s : "allow", "rule_id" => verdict && verdict.rule_id, "enforced" => enforced ? true : false,
        "allow_once_id" => verdict && verdict.allow_once_id, "rendered" => RENDERED.include?(rendered) ? rendered : "none",
        "governed" => governed ? true : false, "error" => error, "duration_ms" => duration_ms
      }
    end

    def rendered(output)
      return "none" if output.nil? || output.to_s.strip.empty?

      data = JSON.parse(output.to_s)
      return "none" unless data.is_a?(Hash)

      native = data["hookSpecificOutput"].is_a?(Hash) ? data["hookSpecificOutput"] : {}
      decision = native["permissionDecision"] || data["decision"] || data["action"]
      return "context" if decision.nil? && (native["additionalContext"] || data["additionalContext"])

      case decision.to_s
      when "deny", "block" then "deny"
      when "ask" then "ask"
      when "allow" then "allow"
      else "none"
      end
    rescue JSON::ParserError
      "none"
    end

    def record
      body = { "schema" => SCHEMA, "ts" => Time.now.utc.iso8601(3) }.merge(yield)
      entry = append(body)
      emit(entry)
      entry
    rescue StandardError => error
      unrecorded(error)
    end

    def unrecorded(error)
      note_stall(error)
      Events.emit("polispec.finding", project: nil, kind: "judgment_unrecorded", detail: "#{error.class}: #{error.message.to_s[0, 200]}", policy_source: nil)
      nil
    rescue StandardError
      nil
    end

    def note_stall(error)
      now = Time.now.utc.iso8601
      current = stalled
      data = {
        "count" => current ? current["count"].to_i + 1 : 1, "first_at" => current ? current["first_at"] : now, "last_at" => now,
        "error" => "#{error.class}: #{error.message.to_s[0, 200]}"
      }
      temp = "#{stalled_path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
      File.write(temp, JSON.generate(data), perm: 0o600)
      File.rename(temp, stalled_path)
    rescue SystemCallError, JSON::GeneratorError => failure
      Trace.info("stall marker not written", error: "#{failure.class}: #{failure.message}") if Trace.on?
    end

    def stalled
      return nil unless File.file?(stalled_path)

      data = JSON.parse(File.read(stalled_path))
      data.is_a?(Hash) && data["count"].is_a?(Integer) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def clear_stall
      File.delete(stalled_path) if File.file?(stalled_path)
    rescue SystemCallError => failure
      Trace.info("stall marker not cleared", error: "#{failure.class}: #{failure.message}") if Trace.on?
    end

    def emit(entry)
      action = entry["action"].is_a?(Hash) ? entry["action"].reject { |key, _| key == "raw" } : entry["action"]
      Events.emit(EVENT, entry.merge("action" => action))
    end

    def seal(body)
      core = body.reject { |key, _| %w[id digest].include?(key) }
      withid = { "schema" => SCHEMA, "id" => "jdg_#{Canonical.sha256(Canonical.json(core))[0, 12]}" }.merge(core)
      withid.merge("digest" => Canonical.sha256(Canonical.json(withid)))
    end

    def append(body)
      State.ensure_dirs
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        head = read_head
        rotate! if File.file?(path) && File.size(path) > ROTATE_BYTES
        entry = seal(body.merge("prev" => head && head["digest"]))
        line = "#{torn_tail?(path) ? "\n" : ''}#{JSON.generate(entry)}\n"
        File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
          written = file.syswrite(line)
          raise Polispec::Error, "judgment append was incomplete; the head anchor was not advanced" unless written == line.bytesize
        end
        write_head("digest" => entry["digest"], "count" => (head ? head["count"].to_i : 0) + 1, "file" => File.basename(path))
        rotate_skips
        clear_stall
        entry
      end
    end

    def torn_tail?(file)
      return false unless File.file?(file)

      size = File.size(file)
      return false if size.zero?

      File.open(file, "rb") do |handle|
        handle.seek(size - 1)
        handle.read(1) != "\n"
      end
    rescue SystemCallError
      false
    end

    def complete_bytes(file)
      return 0 unless file && File.file?(file)

      size = File.size(file)
      return 0 if size.zero?
      return size unless torn_tail?(file)

      chunk = File.open(file, "rb") do |handle|
        handle.seek([size - TAIL_BYTES, 0].max)
        handle.read
      end
      index = chunk.rindex("\n")
      index ? size - (chunk.bytesize - index - 1) : 0
    rescue SystemCallError
      0
    end

    def read_head
      stored = head_file
      tail = tail_digest
      raise Polispec::Error, "judgment journal tail is unreadable; preserve the journal and investigate before appending" if tail.nil? && complete_bytes(files.last).positive?
      return stored if stored && (tail.nil? || tail == stored["digest"])
      return nil unless tail
      return { "digest" => tail, "count" => count_records, "file" => File.basename(path) } unless stored

      ahead = ahead_of(stored["digest"])
      raise Polispec::Error, "judgment head diverges from journal tail; preserve the journal and investigate before appending" if ahead.empty?

      { "digest" => ahead.last["digest"], "count" => stored["count"].to_i + ahead.length, "file" => File.basename(path) }
    end

    def ahead_of(digest)
      window = tail_records
      by_digest = window.to_h { |entry| [entry["digest"], entry] }
      ahead = []
      entry = window.last
      window.length.times do
        break unless entry && entry["digest"] != digest

        ahead.unshift(entry)
        return ahead if entry["prev"] == digest

        entry = by_digest[entry["prev"]]
      end
      []
    end

    def head_file
      return nil unless File.file?(head_path)

      data = JSON.parse(File.read(head_path))
      data.is_a?(Hash) && data["digest"].is_a?(String) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def write_head(data)
      temp = "#{head_path}.#{Process.pid}.tmp"
      File.write(temp, JSON.generate(data), perm: 0o600)
      File.rename(temp, head_path)
    end

    def tail_digest
      parsed = parse_record(tail_lines.last.to_s)
      parsed && parsed["digest"].is_a?(String) ? parsed["digest"] : nil
    rescue SystemCallError
      nil
    end

    def tail_records
      tail_lines.filter_map do |line|
        parsed = parse_record(line)
        parsed if parsed && parsed["digest"].is_a?(String)
      end
    rescue SystemCallError
      []
    end

    def tail_lines
      file = files.last
      return [] unless file

      size = File.size(file)
      return [] if size.zero?

      chunk = File.open(file, "rb") do |handle|
        handle.seek([size - TAIL_BYTES, 0].max)
        handle.read
      end
      index = chunk.rindex("\n")
      return [] unless index

      chunk[0, index].split("\n").reject { |text| text.strip.empty? }
    end

    def parse_record(line)
      State.parse_line(line) || recovered_record(line)
    end

    def recovered_record(line)
      text = line.to_s
      start = text.rindex(RECORD_START)
      return nil unless start && start.positive?

      parsed = State.parse_line(text[start..])
      parsed && parsed["digest"].is_a?(String) ? parsed : nil
    end

    def record_like?(line)
      line.to_s.lstrip.start_with?(RECORD_START)
    end

    def count_records
      total = 0
      each_record { total += 1 }
      total
    end

    def stamp
      Time.now.utc.strftime("%Y%m%dT%H%M%S%LZ")
    end

    def rotate!
      File.rename(path, File.join(State.home, "judgments.#{stamp}.jsonl"))
    end

    def rotate_skips
      file = skips_path
      return unless File.file?(file) && File.size(file) > ROTATE_BYTES

      File.rename(file, File.join(State.home, "skips.#{stamp}.jsonl"))
    rescue SystemCallError
      nil
    end

    def files
      rotated = Dir.glob(File.join(State.home, "judgments.*.jsonl")).sort
      rotated + (File.file?(path) ? [path] : [])
    end

    def skip_files
      rotated = Dir.glob(File.join(State.home, "skips.*.jsonl")).sort
      rotated + (File.file?(skips_path) ? [skips_path] : [])
    end

    def each_record(include_malformed: false)
      files.each do |file|
        File.foreach(file).with_index(1) do |line, number|
          parsed, note = classify(line)
          yield parsed, file, number, note if parsed || include_malformed
        end
      end
    end

    def classify(line)
      parsed = State.parse_line(line)
      return [parsed, nil] if parsed

      parsed = recovered_record(line)
      note = if parsed then "joined"
             elsif !record_like?(line) then "malformed"
             elsif line.end_with?("\n") then "torn"
             else "torn_tail"
             end
      [parsed, note]
    end

    def records
      list = []
      each_record { |entry, _| list << entry }
      list
    end

    def find(id)
      each_record { |entry, _| return entry if entry["id"] == id }
      nil
    end

    def each_recent(now = Time.now)
      cutoff = now - WINDOW_SECONDS
      each_record do |entry, _|
        stamp = stamp_of(entry)
        yield entry if stamp && stamp >= cutoff
      end
    end

    def recent(now = Time.now)
      list = []
      each_recent(now) { |entry| list << entry }
      list
    end

    def stamp_of(entry)
      Time.iso8601(entry["ts"].to_s)
    rescue ArgumentError
      nil
    end

    def rows(entries)
      entries.flat_map do |entry|
        tool = entry["action"].is_a?(Hash) ? entry["action"]["tool"] : nil
        Array(entry["targets"]).flat_map do |target|
          Array(target["rows"]).map { |row| row.merge("ts" => entry["ts"], "project" => target["project"], "tool" => tool) }
        end
      end
    end

    def verify(schema: true, full: false)
      snapshot = capture
      begin
        verify_snapshot(schema: schema, full: full, snapshot: snapshot)
      ensure
        snapshot["handles"].each(&:close)
      end
    end

    def verify_snapshot(schema: true, full: true, snapshot: nil)
      owned = snapshot.nil?
      snapshot ||= capture_files
      entries = snapshot["files"]
      walk = (full ? nil : resume(entries, schema)) || { "previous" => nil, "parent" => nil, "count" => 0, "joined" => 0, "last" => nil, "findings" => [], "interrupted" => [], "ids" => {}, "index" => 0, "offset" => 0, "lines" => 0 }
      kept = nil
      entries.each_with_index do |entry, index|
        next if index < walk["index"]

        walk["index"], walk["offset"], walk["lines"] = index, 0, 0 if index > walk["index"]
        final = index == entries.length - 1
        each_line_in(entry["handle"], walk["offset"], entry["size"]) do |line|
          kept = settled(walk) if final && !line.end_with?("\n")
          take(walk, line, "#{entry['name']}:#{walk['lines'] + 1}", schema)
          next if kept

          walk["offset"] += line.bytesize
          walk["lines"] += 1
        end
      end
      save_checkpoint(kept || settled(walk), entries, schema)
      findings = walk["findings"]
      interrupted = walk["interrupted"]
      count = walk["count"]
      last = walk["last"]
      head = snapshot["head"]
      anchored = count - interrupted.count { |item| item["kind"] == "interrupted_append" } - walk["joined"]
      if last && head.nil?
        findings << finding("truncated", last["id"], "the head anchor #{HEAD} is missing")
      elsif last && (head["digest"] != last["digest"] || head["count"].to_i != anchored)
        findings << finding("truncated", last["id"], "the head anchor records #{head['count']} records ending #{head['digest'].to_s[0, 12]}; the stream has #{anchored} ending #{last['digest'].to_s[0, 12]}")
      elsif last.nil? && head
        findings << finding("truncated", nil, "the head anchor records #{head['count']} records but the stream is empty")
      end
      known = acknowledged
      findings.each do |item|
        entry = item["id"] && known[item["id"]]
        item["acknowledged"] = entry if entry && entry["kind"] == item["kind"]
      end
      open = findings.reject { |item| item["acknowledged"] }
      { "ok" => open.empty?, "records" => count, "files" => entries.map { |entry| entry["name"] }, "findings" => findings, "interrupted" => interrupted, "stalled" => stalled, "skips" => skip_counts }
    ensure
      snapshot["handles"].each(&:close) if owned && snapshot
    end

    def finding(kind, id, detail)
      { "kind" => kind, "id" => id, "detail" => detail }
    end

    def skip_counts
      by_key = Hash.new(0)
      malformed = 0
      skip_files.each do |file|
        File.foreach(file) do |line|
          parsed = State.parse_line(line)
          parsed && parsed["key"].is_a?(String) ? by_key[parsed["key"]] += 1 : malformed += 1
        end
      end
      { "total" => by_key.values.sum, "by_key" => by_key, "malformed" => malformed, "files" => skip_files.map { |file| File.basename(file) } }
    end
  end
end
