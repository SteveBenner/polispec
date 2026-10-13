require "etc"
require "timeout"

module Polispec
  module HarnessControls
    module OwnerHandoff
      TIMEOUT = 60

      module_function

      def profile(owner:, scope:, project:, state_home:, plane:)
        name = owner.to_s
        raise Lifecycle::Failure.new("owner_required", "mutable overlay removal requires an explicit owner", exit_status: 3) if name.empty?
        account = Etc.getpwnam(name)
        raise Lifecycle::Failure.new("owner_invalid", "root cannot be selected as a mutable overlay owner", exit_status: 3) if account.uid.zero?
        selected_scope = scope.to_s
        raise Lifecycle::Failure.new("scope_invalid", "mutable overlay scope must be user or project", exit_status: 3) unless %w[user project].include?(selected_scope)
        home = owned_directory!(account.dir, account.uid, "owner home")
        selected_state = owned_directory!(state_home || File.join(home, ".local", "state"), account.uid, "state home")
        selected_project = nil
        if selected_scope == "project"
          raise Lifecycle::Failure.new("project_required", "project scope requires an explicit project path", exit_status: 3) if project.to_s.empty?
          selected_project = owned_directory!(project, account.uid, "project")
        elsif project
          raise Lifecycle::Failure.new("project_invalid", "project is valid only for project scope", exit_status: 3)
        end
        sdk_home = sdk_home!(plane)
        runtime_dir = runtime_directory(account.uid)
        {
          "owner" => account.name, "uid" => account.uid, "gid" => account.gid,
          "home" => home, "scope" => selected_scope, "project" => selected_project,
          "state_home" => selected_state, "sdk_home" => sdk_home,
          "runtime_dir" => runtime_dir, "protected_paths" => protected_paths(plane)
        }
      rescue ArgumentError
        raise Lifecycle::Failure.new("owner_unknown", "selected owner does not exist", exit_status: 3)
      end

      def run(profile, &operation)
        reader, writer = IO.pipe
        pid = fork do
          reader.close
          begin
            Process.setsid
            $stdout.reopen(File::NULL, "w")
            $stderr.reopen(File::NULL, "w")
            drop_privileges!(profile)
            configure_environment!(profile)
            ports = fresh_ports!
            payload = { "ok" => true, "data" => operation.call(profile, ports) }
          rescue Lifecycle::Failure => error
            payload = { "ok" => false, "code" => error.code, "message" => error.message, "exit_status" => error.exit_status, "data" => error.data, "findings" => error.findings }
          rescue StandardError, ScriptError => error
            payload = { "ok" => false, "code" => "owner_handoff_failed", "message" => "#{error.class}: #{error.message}", "exit_status" => 3, "data" => nil, "findings" => [] }
          end
          bytes = JSON.generate(payload)
          if bytes.bytesize > Files::LIMIT
            bytes = JSON.generate({ "ok" => false, "code" => "owner_handoff_oversize", "message" => "owner handoff response exceeded #{Files::LIMIT} bytes", "exit_status" => 3, "data" => nil, "findings" => [] })
          end
          writer.write(bytes)
          writer.close
          exit! 0
        end
        writer.close
        raw, complete, overflow, status = collect(reader, pid)
        raise Lifecycle::Failure.new("owner_handoff_timeout", "owner handoff exceeded #{TIMEOUT} seconds", exit_status: 3) unless status
        raise Lifecycle::Failure.new("owner_handoff_incomplete", "owner handoff response was incomplete", exit_status: 3) unless complete && status.success?
        raise Lifecycle::Failure.new("owner_handoff_oversize", "owner handoff response exceeded #{Files::LIMIT} bytes", exit_status: 3) if overflow
        response = JSON.parse(raw)
        unless response["ok"] == true
          raise Lifecycle::Failure.new(response["code"] || "owner_handoff_failed", response["message"] || "owner handoff failed", exit_status: response["exit_status"].to_i.nonzero? || 3, data: response["data"], findings: Array(response["findings"]))
        end
        response["data"]
      rescue JSON::ParserError => error
        raise Lifecycle::Failure.new("owner_handoff_invalid", "owner handoff returned invalid JSON: #{error.message}", exit_status: 3)
      rescue SystemCallError, NotImplementedError => error
        raise Lifecycle::Failure.new("owner_handoff_unavailable", "owner handoff is unavailable: #{error.class}: #{error.message}", exit_status: 3)
      ensure
        reader.close if reader && !reader.closed?
        writer.close if writer && !writer.closed?
      end

      def collect(reader, pid)
        content = +""
        overflow = false
        complete = false
        thread = Thread.new do
          loop do
            chunk = reader.readpartial(4096)
            room = Files::LIMIT - content.bytesize
            content << chunk.byteslice(0, room) if room.positive?
            overflow = true if chunk.bytesize > room
          end
        rescue EOFError
          complete = true
        rescue IOError
          complete = false
        end
        status = nil
        Timeout.timeout(TIMEOUT) { _waited, status = Process.waitpid2(pid) }
        thread.join(0.5)
        unless complete && !thread.alive?
          terminate_group(pid)
          reader.close unless reader.closed?
          thread.join(0.5)
        end
        [content, complete && !thread.alive?, overflow, status]
      rescue Timeout::Error
        terminate_group(pid)
        Process.waitpid(pid) rescue nil
        [content, false, overflow, nil]
      rescue SystemCallError
        terminate_group(pid)
        Process.waitpid(pid) rescue nil
        raise
      ensure
        thread.kill if thread && thread.alive?
      end
      private_class_method :collect

      def drop_privileges!(profile)
        uid = profile.fetch("uid")
        gid = profile.fetch("gid")
        Process.groups = []
        Process::GID.change_privilege(gid)
        Process::UID.change_privilege(uid)
        valid = Process.uid == uid && Process.euid == uid && Process.gid == gid && Process.egid == gid && Process.groups.empty?
        raise Lifecycle::Failure.new("privilege_drop_failed", "selected owner identity was not established", exit_status: 3) unless valid
        regained = false
        begin
          Process::UID.change_privilege(0)
          regained = true
        rescue Errno::EPERM
          nil
        end
        raise Lifecycle::Failure.new("privilege_drop_failed", "child retained the ability to regain root", exit_status: 3) if regained
        regained_gid = false
        begin
          Process::GID.change_privilege(0)
          regained_gid = true
        rescue Errno::EPERM
          nil
        end
        raise Lifecycle::Failure.new("privilege_drop_failed", "child retained the ability to regain root group", exit_status: 3) if regained_gid
      rescue Lifecycle::Failure
        raise
      rescue StandardError => error
        raise Lifecycle::Failure.new("privilege_drop_failed", "privilege drop failed: #{error.class}: #{error.message}", exit_status: 3)
      end
      private_class_method :drop_privileges!

      def configure_environment!(profile)
        environment = {
          "HOME" => profile.fetch("home"), "USER" => profile.fetch("owner"), "LOGNAME" => profile.fetch("owner"),
          "XDG_STATE_HOME" => profile.fetch("state_home"), "XDG_CONFIG_HOME" => File.join(profile.fetch("home"), ".config"),
          "RPLUGIN_HOME" => profile.fetch("sdk_home"), "PATH" => "/usr/local/bin:/usr/bin:/bin"
        }
        environment["XDG_RUNTIME_DIR"] = profile["runtime_dir"] if profile["runtime_dir"]
        ENV.replace(environment)
      end
      private_class_method :configure_environment!

      def fresh_ports!
        entry = File.join(ENV.fetch("RPLUGIN_HOME"), "lib", "rplugin.rb")
        require entry unless defined?(::Rplugin::Ports)
        raise Lifecycle::Failure.new("state_unavailable", "the selected owner's rplugin SDK ports are unavailable", exit_status: 3) unless defined?(::Rplugin::Ports)
        ::Rplugin::Ports.for(ID, root: ROOT)
      rescue Lifecycle::Failure
        raise
      rescue StandardError, LoadError => error
        raise Lifecycle::Failure.new("state_unavailable", "selected owner SDK ports failed: #{error.class}: #{error.message}", exit_status: 3)
      end
      private_class_method :fresh_ports!

      def owned_directory!(path, uid, label)
        value = path.to_s
        raise Lifecycle::Failure.new("owner_boundary_invalid", "#{label} must be an absolute path", exit_status: 3) unless value.start_with?("/") && !value.include?("\0")
        expanded = File.expand_path(value)
        each_existing_ancestor(expanded) do |entry|
          raise Lifecycle::Failure.new("owner_boundary_invalid", "#{label} ancestry contains a symlink", exit_status: 3) if File.lstat(entry).symlink?
        end
        stat = File.lstat(expanded)
        valid = stat.directory? && !stat.symlink? && stat.uid == uid && (stat.mode & 0o022).zero?
        raise Lifecycle::Failure.new("owner_boundary_invalid", "#{label} must be a selected-owner directory without group or world write access", exit_status: 3) unless valid
        File.realpath(expanded)
      rescue Lifecycle::Failure
        raise
      rescue SystemCallError => error
        raise Lifecycle::Failure.new("owner_boundary_invalid", "#{label} is unavailable: #{error.class}: #{error.message}", exit_status: 3)
      end
      private_class_method :owned_directory!

      def each_existing_ancestor(path)
        current = path
        entries = []
        loop do
          entries << current if File.exist?(current) || File.symlink?(current)
          parent = File.dirname(current)
          break if parent == current
          current = parent
        end
        entries.reverse_each { |entry| yield entry }
      end
      private_class_method :each_existing_ancestor

      def sdk_home!(plane)
        candidates = []
        runtime = plane.dig("provenance", "runtime")
        if runtime.is_a?(Hash)
          sdk = runtime["sdk"]
          candidates.concat([sdk["realpath"], sdk["path"]]) if sdk.is_a?(Hash)
        end
        value = candidates.compact.find { |path| File.directory?(path.to_s) && !File.symlink?(path.to_s) }
        raise Lifecycle::Failure.new("sdk_profile_unavailable", "active plane does not provide a readable protected SDK directory", exit_status: 3) unless value
        File.realpath(value)
      rescue Lifecycle::Failure
        raise
      rescue SystemCallError => error
        raise Lifecycle::Failure.new("sdk_profile_unavailable", "protected SDK profile is unavailable: #{error.class}: #{error.message}", exit_status: 3)
      end
      private_class_method :sdk_home!

      def runtime_directory(uid)
        path = "/run/user/#{uid}"
        return nil unless File.directory?(path) && !File.symlink?(path)
        stat = File.stat(path)
        stat.uid == uid && (stat.mode & 0o022).zero? ? File.realpath(path) : nil
      rescue SystemCallError
        nil
      end
      private_class_method :runtime_directory

      def protected_paths(plane)
        values = Array(plane["authority_files"])
        values.concat(plane["controls"].values) if plane["controls"].is_a?(Hash)
        values << plane["operator_records"]
        values.concat(["/etc/polispec", "/usr/local/lib/polispec", "/var/lib/polispec"])
        collect_paths(plane.dig("provenance", "runtime"), values)
        values.compact.map { |path| File.expand_path(path.to_s) }.uniq.sort
      end

      def collect_paths(value, result)
        case value
        when Hash
          value.each do |key, item|
            if %w[path realpath launcher entrypoint interpreter].include?(key.to_s) && item.is_a?(String) && item.start_with?("/")
              result << item
            else
              collect_paths(item, result)
            end
          end
        when Array
          value.each { |item| collect_paths(item, result) }
        end
      end
      private_class_method :collect_paths

      def terminate_group(pid)
        Process.kill("TERM", -pid)
        sleep(0.1)
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
      private_class_method :terminate_group
    end
  end
end
