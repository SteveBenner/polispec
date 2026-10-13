#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../harness_controls/authorizations"
require_relative "../harness_controls/authorization_client"

module Polispec
  class AuthorizationsCommand
    USAGE = "usage: polispec authorizations (serve | status [--json] | unit [--json] | recover [--dry-run] [--json])".freeze

    def self.run(args)
      new.run(args)
    end

    def run(args)
      values = args.dup
      action = values.shift
      json_requested = values.include?("--json")
      options = parse(values)
      return usage(json_requested) unless options && %w[serve status unit recover].include?(action)
      return usage(json_requested) if action == "serve" && (options["json"] || options["dry_run"])
      return usage(json_requested) if action != "recover" && options["dry_run"]
      case action
      when "serve"
        HarnessControls::Authorizations.serve
        0
      when "status"
        response = HarnessControls::AuthorizationClient.status
        ok = response["status"] == "available"
        emit(result(ok, "status", response, ok ? [] : [finding(response["error"] || "unavailable", "authorization service is unavailable")]), options["json"], ok ? 0 : 3)
      when "unit"
        service = HarnessControls::Authorizations.unit
        emit(result(true, "unit", { "service" => service }, []), options["json"], 0)
      when "recover"
        recovery = HarnessControls::Authorizations.recover(dry_run: options["dry_run"])
        emit(result(true, "recover", recovery, []), options["json"], 0)
      end
    rescue HarnessControls::Authorizations::Failure, HarnessControls::Authority::Failure => error
      code = error.respond_to?(:code) ? error.code : "authorization_failure"
      emit(result(false, action || "unknown", {}, [finding(code, error.message)]), args.include?("--json"), code == "operator_required" || code.include?("unavailable") ? 3 : 1)
    rescue Operator::Tty::NotTty, Operator::Tty::PhraseMismatch => error
      emit(result(false, action || "unknown", {}, [finding("operator_required", error.message)]), args.include?("--json"), 3)
    end

    private

    def parse(values)
      options = { "json" => false, "dry_run" => false }
      seen = {}
      values.each do |value|
        return nil unless %w[--json --dry-run].include?(value) && !seen[value]
        seen[value] = true
        options[value.delete_prefix("--").tr("-", "_")] = true
      end
      options
    end

    def result(ok, action, data, findings)
      {
        "schema" => "polispec.harness.result/v1",
        "ok" => ok == true,
        "operation" => "authorizations.#{action}",
        "operation_id" => nil,
        "edition" => nil,
        "data" => data,
        "findings" => findings
      }
    end

    def finding(code, detail)
      {
        "code" => code.to_s,
        "detail" => detail.to_s,
        "control_id" => nil,
        "harness" => nil,
        "capability" => "authorization.consume",
        "next_step" => "Start or repair the protected authorization service through the active pinned launcher."
      }
    end

    def emit(payload, json, status)
      if json
        bytes = JSON.generate(payload)
        if bytes.bytesize > HarnessControls::Authorizations::MAX_REPLY
          puts JSON.generate(result(false, payload["operation"].to_s.delete_prefix("authorizations."), {}, [finding("result_too_large", "authorization result exceeds the output limit")]))
          return 1
        end
        puts bytes
      elsif payload["operation"] == "authorizations.unit" && payload["ok"]
        puts payload.dig("data", "service")
      else
        puts "polispec #{payload['operation']}: #{payload['ok'] ? 'ok' : 'blocked'}"
        payload["findings"].each { |item| puts "  #{item['code']}: #{item['detail']}" }
      end
      status
    end

    def usage(json)
      if json
        emit(result(false, "unknown", {}, [finding("invalid_arguments", USAGE)]), true, 2)
      else
        warn USAGE
        2
      end
    end
  end
end

Polispec::CLI.register("authorizations", Polispec::AuthorizationsCommand, summary: "serve or inspect protected one-use authorizations")
