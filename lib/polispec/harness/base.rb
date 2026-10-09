#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Harness
    Input = Struct.new(:tool_name, :tool_input, :cwd, :session_id, :agent_type, :event, keyword_init: true)

    class Base
      SHELL_TOOLS = %w[Bash bash shell exec_command terminal local_shell run_command execute_command].freeze
      EDIT_TOOLS = %w[Edit MultiEdit NotebookEdit patch edit_file str_replace_editor str_replace_based_edit_tool].freeze
      WRITE_TOOLS = %w[Write write_file create_file].freeze
      PATCH_TOOLS = %w[apply_patch].freeze
      PATH_KEYS = %w[file_path path filepath filename notebook_path].freeze
      INLINE_PROD = /\bgit\b.*\b(push|merge|tag|reset)\b.*\b(test|stable)\b|\bsystemctl\b|\bgh\s+release\b/.freeze

      attr_reader :name

      def initialize(name)
        @name = name.to_s
      end

      def ask?
        false
      end

      def parse(text)
        data = JSON.parse(text.to_s)
        raise Polispec::Error, "hook input is not a JSON object" unless data.is_a?(Hash)

        Input.new(
          tool_name: pick(data, %w[tool_name tool toolName]), tool_input: pick(data, %w[tool_input input arguments args toolInput]) || {},
          cwd: pick(data, %w[cwd workdir working_directory workingDirectory]), session_id: pick(data, %w[session_id sessionId session]),
          agent_type: pick(data, %w[agent_type agentType]), event: pick(data, %w[hook_event_name event])
        )
      end

      def calls(input)
        tool = input.tool_name.to_s
        data = input.tool_input.is_a?(Hash) ? input.tool_input : { "command" => input.tool_input.to_s }
        return [[tool, data]] if tool.empty?
        return patch_calls(data) if PATCH_TOOLS.include?(tool)

        [[canonical(tool), normalize(tool, data)]]
      end

      def shell?(input)
        SHELL_TOOLS.include?(input.tool_name.to_s)
      end

      def writer?(input)
        tool = input.tool_name.to_s
        EDIT_TOOLS.include?(tool) || WRITE_TOOLS.include?(tool) || PATCH_TOOLS.include?(tool)
      end

      def command_text(input)
        data = input.tool_input
        return data.to_s unless data.is_a?(Hash)

        shell_command(data).to_s
      end

      def render(verdict)
        case verdict.level.to_s
        when "deny" then decision("deny", reason_text(verdict))
        when "warn" then decision(ask? ? "ask" : "deny", reason_text(verdict))
        end
      end

      def render_deny(text)
        decision("deny", text)
      end

      def render_session(text, event)
        JSON.generate("hookSpecificOutput" => { "hookEventName" => event.to_s.empty? ? "SessionStart" : event, "additionalContext" => text })
      end

      def reason_text(verdict)
        head = verdict.warn? ? "[POLISPEC #{verdict.rule_id}] WARNING" : "[POLISPEC #{verdict.rule_id}] DENIED"
        text = "#{head}: #{verdict.reason}."
        text += " #{verdict.next_step}" if verdict.next_step
        text += warn_suffix(verdict) if verdict.warn?
        text
      end

      private

      def warn_suffix(verdict)
        return " This needs explicit user confirmation before it proceeds." if ask?

        id = verdict.allow_once_id
        return " Blocked until the user confirms." unless id

        " To proceed, the user runs `polispec allow-once #{id}` from an interactive terminal, then this exact call is retried once within 10 minutes. Never run that command yourself."
      end

      def decision(level, reason)
        JSON.generate("hookSpecificOutput" => { "hookEventName" => "PreToolUse", "permissionDecision" => level, "permissionDecisionReason" => reason })
      end

      def pick(data, keys)
        keys.each do |key|
          value = data[key]
          return value unless value.nil?
        end
        nil
      end

      def canonical(tool)
        return "Bash" if SHELL_TOOLS.include?(tool)
        return "Write" if WRITE_TOOLS.include?(tool)
        return "Edit" if EDIT_TOOLS.include?(tool) && !%w[MultiEdit NotebookEdit Edit].include?(tool)

        tool
      end

      def normalize(tool, data)
        return data.merge("command" => shell_command(data)) if SHELL_TOOLS.include?(tool)
        return data unless WRITE_TOOLS.include?(tool) || EDIT_TOOLS.include?(tool)
        return data if data["file_path"]

        key = PATH_KEYS.find { |candidate| data[candidate] }
        key ? data.merge("file_path" => data[key]) : data
      end

      def shell_command(data)
        command = data["command"] || data["cmd"] || data["script"]
        return command.to_s unless command.is_a?(Array)

        wrapped = command.length >= 3 && command[0].to_s =~ /\A(ba|z|)sh\z/ && command[1].to_s =~ /\A-\w*c\z/
        wrapped ? command[2].to_s : Shellwords.join(command.map(&:to_s))
      end

      def patch_calls(data)
        text = (data["input"] || data["patch"] || data["command"] || data["content"]).to_s
        paths = text.scan(/^\*\*\* (?:Update|Add|Delete) File: (.+)$/).flatten.map(&:strip)
        paths = [data["file_path"] || data["path"]].compact if paths.empty?
        paths.map { |path| ["Edit", { "file_path" => path }] }
      end
    end
  end
end
