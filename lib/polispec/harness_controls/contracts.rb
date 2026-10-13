#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module HarnessControls
    class Unavailable < Polispec::Error
      attr_reader :operation, :component

      def initialize(operation, component)
        @operation = operation.to_s
        @component = component.to_s
        super("#{@component} does not implement #{@operation}")
      end

      def to_h
        { "ok" => false, "code" => "unavailable", "operation" => operation, "component" => component }
      end
    end

    Artifact = Struct.new(:path, :content, :digest, :ownership, :format, keyword_init: true) do
      def to_h
        { "path" => path, "content" => content, "digest" => digest, "ownership" => ownership, "format" => format }
      end
    end

    Plan = Struct.new(:schema, :operation_id, :control_digest, :edition, :harness, :scope, :artifacts, :capabilities, :authority, :findings, keyword_init: true) do
      def initialize(**attributes)
        super
        self[:schema] ||= "polispec.harness.plan/v1"
        self[:artifacts] ||= []
        self[:capabilities] ||= []
        self[:findings] ||= []
      end

      def to_h
        { "schema" => schema, "operation_id" => operation_id, "control_digest" => control_digest, "edition" => edition, "harness" => harness, "scope" => scope, "artifacts" => artifacts.map { |item| item.respond_to?(:to_h) ? item.to_h : item }, "capabilities" => capabilities, "authority" => authority, "findings" => findings }
      end
    end

    InstallationReceipt = Struct.new(:schema, :installation_id, :control_digest, :edition, :harness, :scope, :owned_entries, :artifact_digests, :backups, :runtime_digest, :installed_at, keyword_init: true) do
      def initialize(**attributes)
        super
        self[:schema] ||= "polispec.harness.receipt/v1"
        self[:owned_entries] ||= []
        self[:artifact_digests] ||= {}
        self[:backups] ||= []
      end

      def to_h
        { "schema" => schema, "installation_id" => installation_id, "control_digest" => control_digest, "edition" => edition, "harness" => harness, "scope" => scope, "owned_entries" => owned_entries, "artifact_digests" => artifact_digests, "backups" => backups, "runtime_digest" => runtime_digest, "installed_at" => installed_at }
      end
    end

    Verification = Struct.new(:schema, :installation_id, :actual_version, :integrity, :ownership, :probes, :certified, :findings, :checked_at, keyword_init: true) do
      def initialize(**attributes)
        super
        self[:schema] ||= "polispec.harness.verification/v1"
        self[:probes] ||= []
        self[:findings] ||= []
        self[:certified] = false if self[:certified].nil?
      end

      def to_h
        { "schema" => schema, "installation_id" => installation_id, "actual_version" => actual_version, "integrity" => integrity, "ownership" => ownership, "probes" => probes, "certified" => certified, "findings" => findings, "checked_at" => checked_at }
      end
    end

    PlaneRecord = Struct.new(:schema, :edition, :generation, :source_kind, :source_ref, :source_digest, :runtime_digest, :trusted_sdk, :authority_files, keyword_init: true) do
      def initialize(**attributes)
        super
        self[:schema] ||= "polispec.harness.plane/v1"
        self[:authority_files] ||= []
      end

      def to_h
        { "schema" => schema, "edition" => edition, "generation" => generation, "source_kind" => source_kind, "source_ref" => source_ref, "source_digest" => source_digest, "runtime_digest" => runtime_digest, "trusted_sdk" => trusted_sdk, "authority_files" => authority_files }
      end
    end

    module Environment
      module_function

      def scan(context)
        raise Unavailable.new(:scan, "environment")
      end
    end

    module Plane
      module_function

      def resolve
        raise Unavailable.new(:resolve, "plane")
      end

      def operator!(operation)
        raise Unavailable.new(operation, "plane")
      end
    end

    module Lifecycle
      module_function

      def install(plan, actor)
        raise Unavailable.new(:install, "lifecycle")
      end
    end

    module Features
      PATH = File.join(ROOT, "config", "harness-features.yml")

      module_function

      def enabled?(name)
        values.fetch(name.to_s, false) == true
      end

      def values
        @values ||= YAML.safe_load(File.read(PATH), aliases: false) || {}
      rescue SystemCallError, Psych::Exception
        {}
      end
    end
  end
end
