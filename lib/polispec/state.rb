#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module State
    LOGS = %w[pauses allow_once promotions deploys events].freeze

    module_function

    def home
      base = ENV["XDG_STATE_HOME"]
      base = File.join(Dir.home, ".local", "state") if base.nil? || base.empty?
      File.join(base, "polispec")
    end

    def cache_dir
      File.join(home, "cache")
    end

    def state_file
      File.join(home, "state.yml")
    end

    def log_path(name)
      File.join(home, "#{name.to_s.sub(/\.jsonl\z/, '')}.jsonl")
    end

    LOGS.each do |name|
      define_method("#{name}_log") { log_path(name) }
    end

    def ensure_dirs
      FileUtils.mkdir_p(home, mode: 0o700)
      FileUtils.mkdir_p(cache_dir, mode: 0o700)
      home
    end

    def append_jsonl(name, record)
      path = log_path(name)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      line = "#{JSON.generate(record)}\n"
      File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |file| file.syswrite(line) }
      record
    end

    def read_jsonl(name)
      path = log_path(name)
      return [] unless File.file?(path)

      File.foreach(path).filter_map { |line| parse_line(line) }
    end

    def parse_line(line)
      parsed = JSON.parse(line)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end
  end
end
