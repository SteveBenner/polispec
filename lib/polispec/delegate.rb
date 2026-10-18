#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "yaml"
require "time"
require "digest"
require "fileutils"
require "securerandom"
require_relative "state"

module Polispec
  module Delegate
    VERBS = %w[promote deploy].freeze
    APP = /\A[a-z][a-z0-9_-]{0,31}\z/.freeze
    TOKEN_PREFIX = "pdt_"
    MAX_GRANTS = 16
    MAX_BYTES = 16_384
    FLAGS_DEFAULT = %w[--dry-run --json --tag].freeze
    FLAGS_ALLOWED = %w[--dry-run --json --tag --waive-soak --skip-drain].freeze
    SCHEMA = "polispec.delegate_grants/v1"

    class NoAnswer < Polispec::Error; end

    autoload :Grants, File.join(__dir__, "delegate", "grants")
    autoload :Run, File.join(__dir__, "delegate", "run")
    autoload :Server, File.join(__dir__, "delegate", "server")

    class << self
      attr_reader :via

      def via=(text)
        @via = text
      end

      def via_fields
        @via.nil? ? {} : { via: @via }
      end

      def dir
        File.join(State.home, "delegate")
      end

      def grants_path
        File.join(dir, "grants.yml")
      end

      def runs_dir
        File.join(dir, "runs")
      end

      def kill_marker
        File.join(dir, "delegate.disabled")
      end

      def socket_path
        runtime = ENV["XDG_RUNTIME_DIR"].to_s
        File.join(runtime.empty? ? State.home : runtime, "polispec", "delegate.sock")
      end

      def sealed?
        require_relative "runtime"
        require_relative "native_settings"
        Runtime.sealed? || NativeSettings.sealed?
      end
    end
  end
end
