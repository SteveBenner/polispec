#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../../../polispec"
require_relative "../../author"
require_relative "../claude_session"
require_relative "../codex_session"

module Polispec
  module Author
    module Adapters
      class HarnessCli
        DEFAULT = { "harness" => "claude", "model" => "sonnet", "effort" => "medium" }.freeze
        ROLE = "spec-author".freeze
        SESSIONS = { "claude" => ClaudeSession, "codex" => CodexSession }.freeze

        Handle = Struct.new(:id, :session, :harness, :model, :effort)

        def initialize(plugin_id: nil, fallback: nil, root: nil, events: nil, **)
        end

        def open(context)
          spec = role_spec(context)
          klass = SESSIONS[spec["harness"]]
          raise Unavailable.new("harness_unsupported", "the spec-author role names harness #{spec['harness']}; author supports claude and codex") unless klass

          kind = context[:kind].to_s
          session = klass.new(id: (context[:session_id] || SecureRandom.uuid), roots: roots(context), model: spec["model"],
                              effort: spec["effort"], system_prompt: Prompt.system_prompt(kind, context))
          Handle.new(session.id, session, spec["harness"], spec["model"], spec["effort"])
        end

        def turn(handle, text, &emit)
          handle.session.turn(text, &emit)
        end

        def close(handle)
          handle.session.close
        end

        def role_spec(context)
          project = context[:project].to_s
          return DEFAULT.dup if project.empty?

          entry = Ledger.load.project(project)
          roster = entry ? PolicySource.load_roster(entry) : nil
          return DEFAULT.dup unless roster

          slot = Roster.resolve(roster, role: ROLE)["default"]
          DEFAULT.merge(slot.select { |key, value| DEFAULT.key?(key) && value.is_a?(String) })
        rescue Roster::Unknown
          DEFAULT.dup
        rescue StandardError
          DEFAULT.dup
        end

        def roots(context)
          list = [File.join(ROOT, "schemas"), File.join(ROOT, "modules"), File.join(ROOT, "examples")]
          project = context[:project].to_s
          unless project.empty?
            entry = Ledger.load.project(project) rescue nil
            list << File.expand_path(entry.repo) if entry && !entry.repo.to_s.empty?
          end
          shelf = shelf_dir
          list << shelf if shelf
          list.select { |path| File.exist?(path) }
        end

        def shelf_dir
          source = Layers.source
          return nil unless source

          source.kind == :dir ? source.root : source.repo
        rescue StandardError
          nil
        end
      end
    end

    register(BUILTIN, Adapters::HarnessCli)
  end
end
