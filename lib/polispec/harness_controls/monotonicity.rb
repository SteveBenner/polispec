require_relative "language"

module Polispec
  module HarnessControls
    module Monotonicity
      ADDITIVE_EFFECTS = %w[deny ask restrict inject observe verify].freeze

      module_function

      def monotonic(current, proposed, _actor)
        current_errors = Language.validate(current)
        proposed_errors = Language.validate(proposed)
        unless current_errors.empty? && proposed_errors.empty?
          return {
            "disposition" => "operator_required",
            "reasons" => validation_reasons("current", current_errors) + validation_reasons("proposed", proposed_errors)
          }
        end

        current_controls = controls_by_id(current)
        proposed_controls = controls_by_id(proposed)
        removed = current_controls.keys - proposed_controls.keys
        changed = (current_controls.keys & proposed_controls.keys).reject do |id|
          comparable(current_controls[id]) == comparable(proposed_controls[id])
        end
        reasons = []
        reasons.concat(removed.sort.map { |id| "removing control #{id} requires operator authority" })
        reasons.concat(changed.sort.map { |id| "changing control #{id} requires operator authority" })
        unless reasons.empty?
          return { "disposition" => "operator_required", "reasons" => reasons }
        end

        added = proposed_controls.keys - current_controls.keys
        return { "disposition" => "equal", "reasons" => ["the effective control set is unchanged"] } if added.empty?

        unsafe = added.reject { |id| additive?(proposed_controls[id]) }
        unless unsafe.empty?
          return {
            "disposition" => "operator_required",
            "reasons" => unsafe.sort.map { |id| "control #{id} is not a provably additive control" }
          }
        end

        {
          "disposition" => "tightening",
          "reasons" => added.sort.map { |id| "added #{proposed_controls[id]['effect']} control #{id}" }
        }
      rescue StandardError => error
        { "disposition" => "operator_required", "reasons" => ["comparison is uncertain: #{error.class}: #{error.message}"] }
      end

      def controls_by_id(document)
        document.fetch("controls").each_with_object({}) { |control, result| result[control.fetch("id")] = control }
      end

      def comparable(control)
        Language.canonical_value(control)
      end

      def additive?(control)
        return false unless ADDITIVE_EFFECTS.include?(control["effect"])
        return safe_inject?(control) if control["effect"] == "inject"
        return safe_observe?(control) if control["effect"] == "observe"

        true
      end

      def safe_inject?(control)
        text = control.dig("effect_params", "text")
        text.is_a?(String) && text.encoding == Encoding::UTF_8 && text.valid_encoding? && text.bytesize <= 8192
      end

      def safe_observe?(control)
        params = control["effect_params"]
        return false unless params.is_a?(Hash) && params["event"] == "control.observed"

        metadata = params["metadata"]
        metadata.nil? || metadata.values.all? { |value| value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false }
      end

      def validation_reasons(label, errors)
        errors.map { |error| "#{label}#{error['pointer']}: #{error['message']}" }
      end
    end
  end
end
