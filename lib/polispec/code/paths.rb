#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    module Paths
      DEFAULT_REPO = "~/polispec-specs".freeze
      REPO_KEY = "polispec.code.specs_repo".freeze

      module_function

      def home
        require_relative "../harness_controls/plane"
        if defined?(HarnessControls::Plane) && HarnessControls::Plane.respond_to?(:path)
          protected_path = HarnessControls::Plane.path("home")
          return File.expand_path(protected_path) if protected_path
        end
        base = ENV["POLISPEC_HOME"].to_s
        File.expand_path(base.empty? ? "~/.polispec" : base)
      end

      def specs_link
        File.join(home, "specs")
      end

      def specs_repo
        require_relative "../harness_controls/plane"
        if defined?(HarnessControls::Plane) && HarnessControls::Plane.respond_to?(:path)
          protected_path = HarnessControls::Plane.path("code_specs_repo")
          return File.expand_path(protected_path) if protected_path
        end
        forced = ENV["POLISPEC_SPECS_REPO"].to_s
        return File.expand_path(forced) unless forced.empty?

        link = specs_link
        return File.dirname(File.realpath(link)) if File.symlink?(link) && File.exist?(link)

        File.expand_path(Engine::Settings.text(REPO_KEY, DEFAULT_REPO))
      end

      def state_dir
        require_relative "../harness_controls/plane"
        if defined?(HarnessControls::Plane) && HarnessControls::Plane.respond_to?(:path)
          protected_path = HarnessControls::Plane.path("code_state")
          return File.expand_path(protected_path) if protected_path
        end
        forced = ENV["POLISPEC_CODE_STATE"].to_s
        forced.empty? ? State.home : File.expand_path(forced)
      end

      def sessions_dir
        File.join(state_dir, "code", "sessions")
      end

      def baselines_dir
        File.join(state_dir, "baselines")
      end

      def pack_cache_dir
        File.join(State.cache_dir, "code")
      end

      def materialized_dir
        File.join(pack_cache_dir, "blobs")
      end
    end
  end
end
