#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../harness_controls/plane"

module Polispec
  class PlaneCommand
    USAGE = "usage: polispec plane (status|verify [--json] | activate PROJECT_ID... [--dry-run] [--json])"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      values = args.dup
      action = values.shift
      json = values.delete("--json")
      dry_run = values.delete("--dry-run")
      return usage unless %w[status verify activate].include?(action)
      return usage if dry_run && action != "activate"
      return usage unless action == "activate" || values.empty?
      return usage if action == "activate" && values.empty?

      data = case action
             when "status" then HarnessControls::Plane.resolve
             when "verify" then HarnessControls::Plane.verify
             else HarnessControls::Plane.activate(values, dry_run: !!dry_run)
             end
      edition = data["edition"] || data.dig("plane", "edition")
      generation = data["generation"] || data.dig("plane", "generation")
      operation_id = Digest::SHA256.hexdigest(HarnessControls::Authority.canonical_json({ "operation" => "plane.#{action}", "generation" => generation, "projects" => values.sort }))
      ok = action == "status" ? data["status"] != "broken" : action == "verify" ? data["green"] == true : true
      findings = findings_for(data, action)
      status = if data["status"] == "broken"
                 1
               elsif action == "verify" && !ok
                 3
               else
                 0
               end
      emit(result(ok, action, operation_id, edition, data, findings), !!json, status)
    rescue HarnessControls::Authority::Failure => error
      payload = result(false, action || "unknown", nil, nil, {}, Array(error.findings).map { |row| finding(row["code"], row["detail"], "Resolve this authority failure.") } + [finding(error.code, error.message, "Use verified protected operator provenance and satisfy all prerequisites.")])
      emit(payload, args.include?("--json"), error.code == "operator_required" || error.code.include?("prerequisite") ? 3 : 1)
    rescue Operator::Tty::NotTty, Operator::Tty::PhraseMismatch => error
      payload = result(false, action || "unknown", nil, nil, {}, [finding("operator_required", error.message, "Retry from an authenticated interactive operator terminal.")])
      emit(payload, args.include?("--json"), 3)
    end

    private

    def result(ok, action, operation_id, edition, data, findings)
      { "schema" => "polispec.harness.result/v1", "ok" => ok == true, "operation" => "plane.#{action}", "operation_id" => operation_id, "edition" => edition, "data" => data, "findings" => findings }
    end

    def findings_for(data, action)
      rows = Array(data["findings"]).map { |row| finding(row["code"], row["detail"], "Repair the fixed-root plane before relying on it.") }
      if action == "verify"
        rows.concat(Array(data["prerequisites"]).map { |detail| finding("plane_prerequisite", detail, "Supply native protected evidence before activation.") })
      end
      rows
    end

    def finding(code, detail, next_step)
      { "code" => code || "plane_finding", "detail" => detail.to_s, "control_id" => nil, "harness" => nil, "capability" => "plane.authority", "next_step" => next_step }
    end

    def emit(payload, json, status)
      if json
        puts JSON.generate(payload)
      else
        puts "polispec #{payload['operation']}: #{payload['ok'] ? 'ok' : 'blocked'}"
        puts "  status: #{payload.dig('data', 'status')}" if payload.dig("data", "status")
        payload["findings"].each { |item| puts "  #{item['code']}: #{item['detail']}" }
      end
      status
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("plane", Polispec::PlaneCommand, summary: "inspect, verify or activate the protected control plane")
