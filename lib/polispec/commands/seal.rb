#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../harness_controls/plane"

module Polispec
  class SealCommand
    USAGE = "usage: polispec seal (--from REPO@COMMIT | --source /etc/polispec/source) [--dry-run] [--json]"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      json_requested = args.include?("--json")
      options = parse(args)
      return usage(json_requested) unless options
      plan = Trace.step("plan seal", dry_run: options["dry_run"]) do
        built = if options["from"]
                  repo, revision = split_source(options["from"])
                  HarnessControls::Authority.seal_plan(kind: "git", source: repo, revision: revision)
                else
                  HarnessControls::Authority.seal_plan(kind: "root_authored", source: options["source"])
                end
        trace_plan(built)
        built
      end
      operation_id = Digest::SHA256.hexdigest(HarnessControls::Authority.canonical_json(plan.slice("edition", "generation", "source", "runtime")))
      data = { "dry_run" => options["dry_run"], "plan" => plan }
      if !options["dry_run"]
        unless HarnessControls::Features.enabled?("sealed_plane")
          return emit(result(false, operation_id, plan["edition"], data, [finding("feature_disabled", "sealed_plane mutation is disabled during construction", "Enable the accepted sealed_plane feature before operator preparation.")]), options["json"], 3)
        end
        unless plan["preparation_ready"]
          return emit(result(false, operation_id, plan["edition"], data, plane_findings(plan["findings"])), options["json"], 3)
        end
        HarnessControls::Authority.bootstrap_identity!("seal.prepare")
        Operator::Tty.confirm!("seal generation #{plan['generation']}", prompt: "Sealing prepares protected authority and may switch the active generation.")
        data["runtime_preparation"] = Trace.step("prepare runtime") { HarnessControls::Authority.prepare_runtime }
        plan = Trace.step("re-plan seal") do
          built = if options["from"]
                    repo, revision = split_source(options["from"])
                    HarnessControls::Authority.seal_plan(kind: "git", source: repo, revision: revision)
                  else
                    HarnessControls::Authority.seal_plan(kind: "root_authored", source: options["source"])
                  end
          trace_plan(built)
          built
        end
        data["plan"] = plan
        operation_id = Digest::SHA256.hexdigest(HarnessControls::Authority.canonical_json(plan.slice("edition", "generation", "source", "runtime")))
        prepared = Trace.step("build generation", generation: plan["generation"]) { HarnessControls::Plane.build_generation(plan) }
        data["prepared_generation"] = prepared
        unless plan["ready"]
          data["activation"] = { "status" => "blocked", "reason" => "protected runtime and native prerequisites remain unresolved" }
          return emit(result(false, operation_id, plan["edition"], data, plane_findings(plan["findings"])), options["json"], 3)
        end
        data["activation"] = Trace.step("switch generation", generation: plan["generation"]) { HarnessControls::Plane.switch_generation(plan) }
      end
      ok = plan["ready"]
      status = ok ? 0 : 3
      emit(result(ok, operation_id, plan["edition"], data, plane_findings(plan["findings"])), options["json"], status)
    rescue HarnessControls::Authority::Failure => error
      payload = result(false, nil, nil, {}, plane_findings(error.findings) + [finding(error.code, error.message, "Resolve the reported prerequisite and retry through protected operator provenance.")])
      emit(payload, args.include?("--json"), error.code == "operator_required" || error.code.include?("prerequisite") ? 3 : 1)
    rescue Operator::Tty::NotTty, Operator::Tty::PhraseMismatch => error
      payload = result(false, nil, nil, {}, [finding("operator_required", error.message, "Retry from an authenticated interactive operator terminal.")])
      emit(payload, args.include?("--json"), 3)
    end

    private

    def trace_plan(plan)
      return unless Trace.on?

      source = plan["source"].is_a?(Hash) ? plan["source"] : {}
      manifest = source["manifest"].is_a?(Hash) ? source["manifest"] : {}
      blocking = Array(plan["findings"]).count { |row| row.is_a?(Hash) && row["blocking"] }
      Trace.info("seal plan", kind: manifest["kind"], ref: manifest["ref"], entries: Array(manifest["files"]).length, source_digest: source["digest"], generation: plan["generation"], ready: plan["ready"], preparation_ready: plan["preparation_ready"], blocking: blocking)
    end

    def parse(args)
      values = args.dup
      options = { "dry_run" => false, "json" => false }
      seen = {}
      until values.empty?
        token = values.shift
        case token
        when "--dry-run", "--json"
          return nil if seen[token]
          seen[token] = true
          options[token.delete_prefix("--").tr("-", "_")] = true
        when "--from", "--source"
          return nil if seen[token]
          seen[token] = true
          value = values.shift
          return nil unless value && !value.empty? && !value.start_with?("--")
          options[token.delete_prefix("--")] = value
        else
          return nil
        end
      end
      return nil unless !!options["from"] ^ !!options["source"]
      return nil if options["source"] && File.expand_path(options["source"]) != HarnessControls::Authority::SOURCE_PATH
      options
    end

    def split_source(value)
      index = value.rindex("@")
      raise HarnessControls::Authority::Failure.new("invalid_source", "--from requires REPO@COMMIT") unless index && index.positive? && index < value.length - 1
      [value[0...index], value[(index + 1)..]]
    end

    def result(ok, operation_id, edition, data, findings)
      { "schema" => "polispec.harness.result/v1", "ok" => ok == true, "operation" => "seal", "operation_id" => operation_id, "edition" => edition, "data" => data, "findings" => findings }
    end

    def plane_findings(rows)
      Array(rows).map do |row|
        finding(row["code"] || "seal_prerequisite", row["detail"].to_s, row["blocking"] ? "Satisfy this prerequisite before activation." : "Review this evidence.")
      end
    end

    def finding(code, detail, next_step)
      { "code" => code, "detail" => detail, "control_id" => nil, "harness" => nil, "capability" => "plane.authority", "next_step" => next_step }
    end

    def emit(payload, json, status)
      if json
        bytes = JSON.generate(payload)
        if bytes.bytesize > HarnessControls::Authority::MAX_COMMAND_OUTPUT
          puts JSON.generate(result(false, nil, payload["edition"], {}, [finding("result_too_large", "seal result exceeds the bounded output limit", "Use a smaller authority bundle.")]))
          return 1
        end
        puts bytes
      else
        puts "polispec seal: #{payload['ok'] ? 'ready' : 'blocked'}"
        puts "  generation: #{payload.dig('data', 'plan', 'generation')}" if payload.dig("data", "plan", "generation")
        payload["findings"].each { |item| puts "  #{item['code']}: #{item['detail']}" }
      end
      status
    end

    def usage(json)
      if json
        emit(result(false, nil, nil, {}, [finding("invalid_arguments", USAGE, "Provide each supported option once and select exactly one authority source.")]), true, 2)
      else
        warn USAGE
        2
      end
    end
  end
end

Polispec::CLI.register("seal", Polispec::SealCommand, summary: "plan or create a protected control plane generation")
