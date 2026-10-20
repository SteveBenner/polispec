#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../views"

module Polispec
  module Web
    Web.route("pipeline") do |r|
      r.is do
        r.get { view_call { Views.pipeline } }
        fail!(405, "method_not_allowed", "unsupported method")
      end
    end

    Web.route("heatmap") do |r|
      r.is do
        r.get { view_call { Views.heatmap(r.params["window"] || r.params["since"]) } }
        fail!(405, "method_not_allowed", "unsupported method")
      end
    end

    Web.route("sessions") do |r|
      r.is do
        r.get { view_call { Views.sessions(r.params["window"]) } }
        fail!(405, "method_not_allowed", "unsupported method")
      end
    end

    Web.route("changes") do |r|
      r.is do
        r.get { view_call { Views.changes(r.params["since"]) } }
        fail!(405, "method_not_allowed", "unsupported method")
      end
    end
  end
end
