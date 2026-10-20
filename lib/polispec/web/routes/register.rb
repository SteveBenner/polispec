#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../proposals"

module Polispec
  module Web
    module RegisterRoute
      module_function

      def findings(description)
        severity = Engine::Settings.description_strict? ? "error" : "warning"
        Description.lint({ "description" => description.to_s }, nil).map do |item|
          { "severity" => severity, "code" => "description_#{item[:code]}", "message" => item[:message] }
        end
      end

      def dry_run(body)
        preview, record = Proposals.register_plan(body, dry: true)
        blocking = findings(preview[:description]).any? { |item| item["severity"] == "error" }
        list = findings(preview[:description])
        list << { "severity" => "warning", "code" => "runtime_behind", "message" => Registration.behind_note } if Registration.runtime_behind?
        out = {
          "ok" => !blocking, "findings" => list, "owner" => Registration.owner,
          "registered_by" => Proposals.with_actor { Registration.actor }, "preview" => { "yaml" => preview[:yaml] }, "plan" => Proposals.present(record)
        }
        out["starter"] = { "applied" => false, "reason" => "a starter module is planned on the global shelf after the entry is registered" } if body["starter"]
        out
      end
    end

    Web.route("register", mutating: true) do |r|
      r.is do
        r.post do
          body = r.POST
          fail!(400, "bad_json", "path and kind are required") unless body.is_a?(Hash) && body["path"].is_a?(String)
          begin
            if body["dry_run"] == true
              RegisterRoute.dry_run(body)
            else
              _preview, record = Proposals.register_plan(body)
              Proposals.present(record)
            end
          rescue Polispec::Error => e
            fail!(*Proposals.describe(e))
          end
        end
        fail!(405, "method_not_allowed", "unsupported method")
      end
      fail!(404, "not_found", "no such route")
    end
  end
end
