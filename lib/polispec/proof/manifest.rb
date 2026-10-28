#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Proof
    class Manifest
      MAX_EXCEPTION_DAYS = 90
      GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_DOTMATCH | File::FNM_EXTGLOB
      HOST_FACTS = %i[os arch ruby runtime harness].freeze

      attr_reader :data

      class << self
        def load(root:)
          path = File.join(root, MANIFEST_PATH)
          return nil unless File.file?(path)

          parse(File.read(path), MANIFEST_PATH)
        end

        def at(git_dir, rev)
          out, _err, status = Trace.capture3("git", "-C", git_dir.to_s, "show", "#{rev}:#{MANIFEST_PATH}", trace: :silent)
          return nil unless status.success?

          parse(out, "#{rev}:#{MANIFEST_PATH}")
        end

        def parse(text, label = MANIFEST_PATH)
          data = Schema::Document.parse(text, label)
          errors = Schema.validate("features", data)
          unless errors.empty?
            detail = errors.first(5).map { |error| error.pointer.empty? ? error.message : "#{error.pointer} #{error.message}" }.join("; ")
            raise Polispec::Error, "manifest_invalid: #{label}: #{detail}"
          end

          new(deep_freeze(data))
        rescue Schema::Document::ParseError => e
          raise Polispec::Error, "manifest_invalid: #{e.message}"
        end

        def match?(glob, path)
          pattern = glob.to_s
          pattern = "#{pattern}/*" if pattern == "**" || pattern.end_with?("/**")
          File.fnmatch(pattern, path.to_s, GLOB_FLAGS)
        end

        def any_match?(globs, path)
          Array(globs).any? { |glob| match?(glob, path) }
        end

        def host_facts
          os = Smoke.os_info["id"]
          facts = { os: os, arch: Smoke.command(%w[uname -m]), ruby: RUBY_VERSION.split(".").first(2).join(".") }
          runtime = ENV["POLISPEC_PROOF_RUNTIME"].to_s.strip
          harness = ENV["POLISPEC_PROOF_HARNESS"].to_s.strip
          facts[:runtime] = runtime unless runtime.empty?
          facts[:harness] = harness unless harness.empty?
          facts.reject { |_, value| value.nil? || value.to_s.empty? }
        end

        def semantic_problems(data)
          problems = []
          target_ids = data["targets"].map { |target| target["id"] }
          feature_ids = data["features"].map { |feature| feature["id"] }
          problems << "target ids are not unique" unless target_ids.uniq.length == target_ids.length
          problems << "feature ids are not unique" unless feature_ids.uniq.length == feature_ids.length
          data["features"].each do |feature|
            unknown = Array(feature["targets"]) - target_ids
            problems << "feature #{feature['id']} names unknown targets #{unknown.join(', ')}" unless unknown.empty?
          end
          producer_ids = Array(data["trusted_producers"]).map { |producer| producer["id"] }
          problems << "trusted_producers ids are not unique" unless producer_ids.uniq.length == producer_ids.length
          Array(data["exceptions"]).each { |entry| problems.concat(exception_problems(entry, data)) }
          Array(data["trusted_producers"]).each do |producer|
            problems << "trusted producer #{producer['id']} key does not parse" unless Signer.key_parses?(producer["key"])
          end
          problems
        end

        def exception_problems(entry, data)
          label = "exception #{entry['feature']}"
          feature = data["features"].find { |item| item["id"] == entry["feature"] }
          return ["#{label} names an unknown feature"] unless feature

          problems = []
          scope = feature["targets"] || data["targets"].map { |target| target["id"] }
          unknown = Array(entry["targets"]) - scope
          problems << "#{label} names targets the feature does not run on: #{unknown.join(', ')}" unless unknown.empty?
          added = Date.iso8601(entry["added"])
          expires = Date.iso8601(entry["expires"])
          problems << "#{label} expires before it was added" if expires < added
          problems << "#{label} lasts #{(expires - added).to_i} days, more than #{MAX_EXCEPTION_DAYS}" if (expires - added).to_i > MAX_EXCEPTION_DAYS
          problems
        rescue Date::Error
          ["#{label} has an invalid date"]
        end

        def deep_freeze(value)
          case value
          when Hash then value.each { |key, item| deep_freeze(key); deep_freeze(item) }
          when Array then value.each { |item| deep_freeze(item) }
          end
          value.freeze
        end
      end

      def initialize(data)
        @data = data
      end

      def targets
        data["targets"]
      end

      def features
        data["features"]
      end

      def shared
        Array(data["shared"])
      end

      def ignore
        Array(data["ignore"])
      end

      def trusted_producers
        Array(data["trusted_producers"])
      end

      def exceptions
        Array(data["exceptions"])
      end

      def target(id)
        targets.find { |target| target["id"] == id }
      end

      def feature(id)
        features.find { |feature| feature["id"] == id }
      end

      def target_ids_for(feature)
        entry = feature.is_a?(Hash) ? feature : self.feature(feature)
        entry["targets"] || targets.map { |target| target["id"] }
      end

      def cells
        features.flat_map { |feature| target_ids_for(feature).map { |target_id| [feature, target(target_id)] } }
      end

      def min_rung(feature)
        feature["min_rung"] || 2
      end

      def smoke_for(feature, target_id)
        smoke = feature["smoke"]
        override = (smoke["per_target"] || {})[target_id] || {}
        { "run" => override["run"] || smoke["run"], "rung" => override["rung"] || smoke["rung"], "timeout_s" => override["timeout_s"] || smoke["timeout_s"] || 900 }
      end

      def covers?(feature, path)
        self.class.any_match?(feature["paths"], path) || self.class.any_match?(feature["shared"], path) || self.class.any_match?(shared, path)
      end

      def covered_globs(feature)
        Array(feature["paths"]) + Array(feature["shared"]) + shared
      end

      def owned?(path)
        features.any? { |feature| covers?(feature, path) }
      end

      def ignored?(path)
        self.class.any_match?(ignore, path) || path == MANIFEST_PATH || path.start_with?("#{PROOFS_DIR}/")
      end

      def exception_for(feature_id, target_id, today: Date.today)
        exceptions.find do |entry|
          entry["feature"] == feature_id &&
            (entry["targets"].nil? || entry["targets"].include?(target_id)) &&
            Date.iso8601(entry["expires"]) >= today
        end
      end

      def host_target(facts, explicit = nil)
        facts = facts.to_h { |key, value| [key.to_s, value.to_s] }
        if explicit
          chosen = target(explicit)
          raise Polispec::Error, "target_unmatched: no target #{explicit} in #{MANIFEST_PATH}" unless chosen

          differing = chosen["facts"].select { |key, value| facts.key?(key) && facts[key] != value }
          unless differing.empty?
            detail = differing.map { |key, value| "#{key} is #{facts[key]} on this host, #{value} on #{explicit}" }.join("; ")
            raise Polispec::Error, "target_mismatch: #{detail}"
          end
          return chosen
        end

        matches = targets.select { |candidate| candidate["facts"].all? { |key, value| facts.key?(key) && facts[key] == value } }
        raise Polispec::Error, "target_unmatched: no target matches this host (#{facts.map { |key, value| "#{key}=#{value}" }.join(', ')})" if matches.empty?
        raise Polispec::Error, "target_ambiguous: #{matches.map { |match| match['id'] }.join(', ')} all match this host" if matches.length > 1

        matches.first
      end
    end
  end
end
