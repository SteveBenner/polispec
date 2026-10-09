#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "io/console"

module Polispec
  module Operator
    module Tty
      class NotTty < Polispec::Error; end
      class PhraseMismatch < Polispec::Error; end

      module_function

      def terminal?
        !console.nil? && $stdin.tty?
      end

      def confirm!(phrase, prompt: nil)
        tty = console
        raise NotTty, "this action needs an interactive terminal (a TTY on stdin and a controlling console); an agent shell cannot run it" unless tty && $stdin.tty?

        tty.puts(prompt) if prompt
        tty.write("Type exactly: #{phrase}\n> ")
        typed = tty.gets
        raise PhraseMismatch, "the typed phrase did not match; nothing was done" unless typed && typed.chomp == phrase

        true
      end

      def console
        IO.console
      rescue SystemCallError
        nil
      end
    end
  end
end
