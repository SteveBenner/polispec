#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../sessions"

module Polispec
  class SessionsCommand
    USAGE = "usage: polispec sessions list [--active 1h] [--json]"
    UNITS = { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.freeze

    def self.run(args)
      new.run(args)
    end

    def run(args)
      args = args.dup
      json = args.delete("--json")
      verb = args.shift
      return usage unless verb == "list"

      window = 3600
      until args.empty?
        flag = args.shift
        name, inline = flag.split("=", 2)
        return usage unless name == "--active"

        text = inline || args.shift
        match = text.to_s.match(/\A(\d+)([smhd]?)\z/)
        return usage unless match

        window = match[1].to_i * UNITS.fetch(match[2].empty? ? "s" : match[2])
      end
      rows = Sessions.active(window)
      if json
        puts JSON.generate(rows.map { |row| row.reject { |key, _| key == "epochs" } })
      else
        puts "polispec sessions, active within #{window}s: #{rows.length}"
        rows.each do |row|
          launcher = row["launcher"] ? "#{row['launcher']['kind']}#{row['launcher']['version'] ? " #{row['launcher']['version']}" : ''}" : "-"
          puts "#{row['session_id']} #{row['harness']} first #{row['first_seen']} last #{row['last_call']} epoch #{row['epoch'] || '-'} launcher #{launcher}"
        end
      end
      0
    end

    private

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("sessions", Polispec::SessionsCommand, summary: "list the harness sessions seen by the guard, with their epoch and launcher")
