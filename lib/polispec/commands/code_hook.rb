#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../code/core"

Polispec::CLI.register("code-hook", Polispec::Code::Hook, summary: "harness hook entry for code specs: pre, post, stop, session")
