#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Proof
    module Records
      UNSIGNED_KEYS = %w[signature prev hash].freeze

      module_function

      def path(root, feature)
        File.join(root, PROOFS_DIR, "#{feature}.jsonl")
      end

      def signed_body(record)
        Canonical.json(record.reject { |key, _| UNSIGNED_KEYS.include?(key) })
      end

      def identify(record)
        core = record.reject { |key, _| %w[id signature prev hash].include?(key) }
        { "schema" => SCHEMA, "id" => "prf_#{Canonical.sha256(Canonical.json(core))[0, 12]}" }.merge(core)
      end

      def append(root, record)
        file = path(root, record["feature"])
        FileUtils.mkdir_p(File.dirname(file))
        lock = lock_path(file)
        FileUtils.mkdir_p(File.dirname(lock), mode: 0o700)
        File.open(lock, File::RDWR | File::CREAT, 0o600) do |handle|
          handle.flock(File::LOCK_EX)
          linked = Chain.link(record.reject { |key, _| %w[prev hash].include?(key) }, last_hash(file))
          File.open(file, File::WRONLY | File::APPEND | File::CREAT, 0o644) do |out|
            out.syswrite("#{JSON.generate(linked)}\n")
            out.fsync
          end
          linked
        end
      end

      def read(root, feature)
        file = path(root, feature)
        return empty unless File.file?(file)

        parse(File.read(file), file)
      end

      def read_all(root)
        Dir.glob(File.join(root, PROOFS_DIR, "*.jsonl")).sort.to_h { |file| [File.basename(file, ".jsonl"), parse(File.read(file), file)] }
      end

      def at(git_dir, rev, feature)
        label = "#{rev}:#{PROOFS_DIR}/#{feature}.jsonl"
        out, _err, status = Trace.capture3("git", "-C", git_dir.to_s, "show", label, trace: :silent)
        return empty unless status.success?

        parse(out, label)
      end

      def parse(text, label)
        definition = Schema.definition("proof")
        records = []
        findings = []
        text.each_line.with_index(1) do |line, number|
          next if line.strip.empty?

          begin
            entry = JSON.parse(line)
          rescue JSON::ParserError => e
            findings << finding(label, number, "line is not JSON: #{e.message.lines.first.to_s.strip}")
            break
          end
          errors = Schema::Validator.new(definition).call(entry)
          unless errors.empty?
            findings << finding(label, number, "schema: #{errors.first.pointer} #{errors.first.message}")
            break
          end
          records << entry
        end
        broken = Chain.broken_at(records)
        if broken
          findings << finding(label, broken + 1, "prev or hash does not continue the chain")
          records = records.first(broken)
        end
        { "records" => records, "findings" => findings }
      end

      def empty
        { "records" => [], "findings" => [] }
      end

      def finding(label, line, detail)
        { "kind" => "chain_broken", "file" => label, "line" => line, "detail" => detail }
      end

      def last_hash(file)
        return nil unless File.file?(file)

        parsed = parse(File.read(file), file)
        broken = parsed["findings"].first
        raise Polispec::Error, "chain_broken: #{file} line #{broken['line']}: #{broken['detail']}; nothing appended, repair the file from git first" if broken

        parsed["records"].last&.fetch("hash")
      end

      def lock_path(file)
        real = File.join(File.realpath(File.dirname(file)), File.basename(file))
        File.join(State.home, "proof", "locks", "#{Canonical.sha256(real)}.lock")
      end
    end
  end
end
