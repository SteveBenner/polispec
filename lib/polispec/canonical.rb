#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Canonical
    module_function

    def value(data)
      case data
      when Hash then data.keys.sort_by(&:to_s).to_h { |key| [key.to_s, value(data[key])] }
      when Array then data.map { |item| value(item) }
      else data
      end
    end

    def json(data)
      JSON.generate(value(data))
    end

    def sha256(text)
      Digest::SHA256.hexdigest(text)
    end
  end
end
