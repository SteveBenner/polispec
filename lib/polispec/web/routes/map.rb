#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../views"

module Polispec
  module Web
    class App < Roda
      def view_call
        yield
      rescue Views::NotFound => e
        fail!(404, "not_found", e.message)
      rescue Views::Invalid => e
        extra = e.findings.empty? ? {} : { findings: e.findings }
        fail!(422, "invalid", e.message, extra)
      rescue Views::Unavailable => e
        fail!(503, "unavailable", e.message)
      end

      def not_modified?(r, tag)
        return false if tag.nil?

        quoted = %("#{tag}")
        response["ETag"] = quoted
        return false unless r.env["HTTP_IF_NONE_MATCH"].to_s.split(",").map(&:strip).include?(quoted)

        response.status = 304
        true
      end
    end

    Web.route("map") do |r|
      r.is do
        r.get do
          body, tag = view_call { Views.map(r.params["window"]) }
          r.halt if not_modified?(r, tag)
          body
        end
        fail!(405, "method_not_allowed", "unsupported method")
      end
    end
  end
end
