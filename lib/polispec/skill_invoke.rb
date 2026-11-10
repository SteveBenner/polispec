# SPDX-License-Identifier: MIT

module Polispec
  module SkillInvoke
    DEFAULT_TRIGGER_SENTENCE = "The application also tells you when to load it.".freeze
    MAX_DESCRIPTION = 1024
    MAX_NAME = 64
    JACCARD = 0.8
    QUOTE_TRIGGER = /: |#|["\\]|\A[^A-Za-z0-9]/.freeze

    module_function

    def skills(data)
      data.fetch("surfaces", {}).select { |_, surface| surface["kind"] == "skill" && surface["invoke"].is_a?(Hash) }
    end

    def errors(data)
      found = []
      data.fetch("surfaces", {}).each do |id, surface|
        next unless surface.key?("invoke")

        pointer = "/surfaces/#{id}/invoke"
        found << Schema::Error.new(pointer, "surface #{id} has an invoke block but is a #{surface['kind']} surface; only skill surfaces take invoke") unless surface["kind"] == "skill"
      end
      table = skills(data)
      names = {}
      table.each do |id, surface|
        invoke = surface["invoke"]
        pointer = "/surfaces/#{id}/invoke"
        if names.key?(invoke["name"])
          found << Schema::Error.new("#{pointer}/name", "surface #{id} repeats the invoke name #{invoke['name']} of surface #{names[invoke['name']]}")
        else
          names[invoke["name"]] = id
        end
        target_dir = File.basename(File.dirname(surface["target"].to_s))
        unless target_dir == invoke["name"]
          found << Schema::Error.new("#{pointer}/name", "surface #{id} names the skill #{invoke['name']} but its target directory is #{target_dir.empty? ? 'missing' : target_dir}")
        end
        Array(invoke["excludes"]).each_with_index do |entry, index|
          skill = entry["skill"]
          if skill == invoke["name"]
            found << Schema::Error.new("#{pointer}/excludes/#{index}/skill", "surface #{id} excludes its own skill #{skill}")
          elsif !table.any? { |other_id, other| other_id != id && other["invoke"]["name"] == skill }
            found << Schema::Error.new("#{pointer}/excludes/#{index}/skill", "surface #{id} excludes the unknown skill #{skill}")
          end
        end
        text = description(invoke)
        found << Schema::Error.new("#{pointer}/summary", "surface #{id} generates a description of #{text.length} characters, the limit is #{MAX_DESCRIPTION}") if text.length > MAX_DESCRIPTION
        found << Schema::Error.new("#{pointer}/name", "surface #{id} has a skill name longer than #{MAX_NAME} characters") if invoke["name"].length > MAX_NAME
      end
      found.concat(intent_errors(table))
      found
    end

    def intent_errors(table)
      found = []
      entries = table.flat_map do |id, surface|
        invoke = surface["invoke"]
        invoke["intents"].each_with_index.map { |intent, index| { id: id, name: invoke["name"], index: index, norm: normalise(intent), tokens: normalise(intent).split(" ").uniq } }
      end
      entries.combination(2) do |left, right|
        if left[:norm] == right[:norm]
          found << Schema::Error.new("/surfaces/#{right[:id]}/invoke/intents/#{right[:index]}", "surfaces #{left[:id]} and #{right[:id]} carry the same intent")
          next
        end
        next if left[:name] == right[:name]
        next if listed?(table, left[:id], right[:name]) || listed?(table, right[:id], left[:name])
        next if left[:tokens].empty? || right[:tokens].empty?

        score = (left[:tokens] & right[:tokens]).length.to_f / (left[:tokens] | right[:tokens]).length
        next unless score >= JACCARD

        found << Schema::Error.new("/surfaces/#{right[:id]}/invoke/intents/#{right[:index]}", "surfaces #{left[:id]} and #{right[:id]} carry intents that overlap by #{format('%.2f', score)} and neither excludes the other")
      end
      found
    end

    def listed?(table, id, other_name)
      Array(table.fetch(id)["invoke"]["excludes"]).any? { |entry| entry["skill"] == other_name }
    end

    def normalise(text)
      text.to_s.downcase.gsub(/[^[:alnum:]]+/, " ").strip
    end

    def description(invoke)
      parts = ["#{invoke['summary']} Use when #{invoke['intents'].join('; ')}."]
      parts << (invoke["trigger_sentence"] || DEFAULT_TRIGGER_SENTENCE) unless Array(invoke["triggers"]).empty?
      Array(invoke["excludes"]).each { |entry| parts << "Not for #{entry['when']}: use the #{entry['skill']} skill." }
      parts.join(" ")
    end

    def scalar(text)
      return text unless text.match?(QUOTE_TRIGGER)

      "\"#{text.gsub('\\') { '\\\\' }.gsub('"', '\"')}\""
    end

    def frontmatter(invoke)
      "---\nname: #{invoke['name']}\ndescription: #{scalar(description(invoke))}\n---"
    end

    def check_template(surface_id, spec, template)
      invoke = spec["invoke"]
      count = template.scan(/\{\{\s*frontmatter\s*\}\}/).length
      if invoke.nil?
        raise Polispec::Error, "surface #{surface_id} uses {{frontmatter}} but has no invoke block" if count.positive?

        return
      end
      raise Polispec::Error, "surface #{surface_id} template carries its own leading --- block; use {{frontmatter}} instead" if template.match?(/\A\s*---[ \t]*\r?\n/)
      raise Polispec::Error, "surface #{surface_id} must use {{frontmatter}} exactly once, found #{count}" unless count == 1
      raise Polispec::Error, "surface #{surface_id} must start its template with {{frontmatter}}" unless template.match?(/\A\{\{\s*frontmatter\s*\}\}/)
    end
  end
end
