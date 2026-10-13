#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "plane"

module Polispec
  module HarnessControls
    module OperatorRecords
      ROOT = "/var/lib/polispec"
      STREAM = /\A[a-z][a-z0-9_]{0,63}\z/
      MAX_LINE = 262_144
      MAX_STREAM = 16_777_216
      MAX_ROWS = 10_000

      module_function

      def append(stream, record, identity:)
        name = stream_name(stream)
        raise Authority::Failure.new("invalid_record", "operator record must be an object") unless record.is_a?(Hash)
        actual = Plane.operator!("operator_records.append.#{name}")
        supplied = stringify(identity)
        unless supplied["provenance_digest"] == actual["provenance_digest"] && supplied["generation"] == actual["generation"]
          raise Authority::Failure.new("operator_required", "operator identity does not match current protected executable provenance")
        end
        FileUtils.mkdir_p(ROOT, mode: 0o700)
        findings = Authority.protection_findings(ROOT, "operator_records")
        raise Authority::Failure.new("operator_records_unsafe", "operator record root is not protected", findings) unless findings.empty?
        path = stream_path(name)
        authenticated = stringify(record).merge(
          "authorization" => {
            "caller_operation" => supplied["operation"],
            "append_operation" => actual["operation"],
            "generation" => actual["generation"],
            "provenance_digest" => actual["provenance_digest"],
            "euid" => actual["euid"]
          }
        )
        line = JSON.generate(Authority.canonical_value(authenticated)) + "\n"
        raise Authority::Failure.new("record_too_large", "operator record exceeds #{MAX_LINE} bytes") if line.bytesize > MAX_LINE
        flags = File::WRONLY | File::APPEND | File::CREAT
        flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
        File.open(path, flags, 0o600) do |file|
          file.flock(File::LOCK_EX)
          stat = file.stat
          safe = stat.file? && stat.uid.zero? && (stat.mode & 0o077).zero? && stat.nlink == 1
          raise Authority::Failure.new("operator_records_unsafe", "operator record stream must be a root-owned regular 0600 file with one link") unless safe
          raise Authority::Failure.new("operator_records_full", "operator record stream exceeds #{MAX_STREAM} bytes") if stat.size + line.bytesize > MAX_STREAM
          file.syswrite(line)
          file.flush
          file.fsync
        end
        authenticated
      rescue Errno::ELOOP
        raise Authority::Failure.new("operator_records_unsafe", "operator record stream cannot be a symlink")
      end

      def read(stream)
        name = stream_name(stream)
        path = stream_path(name)
        return [] unless File.exist?(path) || File.symlink?(path)
        findings = Authority.protection_findings(path, "operator_records")
        raise Authority::Failure.new("operator_records_unsafe", "operator record stream ancestry is not protected", findings) unless findings.empty?
        stat = File.lstat(path)
        raise Authority::Failure.new("operator_records_unsafe", "operator record stream is not a regular protected file") unless stat.file? && !stat.symlink? && stat.uid.zero? && (stat.mode & 0o077).zero? && stat.nlink == 1
        raise Authority::Failure.new("operator_records_full", "operator record stream exceeds #{MAX_STREAM} bytes") if stat.size > MAX_STREAM
        rows = []
        File.open(path, File::RDONLY) do |file|
          file.flock(File::LOCK_SH)
          file.each_line do |line|
            raise Authority::Failure.new("operator_records_invalid", "operator record line exceeds #{MAX_LINE} bytes") if line.bytesize > MAX_LINE
            raise Authority::Failure.new("operator_records_full", "operator record stream exceeds #{MAX_ROWS} rows") if rows.length >= MAX_ROWS
            value = JSON.parse(line)
            raise Authority::Failure.new("operator_records_invalid", "operator record line must contain an object") unless value.is_a?(Hash)
            rows << stringify(value)
          rescue JSON::ParserError => error
            raise Authority::Failure.new("operator_records_invalid", "operator record stream is malformed: #{error.message}")
          end
        end
        rows
      end

      def stream_path(name)
        File.join(ROOT, "#{name}.jsonl")
      end
      private_class_method :stream_path

      def stream_name(stream)
        name = stream.to_s
        raise Authority::Failure.new("invalid_stream", "invalid operator record stream") unless STREAM.match?(name)
        name
      end
      private_class_method :stream_name

      def stringify(value)
        return {} unless value.is_a?(Hash)
        value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
      end
      private_class_method :stringify
    end
  end
end
