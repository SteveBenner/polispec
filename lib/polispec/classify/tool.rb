#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "commands/support"

module Polispec
  module Classify
    module Tool
      WRITE_TOOLS = %w[edit write multiedit notebookedit str_replace_editor str_replace_based_edit_tool create_file write_file edit_file replace_in_file replace insert_edit_into_file].freeze
      READ_TOOLS = %w[read notebookread read_file view grep search_file_content read_many_files].freeze
      PATCH_TOOLS = %w[apply_patch applypatch patch].freeze
      PATH_KEYS = %w[file_path notebook_path path filepath target_file file absolute_path filename].freeze
      PATCH_LINE = /^\*\*\* (?:Add|Update|Delete) File:\s*(.+?)\s*$|^\*\*\* Move to:\s*(.+?)\s*$/.freeze

      module_function

      def call(tool_name, tool_input, cwd)
        name = tool_name.to_s.downcase
        cwd = Dir.pwd if cwd.to_s.empty?
        if WRITE_TOOLS.include?(name)
          write_paths(tool_input).filter_map { |path| write(path, name, cwd, tool_input) }
        elsif PATCH_TOOLS.include?(name)
          patch_paths(tool_input).filter_map { |path| write(path, name, cwd) }
        elsif READ_TOOLS.include?(name)
          read_paths(tool_input).filter_map { |path| Support.read_action(Support.abs(path, cwd), name) }
        else
          []
        end
      end

      def write(path, name, cwd, input = nil)
        Support.write_action(Support.abs(path, cwd), name, {}, input)
      end

      def write_paths(input)
        value = Support.dig(input, *PATH_KEYS)
        value.is_a?(String) && !value.empty? ? [value] : []
      end

      def read_paths(input)
        write_paths(input)
      end

      def patch_paths(input)
        text = input.is_a?(Hash) ? Array(Support.dig(input, "input", "patch", "command", "diff")).flatten.join("\n") : input.to_s
        text.scan(PATCH_LINE).flatten.compact.uniq
      end
    end

    Registry.register("tool", Tool)
  end
end
