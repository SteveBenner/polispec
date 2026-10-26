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
    EXTENSION_CLASS = /\ARplugin::Adapters::(?:Polispec::)?([A-Za-z0-9]+)(?:::[A-Za-z0-9]+)*::Author\z/.freeze
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

      def shelf_modules
        store = Layers.store
        return [] unless store

        src = store.source
        names = if src.kind == :dir
                  base = File.join(src.root, "modules")
                  File.directory?(base) ? Dir.children(base) : []
                else
                  path = [src.path, "modules"].reject { |part| part.to_s.empty? }.join("/")
                  Environments.git(src.repo, "ls-tree", "--name-only", "#{src.ref}:#{path}").to_s.lines.map(&:chomp)
                end
        names.filter_map { |name| name.delete_suffix(".yml") if name.end_with?(".yml") }.sort
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
        Port.new(Standalone.new(adapter: adapter))
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

      def extension_ids
        chain = extension_port
        return [] unless chain && chain.respond_to?(:adapter_names)

        Array(chain.adapter_names).filter_map { |name| extension_id_of(name) }.uniq
      rescue StandardError, LoadError
        []
      end

      def extension_id_of(class_name)
        match = EXTENSION_CLASS.match(class_name.to_s)
        return nil unless match

        match[1].gsub(/([a-z0-9])([A-Z])/, '\\1-\\2').downcase
      end

      def extension_adapter?(id)
        wanted = id.to_s.gsub(/[-_]/, "").downcase
        extension_ids.any? { |known| known.delete("-") == wanted }
      end

      def port_unavailable?(error)
        error.class.ancestors.any? { |klass| klass.name == "Rplugin::PortUnavailable" }
      end

      def translate(error)
        return error unless port_unavailable?(error)

        Unavailable.new("port_unavailable", error.message)
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
        extension = extension_ids
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
