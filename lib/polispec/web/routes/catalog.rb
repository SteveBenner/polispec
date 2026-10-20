#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../views"

module Polispec
  module Web
    Web.route("catalog") do |r|
      r.is do
        r.get { view_call { Views.catalog } }
        fail!(405, "method_not_allowed", "unsupported method")
      end
    end
  end
end
