#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "base"

module Polispec
  module Harness
    class Codex < Base
      def ask?
        false
      end
    end
  end
end
