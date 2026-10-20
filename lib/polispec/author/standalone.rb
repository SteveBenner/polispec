#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "securerandom"

module Polispec
  module Author
    class Standalone
      Entry = Struct.new(:id, :handle, :adapter, :lock, :used_at, :findings, :adapter_id)

      def initialize(adapter: nil)
        @adapter_id = (adapter || Engine::Settings.author_adapter).to_s
        @adapter_id = BUILTIN if @adapter_id.empty?
        @entries = {}
        @mutex = Mutex.new
        @reaper = nil
      end

      def adapter_id
        @adapter_id
      end

      def draft(kind:, intent:, context: {}, session: nil, on_event: nil)
        Author.ensure_available!
        reap
        relay = lambda do |event|
          normalized = Author.normalize_event(event)
          on_event.call(normalized) if normalized && on_event
        end
        entry = session ? fetch(session) : open_entry(kind, context, relay)
        fresh = session.nil?
        begin
          text = Prompt.user_turn(intent, entry.findings)
          Bounds.take_turn
          started = clock
          done = entry.adapter.turn(entry.handle, text) { |event| relay.call(event) }
          entry.used_at = clock
          built = Draft.build(kind, done_text(done), context)
          entry.findings = built[:findings]
          relay.call(type: "draft", yaml: built[:yaml], findings: built[:findings])
          announce("turn", entry, duration_ms: ((clock - started) * 1000).round, cost: done.is_a?(Hash) ? done[:cost] : nil)
          built.merge(adapter: entry.adapter_id, session: entry.id)
        rescue StandardError => e
          close(entry.id) if fresh
          raise Author.translate(e)
        end
      end

      def close(id)
        entry = @mutex.synchronize { @entries.delete(id) }
        return false unless entry

        begin
          entry.adapter.close(entry.handle)
        ensure
          entry.lock.release
          announce("close", entry)
        end
        true
      end

      def close_all
        @mutex.synchronize { @entries.keys }.each { |id| close(id) }
      end

      def open_sessions
        @mutex.synchronize { @entries.keys }
      end

      def reap
        cutoff = clock - Bounds::IDLE_SECONDS
        idle = @mutex.synchronize { @entries.values.select { |entry| entry.used_at < cutoff }.map(&:id) }
        idle.each { |id| close(id) }
      end

      private

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def done_text(done)
        done.is_a?(Hash) ? (done[:text] || done["text"]).to_s : done.to_s
      end

      def fetch(id)
        entry = @mutex.synchronize { @entries[id] }
        raise Unavailable.new("unknown_session", "no open author session #{id}") unless entry

        entry
      end

      def open_entry(kind, context, relay)
        klass = Author.registry[@adapter_id]
        extension = klass ? nil : extension_adapter
        unless klass || extension
          known = Author.registry.keys.sort.join(", ")
          raise Unavailable.new("unknown_adapter", "no author adapter #{@adapter_id}; built in: #{known}; #{Author.extension_note}")
        end

        id = SecureRandom.uuid
        lock = Bounds.acquire_session(id)
        begin
          adapter = klass ? klass.new : extension
          handle = adapter.open(context.merge(kind: kind.to_s, session_id: id))
          real_id = handle.respond_to?(:id) && !handle.id.to_s.empty? ? handle.id.to_s : id
        rescue StandardError => e
          lock.release
          raise Author.translate(e)
        end
        entry = Entry.new(real_id, handle, adapter, lock, clock, nil, @adapter_id)
        @mutex.synchronize { @entries[real_id] = entry }
        start_reaper
        announce("open", entry)
        entry
      end

      def extension_adapter
        return nil unless Author.extension_adapter?(@adapter_id)

        first = Author.extension_ids.first.to_s
        unless first.delete("-") == @adapter_id.to_s.gsub(/[-_]/, "").downcase
          raise Unavailable.new("adapter_shadowed", "the author port answers from extension #{first} before #{@adapter_id}; select #{first} or remove it")
        end

        Author.extension_port
      end

      def start_reaper
        return if @reaper && @reaper.alive?

        @reaper = Thread.new do
          loop do
            sleep 30
            reap
          end
        end
        @reaper.report_on_exception = false
      end

      def announce(phase, entry, extra = {})
        handle = entry.handle
        Events.emit("polispec.author", {
          phase: phase, session: entry.id, adapter: entry.adapter_id,
          harness: handle.respond_to?(:harness) ? handle.harness : nil,
          model: handle.respond_to?(:model) ? handle.model : nil
        }.merge(extra))
      end
    end
  end
end
