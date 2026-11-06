#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "io/console"
require_relative "../delegate"
require_relative "../native_pin"
require_relative "../native_settings"
require_relative "../exceptions"

module Polispec
  module Operator
    module Tty
      class NotTty < Polispec::Error; end
      class PhraseMismatch < Polispec::Error; end

      AGENT_PROCESSES = %w[claude codex hermes gemini antigravity agy deepseek deepseek-tui pi].freeze
      MAX_ANCESTORS = 64

      module_function

      def delegate=(confirmer)
        @delegate = confirmer
      end

      def delegate
        @delegate
      end

      def delegated?
        !@delegate.nil?
      end

      def terminal?
        return true if delegated?
        return false if agent_ancestor && !confined?

        !console.nil? && $stdin.tty?
      end

      def agent_ancestor
        return "CLAUDECODE" unless ENV["CLAUDECODE"].to_s.empty?
        return nil unless File.directory?("/proc/self")

        pid = Process.ppid
        MAX_ANCESTORS.times do
          break if pid.nil? || pid <= 1

          stat = File.read("/proc/#{pid}/stat")
          comm = stat[(stat.index("(") + 1)...stat.rindex(")")]
          names = [comm] + File.binread("/proc/#{pid}/cmdline").split("\0").first(2).map { |word| File.basename(word) }
          found = names.find { |name| AGENT_PROCESSES.include?(name) }
          return found if found

          pid = stat[(stat.rindex(")") + 2)..].split[1].to_i
        end
        nil
      rescue SystemCallError, ArgumentError, TypeError, NoMethodError
        nil
      end

      def confined?
        root = ENV["POLISPEC_TTY_CONFINE"].to_s
        return false if root.empty? || !File.directory?(root)

        base = File.realpath(root)
        ledger = Ledger.load
        paths = [State.home, Ledger.default_path, NativePin.releases_dir, NativeSettings.path, Exceptions.path, ledger.envs_root, *ledger.projects.map(&:repo)]
        paths.compact.all? { |path| inside?(resolve(path), base) }
      rescue StandardError
        false
      end

      def resolve(path)
        expanded = File.expand_path(path.to_s)
        existing = expanded
        existing = File.dirname(existing) until File.exist?(existing) || existing == "/"
        File.join(File.realpath(existing), expanded[existing.length..].to_s)
      end

      def inside?(path, base)
        path == base || path.start_with?("#{base}/")
      end

      def confirm!(phrase, prompt: nil)
        Trace.step("waiting for the typed phrase on the terminal", phrase: phrase) do
          Trace.hold do
            next confirm_delegated!(phrase, prompt) if delegated?

            ancestor = agent_ancestor
            raise NotTty, "this action needs your own terminal; it was started under #{ancestor}, and an agent cannot confirm it" if ancestor && !confined?

            tty = console
            raise NotTty, "this action needs an interactive terminal (a TTY on stdin and a controlling console); an agent shell cannot run it" unless tty && $stdin.tty?

            tty.puts(prompt) if prompt
            tty.write("Type exactly: #{phrase}\n> ")
            typed = tty.gets
            raise PhraseMismatch, "the typed phrase did not match; nothing was done" unless typed && typed.chomp == phrase

            true
          end
        end
      end

      def confirm_delegated!(phrase, prompt)
        answer = @delegate.confirm(phrase, prompt)
        raise PhraseMismatch, "the typed phrase did not match; nothing was done" unless answer == true

        true
      rescue StandardError => e
        raise unless e.is_a?(Polispec::Delegate::NoAnswer)

        raise NotTty, "this action needs an interactive terminal (a TTY on stdin and a controlling console); an agent shell cannot run it"
      end

      def console
        IO.console
      rescue SystemCallError
        nil
      end
    end
  end
end
