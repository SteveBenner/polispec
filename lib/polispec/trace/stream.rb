#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "time"

module Polispec
  module Trace
    module Stream
      CONTROL = /[\x00-\x08\x0A-\x0C\x0E-\x1F\x7F]/.freeze

      module_function

      def text_line(elapsed, depth, body)
        "#{format('[%7.1fs] ', elapsed)}#{'  ' * depth}#{body}"
      end

      def json_line(elapsed, depth, event, data)
        head = { "v" => 1, "ts" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ"), "t" => elapsed.round(3), "depth" => depth, "event" => event }
        JSON.generate(head.merge(jsonable(data || {})))
      end

      def duration(ms)
        value = ms.to_f
        value > 1000 ? format("%.1f s", value / 1000.0) : "#{value.round} ms"
      end

      def fields(hash)
        return "" if hash.nil? || hash.empty?

        hash.map { |key, value| " #{key}=#{value(value)}" }.join
      end

      def value(item)
        return item.map { |entry| entry.to_s }.join(",") if item.is_a?(Array)

        text = item.to_s.gsub(/\s*[\r\n]+\s*/, " ")
        item.is_a?(String) && (text.empty? || text.match?(/[\s"=]/)) ? text.inspect : text
      end

      def clean(text)
        copy = text.to_s.dup
        copy.force_encoding(Encoding::UTF_8) unless copy.encoding == Encoding::UTF_8
        copy.scrub
      end

      def control(text)
        text.gsub(CONTROL, "?")
      end

      def jsonable(item)
        case item
        when Hash then item.each_with_object({}) { |(key, entry), memo| memo[key.to_s] = jsonable(entry) }
        when Array then item.map { |entry| jsonable(entry) }
        when String then clean(item)
        when Numeric, true, false, nil then item
        else clean(item.to_s)
        end
      end
    end
  end
end
