#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../proposals"

module Polispec
  module Web
    Web.route("plans", mutating: true) do |r|
      r.is do
        r.post do
          body = r.POST
          fail!(400, "bad_json", "target and change are required") unless body.is_a?(Hash) && body["target"].is_a?(Hash) && body["change"].is_a?(Hash)
          begin
            records = Proposals.create(body["target"], body["change"])
          rescue Polispec::Error => e
            fail!(*Proposals.describe(e))
          end
          if records.length == 1
            Proposals.present(records.first)
          else
            { "plans" => records.map { |record| Proposals.present(record) } }
          end
        end
        fail!(405, "method_not_allowed", "unsupported method")
      end
      r.on String do |id|
        r.is do
          r.get do
            record = Proposals.fetch(id)
            fail!(404, "not_found", "no plan #{id}; create it again") unless record
            Proposals.present(record)
          end
          fail!(405, "method_not_allowed", "unsupported method")
        end
        r.is "apply" do
          r.post do
            body = r.POST
            body = {} unless body.is_a?(Hash)
            confirm = body["confirm"]
            fail!(400, "bad_json", "confirm must be a string") unless confirm.nil? || confirm.is_a?(String)
            begin
              Proposals.apply(id, confirm)
            rescue Polispec::Error => e
              fail!(*Proposals.describe(e))
            end
          end
          fail!(405, "method_not_allowed", "unsupported method")
        end
        fail!(404, "not_found", "no such route")
      end
      fail!(404, "not_found", "no such route")
    end
  end
end
