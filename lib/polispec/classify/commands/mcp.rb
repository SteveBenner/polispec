require_relative "support"

module Polispec
  module Classify
    module Mcp
      PATH_ARGS = %w[path file_path filename target destination dest].freeze
      WRITE_OPERATION = /write|edit|create|delete|move|put|update/i.freeze

      module_function

      def call(tool_name, tool_input, cwd)
        server, operation = identity(tool_name)
        return [] unless server
        domain = domain_of(tool_input)
        found = [Action.new(class: "mcp.call", env_hint: Support.hint("server" => server, "operation" => operation, "domain" => domain, "path" => cwd.to_s), raw: tool_name.to_s)]
        found + path_actions(operation, tool_input, cwd)
      end

      def path_actions(operation, input, cwd)
        base = cwd.to_s.empty? ? Dir.pwd : cwd.to_s
        writes = operation.to_s.match?(WRITE_OPERATION)
        argument_paths(input).filter_map do |path|
          target = Support.abs(path, base)
          writes ? Support.write_action(target, "mcp #{operation} #{target}", {}, input) : Support.read_action(target, "mcp #{operation} #{target}")
        end
      end

      def argument_paths(input, nested = true)
        return [] unless input.is_a?(Hash)

        own = PATH_ARGS.filter_map { |key| Support.dig(input, key) }.grep(String).reject(&:empty?)
        edits = nested && Support.dig(input, "edits").is_a?(Array) ? Support.dig(input, "edits").flat_map { |entry| argument_paths(entry, false) } : []
        (own + edits).uniq
      end

      def identity(tool_name)
        name = tool_name.to_s
        if (match = name.match(/\Amcp__(?<server>[^_][A-Za-z0-9_.-]*)__+(?<operation>.+)\z/))
          return [match[:server], match[:operation]]
        end
        if (match = name.match(/\Amcp[_:-](?<server>[A-Za-z0-9_.-]+)[_:-](?<operation>.+)\z/i))
          return [match[:server], match[:operation]]
        end
        [nil, nil]
      end
      private_class_method :identity

      def domain_of(input)
        return nil unless input.is_a?(Hash)
        value = Support.dig(input, "domain", "host", "url")
        value.to_s[%r{\A(?:[a-z]+://)?([^/:]+)}i, 1]
      end
      private_class_method :domain_of

      Registry.register("mcp", Mcp)
    end
  end
end
