#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../proposals"

module Polispec
  module Web
    Web.route("blast-radius") do |r|
      r.is do
        r.post do
          body = r.POST
          fail!(400, "bad_json", "target and change are required") unless body.is_a?(Hash) && body["target"].is_a?(Hash) && body["change"].is_a?(Hash)
          begin
            Proposals.blast(body["target"], body["change"])
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
