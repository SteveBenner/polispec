#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    class Detector
      HEAD_BYTES = 4096
      MODELINE_LINES = 5
      UNKNOWN = "unknown".freeze

      def initialize(pack)
        @extensions = {}
        @filenames = {}
        @shebangs = {}
        @modelines = []
        pack.specs.values.sort_by(&:path).each { |spec| index(spec) }
        @extension_order = @extensions.keys.sort_by { |ext| -ext.length }
      end

      def detect(path, head: nil)
        base = File.basename(path.to_s)
        lowered = base.downcase
        ext = @extension_order.find { |candidate| lowered.end_with?(candidate) && lowered.length > candidate.length }
        return @extensions[ext] if ext
        return @filenames[base] if @filenames.key?(base)

        text = head.nil? ? read_head(path) : head.to_s[0, HEAD_BYTES]
        from_content(text) || UNKNOWN
      end

      def languages
        (@extensions.values + @filenames.values + @shebangs.values + @modelines.map(&:last)).uniq.sort
      end

      private

      def index(spec)
        language = spec.languages.find { |name| name != "*" }
        return unless language

        detection = spec.detection
        Array(detection["extensions"]).each { |ext| @extensions[ext.to_s.downcase] ||= language }
        Array(detection["filenames"]).each { |name| @filenames[name.to_s] ||= language }
        Array(detection["shebangs"]).each { |name| @shebangs[name.to_s] ||= language }
        Array(detection["modelines"]).each { |marker| @modelines << [marker.to_s.downcase, language] }
      end

      def read_head(path)
        return "" unless File.file?(path)

        File.open(path, "rb") { |file| file.read(HEAD_BYTES) }.to_s.force_encoding(Encoding::UTF_8).scrub
      rescue SystemCallError
        ""
      end

      def from_content(text)
        lines = text.to_s.lines.first(MODELINE_LINES)
        first = lines.first.to_s
        if first.start_with?("#!")
          words = first.sub(/\A#!\s*/, "").split(%r{[\s/]+})
          @shebangs.each do |name, language|
            return language if words.any? { |word| word == name || word.match?(/\A#{Regexp.escape(name)}[\d.]*\z/) }
          end
        end
        joined = lines.join.downcase
        @modelines.each { |marker, language| return language if joined.include?(marker) }
        nil
      end
    end
  end
end
