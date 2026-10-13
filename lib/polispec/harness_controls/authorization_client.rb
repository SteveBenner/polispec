#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "socket"
require "timeout"
require_relative "authorizations"

module Polispec
  module HarnessControls
    module AuthorizationClient
      REQUESTS_PER_MINUTE = 48
      TOTAL_SECONDS = 2.0
      RETRIES = 1
      BREAKER_FAILURES = 3
      BREAKER_SECONDS = 10.0
      JITTER_MIN = 0.025
      JITTER_MAX = 0.100

      @mutex = Mutex.new
      @window = []
      @transport_failures = 0
      @breaker_until = 0.0
      @metrics_mutex = Mutex.new
      @request_count = 0
      @success_count = 0
      @failure_count = 0
      @latencies = []

      module_function

      def request(context)
        call("request", context)
      end

      def consume(context)
        call("consume", context)
      end

      def status
        call("status", nil)
      end

      def call(operation, context)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = call_with(operation, context, socket_path: Authorizations::SOCKET_PATH, verify_peer: true, development: false)
        record_metric(operation, response, started)
        response
      end

      def call_with(operation, context, socket_path:, verify_peer:, development:, clock: nil, sleeper: nil, random: nil, authority_check: nil)
        now = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        sleep_call = sleeper || ->(seconds) { sleep(seconds) }
        rng = random || Random.new
        return unavailable(operation, "client_saturated") unless @mutex.try_lock
        begin
          current = now.call
          return unavailable(operation, "circuit_open") if current < @breaker_until
          @window.reject! { |at| at <= current - 60.0 }
          return unavailable(operation, "client_rate_limited") if @window.length >= REQUESTS_PER_MINUTE
          @window << current
          deadline = current + TOTAL_SECONDS
          payload = request_payload(operation, context)
          attempts = 0
          begin
            attempts += 1
            response = exchange(payload, socket_path, deadline, now, verify_peer && !development)
            response = validate_response(response, operation, context)
            @transport_failures = 0
            if response["status"] == "consumed"
              check = authority_check || method(:production_authority_current?)
              begin
                remaining = deadline - now.call
                return unavailable(operation, "authority_changed") unless remaining.positive?
                current_authority = Timeout.timeout(remaining) { check.call(context) }
                return unavailable(operation, "authority_changed") unless current_authority
              rescue StandardError
                return unavailable(operation, "authority_changed")
              end
            end
            response
          rescue ConnectFailure
            if attempts <= RETRIES && deadline - now.call > JITTER_MIN
              maximum = [JITTER_MAX, deadline - now.call].min
              delay = JITTER_MIN + rng.rand * [maximum - JITTER_MIN, 0].max
              sleep_call.call(delay)
              retry
            end
            transport_failed(operation, now.call)
          rescue TransportFailure
            transport_failed(operation, now.call)
          rescue Authorizations::Failure => error
            unavailable(operation, error.code)
          end
        ensure
          @mutex.unlock
        end
      end

      def reset_development_state!
        @mutex.synchronize do
          @window = []
          @transport_failures = 0
          @breaker_until = 0.0
        end
      end

      class ConnectFailure < StandardError; end
      class TransportFailure < StandardError; end

      def exchange(payload, path, deadline, clock, verify_peer)
        verify_socket!(path) if verify_peer
        socket = nil
        begin
          remaining = deadline - clock.call
          raise ConnectFailure unless remaining.positive?
          socket = Timeout.timeout(remaining) { UNIXSocket.new(path) }
          verify_server_peer!(socket) if verify_peer
          bytes = JSON.generate(payload) + "\n"
          raise Authorizations::Failure.new("request_too_large", "authorization request is too large") if bytes.bytesize > Authorizations::MAX_REQUEST
          write_all(socket, bytes, deadline, clock)
          socket.shutdown(Socket::SHUT_WR)
          read_reply(socket, deadline, clock)
        rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::EACCES, Timeout::Error
          raise(socket ? TransportFailure : ConnectFailure)
        rescue IOError, SystemCallError
          raise(socket ? TransportFailure : ConnectFailure)
        ensure
          socket.close if socket && !socket.closed?
        end
      end
      private_class_method :exchange

      def write_all(socket, bytes, deadline, clock)
        offset = 0
        while offset < bytes.bytesize
          wait_writable(socket, deadline, clock)
          count = socket.write_nonblock(bytes.byteslice(offset..), exception: false)
          next if count == :wait_writable
          raise TransportFailure unless count
          offset += count
        end
        true
      end
      private_class_method :write_all

      def read_reply(socket, deadline, clock)
        bytes = +""
        loop do
          wait_readable(socket, deadline, clock)
          chunk = socket.read_nonblock(4096, exception: false)
          break if chunk.nil?
          next if chunk == :wait_readable
          bytes << chunk
          raise TransportFailure if bytes.bytesize > Authorizations::MAX_REPLY
        end
        newline = bytes.index("\n")
        raise TransportFailure unless newline == bytes.bytesize - 1
        value = JSON.parse(bytes.byteslice(0, newline))
        raise TransportFailure unless value.is_a?(Hash)
        value
      rescue JSON::ParserError
        raise TransportFailure
      end
      private_class_method :read_reply

      def wait_readable(socket, deadline, clock)
        remaining = deadline - clock.call
        raise TransportFailure unless remaining.positive? && IO.select([socket], nil, nil, remaining)
      end
      private_class_method :wait_readable

      def wait_writable(socket, deadline, clock)
        remaining = deadline - clock.call
        raise TransportFailure unless remaining.positive? && IO.select(nil, [socket], nil, remaining)
      end
      private_class_method :wait_writable

      def request_payload(operation, context)
        raise Authorizations::Failure.new("invalid_operation", "authorization client operation is invalid") unless %w[request consume status].include?(operation)
        payload = { "schema" => Authorizations::SCHEMA, "operation" => operation }
        payload["context"] = Authorizations.validate_context(context) unless operation == "status"
        payload
      end
      private_class_method :request_payload

      def validate_response(response, operation, context)
        expected = %w[data error id operation schema status]
        raise TransportFailure unless response.keys.sort == expected
        raise TransportFailure unless response["schema"] == Authorizations::SCHEMA && response["operation"] == operation
        statuses = operation == "request" ? %w[pending error unavailable] : operation == "consume" ? %w[consumed denied error unavailable] : %w[available unavailable error]
        raise TransportFailure unless statuses.include?(response["status"])
        if %w[pending consumed].include?(response["status"])
          raise TransportFailure unless Authorizations::RECORD_ID.match?(response["id"].to_s)
        end
        case response["status"]
        when "pending"
          raise TransportFailure unless response["error"].nil? && response["data"].nil?
        when "consumed"
          entry = response["data"]
          valid = entry.is_a?(Hash) && entry["id"] == response["id"] && entry["state"] == "consumed" && entry["context"] == context && entry["uid"].is_a?(Integer) && entry["uid"].positive?
          raise TransportFailure unless valid && response["error"].nil?
        when "available"
          data = response["data"]
          keys = %w[development errors generation plane requests uptime_ms]
          raise TransportFailure unless response["id"].nil? && response["error"].nil? && data.is_a?(Hash) && data.keys.sort == keys
        else
          error = response["error"]
          raise TransportFailure unless response["id"].nil? && response["data"].nil? && error.is_a?(String) && !error.empty? && error.bytesize <= 64
        end
        response
      end
      private_class_method :validate_response

      def verify_socket!(path)
        raise Authorizations::Failure.new("socket_unsafe", "authorization client is restricted to the fixed socket") unless path == Authorizations::SOCKET_PATH
        raise ConnectFailure unless File.exist?(path) || File.symlink?(path)
        raise Authorizations::Failure.new("socket_unsafe", "authorization socket is not a regular Unix socket") unless File.socket?(path) && !File.symlink?(path)
        directory = File.lstat(Authorizations::SOCKET_DIR)
        socket = File.lstat(path)
        safe = directory.directory? && !directory.symlink? && directory.uid.zero? && (directory.mode & 0o777) == 0o755 && socket.socket? && socket.uid.zero? && (socket.mode & 0o777) == 0o666 && socket.nlink == 1
        findings = Authority.protection_findings(Authorizations::SOCKET_DIR, "authorization_socket")
        raise Authorizations::Failure.new("socket_unsafe", "authorization socket is not protected") unless safe && findings.none? { |row| row["blocking"] }
      rescue SystemCallError
        raise ConnectFailure
      end
      private_class_method :verify_socket!

      def verify_server_peer!(socket)
        uid = Authorizations.peer_uid(socket)
        raise Authorizations::Failure.new("peer_untrusted", "authorization service peer is not root") unless uid.zero?
      end
      private_class_method :verify_server_peer!

      def transport_failed(operation, current)
        @transport_failures += 1
        if @transport_failures >= BREAKER_FAILURES
          @breaker_until = current + BREAKER_SECONDS
        end
        unavailable(operation, "transport_unavailable")
      end
      private_class_method :transport_failed

      def production_authority_current?(context)
        plane = Plane.resolve
        return false unless plane.is_a?(Hash) && plane["status"] == "active" && plane["generation"] == context["generation"]
        Authorizations.disabled_marker! == false
      rescue StandardError
        false
      end
      private_class_method :production_authority_current?

      def record_metric(operation, response, started)
        elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).to_i
        snapshot = @metrics_mutex.synchronize do
          @request_count += 1
          if %w[pending consumed available denied].include?(response["status"])
            @success_count += 1
          else
            @failure_count += 1
          end
          @latencies << elapsed
          @latencies.shift while @latencies.length > 128
          sorted = @latencies.sort
          {
            "operation" => operation.to_s,
            "status" => response["status"].to_s,
            "endpoint" => "local_unix",
            "request_count" => @request_count,
            "success_count" => @success_count,
            "failure_count" => @failure_count,
            "transport_failures" => @transport_failures,
            "limiter_remaining" => [REQUESTS_PER_MINUTE - @window.length, 0].max,
            "in_flight_limit" => 1,
            "p50_ms" => percentile(sorted, 0.50),
            "p95_ms" => percentile(sorted, 0.95),
            "p99_ms" => percentile(sorted, 0.99)
          }
        end
        Events.emit("polispec.authorization_client", snapshot)
      rescue StandardError
        nil
      end
      private_class_method :record_metric

      def percentile(values, ratio)
        return 0 if values.empty?
        values[[((values.length - 1) * ratio).ceil, values.length - 1].min]
      end
      private_class_method :percentile

      def unavailable(operation, code)
        {
          "schema" => Authorizations::SCHEMA,
          "operation" => operation.to_s,
          "status" => "unavailable",
          "id" => nil,
          "error" => code.to_s,
          "data" => nil
        }
      end
      private_class_method :unavailable
    end
  end
end
