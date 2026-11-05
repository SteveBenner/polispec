#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require "digest"
require "json"
require "openssl"
require "securerandom"

module Polispec
  module Exposure
    DIRECTORY = "exposure"
    KEY_NAME = "exposure.key"
    MAC_FIELD = "mac"
    COVERAGE_ERRORS = [SystemCallError, IOError, ArgumentError, TypeError, EncodingError, JSON::ParserError, OpenSSL::OpenSSLError].freeze
    EMPTY_TREE_ARGS =["hash-object", "-t", "tree", "/dev/null"].freeze

    module_function

    def audit_argv
      Engine::Settings.argv(Engine::Settings::EXPOSURE_AUDIT_KEY)
    end

    def key_path
      File.join(State.home, KEY_NAME)
    end

    def key(create: false)
      return File.binread(key_path) if File.file?(key_path)
      return nil unless create

      FileUtils.mkdir_p(State.home, mode: 0o700)
      begin
        File.open(key_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(SecureRandom.hex(32)) }
      rescue Errno::EEXIST
        nil
      end
      File.binread(key_path)
    end

    def canonical(record)
      JSON.generate(record.reject { |name, _| name == MAC_FIELD }.sort.to_h)
    end

    def mac_for(record, secret)
      OpenSSL::HMAC.hexdigest("SHA256", secret, canonical(record))
    end

    def valid_mac?(record, secret)
      given = record[MAC_FIELD]
      return false unless secret && given.is_a?(String)

      expected = mac_for(record, secret)
      given.bytesize == expected.bytesize && given.bytes.zip(expected.bytes).sum { |left, right| left ^ right }.zero?
    end

    def program_dirs
      [File.join(Dir.home, ".local", "bin"), File.join(Dir.home, ".rplugin", "bin"), "/usr/local/bin", "/usr/bin", "/bin"]
    end

    def resolved_command(argv = audit_argv)
      head = argv.first.to_s
      return nil if head.empty?

      return nil if head.include?("\0")

      candidate = head.include?("/") ? File.expand_path(head) : program_dirs.map { |dir| File.join(dir, head) }.find { |path| File.file?(path) && File.executable?(path) }
      candidate && File.file?(candidate) && File.executable?(candidate) ? candidate : nil
    rescue ArgumentError, SystemCallError
      nil
    end

    def command_digest(argv = audit_argv)
      resolved = resolved_command(argv)
      return Digest::SHA256.hexdigest((argv + ["\0unresolved"]).join("\0")) unless resolved

      Digest::SHA256.hexdigest([resolved, Digest::SHA256.file(resolved).hexdigest, *argv.drop(1).flat_map { |arg| program_argument(arg) }].join("\0"))
    rescue SystemCallError, ArgumentError
      Digest::SHA256.hexdigest((argv + ["\0unreadable"]).join("\0"))
    end

    def program_argument(arg)
      text = arg.to_s
      text.start_with?("/") && File.file?(text) ? [text, Digest::SHA256.file(text).hexdigest] : [text]
    rescue SystemCallError, ArgumentError
      [text]
    end

    def repo_id(normalized)
      normalized.to_s.gsub(/[^A-Za-z0-9._-]/, "_")
    end

    def log_name(normalized)
      File.join(DIRECTORY, repo_id(normalized))
    end

    def empty_tree(dir)
      Predicates.git_ok(dir, *EMPTY_TREE_ARGS)
    end

    def records(normalized)
      secret = key
      State.read_jsonl(log_name(normalized)).select { |record| valid_mac?(record, secret) }
    end

    def append(normalized, record)
      record = record.merge(MAC_FIELD => mac_for(record, key(create: true)))
      path = State.log_path(log_name(normalized))
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |file| file.syswrite("#{JSON.generate(record)}\n") }
      end
      record
    end

    def current(normalized)
      return [] unless resolved_command

      digest = command_digest
      records(normalized).select { |record| record["command_digest"] == digest }
    rescue *COVERAGE_ERRORS
      []
    end

    def covers_branch?(normalized, remote, ref, to)
      current(normalized).any? { |record| record["remote"] == remote && record["ref"] == ref && record["to"] == to }
    rescue *COVERAGE_ERRORS
      false
    end

    def covers_commit?(normalized, commit)
      current(normalized).any? { |record| record["to"] == commit }
    rescue *COVERAGE_ERRORS
      false
    end
  end
end
