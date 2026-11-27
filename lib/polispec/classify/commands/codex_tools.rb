# frozen_string_literal: true
# SPDX-License-Identifier: MIT

require "uri"
require_relative "web_local"

module Polispec
  module Classify
    module CodexTools
      module_function

      def call(tool, input, cwd)
        hint = { "path" => cwd.to_s, "tool" => tool }
        case tool
        when "collaborationspawn_agent"
          [Action.new(class: "agent.spawn", env_hint: hint, raw: tool)]
        when "webrun"
          web_actions(input, hint)
        else
          []
        end
      end

      def web_actions(input, hint)
        unknown = Action.new(class: "tool.internal", env_hint: hint, raw: { "unknown_tool" => true, "tool" => hint["tool"] })
        return [unknown] unless input.is_a?(Hash)

        actions = []
        input.each do |operation, entries|
          next if operation == "response_length"
          unless %w[search_query open].include?(operation) && entries.is_a?(Array) && !entries.empty?
            actions << unknown
            next
          end
          entries.each do |entry|
            if operation == "search_query" && entry.is_a?(Hash) && entry["q"].is_a?(String) && !entry["q"].strip.empty?
              actions << Action.new(class: "web.fetch", env_hint: hint.merge("search" => true), raw: hint["tool"])
            elsif operation == "open" && entry.is_a?(Hash)
              actions.concat(open_actions(entry["ref_id"], hint, unknown))
            else
              actions << unknown
            end
          end
        end
        actions.empty? ? [unknown] : actions.uniq
      end

      def open_actions(reference, hint, unknown)
        unresolved = [Action.new(class: "web.fetch", env_hint: hint, raw: hint["tool"]), unknown]
        return unresolved unless reference.is_a?(String)

        uri = URI.parse(reference)
        return unresolved unless uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty? && !uri.userinfo

        fetch = Action.new(class: "web.fetch", env_hint: hint.merge("domain" => uri.hostname.downcase), raw: hint["tool"])
        guarded = WebLocal.web_tool(hint["tool"], { "url" => reference })
        [fetch, *guarded]
      rescue URI::InvalidURIError
        unresolved
      end
    end

    Registry.register("codex_tools", CodexTools)
  end
end
