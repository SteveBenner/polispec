#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "fileutils"
require_relative "editions"
require_relative "state"
require_relative "events"

module Polispec
  module Author
    KINDS = %w[policy module package environments roster global spec description].freeze
    BUILTIN = "harness-cli".freeze
    ADAPTER_DIR = File.join(LIB, "author", "adapters")

    class Unavailable < Polispec::Error
      attr_reader :reason

      def initialize(reason, message = nil)
        @reason = reason
        super(message || reason)
      end
    end

    class Busy < Unavailable
      def initialize(message = "author is busy: three sessions are already open")
        super("busy", message)
      end
    end

    class RateLimited < Unavailable
      attr_reader :retry_after

      def initialize(retry_after, message = nil)
        @retry_after = retry_after
        super("rate_limited", message || "author allows 10 turns a minute; retry in #{retry_after} s")
      end
    end

    @registry = {}
    @planner = nil

    class << self
      attr_accessor :planner

      def register(id, klass)
        @registry[id.to_s] = klass
        klass
      end

      def registry
        load_adapters
        @registry.dup
      end

      def load_adapters
        return if @adapters_loaded

        @adapters_loaded = true
        Dir.glob(File.join(ADAPTER_DIR, "*.rb")).sort.each { |file| require file }
      end

      def dir
        File.join(State.home, "author")
      end

      def kill_switch?
        !Engine::Settings.author_enabled?
      end

      def ensure_available!
        raise Unavailable.new("edition_excluded", "author is not part of the lock edition") unless Editions.allowed?("author")
        raise Unavailable.new("kill_switch", "author is switched off (polispec.author.enabled or POLISPEC_AUTHOR=off)") if kill_switch?

        true
      end

      def port(adapter: nil)
        ensure_available!
        external = adapter ? nil : extension_port
        Port.new(external || Standalone.new(adapter: adapter))
      end

      def draft(kind:, intent:, context: {}, session: nil, on_event: nil, adapter: nil)
        port(adapter: adapter).draft(kind: kind, intent: intent, context: context, session: session, on_event: on_event)
      end

      def extension_port
        return nil if State.redirected

        ports = Events.port_set
        return nil unless ports && ports.respond_to?(:author)

        ports.author
      rescue StandardError, LoadError
        nil
      end

      def extension_note
        return "no rplugin port set: state is redirected" if State.redirected

        ports = Events.port_set
        return "rplugin is not installed or its SDK did not load" unless ports
        return "installed rplugin has no declared author port (it predates plugin-declared ports)" unless ports.respond_to?(:author)

        "the declared author port is installed but no extension maps an adapter to it"
      rescue StandardError, LoadError => e
        "rplugin port failed to load: #{e.message}"
      end

      def adapters
        external = extension_port
        extension = external && external.respond_to?(:adapters) ? Array(external.adapters).map(&:to_s) : []
        {
          "builtin" => registry.keys.sort,
          "extension" => extension,
          "extension_note" => extension.empty? ? extension_note : nil,
          "selected" => Engine::Settings.author_adapter
        }
      end

      def normalize_event(event)
        return nil unless event.is_a?(Hash)

        out = event.each_with_object({}) { |(key, value), memo| memo[key.to_s.to_sym] = value }
        out[:type] = out[:type].to_s
        out
      end
    end

    class Port
      def initialize(inner)
        @inner = inner
      end

      def draft(kind:, intent:, context: {}, session: nil, on_event: nil)
        kind = kind.to_s
        raise Polispec::Error, "unknown author kind #{kind}" unless KINDS.include?(kind)

        Author.ensure_available!
        relay = lambda do |event|
          normalized = Author.normalize_event(event)
          on_event.call(normalized) if normalized && on_event
        end
        @inner.draft(kind: kind, intent: intent.to_s, context: symbolize(context), session: session, on_event: relay)
      end

      def close(session)
        @inner.close(session) if @inner.respond_to?(:close)
      end

      def method_missing(name, *args, &block)
        @inner.respond_to?(name) ? @inner.public_send(name, *args, &block) : super
      end

      def respond_to_missing?(name, include_private = false)
        @inner.respond_to?(name, include_private) || super
      end

      private

      def symbolize(value)
        return {} unless value.is_a?(Hash)

        value.each_with_object({}) { |(key, item), memo| memo[key.to_s.to_sym] = item }
      end
    end
  end
end

require_relative "author/bounds"
require_relative "author/prompt"
require_relative "author/draft"
require_relative "author/standalone"
