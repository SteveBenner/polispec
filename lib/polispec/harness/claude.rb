#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "base"

module Polispec
  module Harness
    class Claude < Base
      def ask?
        true
      end
    end
  end
end
