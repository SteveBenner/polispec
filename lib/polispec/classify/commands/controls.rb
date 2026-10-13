require_relative "support"
require_relative "../tool"

module Polispec
  module Classify
    module Controls
      FIXED = ["/etc/polispec", "/usr/local/lib/polispec", "/var/lib/polispec", "/run/polispec"].freeze
      MARKERS = ["/.polispec/harness/", "/.config/polispec/harness/"].freeze

      module_function

      def call(tool_name, tool_input, cwd)
        name = tool_name.to_s.downcase
        paths = if Tool::PATCH_TOOLS.include?(name)
                  Tool.patch_changes(tool_input).flat_map { |change| [change["old"], change["new"]] }
                elsif Tool::WRITE_TOOLS.include?(name) || Tool::DELETE_TOOLS.include?(name)
                  Tool.write_paths(tool_input)
                else
                  []
                end
        paths.compact.map { |path| File.expand_path(path.to_s, cwd.to_s.empty? ? Dir.pwd : cwd.to_s) }.select { |path| control_path?(path) }.uniq.map do |path|
          Action.new(class: "control.edit", env_hint: { "path" => path }, raw: tool_name.to_s)
        end
      end

      def control_path?(path)
        FIXED.any? { |root| path == root || path.start_with?("#{root}/") || root.start_with?("#{path}/") } || MARKERS.any? { |marker| path.include?(marker) }
      end
      private_class_method :control_path?

      Registry.register("controls", Controls)
    end
  end
end
