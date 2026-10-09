#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    module Diff
      MAX_CELLS = 1_000_000

      module_function

      def changed_lines(before, after)
        old = before.to_s.lines.map(&:chomp)
        new = after.to_s.lines.map(&:chomp)
        head = 0
        head += 1 while head < old.length && head < new.length && old[head] == new[head]
        tail = 0
        tail += 1 while tail < old.length - head && tail < new.length - head && old[old.length - 1 - tail] == new[new.length - 1 - tail]
        middle_old = old[head...(old.length - tail)]
        middle_new = new[head...(new.length - tail)]
        offset = head + 1
        return Set.new if middle_new.empty?
        return Set.new((offset...(offset + middle_new.length)).to_a) if middle_old.empty? || middle_old.length * middle_new.length > MAX_CELLS

        kept = lcs_kept(middle_old, middle_new)
        changed = Set.new
        middle_new.each_index { |index| changed << (offset + index) unless kept.include?(index) }
        changed
      end

      def lcs_kept(left, right)
        ids = {}
        a = left.map { |line| ids[line] ||= ids.length }
        b = right.map { |line| ids[line] ||= ids.length }
        rows = Array.new(a.length + 1) { Array.new(b.length + 1, 0) }
        (a.length - 1).downto(0) do |i|
          (b.length - 1).downto(0) do |j|
            rows[i][j] = a[i] == b[j] ? rows[i + 1][j + 1] + 1 : [rows[i + 1][j], rows[i][j + 1]].max
          end
        end
        kept = Set.new
        i = 0
        j = 0
        while i < a.length && j < b.length
          if a[i] == b[j]
            kept << j
            i += 1
            j += 1
          elsif rows[i + 1][j] >= rows[i][j + 1]
            i += 1
          else
            j += 1
          end
        end
        kept
      end
    end

    module Edit
      Change = Struct.new(:path, :before, :after, :lines, :skip, :notebook, :language_hint, keyword_init: true)
      WRITE_TOOLS = %w[Write write_file create_file].freeze
      EDIT_TOOLS = %w[Edit edit_file str_replace_editor str_replace_based_edit_tool patch].freeze
      MULTI_TOOLS = %w[MultiEdit].freeze
      NOTEBOOK_TOOLS = %w[NotebookEdit].freeze
      PATCH_TOOLS = %w[apply_patch].freeze
      MAX_BYTES = 2_000_000

      module_function

      def tool?(name)
        all = WRITE_TOOLS + EDIT_TOOLS + MULTI_TOOLS + NOTEBOOK_TOOLS + PATCH_TOOLS
        all.include?(name.to_s)
      end

      def simulate(tool, input, cwd)
        input = {} unless input.is_a?(Hash)
        tool = tool.to_s
        return patch_changes(input, cwd) if PATCH_TOOLS.include?(tool)
        return [notebook_change(input, cwd)] if NOTEBOOK_TOOLS.include?(tool)

        path = resolve(path_of(input), cwd)
        return [] if path.nil?

        before = existing(path)
        after =
          if WRITE_TOOLS.include?(tool) || input.key?("content") && !input.key?("old_string")
            input["content"].to_s
          elsif MULTI_TOOLS.include?(tool) || input["edits"].is_a?(Array)
            apply_edits(before, input["edits"])
          else
            apply_edits(before, [input])
          end
        return [Change.new(path: path, before: before.to_s, after: nil, lines: Set.new, skip: "edit does not apply")] if after.nil?
        return [Change.new(path: path, before: before.to_s, after: after, lines: Set.new, skip: "file too large")] if after.bytesize > MAX_BYTES

        [Change.new(path: path, before: before.to_s, after: after, lines: Diff.changed_lines(before, after))]
      end

      def target_paths(tool, input, cwd)
        input = {} unless input.is_a?(Hash)
        if PATCH_TOOLS.include?(tool.to_s)
          text = patch_text(input)
          return [] unless text

          return parse_patch(text).reject { |entry| entry[:op] == "Delete" }.map { |entry| resolve(entry[:move] || entry[:path], cwd) }.compact
        end
        [resolve(path_of(input), cwd)].compact
      end

      def path_of(input)
        %w[file_path path filepath filename notebook_path].each do |key|
          return input[key].to_s if input[key].is_a?(String) && !input[key].empty?
        end
        nil
      end

      def resolve(path, cwd)
        return nil if path.nil? || path.empty?

        File.expand_path(path, cwd.to_s.empty? ? Dir.pwd : cwd)
      end

      def existing(path)
        File.file?(path) ? File.read(path) : nil
      rescue SystemCallError
        nil
      end

      def apply_edits(before, edits)
        text = before.nil? ? nil : before.dup
        Array(edits).each do |edit|
          return nil unless edit.is_a?(Hash)

          old = edit["old_string"].to_s
          replacement = edit["new_string"].to_s
          if old.empty?
            text = (text || "") + replacement if text.nil? || text.empty?
            return nil if text.nil?

            next
          end
          return nil if text.nil?

          count = text.scan(old).length
          return nil if count.zero?
          return nil if count > 1 && edit["replace_all"] != true

          text = edit["replace_all"] == true ? text.gsub(old) { replacement } : text.sub(old) { replacement }
        end
        text
      end

      def notebook_change(input, cwd)
        path = resolve(path_of(input), cwd)
        cell = input["cell_type"].to_s
        hint = cell == "markdown" ? "markdown" : notebook_language(path)
        Change.new(path: path, before: "", after: input["new_source"].to_s, lines: Set.new, skip: "notebook cell", notebook: true, language_hint: hint)
      end

      def notebook_language(path)
        data = JSON.parse(File.read(path))
        name = data.dig("metadata", "language_info", "name") || data.dig("metadata", "kernelspec", "language")
        name.to_s.empty? ? "python" : name.to_s.downcase
      rescue SystemCallError, JSON::ParserError, TypeError
        "python"
      end

      def patch_text(input)
        candidates = [input["input"], input["patch"], input["content"], input["command"], input["cmd"]]
        candidates.each do |value|
          text = value.is_a?(Array) ? value.map(&:to_s).find { |item| item.include?("*** Begin Patch") } : value.to_s
          return text if text && text.include?("*** Begin Patch")
        end
        nil
      end

      def patch_changes(input, cwd)
        text = patch_text(input)
        return [] unless text

        files = parse_patch(text)
        files.map { |entry| patch_change(entry, cwd) }.compact
      end

      def parse_patch(text)
        entries = []
        current = nil
        text.each_line do |raw|
          line = raw.chomp
          if (m = line.match(/\A\*\*\* (Add|Update|Delete) File: (.+)\z/))
            current = { op: m[1], path: m[2].strip, hunks: [], add: [] }
            entries << current
          elsif line.start_with?("*** Move to:")
            current[:move] = line.sub("*** Move to:", "").strip if current
          elsif line.start_with?("*** End Patch", "*** Begin Patch")
            current = nil if line.start_with?("*** End Patch")
          elsif current
            patch_line(current, line)
          end
        end
        entries
      end

      def patch_line(entry, line)
        if entry[:op] == "Add"
          entry[:add] << line[1..-1].to_s if line.start_with?("+")
        elsif entry[:op] == "Update"
          if line.start_with?("@@")
            entry[:hunks] << []
          else
            entry[:hunks] << [] if entry[:hunks].empty?
            entry[:hunks].last << line
          end
        end
      end

      def patch_change(entry, cwd)
        path = resolve(entry[:move] || entry[:path], cwd)
        return nil if entry[:op] == "Delete" || path.nil?

        if entry[:op] == "Add"
          after = entry[:add].join("\n") + "\n"
          return Change.new(path: path, before: "", after: after, lines: Diff.changed_lines("", after))
        end

        source = resolve(entry[:path], cwd)
        before = existing(source)
        return Change.new(path: path, before: "", after: nil, lines: Set.new, skip: "patch target missing") if before.nil?

        after = apply_hunks(before, entry[:hunks])
        return Change.new(path: path, before: before, after: nil, lines: Set.new, skip: "patch does not apply") if after.nil?

        Change.new(path: path, before: before, after: after, lines: Diff.changed_lines(before, after))
      end

      def apply_hunks(before, hunks)
        text = before.dup
        cursor = 0
        hunks.each do |hunk|
          old = hunk.select { |line| line.start_with?(" ", "-") || line.empty? }.map { |line| line[1..-1].to_s }
          new = hunk.select { |line| line.start_with?(" ", "+") || line.empty? }.map { |line| line[1..-1].to_s }
          if old.empty?
            text += "\n" unless text.end_with?("\n") || text.empty?
            text += new.join("\n") + "\n"
            cursor = text.length
            next
          end
          old_text = old.join("\n")
          index = text.index(old_text, cursor) || text.index(old_text)
          return nil unless index

          new_text = new.join("\n")
          text = text[0, index] + new_text + text[(index + old_text.length)..-1].to_s
          cursor = index + new_text.length
        end
        text
      end
    end
  end
end
