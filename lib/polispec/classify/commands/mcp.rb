require_relative "support"

module Polispec
  module Classify
    module Mcp
      module_function

      def call(tool_name, tool_input, cwd)
        server, operation = identity(tool_name, tool_input)
        return [] unless server
        domain = domain_of(tool_input)
        [Action.new(class: "mcp.call", env_hint: Support.hint("server" => server, "operation" => operation, "domain" => domain, "path" => cwd.to_s), raw: tool_name.to_s)]
      end

      def identity(tool_name, tool_input)
        name = tool_name.to_s
        if (match = name.match(/\Amcp__(?<server>[^_][A-Za-z0-9_.-]*)__+(?<operation>.+)\z/))
          return [match[:server], match[:operation]]
        end
        if (match = name.match(/\Amcp[_:-](?<server>[A-Za-z0-9_.-]+)[_:-](?<operation>.+)\z/i))
          return [match[:server], match[:operation]]
        end
        return [nil, nil] unless name.downcase.include?("mcp") && tool_input.is_a?(Hash)
        server = Support.dig(tool_input, "server", "server_name", "mcp_server")
        operation = Support.dig(tool_input, "operation", "method", "tool", "name")
        server.to_s.empty? || operation.to_s.empty? ? [nil, nil] : [server.to_s, operation.to_s]
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
