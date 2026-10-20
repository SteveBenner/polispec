#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../views"

module Polispec
  module Web
    Web.route("rulebooks") do |r|
      r.get String, String, "source" do |kind, id|
        data = view_call { Views.source(kind, id) }
        tag = %("#{data['digest']}")
        response["ETag"] = tag
        if kind != "project" && r.env["HTTP_IF_NONE_MATCH"].to_s.split(",").map(&:strip).include?(tag)
          response.status = 304
          r.halt
        end
        data
      end
      r.get String, String, "composition" do |kind, id|
        data = view_call { Views.composition(kind, id, r.params["action"], r.params["path"]) }
        data.reject { |key, _| key == "__side" }
      end
      r.get String, String, "history" do |kind, id|
        view_call { Views.history(kind, id, r.params["from"], r.params["to"]) }
      end
      fail!(404, "not_found", "no such route")
    end
  end
end
