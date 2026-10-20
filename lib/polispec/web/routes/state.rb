#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../views"

module Polispec
  module Web
    LAYOUT_KEY = /\A[A-Za-z0-9_.:@\/-]{1,200}\z/.freeze
    LAYOUT_LIMIT = 2000

    class App < Roda
      def valid_positions(body)
        positions = body.is_a?(Hash) ? body["positions"] : nil
        fail!(422, "invalid", "positions must be an object") unless positions.is_a?(Hash)
        fail!(422, "invalid", "positions holds more than #{LAYOUT_LIMIT} entries") if positions.length > LAYOUT_LIMIT
        positions.each do |key, value|
          fail!(422, "invalid", "position key #{key.to_s[0, 40].inspect} is not valid") unless key.to_s.match?(LAYOUT_KEY)
          ok = value.is_a?(Hash) && %w[x y].all? { |axis| value[axis].is_a?(Numeric) && value[axis].to_f.finite? }
          fail!(422, "invalid", "position #{key} needs numeric x and y") unless ok
        end
        positions.transform_values { |value| { "x" => value["x"], "y" => value["y"] } }
      end

      def write_layout(positions)
        Web.ensure_dir
        path = Views.layout_path
        temp = "#{path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
        File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate("positions" => positions)) }
        File.chmod(0o600, temp)
        File.rename(temp, path)
      end
    end

    Web.route("state", mutating: true) do |r|
      r.is "layout" do
        r.get { Views.layout }
        r.put do
          positions = valid_positions(r.POST)
          write_layout(positions)
          { "positions" => positions }
        end
        fail!(405, "method_not_allowed", "unsupported method")
      end
      fail!(404, "not_found", "no such route")
    end
  end
end
