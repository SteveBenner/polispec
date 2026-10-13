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
      options = parse(args)
      return usage unless options
      plan = if options["from"]
               repo, revision = split_source(options["from"])
               HarnessControls::Authority.seal_plan(kind: "git", source: repo, revision: revision)
             else
               HarnessControls::Authority.seal_plan(kind: "root_authored", source: options["source"])
             end
      operation_id = Digest::SHA256.hexdigest(HarnessControls::Authority.canonical_json(plan.slice("edition", "generation", "source", "runtime")))
      data = { "dry_run" => options["dry_run"], "plan" => plan }
      if !options["dry_run"]
        unless plan["preparation_ready"]
          return emit(result(false, operation_id, plan["edition"], data, plane_findings(plan["findings"])), options["json"], 3)
        end
        HarnessControls::Authority.bootstrap_identity!("seal.prepare")
        Operator::Tty.confirm!("seal generation #{plan['generation']}", prompt: "Sealing prepares protected authority and may switch the active generation.")
        prepared = HarnessControls::Plane.build_generation(plan)
        data["prepared_generation"] = prepared
        unless plan["ready"]
          data["activation"] = { "status" => "blocked", "reason" => "protected runtime and native prerequisites remain unresolved" }
          return emit(result(false, operation_id, plan["edition"], data, plane_findings(plan["findings"])), options["json"], 3)
        end
        data["activation"] = HarnessControls::Plane.switch_generation(plan)
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

    def parse(args)
      values = args.dup
      options = { "dry_run" => false, "json" => false }
      until values.empty?
        token = values.shift
        case token
        when "--dry-run" then options["dry_run"] = true
        when "--json" then options["json"] = true
        when "--from", "--source"
          value = values.shift
          return nil unless value && !value.empty?
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
        puts JSON.generate(payload)
      else
        puts "polispec seal: #{payload['ok'] ? 'ready' : 'blocked'}"
        puts "  generation: #{payload.dig('data', 'plan', 'generation')}" if payload.dig("data", "plan", "generation")
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

Polispec::CLI.register("seal", Polispec::SealCommand, summary: "plan or create a protected control plane generation")
