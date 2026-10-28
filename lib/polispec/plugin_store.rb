#!/usr/bin/env ruby
# frozen_string_literal: true

# SPDX-License-Identifier: MIT

module Polispec
  module PluginStore
    module_function

    def home
      value = ENV["RPLUGINS_HOME"].to_s
      File.expand_path(value.empty? ? "~/.rplugins" : value)
    end

    def path(plugin_id)
      File.join(home, plugin_id.to_s)
    end

    def root(plugin_id)
      real = File.realpath(path(plugin_id))
      File.directory?(real) ? real : nil
    rescue SystemCallError
      nil
    end

    def version(root)
      file = File.join(root, "VERSION")
      File.file?(file) ? File.read(file).strip : nil
    rescue SystemCallError
      nil
    end

    def env_name(plugin_id)
      "POLISPEC_PLUGIN_#{plugin_id.to_s.upcase.tr('-', '_')}_ROOT"
    end

    def satisfies?(installed, requirement)
      return true if requirement.to_s.strip.empty?
      return false if installed.to_s.empty?

      Gem::Requirement.new(requirement.to_s).satisfied_by?(Gem::Version.new(installed))
    rescue ArgumentError
      false
    end
  end
end
