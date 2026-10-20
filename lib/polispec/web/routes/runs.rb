#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "exceptions"

module Polispec
  module Web
    module RunsRoute
      module_function

      def change_for(reply)
        return nil unless reply["state"] == "succeeded"

        started = reply["started_at"].to_s
        change = Changes.records.reverse.find { |item| item["kind"].to_s.start_with?("exceptions.") && item["ts"].to_s >= started }
        change && change["id"]
      rescue StandardError
        nil
      end

      def snapshot(run_id, offset)
        reply = DelegateClient.call("op" => "output", "run_id" => run_id, "offset" => offset)
        return [nil, reply] unless reply["ok"] == true

        out = {
          "run_id" => reply["run_id"], "state" => reply["state"], "exit_code" => reply["exit_code"], "offset" => reply["offset"], "data" => reply["data"].to_s,
          "truncated" => reply["truncated"] == true, "prompt" => reply["prompt"].is_a?(Hash) ? reply["prompt"] : nil, "started_at" => reply["started_at"], "ended_at" => reply["ended_at"]
        }
        out["change_id"] = change_for(reply)
        [out, nil]
      end
    end

    Web.route("runs", mutating: true) do |r|
      r.on String do |run_id|
        fail!(404, "not_found", "no such run") unless DelegateClient::RUN_ID.match?(run_id)
        r.is do
          r.get do
            raw = r.params["offset"].to_s
            fail!(400, "bad_request", "offset must be a non-negative integer") unless raw.empty? || raw.match?(/\A\d{1,12}\z/)
            begin
              out, refused = RunsRoute.snapshot(run_id, raw.empty? ? 0 : raw.to_i)
            rescue DelegateClient::Unavailable => e
              fail!(403, "disabled", e.message, reason: e.message)
            end
            fail!(*DelegateClient.refuse(refused)) unless out
            out
          end
          fail!(405, "method_not_allowed", "unsupported method")
        end
        r.is "phrase" do
          r.post do
            body = r.POST
            text = body.is_a?(Hash) ? body["text"] : nil
            fail!(400, "bad_json", "text is required") unless text.is_a?(String) && !text.empty? && text.bytesize <= 200 && !text.include?("\n") && !text.include?("\r")
            begin
              reply = DelegateClient.call("op" => "phrase", "run_id" => run_id, "text" => text)
            rescue DelegateClient::Unavailable => e
              fail!(403, "disabled", e.message, reason: e.message)
            end
            if reply["ok"] == true
              { "ok" => true }
            else
              status, kind, message, = DelegateClient.refuse(reply)
              fail!(status, kind, message) if status != 200
              { "ok" => false, "code" => kind, "message" => message }
            end
          end
          fail!(405, "method_not_allowed", "unsupported method")
        end
        r.is "cancel" do
          r.post do
            begin
              reply = DelegateClient.call("op" => "cancel", "run_id" => run_id)
            rescue DelegateClient::Unavailable => e
              fail!(403, "disabled", e.message, reason: e.message)
            end
            fail!(*DelegateClient.refuse(reply)) unless reply["ok"] == true
            { "ok" => true }
          end
          fail!(405, "method_not_allowed", "unsupported method")
        end
        fail!(404, "not_found", "no such route")
      end
      fail!(404, "not_found", "no such route")
    end
  end
end
