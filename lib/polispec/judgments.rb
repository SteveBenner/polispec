#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "canonical"
require_relative "runtime"

module Polispec
  module Judgments
    SCHEMA = "polispec.judgment/v1"
    EVENT = "polispec.judgment"
    STREAM = "judgments"
    SKIPS = "skips"
    HEAD = "judgments.head.json"
    LOCK = "judgments.lock"
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
      Events.emit("polispec.finding", project: nil, kind: "judgment_unrecorded", detail: "#{error.class}: #{error.message.to_s[0, 200]}", policy_source: nil)
      nil
    rescue StandardError
      nil
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
        File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |file| file.syswrite("#{JSON.generate(entry)}\n") }
        write_head("digest" => entry["digest"], "count" => (head ? head["count"].to_i : 0) + 1, "file" => File.basename(path))
        rotate_skips
        entry
      end
    end

    def read_head
      stored = head_file
      tail = tail_digest
      return stored if stored && (tail.nil? || tail == stored["digest"])
      return nil unless tail
      return { "digest" => tail, "count" => count_records, "file" => File.basename(path) } unless stored

      ahead = ahead_of(stored["digest"])
      return stored if ahead.empty?

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
      parsed = State.parse_line(tail_lines.last.to_s)
      parsed && parsed["digest"].is_a?(String) ? parsed["digest"] : nil
    rescue SystemCallError
      nil
    end

    def tail_records
      tail_lines.filter_map do |line|
        parsed = State.parse_line(line)
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
      chunk.split("\n").reject { |text| text.strip.empty? }
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

    def each_record
      files.each do |file|
        File.foreach(file) do |line|
          parsed = State.parse_line(line)
          yield parsed, file if parsed
        end
      end
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

    def recent(now = Time.now)
      cutoff = now - WINDOW_SECONDS
      records.select { |entry| stamp_of(entry) && stamp_of(entry) >= cutoff }
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

    def verify(schema: true)
      findings = []
      interrupted = []
      previous = nil
      parent = nil
      seen = {}
      count = 0
      last = nil
      each_record do |entry, _|
        count += 1
        id = entry["id"]
        Schema.validate("judgment", entry).each { |error| findings << finding("schema", id, "#{error.pointer.empty? ? '/' : error.pointer} #{error.message}") } if schema
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
        last = entry
      end
      head = head_file
      anchored = count - interrupted.length
      if last && head.nil?
        findings << finding("truncated", last["id"], "the head anchor #{HEAD} is missing")
      elsif last && (head["digest"] != last["digest"] || head["count"].to_i != anchored)
        findings << finding("truncated", last["id"], "the head anchor records #{head['count']} records ending #{head['digest'].to_s[0, 12]}; the stream has #{anchored} ending #{last['digest'].to_s[0, 12]}")
      elsif last.nil? && head
        findings << finding("truncated", nil, "the head anchor records #{head['count']} records but the stream is empty")
      end
      { "ok" => findings.empty?, "records" => count, "files" => files.map { |file| File.basename(file) }, "findings" => findings, "interrupted" => interrupted, "skips" => skip_counts }
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
