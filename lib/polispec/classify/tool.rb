#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "commands/support"

module Polispec
  module Classify
    module Tool
      WRITE_TOOLS = %w[edit write multiedit notebookedit str_replace_editor str_replace_based_edit_tool create_file write_file edit_file replace_in_file replace insert_edit_into_file].freeze
      DELETE_TOOLS = %w[delete delete_file remove_file].freeze
      READ_TOOLS = %w[read notebookread read_file view grep search_file_content read_many_files].freeze
      PATCH_TOOLS = %w[apply_patch applypatch patch].freeze
      PATH_KEYS = %w[file_path notebook_path path filepath target_file file absolute_path filename].freeze
      PATCH_FILE = /^\*\*\* (Add|Update|Delete) File:\s*(.+?)\s*$/.freeze
      PATCH_MOVE = /^\*\*\* Move to:\s*(.+?)\s*$/.freeze

      module_function

      def call(tool_name, tool_input, cwd)
        name = tool_name.to_s.downcase
        cwd = Dir.pwd if cwd.to_s.empty?
        if DELETE_TOOLS.include?(name)
          write_paths(tool_input).map { |path| Support.act("fs.delete", "#{name} #{Support.abs(path, cwd)}", "path" => Support.abs(path, cwd)) }
        elsif WRITE_TOOLS.include?(name)
          write_paths(tool_input).map { |path| write(path, name, cwd, tool_input) }.compact
        elsif PATCH_TOOLS.include?(name)
          patch_changes(tool_input).flat_map do |change|
            rows = []
            rows << Support.act("fs.delete", "#{name} #{Support.abs(change["old"], cwd)}", "path" => Support.abs(change["old"], cwd)) if change["delete"]
            rows << write(change["new"], name, cwd) if change["new"]
            rows.compact
          end
        elsif READ_TOOLS.include?(name)
          read_paths(tool_input).map { |path| Support.read_action(Support.abs(path, cwd), "#{name} #{Support.abs(path, cwd)}") }.compact
        else
          []
        end
      end

      def write(path, name, cwd, input = nil)
        target = Support.abs(path, cwd)
        Support.write_action(target, "#{name} #{target}", {}, input)
      end

      def write_paths(input)
        if input.is_a?(Hash) && input["edits"].is_a?(Array)
          edits = input["edits"]
          return [] if edits.empty? || edits.length > Harness::Base::MULTI_LIMIT
          return edits.map { |entry| entry.is_a?(Hash) ? Support.dig(entry, *PATH_KEYS) : nil }.select { |value| value.is_a?(String) && !value.empty? }
        end
        value = Support.dig(input, *PATH_KEYS)
        value.is_a?(String) && !value.empty? ? [value] : []
      end

      def read_paths(input)
        write_paths(input)
      end

      def patch_paths(input)
        patch_changes(input).flat_map { |change| [change["old"], change["new"]] }.compact.uniq
      end

      def patch_changes(input)
        text = input.is_a?(Hash) ? Array(Support.dig(input, "input", "patch", "command", "diff")).flatten.join("\n") : input.to_s
        changes = []
        current = nil
        text.each_line do |line|
          if (match = PATCH_FILE.match(line))
            kind = match[1]
            path = match[2]
            current = { "old" => kind == "Add" ? nil : path, "new" => kind == "Delete" ? nil : path, "delete" => kind == "Delete" }
            changes << current
          elsif current && (match = PATCH_MOVE.match(line))
            current["new"] = match[1]
            current["delete"] = true
          end
        end
        if changes.empty?
          path = input.is_a?(Hash) && Support.dig(input, "file_path", "path")
          changes << { "old" => path, "new" => path, "delete" => false } if path
        end
        changes
      end
    end

    Registry.register("tool", Tool)
  end
end
