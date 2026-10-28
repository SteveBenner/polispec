#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT
# frozen_string_literal: true

require_relative "adapters/local"

module Polispec
  module Proof
    module Runner
      SETTING = "polispec.proof.runner"
      DEFAULT = "local"
      KILL_SWITCH = "POLISPEC_PROOF_RUNNER"
      EXTENSION_CLASS = /\ARplugin::Adapters::(?:Polispec::)?([A-Za-z0-9]+)(?:::[A-Za-z0-9]+)*::ProofRunner\z/.freeze

      module_function

      def adapter_id
        Engine::Settings.text(SETTING, DEFAULT).to_s
      end

      def switched_off?
        ENV[KILL_SWITCH].to_s.strip.downcase == "off"
      end

      def adapter
        raise Polispec::Error, "runner_unavailable: proof runner is switched off (#{KILL_SWITCH}=off)" if switched_off?

        id = adapter_id
        id = DEFAULT if id.empty?
        return Adapters::Local.new if id == DEFAULT

        extension(id)
      end

      def extension(id)
        ports = State.redirected ? nil : Events.port_set
        unless ports && ports.respond_to?(:proof_runner)
          raise Polispec::Error, "runner_unavailable: no proof runner adapter #{id}; built in: #{DEFAULT}; #{extension_note(ports)}"
        end

        chain = ports.proof_runner
        wanted = id.to_s.gsub(/[-_]/, "").downcase
        return chain if extension_ids(chain).any? { |known| known.delete("-") == wanted }

        raise Polispec::Error, "runner_unavailable: no proof runner adapter #{id}; built in: #{DEFAULT}; #{extension_note(ports)}"
      rescue Polispec::Error
        raise
      rescue StandardError, LoadError => e
        raise Polispec::Error, "runner_unavailable: #{e.message}"
      end

      def extension_ids(chain)
        return [] unless chain.respond_to?(:adapter_names)

        Array(chain.adapter_names).filter_map do |name|
          match = EXTENSION_CLASS.match(name.to_s)
          match && match[1].gsub(/([a-z0-9])([A-Z])/, '\\1-\\2').downcase
        end.uniq
      end

      def extension_note(ports)
        return "no rplugin port set: state is redirected or rplugin did not load" unless ports
        return "installed rplugin has no declared proof_runner port" unless ports.respond_to?(:proof_runner)

        "the declared proof_runner port is installed but no extension maps that adapter to it"
      end
    end
  end
end
