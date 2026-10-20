#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "etc"
require "json"
require "shellwords"
require "socket"
require_relative "../proposals"
require_relative "../../delegate"
require_relative "../../exceptions"

module Polispec
  module Web
    module DelegateClient
      APP = "polispec-web".freeze
      RUN_ID = /\Adrn_[0-9a-f]{12}\z/.freeze
      VERBS = %w[add promote remove].freeze
      OPERATOR_VERBS = %w[pause allow-once seal plane deploy].freeze
      WAIT = 10

      class Unavailable < Polispec::Error; end

      module_function

      def token
        path = File.join(Web.dir, "delegate.token")
        text = File.file?(path) ? File.read(path).strip : ""
        raise Unavailable, "no delegate token is stored: run polispec web token set in a terminal" if text.empty?

        text
      end

      def by
        name = begin
          Etc.getpwuid(Process.uid).name
        rescue StandardError
          "user"
        end
        "web:#{name}".gsub(/[^A-Za-z0-9 ._@:-]/, "_")[0, 64]
      end

      def call(request)
        path = Polispec::Delegate.socket_path
        raise Unavailable, "the delegate runner is not running: start it with polispec delegate serve" unless File.socket?(path)

        secret = token
        UNIXSocket.open(path) do |sock|
          sock.write("#{JSON.generate(request.merge('app' => APP, 'token' => secret))}\n")
          raise Unavailable, "the delegate runner did not answer in #{WAIT} s" unless IO.select([sock], nil, nil, WAIT)

          parsed = JSON.parse(sock.gets.to_s)
          raise Unavailable, "the delegate runner sent an unreadable answer" unless parsed.is_a?(Hash)

          parsed
        end
      rescue SystemCallError, IOError, JSON::ParserError => e
        raise Unavailable, "the delegate runner could not be reached: #{e.class}"
      end

      def refuse(reply)
        code = reply["code"].to_s
        detail = reply["detail"].to_s
        case code
        when "unauthorized" then [403, "disabled", "the delegate runner did not accept the stored token; run polispec web token set", { reason: "delegate_unauthorized" }]
        when "disabled" then [403, "disabled", "delegation is disabled#{detail.empty? ? '' : " (#{detail})"}", { reason: "delegate_disabled" }]
        when "out_of_scope" then [422, "out_of_scope", detail.empty? ? "the grant does not cover that request" : detail, { code: code }]
        when "busy" then [409, "busy", "an exceptions run is already active", { run_id: reply["run_id"], code: code }.reject { |_, value| value.nil? }]
        when "rate_limited" then [429, "rate_limited", "the delegate runner is rate limiting this app", { retry_after: 30 }]
        when "not_found" then [404, "not_found", "no such run", {}]
        when "not_waiting" then [200, "not_waiting", "the run is not waiting for a phrase", {}]
        else [422, code.empty? ? "delegate_error" : code, detail.empty? ? "the delegate runner refused the request" : detail, { code: code }]
        end
      end
    end

    module ExceptionsRoute
      module_function

      def stamp(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def usage
        table = Hash.new { |hash, key| hash[key] = { "hits" => 0, "first" => nil, "last" => nil, "sessions" => {} } }
        Judgments.recent.each do |record|
          Array(record["exceptions"]).each do |id|
            row = table[id]
            row["hits"] += 1
            ts = record["ts"].to_s
            row["first"] = ts if row["first"].nil? || ts < row["first"]
            row["last"] = ts if row["last"].nil? || ts > row["last"]
            session = record.dig("action", "session_id")
            next unless session

            entry = row["sessions"][session] ||= { "id" => session, "harness" => record.dig("action", "harness"), "last_use" => ts, "hits" => 0 }
            entry["hits"] += 1
            entry["last_use"] = ts if ts > entry["last_use"]
          end
        end
        table
      end

      def adders
        map = {}
        Changes.records.each do |change|
          next unless change["kind"] == "exceptions.add"

          Array(change.dig("subject", "entry_ids")).each { |id| map[id] = change["actor"] }
        end
        map
      end

      def list
        Exceptions.reset!
        loaded = Exceptions.load
        usage_by = usage
        authors = adders
        rows = loaded.entries.map do |entry|
          used = usage_by.key?(entry["id"]) ? usage_by[entry["id"]] : { "hits" => 0, "first" => nil, "last" => nil, "sessions" => {} }
          {
            "id" => entry["id"], "kind" => entry["kind"], "tool" => entry["tool"], "command" => entry["command"], "rule" => entry["rule"], "scope" => entry["scope"],
            "note" => entry["note"], "added_by" => authors[entry["id"]], "added" => entry["added"], "first_use" => used["first"], "last_use" => used["last"],
            "hits" => used["hits"], "sessions" => used["sessions"].values.sort_by { |item| item["last_use"] }.reverse
          }
        end
        { "exceptions" => rows, "enabled" => Exceptions.enabled?, "problems" => loaded.problems }
      end

      def proposer(proposal, ledger)
        located = ledger.locate(proposal["cwd"].to_s, paths: true) unless proposal["cwd"].to_s.empty?
        id = located && (located.project ? located.project.id : located.entry&.id)
        id ? "agent in #{id}" : "agent"
      rescue StandardError
        "agent"
      end

      def proposals
        ledger = Ledger.load
        rows = Exceptions.proposals.map do |item|
          {
            "id" => item["id"], "kind" => item["kind"], "tool" => item["tool"], "command" => item["command"], "rule" => item["rule"], "proposed_by" => proposer(item, ledger),
            "reason" => item["rule"] ? "blocked by #{item['rule']}" : "blocked by a harness control", "ts" => item["created"]
          }
        end
        { "proposals" => rows }
      end

      def operator_command(verb, args)
        words = ["polispec", verb] + Array(args).select { |item| item.is_a?(String) }.first(8).map { |item| Shellwords.escape(item) }
        words.join(" ")
      end
    end

    Web.route("exceptions", mutating: true) do |r|
      r.is do
        r.get { ExceptionsRoute.list }
        fail!(405, "method_not_allowed", "unsupported method")
      end
      r.is "proposals" do
        r.get { ExceptionsRoute.proposals }
        fail!(405, "method_not_allowed", "unsupported method")
      end
      r.is String do |verb|
        r.post do
          body = r.POST
          body = {} unless body.is_a?(Hash)
          args = body["args"]
          if DelegateClient::OPERATOR_VERBS.include?(verb)
            command = ExceptionsRoute.operator_command(verb, args)
            fail!(422, "operator_only", "#{verb} is an operator action; the server never runs it", operator_command: command)
          end
          fail!(404, "not_found", "no such exceptions verb") unless DelegateClient::VERBS.include?(verb)
          fail!(400, "bad_json", "args must be a list of strings") unless args.is_a?(Array) && args.all? { |item| item.is_a?(String) }
          begin
            reply = DelegateClient.call("op" => "request", "by" => DelegateClient.by, "argv" => ["exceptions", verb] + args)
          rescue DelegateClient::Unavailable => e
            fail!(403, "disabled", e.message, reason: e.message)
          end
          fail!(*DelegateClient.refuse(reply)) unless reply["ok"] == true && reply["run_id"].is_a?(String)
          { "run_id" => reply["run_id"] }
        end
        fail!(405, "method_not_allowed", "unsupported method")
      end
      fail!(404, "not_found", "no such route")
    end
  end
end
