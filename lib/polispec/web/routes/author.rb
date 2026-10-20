#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "securerandom"
require_relative "../proposals"
require_relative "../../author"

module Polispec
  module Web
    Author.planner = Proposals.author_planner

    module AuthorHub
      MAX_SESSIONS = 3
      IDLE_SECONDS = 15 * 60
      HEARTBEAT = 15
      EARLY_WAIT = 1.0
      KIND_MAP = { "project" => "policy", "path" => "module", "global" => "global", "module" => "module" }.freeze
      PASS = %w[delta tool status].freeze
      SID = /\Aases_[0-9a-f]{16}\z/.freeze

      class Session
        attr_reader :sid, :kind, :project, :target_file, :target, :created
        attr_accessor :adapter_session, :stopped, :closed, :running, :used_at, :early_failure, :responded

        def initialize(sid, kind, project, target_file, target)
          @sid = sid
          @kind = kind
          @project = project
          @target_file = target_file
          @target = target
          @created = Time.now.utc
          @used_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @events = []
          @mutex = Mutex.new
          @cv = ConditionVariable.new
          @running = false
          @closed = false
          @stopped = false
          @responded = false
        end

        def push(type, data)
          @mutex.synchronize do
            @events << [type, data]
            @cv.broadcast
          end
        end

        def count
          @mutex.synchronize { @events.length }
        end

        def await(index, seconds)
          @mutex.synchronize do
            @cv.wait(@mutex, seconds) if @events.length <= index && !@closed
            @events[index..-1].to_a
          end
        end

        def await_start(seconds)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
          @mutex.synchronize do
            loop do
              left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              break if @events.length.positive? || !@running || left <= 0

              @cv.wait(@mutex, left)
            end
            @responded = true
          end
        end

        def finish_turn
          @mutex.synchronize do
            @running = false
            @cv.broadcast
          end
        end

        def record_failure(error_hash)
          @mutex.synchronize do
            if @responded || @events.length.positive?
              @events << ["error", error_hash]
            else
              @early_failure = error_hash
            end
            @cv.broadcast
          end
        end

        def close!
          @mutex.synchronize do
            @closed = true
            @events << ["closed", {}]
            @cv.broadcast
          end
        end
      end

      Body = Struct.new(:session, :start, :alive) do
        def call(stream)
          index = start
          beat = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          stream.write(": ready\n\n")
          loop do
            batch = session.await(index, 1.0)
            batch.each do |type, data|
              stream.write("id: #{index + 1}\nevent: #{type}\ndata: #{JSON.generate(data)}\n\n")
              index += 1
              beat = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
            break if session.closed && session.count <= index

            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if now - beat >= HEARTBEAT
              stream.write(": heartbeat\n\n")
              beat = now
            end
            break unless alive.call
          end
        rescue SystemCallError, IOError
          nil
        end
      end

      @sessions = {}
      @lock = Mutex.new
      @port = nil

      class << self
        def port
          @lock.synchronize do
            Polispec::Author.ensure_available!
            @port ||= Polispec::Author.port
          end
        end

        def forget_port
          @lock.synchronize { @port = nil }
        end

        def find(sid)
          @lock.synchronize { @sessions[sid.to_s] }
        end

        def open_count
          @lock.synchronize { @sessions.length }
        end

        def reap
          cutoff = Process.clock_gettime(Process::CLOCK_MONOTONIC) - IDLE_SECONDS
          idle = @lock.synchronize { @sessions.values.select { |session| session.used_at < cutoff && !session.running } }
          idle.each { |session| close(session) }
        end

        def target_of(body)
          file = body["target_file"].to_s
          if file.include?("/")
            kind, id = file.split("/", 2)
            return { "kind" => kind, "id" => id }
          end
          project = body["project"].to_s
          project.empty? ? nil : { "kind" => "project", "id" => project }
        end

        def author_kind(body, target)
          raw = body["kind"].to_s
          mapped = KIND_MAP[raw] || (Polispec::Author::KINDS.include?(raw) ? raw : nil)
          mapped ||= KIND_MAP[target["kind"].to_s] if target
          raise Operator::Failure.new("invalid", "kind must be one of #{Polispec::Author::KINDS.join(', ')}") unless mapped

          mapped
        end

        def roster(project)
          Polispec::Author.load_adapters
          klass = Polispec::Author.registry["harness-cli"]
          spec = klass ? klass.new.role_spec(project: project.to_s) : {}
          { "harness" => spec["harness"], "model" => spec["model"], "effort" => spec["effort"] }
        rescue StandardError
          { "harness" => "claude", "model" => "sonnet", "effort" => "medium" }
        end

        def create(body)
          reap
          raise Operator::Failure.new("busy", "#{MAX_SESSIONS} author sessions are already open on this host; close one first") if open_count >= MAX_SESSIONS

          target = target_of(body)
          kind = author_kind(body, target)
          project = target && target["kind"] == "project" ? target["id"] : body["project"].to_s
          session = Session.new("ases_#{SecureRandom.hex(8)}", kind, project.to_s.empty? ? nil : project.to_s, body["target_file"].to_s.empty? ? nil : body["target_file"].to_s, target)
          @lock.synchronize { @sessions[session.sid] = session }
          { "sid" => session.sid, "kind" => session.kind, "project" => session.project, "target_file" => session.target_file, "roster" => roster(session.project) }
        end

        def context_for(session, supplied)
          target = supplied.is_a?(Hash) && supplied["target"].is_a?(Hash) ? supplied["target"] : session.target
          context = { project: session.project, target_file: target ? "#{target['kind']}/#{target['id']}" : session.target_file, schema_id: "polispec.#{session.kind}/v1" }
          context[:shelf_modules] = Dir.glob(File.join(ROOT, "modules", "*.yml")).map { |file| File.basename(file, ".yml") }.sort
          if target
            begin
              tgt = Proposals.resolve_target(target["kind"], target["id"])
              context[:current_yaml] = Proposals.current_text(tgt)
              context[:schema_id] = "polispec.#{tgt.schema_kind}/v1"
            rescue Polispec::Error
              context[:current_yaml] = nil
            end
          end
          context
        end

        def finding(item)
          code = (item[:code] || item["code"]).to_s
          { "severity" => code.start_with?("description_") || code == "lint_unchecked" ? "warning" : "error", "code" => code, "message" => (item[:message] || item["message"]).to_s, "pointer" => item[:pointer] || item["pointer"] }
        end

        def draft_event(session, result)
          findings = Array(result[:findings]).map { |item| finding(item) }
          yaml = result[:yaml]
          refused = false
          if yaml && Description.ahead_of_runtime?
            refused = (YAML.safe_load(yaml, permitted_classes: [Date, Time], aliases: false) || {})["description"] ? true : false rescue false
          end
          {
            "target" => session.target, "yaml" => yaml, "rationale" => result[:rationale].to_s, "adapter" => result[:adapter], "session" => result[:session],
            "validation" => { "ok" => findings.none? { |item| item["severity"] == "error" } && !yaml.nil?, "findings" => findings },
            "plan" => result[:plan], "description_refused" => refused
          }
        end

        def relay(session)
          lambda do |event|
            type = event[:type].to_s
            next unless PASS.include?(type)

            session.push(type, event.reject { |key, _| key == :type })
          end
        end

        def error_hash(error)
          code = error.respond_to?(:reason) ? error.reason : error.class.name.split("::").last
          { "message" => error.message.to_s[0, 500], "code" => code.to_s, "id" => Web.new_request_id }
        end

        def start_turn(session, intent, context)
          session.running = true
          session.stopped = false
          session.early_failure = nil
          session.responded = false
          session.used_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Thread.new do
            begin
              result = port.draft(kind: session.kind, intent: intent, context: context, session: session.adapter_session, on_event: relay(session))
              session.adapter_session = result[:session]
              session.push("draft", draft_event(session, result))
              session.push("done", {})
            rescue StandardError => e
              session.record_failure(error_hash(e)) unless session.stopped
              session.adapter_session = nil if e.is_a?(Polispec::Author::Unavailable) && e.reason == "unknown_session"
            ensure
              session.finish_turn
            end
          end.tap { |thread| thread.report_on_exception = false }
          session.await_start(EARLY_WAIT)
          session.early_failure
        end

        def stop(session)
          session.stopped = true
          adapter = session.adapter_session
          session.adapter_session = nil
          @port&.close(adapter) if adapter
          session.push("done", { "stopped" => true }) if session.running
        end

        def close(session)
          session.stopped = true
          adapter = session.adapter_session
          session.adapter_session = nil
          @port&.close(adapter) if adapter
          session.close!
          @lock.synchronize { @sessions.delete(session.sid) }
        end

        def close_all
          list = @lock.synchronize { @sessions.values }
          list.each do |session|
            begin
              close(session)
            rescue StandardError
              nil
            end
          end
          @port.close_all if @port && @port.respond_to?(:close_all)
        rescue StandardError
          nil
        end
      end
    end

    Web.at_stop { AuthorHub.close_all }

    Web.route("author", mutating: true) do |r|
      unavailable = lambda do
        begin
          Polispec::Author.ensure_available!
        rescue Polispec::Author::Unavailable => e
          disabled!(e.reason)
        end
      end
      r.on "sessions" do
        r.is do
          r.post do
            unavailable.call
            body = r.POST
            fail!(400, "bad_json", "kind is required") unless body.is_a?(Hash)
            begin
              AuthorHub.create(body)
            rescue Polispec::Error => e
              fail!(*Proposals.describe(e))
            end
          end
          fail!(405, "method_not_allowed", "unsupported method")
        end
        r.on String do |sid|
          session = AuthorHub::SID.match?(sid) ? AuthorHub.find(sid) : nil
          fail!(404, "not_found", "no author session #{sid}") unless session
          r.is do
            r.delete do
              AuthorHub.close(session)
              { "ok" => true }
            end
            fail!(405, "method_not_allowed", "unsupported method")
          end
          r.is "turns" do
            r.post do
              unavailable.call
              body = r.POST
              intent = body.is_a?(Hash) ? body["intent"] : nil
              fail!(400, "bad_json", "intent is required") unless intent.is_a?(String) && !intent.strip.empty? && intent.bytesize <= 8000
              fail!(409, "conflict", "the session is busy with another turn", code: "turn_running") if session.running
              fail!(409, "conflict", "the session is closed", code: "closed") if session.closed
              if session.adapter_session.nil? && Polispec::Author::Bounds.live_locks.length >= Polispec::Author::Bounds::MAX_SESSIONS
                fail!(409, "busy", "three author sessions are already open on this host", code: "busy")
              end
              failure = AuthorHub.start_turn(session, intent, AuthorHub.context_for(session, body["context"]))
              if failure
                code = failure["code"]
                case code
                when "rate_limited" then fail!(429, "rate_limited", failure["message"], retry_after: 30, code: code)
                when "busy" then fail!(409, "busy", failure["message"], code: code)
                when "unknown_session" then fail!(409, "conflict", failure["message"], code: code)
                when "kill_switch", "edition_excluded" then disabled!(code)
                else fail!(502, "author_failed", failure["message"], code: code)
                end
              end
              response.status = 202
              { "ok" => true, "sid" => session.sid }
            end
            fail!(405, "method_not_allowed", "unsupported method")
          end
          r.is "stop" do
            r.post do
              AuthorHub.stop(session)
              { "ok" => true }
            end
            fail!(405, "method_not_allowed", "unsupported method")
          end
          r.is "stream" do
            r.get do
              unavailable.call
              token = current_session.token
              start = r.env["HTTP_LAST_EVENT_ID"].to_s.match?(/\A\d{1,9}\z/) ? r.env["HTTP_LAST_EVENT_ID"].to_i : 0
              body = AuthorHub::Body.new(session, start, -> { !auth.lookup(token).nil? })
              headers = response.headers.to_h.merge("Content-Type" => "text/event-stream", "Cache-Control" => "no-store", "X-Request-Id" => request_id, "X-Accel-Buffering" => "no")
              r.halt([200, headers, body])
            end
            fail!(405, "method_not_allowed", "unsupported method")
          end
          fail!(404, "not_found", "no such route")
        end
        fail!(404, "not_found", "no such route")
      end
      fail!(404, "not_found", "no such route")
    end
  end
end
