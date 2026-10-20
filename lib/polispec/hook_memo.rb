#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module HookMemo
    SLOT = :polispec_policy_memo

    module_function

    def active?
      Thread.current[SLOT].is_a?(Hash)
    end

    def fetch(*key)
      memo = Thread.current[SLOT]
      return yield unless memo.is_a?(Hash)

      full = [:hook_memo, *key]
      return memo[full] if memo.key?(full)

      memo[full] = yield
    end

    def copy(*key)
      value = fetch(*key) { yield }
      active? ? Marshal.load(Marshal.dump(value)) : value
    end
  end
end
