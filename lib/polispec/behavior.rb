module Polispec
  module Behavior
    MAX_BYTES = 2 * 1024 * 1024
    AUTHENTICATION = { "application" => "release", "course" => "signed-package", "control" => "signed-control" }.freeze
    V2 = "polispec.behavior/v2"
    COMPILED_V1 = "polispec.behavior.compiled/v1"
    COMPILED_V2 = "polispec.behavior.compiled/v2"
    DEFAULT_LOCALE = "en-US"
    DEFAULT_SCOPE = "everywhere"

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

    def v2?(data)
      data.is_a?(Hash) && data["schema"] == V2
    end

    def validate(data)
      return Schema.validate("behavior", data) unless v2?(data)

      errors = Schema::Validator.new(Schema::Document.load(File.join(Schema::DIR, "behavior.v2.yml"))).call(data)
      errors.concat(semantic_errors(data), v2_errors(data)) if errors.empty?
      errors
    end

    def v2_errors(data)
      errors = []
      directives = data.fetch("directives")
      known = directive_index(directives)
      messages = data.fetch("messages", {})
      directives.each_with_index do |entry, index|
        if entry.key?("body") && entry.key?("body_ref")
          errors << Schema::Error.new("/directives/#{index}", "body and body_ref are mutually exclusive")
        end
        if entry.dig("body_ref", "path") && !Schema.safe_relative?(entry["body_ref"]["path"])
          errors << Schema::Error.new("/directives/#{index}/body_ref/path", "must be a repository-relative path without ..")
        end
        target = entry["duplicate_of"]
        next unless target

        errors << Schema::Error.new("/directives/#{index}/duplicate_of", "must name another directive") if !known.key?(target) || known[target].equal?(entry)
      end
      data.fetch("surfaces", {}).each do |name, surface|
        pointer = "/surfaces/#{name}"
        errors << Schema::Error.new("#{pointer}/template", "is required for #{surface['kind']} surfaces") if surface["kind"] != "rows" && !surface["template"]
        %w[target template].each do |key|
          next unless surface[key]

          errors << Schema::Error.new("#{pointer}/#{key}", "must be a repository-relative path without ..") unless Schema.safe_relative?(surface[key])
        end
        Array(surface["refs"]).each_with_index do |ref, index|
          errors << Schema::Error.new("#{pointer}/refs/#{index}", "unknown directive or message #{ref}") unless known.key?(ref) || messages.key?(ref)
        end
      end
      seen = {}
      data.fetch("frames", []).each_with_index do |frame, index|
        errors << Schema::Error.new("/frames/#{index}/id", "duplicate id #{frame['id']}") if seen[frame["id"]]
        seen[frame["id"]] = true
        errors << Schema::Error.new("/frames/#{index}/text_ref", "unknown message #{frame['text_ref']}") unless messages.key?(frame["text_ref"])
      end
      seen = {}
      data.fetch("antifeatures", []).each_with_index do |entry, index|
        errors << Schema::Error.new("/antifeatures/#{index}/id", "duplicate id #{entry['id']}") if seen[entry["id"]]
        seen[entry["id"]] = true
        entry["refs"].each_with_index do |ref, ref_index|
          errors << Schema::Error.new("/antifeatures/#{index}/refs/#{ref_index}", "unknown directive or message #{ref}") unless known.key?(ref) || messages.key?(ref)
        end
      end
      data.fetch("controls", {}).each do |name, control|
        errors << Schema::Error.new("/controls/#{name}/text_ref", "unknown message #{control['text_ref']}") unless messages.key?(control["text_ref"])
      end
      messages.each_key do |id|
        errors << Schema::Error.new("/messages/#{id}", "id must match ^[A-Za-z][A-Za-z0-9_.:-]+$") unless id.match?(/\A[A-Za-z][A-Za-z0-9_.:-]+\z/)
      end
      errors
    end

    def directive_index(directives)
      directives.each_with_object({}) do |entry, index|
        index[entry["id"]] = entry
        index[entry["opcode"]] = entry if entry["opcode"]
      end
    end

    def compile(data, root: nil)
      errors = validate(data)
      raise Polispec::Error, errors.map { |error| "#{error.pointer}: #{error.message}" }.join("; ") unless errors.empty?
      return compile_v2(data, root) if v2?(data)

      { "schema" => COMPILED_V1, "digest" => digest(data), "policy" => canonical(data) }
    end

    def compile_v2(data, root)
      policy = canonical(data)
      policy["directives"].each do |entry|
        entry["scope"] ||= DEFAULT_SCOPE
        next unless entry["body_ref"]

        entry["body_sha256"] = body_sha256(entry, root)
      end
      policy.fetch("messages", {}).each_value { |message| message["locale"] ||= DEFAULT_LOCALE }
      compiled = { "schema" => COMPILED_V2, "digest" => digest(policy), "policy" => policy }
      surfaces = surface_digests(compiled, root)
      compiled["surfaces"] = surfaces unless surfaces.empty?
      compiled
    end

    def surface_digests(compiled, root)
      require_relative "surfaces"
      compiled["policy"].fetch("surfaces", {}).each_with_object({}) do |(id, spec), found|
        raise Polispec::Error, "surface #{id} cannot render without --root" unless root

        text = begin
          Surfaces.render(compiled, id, root: root)
        rescue Polispec::Error => e
          raise Polispec::Error, "surface #{id} cannot render: #{e.message}"
        end
        entry = { "kind" => spec["kind"], "target" => spec["target"], "refs" => Array(spec["refs"]), "sha256" => Digest::SHA256.hexdigest(text) }
        entry["harness"] = spec["harness"] if spec["harness"]
        found[id] = entry
      end
    end

    def body_sha256(entry, root)
      raise Polispec::Error, "directive #{entry['id']} has a body_ref and no --root to read it from" unless root

      path = File.join(root, entry["body_ref"]["path"])
      raise Polispec::Error, "body_ref #{entry['body_ref']['path']} of #{entry['id']} is missing under #{root}" unless File.file?(path)

      actual = Digest::SHA256.file(path).hexdigest
      unless actual == entry["body_ref"]["sha256"]
        raise Polispec::Error, "body_ref #{entry['body_ref']['path']} of #{entry['id']} has sha256 #{actual}, the document declares #{entry['body_ref']['sha256']}"
      end

      actual
    end

    def load(path)
      raise Polispec::Error, "behavior policy exceeds #{MAX_BYTES} bytes" if File.size(path) > MAX_BYTES

      Schema::Document.load(path)
    end

    def decisions(data, event, facts)
      raise Polispec::Error, "facts must be an object" unless facts.is_a?(Hash)
      errors = validate(data)
      raise Polispec::Error, errors.map { |error| "#{error.pointer}: #{error.message}" }.join("; ") unless errors.empty?

      data.fetch("rules").select { |rule| rule["mode"] == "declarative" && rule["event"] == event }.map do |rule|
        missing = rule.fetch("all").keys - facts.keys
        matched = missing.empty? && rule.fetch("all").all? { |name, values| values.any? { |value| value.class == facts[name].class && value == facts[name] } }
        next if missing.empty? && !matched

        { "rule" => rule["id"], "verdict" => "deny", "message_id" => rule["message_id"], "missing_facts" => missing }
      end.compact
    end
  end
end
