module Polispec
  module HarnessControls
    module Language
      MAX_INPUT_BYTES = 1_048_576
      FIXTURE_ROOT = "/tmp/polispec-control-fixtures"
      VERBS = %w[read write delete run call fetch spawn commit push tag merge rewrite].freeze
      OBJECTS = %w[file command mcp url agent repository control].freeze
      EFFECTS = %w[deny ask restrict inject observe].freeze
      MATCH_KEYS = %w[env class crosses destructive shape lock_held live_binary delete_protected delete_protected_file delete_unbacked supervised pin_regress tag_claimed base_unpushed public_remote public_path push_unscanned ref path tool server operation domain role].freeze
      PAIRS = {
        ["write", "file"] => "fs.write",
        ["delete", "file"] => "fs.delete",
        ["write", "control"] => "control.edit",
        ["delete", "control"] => "control.edit",
        ["run", "command"] => "shell.exec",
        ["call", "mcp"] => "mcp.call",
        ["fetch", "url"] => "web.fetch",
        ["spawn", "agent"] => "agent.spawn",
        ["commit", "repository"] => "git.commit",
        ["push", "repository"] => "git.push",
        ["tag", "repository"] => "git.tag",
        ["merge", "repository"] => "git.merge",
        ["rewrite", "repository"] => "git.rewrite"
      }.freeze
      VERB_ALIASES = { "edit" => "write", "remove" => "delete", "execute" => "run", "invoke" => "call", "request" => "fetch", "delegate" => "spawn" }.freeze
      OBJECT_ALIASES = { "path" => "file", "cmd" => "command", "web" => "url", "subagent" => "agent", "repo" => "repository", "git" => "repository", "policy" => "control", "controls" => "control" }.freeze
      DYNAMIC_MATCH_KEYS = %w[crosses destructive shape lock_held live_binary delete_protected delete_protected_file delete_unbacked supervised pin_regress tag_claimed base_unpushed public_remote public_path push_unscanned].freeze

      class ParseError < Polispec::Error
        attr_reader :offset, :suggestions, :code

        def initialize(message, offset:, suggestions: [], code: "invalid_syntax")
          @offset = offset
          @suggestions = suggestions.map(&:to_s).uniq
          @code = code.to_s
          super(message)
        end

        def to_h
          { "code" => code, "message" => message, "offset" => offset, "suggestions" => suggestions }
        end
      end

      module_function

      def parse(text)
        Parser.new(text).parse
      end

      def validate(data)
        errors = Schema.validate("control", data).map(&:to_h)
        errors.concat(semantic_errors(data)) if data.is_a?(Hash) && data["controls"].is_a?(Array)
        begin
          encoded = JSON.generate(data)
          errors << { "pointer" => "", "message" => "must encode as valid UTF-8" } unless encoded.encoding == Encoding::UTF_8 && encoded.valid_encoding?
          errors << { "pointer" => "", "message" => "must be at most #{MAX_INPUT_BYTES} bytes" } if encoded.bytesize > MAX_INPUT_BYTES
        rescue JSON::GeneratorError, EncodingError
          errors << { "pointer" => "", "message" => "must be JSON-ready UTF-8 data" }
        end
        errors
      end

      def semantic_errors(data)
        data["controls"].each_with_index.flat_map do |control, index|
          next [] unless control.is_a?(Hash)

          pointer = "/controls/#{index}"
          errors = fixture_errors(control, pointer)
          canonical = control["canonical"]
          digest = control["digest"]
          if canonical || digest
            unless canonical.is_a?(String) && digest.is_a?(String)
              errors << { "pointer" => pointer, "message" => "canonical and digest must be supplied together" }
              next errors
            end
            expected_digest = Digest::SHA256.hexdigest(canonical)
            errors << { "pointer" => "#{pointer}/digest", "message" => "must equal the canonical SHA-256" } unless digest == expected_digest
            begin
              decoded = JSON.parse(canonical)
              errors << { "pointer" => "#{pointer}/canonical", "message" => "must use stable JSON serialization" } unless canonical_json(decoded) == canonical
              errors << { "pointer" => "#{pointer}/canonical", "message" => "must encode this control's semantic fields" } unless canonical_value(decoded) == canonical_value(semantic_fields(control))
            rescue JSON::ParserError, EncodingError
              errors << { "pointer" => "#{pointer}/canonical", "message" => "must be valid JSON" }
            end
          end
          errors
        end
      end

      def semantic_fields(control)
        keys = control["trigger"] == "schedule" ? %w[trigger calendar target_control_id effect reason] : %w[trigger action match effect effect_params reason]
        keys.each_with_object({}) { |key, result| result[key] = control[key] if control.key?(key) }
      end

      def fixture_errors(control, pointer)
        return [] if control["trigger"] == "schedule"
        fixture = control["fixture"]
        return [] unless fixture.is_a?(Hash)

        errors = []
        if fixture["expected"] != control["effect"]
          errors << { "pointer" => "#{pointer}/fixture/expected", "message" => "must equal the control effect" }
        end
        input = fixture["input"]
        return errors unless input.is_a?(Hash)

        unsafe_fixture_values(input).each do |path|
          errors << { "pointer" => "#{pointer}/fixture/input#{path}", "message" => "must be a synthetic non-privileged fixture value" }
        end
        errors
      end

      def unsafe_fixture_values(value, path = "")
        case value
        when Hash
          value.flat_map do |key, item|
            child = "#{path}/#{key.to_s.gsub('~', '~0').gsub('/', '~1')}"
            unsafe = if %w[file_path path cwd].include?(key.to_s) && item.is_a?(String)
                       !item.valid_encoding? || !item.start_with?("/tmp/") || item.split("/").include?("..")
                     elsif key.to_s == "command" && item.is_a?(String)
                       !item.valid_encoding? || item.match?(/(?:^|\s)(?:sudo|su|doas|mount|umount|chown|chmod|curl|wget|ssh|scp|nc|ncat|rm)(?:\s|$)/)
                     elsif key.to_s == "url" && item.is_a?(String)
                       !item.valid_encoding? || !item.match?(%r{\Ahttps://(?:[A-Za-z0-9-]+\.)*invalid(?:/|\z)})
                     else
                       false
                     end
            [unsafe ? child : nil, *unsafe_fixture_values(item, child)].compact
          end
        when Array
          value.each_with_index.flat_map { |item, index| unsafe_fixture_values(item, "#{path}/#{index}") }
        else
          []
        end
      end

      def canonical_json(value)
        JSON.generate(canonical_value(value))
      end

      def canonical_value(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
            source_key = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
            result[key] = canonical_value(value[source_key])
          end
        when Array
          value.map { |item| canonical_value(item) }
        else
          value
        end
      end

      def suggestions(word, vocabulary)
        vocabulary.map { |candidate| [distance(word.to_s, candidate), candidate] }.sort_by { |pair| pair }.first(3).select { |pair| pair[0] <= [2, word.to_s.length / 2].max }.map(&:last)
      end

      def distance(left, right)
        previous = (0..right.length).to_a
        left.each_char.with_index(1) do |left_char, row|
          current = [row]
          right.each_char.with_index(1) do |right_char, column|
            current[column] = [current[column - 1] + 1, previous[column] + 1, previous[column - 1] + (left_char == right_char ? 0 : 1)].min
          end
          previous = current
        end
        previous.last
      end

      class Parser
        def initialize(text)
          unless text.is_a?(String)
            raise ParseError.new("control sentence must be a string", offset: 0, code: "invalid_input")
          end
          unless text.encoding == Encoding::UTF_8 && text.valid_encoding?
            raise ParseError.new("control sentence must be valid UTF-8", offset: 0, code: "invalid_encoding")
          end
          if text.bytesize > MAX_INPUT_BYTES
            raise ParseError.new("control sentence must be at most #{MAX_INPUT_BYTES} bytes", offset: MAX_INPUT_BYTES, code: "input_too_large")
          end

          @text = text
          @offset = 0
        end

        def parse
          keyword("when")
          start = @offset
          subject = word
          return parse_schedule if subject == "schedule"
          unless subject == "agent"
            fail_at("expected agent or schedule", start, subject, %w[agent schedule])
          end

          parse_agent
        end

        private

        def parse_agent
          verb_offset = @offset
          raw_verb = word
          verb = VERB_ALIASES.fetch(raw_verb, raw_verb)
          fail_at("unknown verb #{raw_verb.inspect}", verb_offset, raw_verb, VERBS + VERB_ALIASES.keys) unless VERBS.include?(verb)

          object_offset = @offset
          raw_object = word
          object = OBJECT_ALIASES.fetch(raw_object, raw_object)
          fail_at("unknown object #{raw_object.inspect}", object_offset, raw_object, OBJECTS + OBJECT_ALIASES.keys) unless OBJECTS.include?(object)
          action = PAIRS[[verb, object]]
          unless action
            allowed = PAIRS.keys.select { |pair| pair[0] == verb }.map { |pair| pair.join(" ") }
            allowed = PAIRS.keys.map { |pair| pair.join(" ") } if allowed.empty?
            raise ParseError.new("unsupported action-object pair #{verb} #{object}", offset: verb_offset, suggestions: allowed, code: "unsupported_pair")
          end

          match = {}
          if peek_word == "where"
            word
            loop do
              key_offset = @offset
              key = word
              fail_at("unknown predicate #{key.inspect}", key_offset, key, MATCH_KEYS) unless MATCH_KEYS.include?(key)
              raise ParseError.new("duplicate predicate #{key.inspect}", offset: key_offset, code: "duplicate_predicate") if match.key?(key)
              symbol("=")
              match[key] = json_value
              break unless peek_word == "and"

              word
            end
          end

          keyword("then")
          effect_offset = @offset
          effect = word
          fail_at("unknown effect #{effect.inspect}", effect_offset, effect, EFFECTS) unless EFFECTS.include?(effect)
          params = nil
          if peek_word == "with"
            word
            params = json_value
            unless params.is_a?(Hash)
              raise ParseError.new("effect payload must be a JSON object", offset: effect_offset, code: "invalid_effect_payload")
            end
          end
          reason = parse_reason
          finish!

          fixture = fixture_for(verb, object, action, match, effect)
          semantic = { "trigger" => "pre_tool", "action" => action, "match" => Language.canonical_value(match), "effect" => effect }
          semantic["effect_params"] = Language.canonical_value(params) if params
          semantic["reason"] = reason if reason
          canonical = Language.canonical_json(semantic)
          digest = Digest::SHA256.hexdigest(canonical)
          control = { "id" => "ctl_#{digest[0, 16]}", "trigger" => "pre_tool", "action" => action, "match" => Language.canonical_value(match), "effect" => effect, "fixture" => fixture, "canonical" => canonical, "digest" => digest }
          control["effect_params"] = Language.canonical_value(params) if params
          control["reason"] = reason if reason
          document = { "schema" => "polispec.control/v1", "controls" => [control] }
          errors = Language.validate(document)
          unless errors.empty?
            detail = errors.first
            raise ParseError.new("invalid control at #{detail['pointer']}: #{detail['message']}", offset: effect_offset, code: "invalid_control")
          end
          document
        end

        def parse_schedule
          calendar_offset = @offset
          calendar = json_value
          unless calendar.is_a?(String) && !calendar.empty?
            raise ParseError.new("schedule calendar must be a nonempty JSON string", offset: calendar_offset, code: "invalid_calendar")
          end
          if calendar.length > Schema::CALENDAR_LIMIT
            raise ParseError.new("schedule calendar must be at most #{Schema::CALENDAR_LIMIT} characters", offset: calendar_offset, code: "invalid_calendar")
          end
          keyword("then")
          keyword("verify")
          id_offset = @offset
          target = word
          unless /\Actl_[A-Za-z0-9_-]+\z/.match?(target)
            raise ParseError.new("verify target must be a control ID", offset: id_offset, code: "invalid_control_id")
          end
          reason = parse_reason
          finish!
          semantic = { "trigger" => "schedule", "calendar" => calendar, "target_control_id" => target, "effect" => "verify" }
          semantic["reason"] = reason if reason
          canonical = Language.canonical_json(semantic)
          digest = Digest::SHA256.hexdigest(canonical)
          control = semantic.merge("id" => "ctl_#{digest[0, 16]}", "canonical" => canonical, "digest" => digest)
          { "schema" => "polispec.control/v1", "controls" => [Language.canonical_value(control)] }
        end

        def fixture_for(verb, object, action, match, effect)
          dynamic = match.keys & DYNAMIC_MATCH_KEYS
          unless dynamic.empty?
            raise ParseError.new("a safe matching fixture is required for predicates: #{dynamic.sort.join(', ')}", offset: 0, suggestions: ["supply this control through YAML IR with a fixture"], code: "fixture_required")
          end
          classes = match["class"]
          if classes && (!classes.is_a?(Array) || !classes.include?(action))
            raise ParseError.new("class predicate cannot match generated action #{action}", offset: 0, suggestions: [action], code: "fixture_required")
          end
          fixture_compatibility!(verb, object, match)

          path = fixture_path(match["path"], object)
          input = case [verb, object]
                  when ["write", "file"], ["write", "control"]
                    { "tool_name" => "Write", "tool_input" => { "file_path" => path, "content" => "polispec fixture\n" }, "cwd" => FIXTURE_ROOT }
                  when ["delete", "file"], ["delete", "control"]
                    { "tool_name" => "Delete", "tool_input" => { "file_path" => path }, "cwd" => FIXTURE_ROOT }
                  when ["run", "command"]
                    { "tool_name" => match["tool"] || "Bash", "tool_input" => { "command" => "printf polispec-control-fixture" }, "cwd" => FIXTURE_ROOT }
                  when ["call", "mcp"]
                    server = match["server"] || "polispec_fixture"
                    operation = match["operation"] || "inspect"
                    { "tool_name" => match["tool"] || "mcp__#{server}__#{operation}", "tool_input" => { "server" => server, "operation" => operation }, "cwd" => FIXTURE_ROOT }
                  when ["fetch", "url"]
                    domain = match["domain"] || "polispec.invalid"
                    unless domain.is_a?(String) && domain.match?(/\A(?:[A-Za-z0-9-]+\.)*invalid\z/)
                      raise ParseError.new("a safe matching fixture cannot be generated for domain #{domain.inspect}", offset: 0, suggestions: ["supply this control through YAML IR with a fixture"], code: "fixture_required")
                    end
                    { "tool_name" => match["tool"] || "WebFetch", "tool_input" => { "url" => "https://#{domain}/fixture" }, "cwd" => FIXTURE_ROOT }
                  when ["spawn", "agent"]
                    { "tool_name" => match["tool"] || "Agent", "tool_input" => { "role" => match["role"] || "fixture", "prompt" => "Return the fixture identifier only." }, "cwd" => FIXTURE_ROOT }
                  else
                    { "tool_name" => "Bash", "tool_input" => { "command" => git_command(verb, match["ref"]) }, "cwd" => FIXTURE_ROOT }
                  end
          input["env"] = match["env"] if match.key?("env")
          input["action"] = action
          { "input" => Language.canonical_value(input), "expected" => effect }
        end

        def fixture_compatibility!(verb, object, match)
          compatible = {
            "path" => %w[file control],
            "server" => %w[mcp],
            "operation" => %w[mcp],
            "domain" => %w[url],
            "role" => %w[agent],
            "ref" => %w[repository]
          }
          incompatible = compatible.keys.select { |key| match.key?(key) && !compatible[key].include?(object) }
          unless incompatible.empty?
            raise ParseError.new("a matching fixture cannot represent predicates: #{incompatible.sort.join(', ')}", offset: 0, suggestions: ["remove incompatible predicates or supply this control through YAML IR with a fixture"], code: "fixture_required")
          end

          expected = case [verb, object]
                     when ["write", "file"], ["write", "control"] then "Write"
                     when ["delete", "file"], ["delete", "control"] then "Delete"
                     when ["run", "command"] then "Bash"
                     when ["fetch", "url"] then "WebFetch"
                     when ["spawn", "agent"] then "Agent"
                     else "Bash" if object == "repository"
                     end
          return if !match.key?("tool") || object == "mcp" || match["tool"] == expected

          raise ParseError.new("tool predicate #{match['tool'].inspect} cannot match the generated #{verb} #{object} fixture", offset: 0, suggestions: [expected], code: "fixture_required")
        end

        def fixture_path(pattern, object)
          suffix = object == "control" ? "controls.json" : "fixture.txt"
          return File.join(FIXTURE_ROOT, suffix) if pattern.nil?
          unless pattern.is_a?(String) && pattern.start_with?("/tmp/") && !pattern.split("/").include?("..") && !pattern.match?(/[\[\]{}]/)
            raise ParseError.new("a safe matching fixture cannot be generated for path #{pattern.inspect}", offset: 0, suggestions: ["supply this control through YAML IR with a fixture"], code: "fixture_required")
          end

          candidate = pattern.gsub("**", "fixture").gsub("*", "fixture").gsub("?", "x")
          candidate.end_with?("/") ? "#{candidate}#{suffix}" : candidate
        end

        def git_command(verb, ref)
          if ref && (!ref.is_a?(String) || !ref.match?(/\A(?!-)(?!.*\.\.)[A-Za-z0-9][A-Za-z0-9._\/-]*\z/))
            raise ParseError.new("a safe matching fixture cannot be generated for ref #{ref.inspect}", offset: 0, suggestions: ["supply this control through YAML IR with a fixture"], code: "fixture_required")
          end
          repository = File.join(FIXTURE_ROOT, "nonexistent-repository")
          case verb
          when "commit" then "git -C #{repository} commit --allow-empty -m polispec-control-fixture"
          when "push" then "git -C #{repository} push #{FIXTURE_ROOT}/nonexistent-remote.git #{ref || 'polispec-control-fixture'}"
          when "tag" then "git -C #{repository} tag #{ref || 'polispec-control-fixture'}"
          when "merge" then "git -C #{repository} merge --no-commit #{ref || 'polispec-control-fixture'}"
          else "git -C #{repository} rebase #{ref || 'polispec-control-fixture'}"
          end
        end

        def parse_reason
          return nil unless peek_word == "because"

          word
          offset = @offset
          value = json_value
          unless value.is_a?(String) && !value.empty?
            raise ParseError.new("reason must be a nonempty JSON string", offset: offset, code: "invalid_reason")
          end
          value
        end

        def json_value
          skip_space
          start = @offset
          raise ParseError.new("expected JSON value", offset: start, code: "invalid_json") if eof?
          finish = json_end(start)
          source = @text[start...finish]
          value = JSON.parse(source)
          @offset = finish
          value
        rescue JSON::ParserError => error
          raise ParseError.new("invalid JSON value: #{error.message}", offset: start, code: "invalid_json")
        end

        def json_end(start)
          opening = @text[start]
          return string_end(start) if opening == '"'
          return composite_end(start) if opening == "{" || opening == "["

          cursor = start
          cursor += 1 while cursor < @text.length && !whitespace?(@text[cursor])
          cursor
        end

        def string_end(start)
          cursor = start + 1
          escaped = false
          while cursor < @text.length
            character = @text[cursor]
            return cursor + 1 if character == '"' && !escaped

            escaped = character == "\\" && !escaped
            escaped = false unless character == "\\"
            cursor += 1
          end
          raise ParseError.new("unterminated JSON string", offset: start, code: "invalid_json")
        end

        def composite_end(start)
          stack = []
          cursor = start
          quoted = false
          escaped = false
          while cursor < @text.length
            character = @text[cursor]
            if quoted
              quoted = false if character == '"' && !escaped
              escaped = character == "\\" && !escaped
              escaped = false unless character == "\\"
            elsif character == '"'
              quoted = true
            elsif character == "{" || character == "["
              stack << character
            elsif character == "}" || character == "]"
              expected = character == "}" ? "{" : "["
              raise ParseError.new("mismatched JSON delimiter", offset: cursor, code: "invalid_json") unless stack.pop == expected
              return cursor + 1 if stack.empty?
            end
            cursor += 1
          end
          raise ParseError.new("unterminated JSON value", offset: start, code: "invalid_json")
        end

        def keyword(expected)
          start = @offset
          actual = word
          fail_at("expected #{expected.inspect}", start, actual, [expected]) unless actual == expected
        end

        def symbol(expected)
          skip_space
          unless @text[@offset, expected.length] == expected
            raise ParseError.new("expected #{expected.inspect}", offset: @offset, suggestions: [expected], code: "invalid_syntax")
          end
          @offset += expected.length
        end

        def peek_word
          saved = @offset
          skip_space
          return nil if eof?

          word
        ensure
          @offset = saved
        end

        def word
          skip_space
          start = @offset
          match = /\A[A-Za-z_][A-Za-z0-9_.-]*/.match(@text[@offset..].to_s)
          raise ParseError.new("expected a word", offset: start, code: "invalid_syntax") unless match

          @offset += match[0].length
          match[0]
        end

        def finish!
          skip_space
          return if eof?

          raise ParseError.new("unexpected trailing input", offset: @offset, code: "invalid_syntax")
        end

        def fail_at(message, offset, actual, vocabulary)
          normalized = vocabulary.map { |item| VERB_ALIASES.fetch(item, OBJECT_ALIASES.fetch(item, item)) }.uniq
          raise ParseError.new(message, offset: offset, suggestions: Language.suggestions(actual, normalized), code: "unknown_vocabulary")
        end

        def skip_space
          @offset += 1 while @offset < @text.length && whitespace?(@text[@offset])
        end

        def whitespace?(character)
          character&.match?(/\s/)
        end

        def eof?
          @offset >= @text.length
        end
      end
    end
  end
end
