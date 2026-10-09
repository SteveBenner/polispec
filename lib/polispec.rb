#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "yaml"
require "time"
require "date"
require "digest"
require "fileutils"
require "shellwords"
require "open3"

module Polispec
  ID = "polispec"
  ROOT = File.expand_path("..", __dir__)
  LIB = File.join(ROOT, "lib", "polispec")

  ACTION_CLASSES = %w[
    git.commit git.push git.tag git.merge git.rewrite git.branch release.publish
    service.control service.config fs.write data.write data.copy secrets.read
    policy.edit promote deploy
  ].freeze
  ENVIRONMENTS = %w[dev test prod].freeze
  LEVELS = %w[allow warn deny].freeze

  class Error < StandardError; end

  def self.version
    @version ||= File.read(File.join(ROOT, "VERSION")).strip
  rescue SystemCallError
    "0.0.0"
  end

  autoload :Resolve, File.join(LIB, "resolve")
  autoload :PolicySource, File.join(LIB, "policy_source")
  autoload :Engine, File.join(LIB, "engine")
  autoload :Fastpath, File.join(LIB, "fastpath")
  autoload :Freeze, File.join(LIB, "freeze")
  autoload :Roster, File.join(LIB, "roster")
  autoload :Environments, File.join(LIB, "environments")
  autoload :AgentsRender, File.join(LIB, "agents_render")
  autoload :GitHook, File.join(LIB, "git_hook")

  module Operator
    autoload :Tty, File.join(LIB, "operator", "tty")
    autoload :Git, File.join(LIB, "operator", "git")
    autoload :Gates, File.join(LIB, "operator", "gates")
    autoload :Promote, File.join(LIB, "operator", "promote")
    autoload :Deploy, File.join(LIB, "operator", "deploy")
  end

  module Harness
    autoload :Claude, File.join(LIB, "harness", "claude")
    autoload :Codex, File.join(LIB, "harness", "codex")
    autoload :Generic, File.join(LIB, "harness", "generic")
  end
end

require_relative "polispec/types"
require_relative "polispec/state"
require_relative "polispec/events"
require_relative "polispec/schema/core"
require_relative "polispec/ledger"
require_relative "polispec/classify/registry"
require_relative "polispec/cli"
