#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "fileutils"

module Polispec
  module Trace
    module Logfile
      CAP = 8 * 1024 * 1024
      KEEP = 63
      MAX_AGE = 14 * 24 * 3600
      CLOSING = "# trace file stopped at 8 MiB".freeze

      class Handle
        attr_reader :path

        def initialize(io, path)
          @io = io
          @path = path
          @bytes = 0
          @stopped = false
        end

        def stopped?
          @stopped
        end

        def append(line, closing)
          return if @stopped

          if @bytes + line.bytesize > CAP
            @stopped = true
            @io.syswrite(closing)
            return
          end
          @io.syswrite(line)
          @bytes += line.bytesize
        rescue IOError, SystemCallError
          @stopped = true
        end

        def close
          @io.close unless @io.closed?
        rescue IOError, SystemCallError
          nil
        end
      end

      @failure = nil

      module_function

      def failure
        @failure
      end

      def open(mode, op)
        @failure = nil
        return nil unless Engine::Settings.verbose_trace?

        return nil unless File.directory?(State.home)

        dir = File.join(State.home, "trace")
        FileUtils.mkdir_p(dir, mode: 0o700)
        prune(dir)
        ext = mode == :json ? "ndjson" : "log"
        safe = op.to_s.downcase.gsub(/[^a-z0-9-]/, "-")
        path = File.join(dir, "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{safe}-#{Process.pid}.#{ext}")
        Handle.new(File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600), path)
      rescue StandardError, ScriptError => e
        @failure = e.class.name
        nil
      end

      def prune(dir)
        files = Dir.glob(File.join(dir, "*.{log,ndjson}")).map do |file|
          [file, File.mtime(file)]
        rescue SystemCallError
          nil
        end.compact
        cutoff = Time.now - MAX_AGE
        files.select { |_, mtime| mtime < cutoff }.each { |file, _| remove(file) }
        left = files.reject { |_, mtime| mtime < cutoff }.sort_by { |_, mtime| mtime }
        left.first([left.length - KEEP, 0].max).each { |file, _| remove(file) }
      rescue SystemCallError
        nil
      end

      def remove(file)
        File.delete(file)
      rescue SystemCallError
        nil
      end

      def write(handle, mode, line, elapsed, depth)
        return handle unless handle

        closing = mode == :json ? "#{Stream.json_line(elapsed, depth, 'info', 'message' => 'trace file stopped at 8 MiB', 'fields' => {})}\n" : "#{Stream.text_line(elapsed, depth, CLOSING)}\n"
        handle.append("#{line}\n", closing)
        handle
      end
    end
  end
end
