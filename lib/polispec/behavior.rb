module Polispec
  module Behavior
    MAX_BYTES = 2 * 1024 * 1024
    AUTHENTICATION = { "application" => "release", "course" => "signed-package", "control" => "signed-control" }.freeze

    module_function

    def canonical(value)
      case value
      when Hash then value.keys.sort.each_with_object({}) { |key, out| out[key] = canonical(value.fetch(key)) }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def digest(data)
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(data)))}"
    end

    def semantic_errors(data)
      errors = []
      authority = data.fetch("authority")
      if authority["authentication"] != AUTHENTICATION[authority["kind"]]
        errors << Schema::Error.new("/authority/authentication", "does not match the declared authority kind")
      end
      %w[directives rules].each do |section|
        seen = {}
        data.fetch(section).each_with_index do |entry, index|
          id = entry["id"]
          errors << Schema::Error.new("/#{section}/#{index}/id", "duplicate id #{id}") if seen[id]
          seen[id] = true
        end
      end
      %w[opcode alias].each do |field|
        seen = {}
        data.fetch("directives").each_with_index do |entry, index|
          next unless entry.key?(field)
          value = entry[field]
          errors << Schema::Error.new("/directives/#{index}/#{field}", "duplicate #{field} #{value}") if seen[value]
          seen[value] = true
        end
      end
      data.fetch("directives").each_with_index do |entry, index|
        if entry["opcode"] && entry["rule"].length > 88
          errors << Schema::Error.new("/directives/#{index}/rule", "opcode directive summaries are limited to 88 characters")
        end
        if authority["kind"] == "application" && entry["tier"] == "private"
          errors << Schema::Error.new("/directives/#{index}/tier", "an application document cannot own private course directives")
        end
        if authority["kind"] != "application" && entry["tier"] == "public"
          errors << Schema::Error.new("/directives/#{index}/tier", "a course or control document cannot own application directives")
        end
      end
      data.fetch("rules").each_with_index do |rule, index|
        if rule["mode"] == "declarative"
          unless rule["all"].is_a?(Hash) && !rule["all"].empty? && rule["failure"] == "deny" && rule["message_id"]
            errors << Schema::Error.new("/rules/#{index}", "declarative rules need nonempty all predicates, a deny failure, and a message_id")
          end
        elsif rule.key?("all")
          errors << Schema::Error.new("/rules/#{index}/all", "predicates require declarative enforcement")
        end
        if rule["mode"] == "advisory" && rule["failure"] != "instruct"
          errors << Schema::Error.new("/rules/#{index}/failure", "advisory guidance cannot claim deterministic enforcement")
        end
      end
      errors
    end

    def compile(data)
      errors = Schema.validate("behavior", data)
      raise Polispec::Error, errors.map { |error| "#{error.pointer}: #{error.message}" }.join("; ") unless errors.empty?

      { "schema" => "polispec.behavior.compiled/v1", "digest" => digest(data), "policy" => canonical(data) }
    end

    def load(path)
      raise Polispec::Error, "behavior policy exceeds #{MAX_BYTES} bytes" if File.size(path) > MAX_BYTES

      Schema::Document.load(path)
    end

    def decisions(data, event, facts)
      raise Polispec::Error, "facts must be an object" unless facts.is_a?(Hash)
      compile(data)
      data.fetch("rules").select { |rule| rule["mode"] == "declarative" && rule["event"] == event }.map do |rule|
        missing = rule.fetch("all").keys - facts.keys
        matched = missing.empty? && rule.fetch("all").all? { |name, values| values.any? { |value| value.class == facts[name].class && value == facts[name] } }
        next if missing.empty? && !matched

        { "rule" => rule["id"], "verdict" => "deny", "message_id" => rule["message_id"], "missing_facts" => missing }
      end.compact
    end
  end
end
