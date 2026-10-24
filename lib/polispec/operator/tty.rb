#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "io/console"
require_relative "../delegate"

module Polispec
  module Operator
    module Tty
      class NotTty < Polispec::Error; end
      class PhraseMismatch < Polispec::Error; end

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

        !console.nil? && $stdin.tty?
      end

      def confirm!(phrase, prompt: nil)
        Trace.step("waiting for the typed phrase on the terminal", phrase: phrase) do
          next confirm_delegated!(phrase, prompt) if delegated?

          tty = console
          raise NotTty, "this action needs an interactive terminal (a TTY on stdin and a controlling console); an agent shell cannot run it" unless tty && $stdin.tty?

          tty.puts(prompt) if prompt
          tty.write("Type exactly: #{phrase}\n> ")
          typed = tty.gets
          raise PhraseMismatch, "the typed phrase did not match; nothing was done" unless typed && typed.chomp == phrase

          true
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
