#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module HarnessControls
    module RootGuard
      CONTAINER_COMMANDS = %w[docker podman nerdctl lxc incus].freeze
      SHELL_TOOLS = %w[Bash shell shell.exec exec_command terminal Monitor].freeze
      SOCKET_NAMES = %w[docker.sock podman.sock containerd.sock].freeze

      module_function

      def classify(tool_name, tool_input, cwd)
        argv = command_argv(tool_name, tool_input)
        return [] if argv.empty?

        command_index = argv.index { |item| CONTAINER_COMMANDS.include?(File.basename(item.to_s)) }
        return [] unless command_index

        command = File.basename(argv[command_index].to_s)
        arguments = argv[(command_index + 1)..-1] || []
        risks = risks_for(command, arguments, argv)
        risks.map do |risk|
          Polispec::Action.new(
            class: "shell.exec",
            env_hint: { "cwd" => cwd.to_s },
            raw: { "root_guard_risk" => risk }
          )
        end
      rescue ArgumentError
        []
      end

      def command_argv(tool_name, tool_input)
        name = tool_name.to_s
        if CONTAINER_COMMANDS.include?(File.basename(name))
          return [name] + direct_arguments(tool_input)
        end
        return [] unless SHELL_TOOLS.include?(name) || SHELL_TOOLS.include?(File.basename(name))

        text = if tool_input.is_a?(Hash)
                 tool_input["cmd"] || tool_input[:cmd] || tool_input["command"] || tool_input[:command]
               else
                 tool_input
               end
        return [] unless text.is_a?(String) && text.bytesize <= 64 * 1024

        Shellwords.split(text)
      end
      private_class_method :command_argv

      def direct_arguments(tool_input)
        return tool_input.map(&:to_s) if tool_input.is_a?(Array)
        if tool_input.is_a?(Hash)
          value = tool_input["argv"] || tool_input[:argv] || tool_input["args"] || tool_input[:args]
          return value.map(&:to_s) if value.is_a?(Array)
        end
        return Shellwords.split(tool_input) if tool_input.is_a?(String) && tool_input.bytesize <= 64 * 1024

        []
      end
      private_class_method :direct_arguments

      def risks_for(command, arguments, argv)
        risks = []
        risks << risk("privileged_container", "#{command} requests privileged container execution.") if privileged?(arguments) || lxd_privileged?(command, arguments)
        risks << risk("host_mount", "#{command} requests a host bind mount.") if host_mount?(arguments)
        risks << risk("daemon_socket", "#{command} requests container daemon socket access.") if daemon_socket?(argv)
        risks << risk("host_namespace", "#{command} requests a host namespace or device boundary.") if host_boundary?(arguments)
        risks << risk("host_device", "#{command} requests a host device.") if lxd_host_device?(command, arguments)
        risks.uniq { |item| item["code"] }
      end
      private_class_method :risks_for

      def privileged?(arguments)
        arguments.each_with_index.any? do |item, index|
          item == "--privileged" || item.start_with?("--privileged=") ||
            item == "--cap-add=ALL" || item == "--cap-add=SYS_ADMIN" ||
            (item == "--cap-add" && %w[ALL SYS_ADMIN].include?(arguments[index + 1]))
        end
      end
      private_class_method :privileged?

      def lxd_privileged?(command, arguments)
        %w[lxc incus].include?(command) && arguments.any? { |item| item == "security.privileged=true" }
      end
      private_class_method :lxd_privileged?

      def host_mount?(arguments)
        arguments.each_with_index.any? do |item, index|
          if %w[-v --volume].include?(item)
            bind_source?(arguments[index + 1])
          elsif item.start_with?("--volume=") || item.start_with?("-v=")
            bind_source?(item.split("=", 2).last)
          elsif item.start_with?("-v") && item.length > 2
            bind_source?(item[2..-1])
          elsif item == "--mount"
            mount_spec_risky?(arguments[index + 1])
          elsif item.start_with?("--mount=")
            mount_spec_risky?(item.split("=", 2).last)
          else
            false
          end
        end
      rescue StandardError
        false
      end
      private_class_method :host_mount?

      def bind_source?(value)
        return false unless value

        source = value.to_s.split(":", 2).first
        source.start_with?("/", "./", "../", "~/") || source == "." || source == ".." || source.include?("/")
      end
      private_class_method :bind_source?

      def mount_spec_risky?(value)
        return false unless value

        fields = value.to_s.split(",").map { |field| field.split("=", 2) }.to_h
        type = fields["type"]
        source = fields["source"] || fields["src"]
        type == "bind" && !source.to_s.empty?
      rescue StandardError
        false
      end
      private_class_method :mount_spec_risky?

      def daemon_socket?(arguments)
        arguments.any? do |item|
          SOCKET_NAMES.any? { |socket| item.to_s.include?(socket) } || item.to_s.start_with?("DOCKER_HOST=unix:", "CONTAINER_HOST=unix:")
        end
      end
      private_class_method :daemon_socket?

      def host_boundary?(arguments)
        arguments.each_with_index.any? do |item, index|
          item == "--pid=host" || item == "--network=host" || item == "--ipc=host" || item == "--uts=host" ||
            item == "--device" || item.start_with?("--device=") ||
            (item == "--pid" && arguments[index + 1] == "host") ||
            (item == "--network" && arguments[index + 1] == "host") ||
            (item == "--ipc" && arguments[index + 1] == "host") ||
            (item == "--uts" && arguments[index + 1] == "host")
        end
      end
      private_class_method :host_boundary?

      def lxd_host_device?(command, arguments)
        return false unless %w[lxc incus].include?(command)
        return false unless arguments.each_cons(3).any? { |items| items == %w[config device add] }

        device_types = %w[disk unix-char unix-block gpu usb pci proxy]
        arguments.any? { |item| device_types.include?(item) } || arguments.any? { |item| item.start_with?("source=/", "path=/dev/") }
      end
      private_class_method :lxd_host_device?

      def risk(code, detail)
        { "code" => code, "detail" => detail, "disposition" => "deny" }
      end
      private_class_method :risk
    end
  end
end
