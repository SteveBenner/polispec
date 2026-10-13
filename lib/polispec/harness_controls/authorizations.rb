#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "securerandom"
require "socket"
require "timeout"
require_relative "plane"
require_relative "operator_records"

module Polispec
  module HarnessControls
    module Authorizations
      SOCKET_PATH = "/run/polispec/authorizations.sock".freeze
      SOCKET_DIR = File.dirname(SOCKET_PATH).freeze
      DISABLED_PATH = "/etc/polispec/authorizations.disabled".freeze
      STREAM = "harness_authorizations".freeze
      SCHEMA = "polispec.authorization/v1".freeze
      RECORD_SCHEMA = "polispec.authorization.record/v1".freeze
      CONTEXT_KEYS = %w[generation project action_digest rule_id session_id harness action_class env].freeze
      RECORD_ID = /\Aalo_[0-9a-f]{12}\z/
      GENERATION = /\A[0-9a-f]{32}\z/
      DIGEST = /\A[0-9a-f]{64}\z/
      MAX_STRING = 256
      MAX_REQUEST = 16_384
      MAX_REPLY = 32_768
      MAX_PENDING = 16
      REQUEST_TTL = 600
      REDEMPTION_TTL = 600
      CONNECTION_SECONDS = 2.0
      UID_RATE = 60
      GLOBAL_RATE = 300
      MAX_UID_BUCKETS = 256
      BACKLOG = 8

      class Failure < StandardError
        attr_reader :code

        def initialize(code, message)
          @code = code.to_s
          super(message)
        end
      end

      class ProductionRecords
        attr_reader :identity

        def initialize(identity)
          @identity = identity
        end

        def synchronize(&block)
          OperatorRecords.synchronize(STREAM, identity: identity, &block)
        end

        def read
          OperatorRecords.read(STREAM)
        end

        def append(record)
          authenticated = OperatorRecords.append(STREAM, record, identity: identity)
          confirmed = OperatorRecords.read(STREAM).any? do |stored|
            Authority.canonical_json(stored) == Authority.canonical_json(authenticated)
          end
          raise Failure.new("record_unconfirmed", "authorization transition was not confirmed by protected readback") unless confirmed
          authenticated
        end

        def development?
          false
        end
      end

      class DevelopmentRecords
        def initialize(identity: nil)
          @rows = []
          @mutex = Mutex.new
          @identity = identity || {
            "operation" => "development.authorization",
            "generation" => "0" * 32,
            "provenance_digest" => "0" * 64,
            "euid" => 0,
            "launch_evidence" => { "verified" => false, "development" => true }
          }
        end

        def synchronize(&block)
          @mutex.synchronize(&block)
        end

        def read
          Marshal.load(Marshal.dump(@rows))
        end

        def append(record)
          row = deep_stringify(record).merge(
            "authorization" => {
              "caller_operation" => @identity["operation"],
              "append_operation" => "development.append",
              "generation" => @identity["generation"],
              "provenance_digest" => @identity["provenance_digest"],
              "euid" => 0,
              "launch_evidence" => @identity["launch_evidence"]
            }
          )
          @rows << Marshal.load(Marshal.dump(row))
          row
        end

        def development?
          true
        end

        private

        def deep_stringify(value)
          case value
          when Hash
            value.each_with_object({}) { |(key, item), result| result[key.to_s] = deep_stringify(item) }
          when Array
            value.map { |item| deep_stringify(item) }
          else
            value
          end
        end
      end

      class DevelopmentPlane
        def initialize(generation:, identity: nil)
          @generation = generation
          @identity = identity || {
            "operation" => "development.authorization",
            "generation" => generation,
            "provenance_digest" => "0" * 64,
            "euid" => 0,
            "launch_evidence" => { "verified" => false, "development" => true }
          }
        end

        def resolve
          { "status" => "active", "generation" => @generation, "development" => true }
        end

        def operator!(_operation)
          @identity
        end
      end

      class Service
        attr_reader :socket_path

        def initialize(socket_path:, records:, plane:, clock:, kill_switch:, peer_uid:, events:, startup_lock:, development:)
          @socket_path = socket_path
          @records = records
          @plane = plane
          @clock = clock
          @kill_switch = kill_switch
          @peer_uid = peer_uid
          @events = events
          @startup_lock = startup_lock
          @development = development == true
          @uid_windows = {}
          @global_window = []
          @counters = Hash.new(0)
          @started = monotonic
        end

        def serve
          server = nil
          inode = nil
          @startup_lock.call do
            validate_server_destination!
            server = UNIXServer.new(socket_path)
            inode = File.lstat(socket_path).ino
            File.chmod(0o666, socket_path)
            socket = File.lstat(socket_path)
            safe = socket.socket? && socket.uid.zero? && (socket.mode & 0o777) == 0o666 && socket.nlink == 1
            raise Failure.new("socket_unsafe", "authorization socket could not be protected") unless @development || safe
            server.listen(BACKLOG)
          end
          loop do
            client = server.accept
            handle_connection(client)
          ensure
            client.close if client && !client.closed?
          end
        ensure
          server.close if server && !server.closed?
          remove_owned_socket(inode)
        end

        def handle_connection(client, drop_reply: false)
          deadline = monotonic + CONNECTION_SECONDS
          uid = Integer(@peer_uid.call(client))
          rate_limit!(uid)
          request = read_request(client, deadline)
          remaining = deadline - monotonic
          raise Timeout::Error unless remaining.positive?
          response = Timeout.timeout(remaining) { dispatch(request, uid) }
          safe_write_reply(client, response, deadline) unless drop_reply
          response
        rescue Timeout::Error
          @counters["errors"] += 1
          response = reply(request && request["operation"], "unavailable", error: "deadline_exceeded")
          safe_write_reply(client, response, deadline || monotonic) unless drop_reply
          response
        rescue Failure => error
          @counters["errors"] += 1
          response = reply(request && request["operation"], "error", error: error.code)
          safe_write_reply(client, response, deadline || monotonic) unless drop_reply
          response
        rescue StandardError
          @counters["errors"] += 1
          response = reply(request && request["operation"], "unavailable", error: "service_failure")
          safe_write_reply(client, response, deadline || monotonic) unless drop_reply
          response
        ensure
          emit_metric(request && request["operation"], response && response["status"], uid, deadline)
        end

        def dispatch(request, uid)
          operation = request.fetch("operation")
          @counters["requests"] += 1
          return status_reply if operation == "status"
          raise Failure.new("peer_forbidden", "authorization mutation requires a nonroot peer") unless uid.positive?
          disabled!
          context = Authorizations.validate_context(request["context"])
          active = @plane.resolve
          raise Failure.new("plane_unavailable", "authorization service requires an active plane") unless active.is_a?(Hash) && active["status"] == "active"
          raise Failure.new("generation_mismatch", "authorization generation is not active") unless context["generation"] == active["generation"]
          operation == "request" ? issue(context, uid) : consume_transition(context, uid)
        end

        def status_reply
          disabled!
          plane = @plane.resolve
          state = plane.is_a?(Hash) ? plane["status"].to_s : "unavailable"
          raise Failure.new("plane_unavailable", "authorization service requires an active plane") unless state == "active" && GENERATION.match?(plane["generation"].to_s)
          @records.synchronize { Authorizations.fold_rows(@records.read, development: @records.development?) }
          reply("status", "available", data: {
            "plane" => state,
            "generation" => state == "active" ? plane["generation"] : nil,
            "requests" => @counters["requests"],
            "errors" => @counters["errors"],
            "uptime_ms" => ((monotonic - @started) * 1000).to_i,
            "development" => @development
          })
        rescue Failure => error
          reply("status", "unavailable", error: error.code)
        rescue StandardError
          reply("status", "unavailable", error: "dependency_unavailable")
        end

        def issue(context, uid)
          result = nil
          @records.synchronize do
            now = current_time
            states = Authorizations.fold_rows(@records.read, development: @records.development?)
            reusable = states.values.find do |entry|
              entry["state"] == "issued" && entry["uid"] == uid && entry["context"] == context && Authorizations.parse_time(entry["request_expires_at"]) > now
            end
            if reusable
              result = reply("request", "pending", id: reusable["id"])
              next
            end
            pending = states.values.count do |entry|
              entry["uid"] == uid && entry["state"] == "issued" && Authorizations.parse_time(entry["request_expires_at"]) > now
            end
            raise Failure.new("pending_limit", "authorization pending-request capacity is exhausted") if pending >= MAX_PENDING
            id = unique_id(states)
            record = {
              "schema" => RECORD_SCHEMA,
              "event" => "issued",
              "id" => id,
              "uid" => uid,
              "context" => context,
              "issued_at" => Authorizations.timestamp(now),
              "request_expires_at" => Authorizations.timestamp(now + REQUEST_TTL)
            }
            append_transition(record)
            result = reply("request", "pending", id: id)
          end
          result
        end

        def consume_transition(context, uid)
          result = nil
          @records.synchronize do
            now = current_time
            states = Authorizations.fold_rows(@records.read, development: @records.development?)
            match = states.values.select do |entry|
              entry["state"] == "redeemed" && entry["uid"] == uid && entry["context"] == context && Authorizations.parse_time(entry["expires_at"]) > now
            end.min_by { |entry| [entry["redeemed_at"], entry["id"]] }
            unless match
              result = reply("consume", "denied", error: "authorization_unavailable")
              next
            end
            raise Failure.new("invalid_time", "authorization clock moved before redemption") if now < Authorizations.parse_time(match["redeemed_at"])
            record = {
              "schema" => RECORD_SCHEMA,
              "event" => "consumed",
              "id" => match["id"],
              "uid" => uid,
              "context" => context,
              "consumed_at" => Authorizations.timestamp(now)
            }
            append_transition(record)
            consumed = match.merge("state" => "consumed", "consumed_at" => record["consumed_at"])
            result = reply("consume", "consumed", id: match["id"], data: consumed)
          end
          begin
            disabled!
            active = @plane.resolve
            current = active.is_a?(Hash) && active["status"] == "active" && active["generation"] == context["generation"]
            return reply("consume", "unavailable", error: "authority_changed") unless current
          rescue StandardError
            return reply("consume", "unavailable", error: "authority_changed")
          end
          result
        end

        private

        def validate_server_destination!
          return if @development
          raise Failure.new("socket_unsafe", "authorization socket directory cannot be a symlink") if File.symlink?(SOCKET_DIR)
          FileUtils.mkdir_p(SOCKET_DIR, mode: 0o755)
          File.chmod(0o755, SOCKET_DIR)
          stat = File.lstat(SOCKET_DIR)
          raise Failure.new("socket_unsafe", "authorization socket directory must be root-owned 0755") unless stat.directory? && stat.uid.zero? && (stat.mode & 0o777) == 0o755
          findings = Authority.protection_findings(SOCKET_DIR, "authorization_socket")
          raise Failure.new("socket_unsafe", "authorization socket directory ancestry is unsafe") if findings.any? { |row| row["blocking"] }
          raise Failure.new("socket_exists", "authorization socket already exists; operator recovery is required") if File.exist?(socket_path) || File.symlink?(socket_path)
        end

        def remove_owned_socket(inode)
          return unless inode && (File.exist?(socket_path) || File.symlink?(socket_path))
          stat = File.lstat(socket_path)
          File.unlink(socket_path) if stat.socket? && stat.ino == inode
        rescue SystemCallError
          nil
        end

        def read_request(client, deadline)
          bytes = +""
          newline = nil
          loop do
            wait_readable(client, deadline)
            chunk = client.read_nonblock(4096, exception: false)
            break if chunk.nil?
            next if chunk == :wait_readable
            bytes << chunk
            raise Failure.new("request_too_large", "authorization request exceeds #{MAX_REQUEST} bytes") if bytes.bytesize > MAX_REQUEST
            newline ||= bytes.index("\n")
          end
          raise Failure.new("invalid_request", "authorization request must end with one newline") unless newline == bytes.bytesize - 1
          value = JSON.parse(bytes.byteslice(0, newline))
          validate_request(value)
        rescue JSON::ParserError
          raise Failure.new("invalid_json", "authorization request is malformed")
        end

        def validate_request(value)
          raise Failure.new("invalid_request", "authorization request must be an object") unless value.is_a?(Hash)
          operation = value["operation"]
          raise Failure.new("invalid_operation", "authorization operation is invalid") unless %w[request consume status].include?(operation)
          expected = operation == "status" ? %w[operation schema] : %w[context operation schema]
          raise Failure.new("invalid_request", "authorization request fields are invalid") unless value.keys.sort == expected
          raise Failure.new("invalid_schema", "authorization schema is invalid") unless value["schema"] == SCHEMA
          value
        end

        def write_reply(client, response, deadline)
          bytes = JSON.generate(response) + "\n"
          raise Failure.new("reply_too_large", "authorization reply exceeds #{MAX_REPLY} bytes") if bytes.bytesize > MAX_REPLY
          offset = 0
          while offset < bytes.bytesize
            wait_writable(client, deadline)
            count = client.write_nonblock(bytes.byteslice(offset..), exception: false)
            next if count == :wait_writable
            raise Failure.new("transport_closed", "authorization transport closed") unless count
            offset += count
          end
        rescue IOError, SystemCallError
          nil
        end

        def safe_write_reply(client, response, deadline)
          write_reply(client, response, deadline)
        rescue StandardError
          nil
        end

        def wait_readable(io, deadline)
          remaining = deadline - monotonic
          raise Failure.new("deadline_exceeded", "authorization request exceeded its deadline") unless remaining.positive?
          raise Failure.new("deadline_exceeded", "authorization request exceeded its deadline") unless IO.select([io], nil, nil, remaining)
        end

        def wait_writable(io, deadline)
          remaining = deadline - monotonic
          raise Failure.new("deadline_exceeded", "authorization reply exceeded its deadline") unless remaining.positive?
          raise Failure.new("deadline_exceeded", "authorization reply exceeded its deadline") unless IO.select(nil, [io], nil, remaining)
        end

        def rate_limit!(uid)
          now = monotonic
          cutoff = now - 60.0
          @global_window.reject! { |at| at <= cutoff }
          global_limited = @global_window.length >= GLOBAL_RATE
          @global_window << now unless global_limited
          capacity_limited = false
          unless @uid_windows.key?(uid)
            inactive = @uid_windows.keys.find { |key| @uid_windows[key].all? { |at| at <= cutoff } }
            @uid_windows.delete(inactive) if inactive
            if @uid_windows.length >= MAX_UID_BUCKETS
              capacity_limited = true
            else
              @uid_windows[uid] = []
            end
          end
          window = @uid_windows[uid]
          window.reject! { |at| at <= cutoff } if window
          uid_limited = window && window.length >= UID_RATE
          window << now if window && !uid_limited
          raise Failure.new("rate_limited", "authorization global request rate exceeded") if global_limited
          raise Failure.new("rate_capacity", "authorization UID limiter capacity is exhausted") if capacity_limited
          raise Failure.new("rate_limited", "authorization UID request rate exceeded") if uid_limited
        end

        def disabled!
          disabled = @kill_switch.call
          raise Failure.new("disabled", "authorization service is disabled") if disabled
        rescue Failure
          raise
        rescue StandardError
          raise Failure.new("kill_switch_unsafe", "authorization kill switch could not be verified")
        end

        def append_transition(record)
          authenticated = @records.append(record)
          rows = @records.read
          confirmed = rows.any? { |row| Authority.canonical_json(row) == Authority.canonical_json(authenticated) }
          raise Failure.new("record_unconfirmed", "authorization transition was not confirmed by exact readback") unless confirmed
          Authorizations.fold_rows(rows, development: @records.development?)
          authenticated
        end

        def unique_id(states)
          8.times do
            id = "alo_#{SecureRandom.hex(6)}"
            return id unless states.key?(id)
          end
          raise Failure.new("id_capacity", "authorization ID allocation failed")
        end

        def reply(operation, status, id: nil, error: nil, data: nil)
          {
            "schema" => SCHEMA,
            "operation" => operation.to_s,
            "status" => status.to_s,
            "id" => id,
            "error" => error,
            "data" => data
          }
        end

        def emit_metric(operation, status, uid, deadline)
          duration = deadline ? [((monotonic - (deadline - CONNECTION_SECONDS)) * 1000).to_i, 0].max : 0
          @events.call("polispec.authorization", {
            "operation" => operation.to_s,
            "status" => status.to_s,
            "peer_uid" => uid,
            "duration_ms" => duration,
            "request_count" => @counters["requests"],
            "error_count" => @counters["errors"]
          })
        rescue StandardError
          nil
        end

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def current_time
          value = @clock.call
          value.is_a?(Time) ? value.utc : Time.at(Float(value)).utc
        end
      end

      module_function

      def request(context)
        response = client.request(context)
        return response["id"] if response["status"] == "pending"
        raise Failure.new(response["error"] || "unavailable", "authorization request is unavailable")
      end

      def consume(context)
        response = client.consume(context)
        return response["data"] if response["status"] == "consumed"
        return nil if response["status"] == "denied"
        raise Failure.new(response["error"] || "unavailable", "authorization consumption is unavailable")
      end

      def fold
        identity = Plane.operator!("authorizations.fold")
        records = ProductionRecords.new(identity)
        result = nil
        records.synchronize { result = fold_rows(records.read, development: false) }
        result
      end

      def redeem(id, clock: -> { Time.now.utc }, records: nil, plane: Plane, confirmer: Operator::Tty)
        raise Failure.new("invalid_id", "authorization ID is invalid") unless RECORD_ID.match?(id.to_s)
        identity = plane.operator!("authorizations.redeem")
        adapter = records || ProductionRecords.new(identity)
        raise Failure.new("disabled", "authorization service is disabled") if !adapter.development? && disabled_marker!
        snapshot = nil
        adapter.synchronize do
          now = clock_time(clock)
          states = fold_rows(adapter.read, development: adapter.development?)
          entry = states[id.to_s]
          raise Failure.new("unknown_id", "authorization ID is unknown") unless entry
          raise Failure.new("invalid_transition", "authorization is no longer pending") unless entry["state"] == "issued"
          raise Failure.new("authorization_expired", "authorization request has expired") unless parse_time(entry["request_expires_at"]) > now
          context = entry.fetch("context")
          active = plane.resolve
          raise Failure.new("generation_mismatch", "authorization generation is not active") unless active.is_a?(Hash) && active["status"] == "active" && active["generation"] == context["generation"] && identity["generation"] == context["generation"]
          snapshot = Marshal.load(Marshal.dump(entry))
        end
        context = snapshot.fetch("context")
        phrase = "authorize #{snapshot['id']}"
        prompt = "Authorize one call from kernel UID #{snapshot['uid']} for #{context['project']} (#{context['env']}, #{context['harness']}, #{context['action_class']}, rule #{context['rule_id']}, session #{context['session_id']}):\n  action digest #{context['action_digest']}"
        confirmer.confirm!(phrase, prompt: prompt)
        result = nil
        adapter.synchronize do
          now = clock_time(clock)
          raise Failure.new("disabled", "authorization service is disabled") if !adapter.development? && disabled_marker!
          states = fold_rows(adapter.read, development: adapter.development?)
          entry = states[id.to_s]
          raise Failure.new("invalid_transition", "authorization is no longer pending") unless entry && entry["state"] == "issued"
          raise Failure.new("authorization_changed", "authorization request changed during confirmation") unless entry == snapshot
          raise Failure.new("authorization_expired", "authorization request expired during confirmation") unless parse_time(entry["request_expires_at"]) > now
          raise Failure.new("invalid_time", "authorization clock moved before issuance") if now < parse_time(entry["issued_at"])
          active = plane.resolve
          raise Failure.new("generation_mismatch", "authorization generation is not active") unless active.is_a?(Hash) && active["status"] == "active" && active["generation"] == context["generation"] && identity["generation"] == context["generation"]
          record = {
            "schema" => RECORD_SCHEMA,
            "event" => "redeemed",
            "id" => entry["id"],
            "redeemed_at" => timestamp(now),
            "expires_at" => timestamp(now + REDEMPTION_TTL)
          }
          authenticated = adapter.append(record)
          rows = adapter.read
          confirmed = rows.any? { |row| Authority.canonical_json(row) == Authority.canonical_json(authenticated) }
          raise Failure.new("record_unconfirmed", "authorization redemption was not confirmed by exact readback") unless confirmed
          fold_rows(rows, development: adapter.development?)
          result = entry.merge("state" => "redeemed", "redeemed_at" => record["redeemed_at"], "expires_at" => record["expires_at"])
        end
        result
      end

      def serve
        identity = Plane.operator!("authorizations.serve")
        service = Service.new(
          socket_path: SOCKET_PATH,
          records: ProductionRecords.new(identity),
          plane: Plane,
          clock: -> { Time.now.utc },
          kill_switch: method(:disabled_marker!),
          peer_uid: method(:peer_uid),
          events: ->(type, fields) { Events.emit(type, fields) },
          startup_lock: ->(&block) { OperatorRecords.synchronize("authorization_service", identity: identity, &block) },
          development: false
        )
        service.serve
      end

      def development_service(socket_path:, records:, plane:, clock: -> { Time.now.utc }, kill_switch: -> { false }, peer_uid: nil, events: ->(_type, _fields) {})
        expanded = File.expand_path(socket_path.to_s)
        valid = socket_path.to_s.start_with?("/") && expanded.start_with?("/tmp/") && !socket_path.to_s.include?("\0") && File.dirname(expanded) != SOCKET_DIR
        raise Failure.new("invalid_development_path", "development socket must be an absolute scratch path beneath /tmp") unless valid
        resolver = peer_uid || method(:peer_uid)
        startup = Mutex.new
        Service.new(socket_path: expanded, records: records, plane: plane, clock: clock, kill_switch: kill_switch, peer_uid: resolver, events: events, startup_lock: ->(&block) { startup.synchronize(&block) }, development: true)
      end

      def recover(dry_run: false, plane: Plane, confirmer: Operator::Tty, socket_path: SOCKET_PATH)
        identity = plane.operator!("authorizations.recover")
        result = nil
        OperatorRecords.synchronize("authorization_service", identity: identity) do
          raise Failure.new("socket_unavailable", "authorization socket does not exist") unless File.exist?(socket_path) || File.symlink?(socket_path)
          raise Failure.new("socket_unsafe", "authorization recovery is restricted to the fixed socket") unless socket_path == SOCKET_PATH
          directory = File.lstat(SOCKET_DIR)
          socket = File.lstat(socket_path)
          safe = directory.directory? && !directory.symlink? && directory.uid.zero? && (directory.mode & 0o777) == 0o755 && socket.socket? && socket.uid.zero? && (socket.mode & 0o777) == 0o666 && socket.nlink == 1
          findings = Authority.protection_findings(SOCKET_DIR, "authorization_socket")
          raise Failure.new("socket_unsafe", "authorization socket is not protected") unless safe && findings.none? { |row| row["blocking"] }
          inode = socket.ino
          begin
            Timeout.timeout(0.25) do
              probe = UNIXSocket.new(socket_path)
              probe.close
            end
            raise Failure.new("socket_live", "authorization socket has a live listener")
          rescue Errno::ECONNREFUSED
            nil
          rescue Failure
            raise
          rescue StandardError
            raise Failure.new("socket_ambiguous", "authorization socket liveness is ambiguous")
          end
          backup = "#{socket_path}.stale.#{inode}"
          raise Failure.new("backup_exists", "authorization stale-socket backup already exists") if File.exist?(backup) || File.symlink?(backup)
          result = { "dry_run" => dry_run == true, "socket" => socket_path, "inode" => inode, "backup" => backup }
          next if dry_run
          confirmer.confirm!("recover authorization socket #{inode}", prompt: "Rename the confirmed stale authorization socket inode #{inode} to #{backup}.")
          current = File.lstat(socket_path)
          raise Failure.new("socket_changed", "authorization socket changed during recovery") unless current.socket? && current.ino == inode && current.uid.zero?
          raise Failure.new("backup_exists", "authorization stale-socket backup appeared during recovery") if File.exist?(backup) || File.symlink?(backup)
          File.rename(socket_path, backup)
          renamed = File.lstat(backup)
          raise Failure.new("recovery_unconfirmed", "authorization socket backup could not be confirmed") unless renamed.socket? && renamed.ino == inode
          File.open(SOCKET_DIR, File::RDONLY) { |directory_io| directory_io.fsync }
        end
        result
      rescue Errno::ENOENT
        raise Failure.new("socket_changed", "authorization socket changed during recovery")
      end

      def unit
        plane = Plane.resolve
        raise Failure.new("plane_unavailable", "authorization unit requires an active plane") unless plane.is_a?(Hash) && plane["status"] == "active"
        launcher = plane.dig("provenance", "runtime", "launcher", "realpath")
        raise Failure.new("launcher_unavailable", "active plane has no pinned launcher") unless launcher.is_a?(String) && launcher.start_with?("/") && !launcher.match?(/[\s\\\"']/)
        findings = Authority.protection_findings(launcher, "authorization_launcher")
        raise Failure.new("launcher_unsafe", "active pinned launcher is not protected") if findings.any? { |row| row["blocking"] }
        [
          "[Unit]",
          "Description=Polispec one-use authorization service; run polispec authorizations recover after a stale-socket crash",
          "After=local-fs.target",
          "",
          "[Service]",
          "Type=simple",
          "User=root",
          "UMask=0077",
          "ExecStartPre=/usr/bin/test ! -e #{SOCKET_PATH}",
          "ExecStart=#{launcher} authorizations serve",
          "Restart=on-failure",
          "KillMode=control-group",
          "",
          "[Install]",
          "WantedBy=multi-user.target",
          ""
        ].join("\n")
      end

      def fold_rows(rows, development: false)
        raise Failure.new("invalid_history", "authorization history must be an array") unless rows.is_a?(Array) && rows.length <= OperatorRecords::MAX_ROWS
        states = {}
        rows.each do |raw|
          record = stringify_hash(raw)
          validate_record_header!(record, development)
          id = record["id"]
          case record["event"]
          when "issued"
            validate_exact_keys!(record, %w[authorization context event id issued_at request_expires_at schema uid])
            raise Failure.new("invalid_history", "authorization ID is duplicated") if states.key?(id)
            context = validate_context(record["context"])
            issued = parse_time(record["issued_at"])
            expires = parse_time(record["request_expires_at"])
            raise Failure.new("invalid_history", "authorization request expiry is invalid") unless expires > issued && expires <= issued + REQUEST_TTL
            raise Failure.new("invalid_history", "authorization UID is invalid") unless record["uid"].is_a?(Integer) && record["uid"].positive?
            validate_authorization!(record["authorization"], context["generation"], development)
            states[id] = record.merge("state" => "issued", "context" => context)
          when "redeemed"
            validate_exact_keys!(record, %w[authorization event expires_at id redeemed_at schema])
            prior = states[id]
            raise Failure.new("invalid_history", "authorization redemption has no pending issue") unless prior && prior["state"] == "issued"
            redeemed = parse_time(record["redeemed_at"])
            expires = parse_time(record["expires_at"])
            raise Failure.new("invalid_history", "authorization redemption predates issuance") if redeemed < parse_time(prior["issued_at"])
            raise Failure.new("invalid_history", "authorization was redeemed after request expiry") if redeemed >= parse_time(prior["request_expires_at"])
            raise Failure.new("invalid_history", "authorization redemption expiry is invalid") unless expires > redeemed && expires <= redeemed + REDEMPTION_TTL
            validate_authorization!(record["authorization"], prior.dig("context", "generation"), development)
            states[id] = prior.merge("state" => "redeemed", "redeemed_at" => record["redeemed_at"], "expires_at" => record["expires_at"])
          when "consumed"
            validate_exact_keys!(record, %w[authorization consumed_at context event id schema uid])
            prior = states[id]
            raise Failure.new("invalid_history", "authorization consumption has no redemption") unless prior && prior["state"] == "redeemed"
            context = validate_context(record["context"])
            consumed = parse_time(record["consumed_at"])
            raise Failure.new("invalid_history", "authorization consumption binding differs") unless record["uid"] == prior["uid"] && context == prior["context"]
            raise Failure.new("invalid_history", "authorization consumption time is invalid") unless consumed >= parse_time(prior["redeemed_at"]) && consumed < parse_time(prior["expires_at"])
            validate_authorization!(record["authorization"], context["generation"], development)
            states[id] = prior.merge("state" => "consumed", "consumed_at" => record["consumed_at"])
          else
            raise Failure.new("invalid_history", "authorization event is invalid")
          end
        end
        states
      end

      def validate_context(value)
        context = stringify_hash(value)
        validate_exact_keys!(context, CONTEXT_KEYS)
        CONTEXT_KEYS.each do |key|
          text = context[key]
          raise Failure.new("invalid_context", "authorization context #{key} is invalid") unless text.is_a?(String) && !text.empty? && text.bytesize <= MAX_STRING && text.valid_encoding? && !text.include?("\0")
        end
        raise Failure.new("invalid_context", "authorization generation is invalid") unless GENERATION.match?(context["generation"])
        raise Failure.new("invalid_context", "authorization action digest is invalid") unless DIGEST.match?(context["action_digest"])
        context
      end

      def disabled_marker!
        parent = File.dirname(DISABLED_PATH)
        ancestry = File.exist?(parent) || File.symlink?(parent) ? parent : File.dirname(parent)
        stat = File.lstat(ancestry)
        safe_ancestry = stat.directory? && !stat.symlink? && stat.uid.zero? && (stat.mode & 0o022).zero?
        findings = Authority.protection_findings(ancestry, "authorization_kill_switch")
        raise Failure.new("kill_switch_unsafe", "authorization kill switch ancestry is unsafe") unless safe_ancestry && findings.none? { |row| row["blocking"] }
        return false unless File.exist?(DISABLED_PATH) || File.symlink?(DISABLED_PATH)
        stat = File.lstat(DISABLED_PATH)
        safe = stat.file? && !stat.symlink? && stat.uid.zero? && (stat.mode & 0o022).zero? && stat.nlink == 1
        marker_findings = Authority.protection_findings(DISABLED_PATH, "authorization_kill_switch")
        raise Failure.new("kill_switch_unsafe", "authorization kill switch is unsafe") unless safe && marker_findings.none? { |row| row["blocking"] }
        true
      rescue SystemCallError
        raise Failure.new("kill_switch_unsafe", "authorization kill switch could not be verified")
      end

      def peer_uid(socket)
        raise Failure.new("peer_unavailable", "Linux peer credentials are unavailable") unless Socket.const_defined?(:SO_PEERCRED)
        bytes = socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_PEERCRED).to_s
        values = bytes.unpack("iii")
        raise Failure.new("peer_unavailable", "Linux peer credentials are malformed") unless values.length == 3
        values[1]
      rescue SystemCallError
        raise Failure.new("peer_unavailable", "Linux peer credentials could not be read")
      end

      def client
        require_relative "authorization_client"
        AuthorizationClient
      end

      def validate_record_header!(record, development)
        raise Failure.new("invalid_history", "authorization record must be an object") unless record.is_a?(Hash)
        raise Failure.new("invalid_history", "authorization record schema is invalid") unless record["schema"] == RECORD_SCHEMA
        raise Failure.new("invalid_history", "authorization record ID is invalid") unless RECORD_ID.match?(record["id"].to_s)
        raise Failure.new("invalid_history", "authorization record lacks authenticated provenance") unless development || record["authorization"].is_a?(Hash)
      end
      private_class_method :validate_record_header!

      def validate_authorization!(value, generation, development)
        auth = stringify_hash(value)
        required = %w[append_operation caller_operation euid generation launch_evidence provenance_digest]
        validate_exact_keys!(auth, required)
        return if development && auth["launch_evidence"].is_a?(Hash) && auth["launch_evidence"]["development"] == true
        operations = %w[append_operation caller_operation].all? do |key|
          auth[key].is_a?(String) && !auth[key].empty? && auth[key].bytesize <= MAX_STRING && !auth[key].include?("\0")
        end
        evidence = auth["launch_evidence"]
        bounded_value!(evidence, 0)
        valid = operations && Authority.canonical_json(evidence).bytesize <= MAX_REQUEST && auth["euid"] == 0 && auth["generation"] == generation && DIGEST.match?(auth["provenance_digest"].to_s) && evidence.is_a?(Hash) && evidence["verified"] == true
        raise Failure.new("invalid_history", "authorization record provenance is invalid") unless valid
      end
      private_class_method :validate_authorization!

      def bounded_value!(value, depth)
        raise Failure.new("invalid_history", "authorization provenance is too deeply nested") if depth > 8
        case value
        when Hash
          raise Failure.new("invalid_history", "authorization provenance has too many fields") if value.length > 128
          value.each do |key, item|
            raise Failure.new("invalid_history", "authorization provenance key is invalid") unless key.is_a?(String) && key.bytesize <= MAX_STRING && !key.include?("\0")
            bounded_value!(item, depth + 1)
          end
        when Array
          raise Failure.new("invalid_history", "authorization provenance array is too large") if value.length > 128
          value.each { |item| bounded_value!(item, depth + 1) }
        when String
          raise Failure.new("invalid_history", "authorization provenance string is too large") unless value.bytesize <= 4096 && value.valid_encoding? && !value.include?("\0")
        when Integer, Float, TrueClass, FalseClass, NilClass
          nil
        else
          raise Failure.new("invalid_history", "authorization provenance value is invalid")
        end
      end
      private_class_method :bounded_value!

      def validate_exact_keys!(hash, keys)
        raise Failure.new("invalid_fields", "authorization fields are invalid") unless hash.is_a?(Hash) && hash.keys.sort == keys.sort
      end
      private_class_method :validate_exact_keys!

      def stringify_hash(value)
        raise Failure.new("invalid_object", "authorization value must be an object") unless value.is_a?(Hash)
        value.each_with_object({}) { |(key, item), result| result[key.to_s] = item }
      end
      private_class_method :stringify_hash

      def parse_time(value)
        raise Failure.new("invalid_time", "authorization time is invalid") unless value.is_a?(String) && value.bytesize <= 64
        Time.iso8601(value).utc
      rescue ArgumentError
        raise Failure.new("invalid_time", "authorization time is invalid")
      end

      def timestamp(value)
        value.utc.iso8601(6)
      end

      def clock_time(clock)
        value = clock.call
        value.is_a?(Time) ? value.utc : Time.at(Float(value)).utc
      rescue ArgumentError, TypeError
        raise Failure.new("invalid_time", "authorization clock is invalid")
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
      private_class_method :monotonic
    end
  end
end
