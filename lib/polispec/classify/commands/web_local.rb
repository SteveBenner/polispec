#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require_relative "support"

module Polispec
  module Classify
    module WebLocal
      extend Support::Family

      NAMES = %w[curl wget http https xh].freeze
      WEB_TOOLS = %w[webfetch web_fetch].freeze
      LOCAL_URL = %r{\A(?:[a-z][a-z0-9+.-]*://)?(?:127\.0\.0\.1|localhost|\[::1\]|0\.0\.0\.0)(?::\d+)?(?:[/?#]|\z)}i.freeze
      SAFE_METHODS = %w[GET HEAD].freeze
      CURL_BODY_FLAGS = %w[-d -F -T --json --form --upload-file].freeze
      CURL_BODY_PREFIXES = %w[--data --form-string].freeze
      WGET_BODY_FLAGS = %w[--post-data --post-file --body-data --body-file].freeze
      GUARDED_PREFIXES = %w[/api/v1/exceptions/ /api/v1/author /api/v1/state /api/v1/register /api/v1/session].freeze
      PLAN_APPLY = %r{\A/api/v1/plans/[^/]+/apply/?\z}.freeze
      HTTPIE_DATA = /\A[^=:@\s]+(?::=|=@|=)/.freeze
      HTTPIE_QUERY = /\A[^=\s]+==/.freeze
      METHOD_WORD = /\A[A-Za-z]+\z/.freeze

      class << self
        def call(tool_name, tool_input, cwd)
          return web_tool(tool_name, tool_input) if WEB_TOOLS.include?(tool_name.to_s.downcase)

          super
        end

        def classify(cmd)
          url = cmd.args.map(&:to_s).find { |arg| web_url?(arg) }
          return [] unless url

          uri = parse(url)
          return [] unless uri

          path = uri.path.to_s.empty? ? "/" : uri.path
          action(cmd.text, uri, path, mutating?(cmd, url) || guarded?(path))
        end

        def web_tool(tool_name, tool_input)
          url = Support.dig(tool_input, "url", "uri").to_s
          uri = web_url?(url) ? parse(url) : nil
          return [] unless uri

          path = uri.path.to_s.empty? ? "/" : uri.path
          guarded?(path) ? action(tool_name.to_s, uri, path, true) : []
        end

        def action(raw, uri, path, edit)
          hint = { "domain" => uri.host.to_s.delete("[]").downcase, "port" => uri.port, "url_path" => path }
          return [Support.act("web.fetch", raw, hint)] unless edit

          [Support.act("policy.edit", raw, hint.merge("shape" => ["web_local"]))]
        end

        def parse(text)
          require "uri"
          text = "http://#{text}" unless text.include?("://")
          URI.parse(text)
        rescue URI::InvalidURIError
          nil
        end

        def local_port?(port)
          return false if port.nil?

          [configured_port, running_port].compact.include?(port)
        end

        def web_url?(text)
          return false unless LOCAL_URL.match?(text) || text.match?(%r{\Ahttps://}i)

          uri = parse(text)
          return false unless uri
          return true if LOCAL_URL.match?(text) && local_port?(uri.port)

          configured = Engine::Settings.web_public_origin
          [configured, running_origin].compact.any? do |origin|
            public_uri = parse(origin)
            public_uri && public_uri.scheme == "https" && uri.scheme == public_uri.scheme &&
              uri.host.to_s.downcase == public_uri.host.to_s.downcase && uri.port == public_uri.port
          end
        rescue StandardError
          false
        end

        def running_origin
          data = JSON.parse(File.read(File.join(State.home, "web", "server.json")))
          data.is_a?(Hash) ? data["public_origin"] : nil
        rescue SystemCallError, JSON::ParserError
          nil
        end

        def configured_port
          Engine::Settings.web_port
        rescue StandardError
          nil
        end

        def running_port
          data = JSON.parse(File.read(File.join(State.home, "web", "server.json")))
          data.is_a?(Hash) && data["port"].is_a?(Integer) ? data["port"] : nil
        rescue SystemCallError, JSON::ParserError
          nil
        end

        def guarded?(path)
          PLAN_APPLY.match?(path) || GUARDED_PREFIXES.any? { |prefix| path.start_with?(prefix) }
        end

        def mutating?(cmd, url)
          case cmd.name
          when "curl" then curl?(cmd.args.map(&:to_s))
          when "wget" then wget?(cmd.args.map(&:to_s))
          else httpie?(cmd.args.map(&:to_s), url)
          end
        end

        def curl?(args)
          method = Support.option_value(args, "-X", "--request")
          method ||= args.find { |arg| arg.match?(/\A-X./) }&.sub("-X", "")
          return true if method && !SAFE_METHODS.include?(method.upcase)

          args.any? do |arg|
            CURL_BODY_FLAGS.include?(arg) || CURL_BODY_PREFIXES.any? { |prefix| arg.start_with?(prefix) } || arg.match?(/\A-[dFT]./)
          end
        end

        def wget?(args)
          method = Support.option_value(args, "--method")
          return true if method && !SAFE_METHODS.include?(method.upcase)

          args.any? { |arg| WGET_BODY_FLAGS.any? { |flag| arg == flag || arg.start_with?("#{flag}=") } }
        end

        def httpie?(args, url)
          index = args.index(url)
          before = index ? args.first(index) : []
          after = index ? args.drop(index + 1) : []
          verb = before.find { |arg| METHOD_WORD.match?(arg) }
          return true if verb && !SAFE_METHODS.include?(verb.upcase)

          after.any? { |arg| HTTPIE_DATA.match?(arg) && !HTTPIE_QUERY.match?(arg) }
        end
      end
    end

    Registry.register("web_local", WebLocal)
  end
end
