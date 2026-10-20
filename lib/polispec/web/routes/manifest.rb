#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../views"

module Polispec
  module Web
    Web.route("manifest") do |r|
      r.get "index" do
        view_call { Views.manifest_index }
      end
      r.get String do |id|
        view_call { Views.manifest(id) }
      end
      fail!(404, "not_found", "no such route")
    end

    Web.route("badge") do |r|
      r.get %r{([^/]+)\.svg} do |id|
        data = view_call { Views.manifest(id) }
        response["Content-Type"] = "image/svg+xml"
        Manifest.badge_svg(data["generated"])
      end
      fail!(404, "not_found", "no such route")
    end
  end
end
