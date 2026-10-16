#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "judgments"

module Polispec
  module Journal
    module_function

    def recent(now = Time.now)
      Judgments.rows(Judgments.recent(now))
    end

    def home_relative(path)
      Judgments.home_relative(path)
    end

    def expand(path)
      path.is_a?(String) && path.start_with?("~/") ? File.join(Dir.home, path[2..]) : path
    end

    def action_for(row)
      hint = { "env" => row["env"] }
      hint["ref"] = row["ref"] if row["ref"]
      hint["path"] = expand(row["path"]) if row["path"]
      hint["destructive"] = true if row["destructive"]
      hint["shape"] = row["shape"] if row["shape"].is_a?(Array) && !row["shape"].empty?
      Action.new(class: row["action_class"], env_hint: hint, raw: "journal replay")
    end

    def label(row)
      "#{row['action_class']} #{[row['ref'], row['path']].compact.join(' ')}".strip
    end
  end
end
