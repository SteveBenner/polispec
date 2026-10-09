#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  class AllowOnceCommand
    USAGE = "usage: polispec allow-once <alo_id>"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      id = args.first
      return usage unless args.length == 1 && id.to_s.match?(/\Aalo_[0-9a-f]{12}\z/)

      ledger = Ledger.load
      entry = Engine::Passes.fold(ledger)[id]
      raise Polispec::Error, "unknown allow-once id #{id}" unless entry
      raise Polispec::Error, "#{id} was already consumed" if entry["consumed_at"]

      Operator::Tty.confirm!("allow-once #{id}", prompt: describe(entry))
      Engine::Passes.redeem!(ledger, id)
      Events.emit("polispec.allow_once", project: entry["project"], id: id, action_class: entry["action_class"], rule_id: entry["rule_id"], redeemed_at: Time.now.utc.iso8601, consumed_by_session: nil)
      puts "polispec: #{id} redeemed; the matching call is allowed once within #{Engine::Passes::TTL / 60} minutes"
      0
    end

    private

    def describe(entry)
      "Allow one call for #{entry['project']} (#{entry['env']}, #{entry['action_class']}, rule #{entry['rule_id']}):\n  #{entry['raw']}"
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("allow-once", Polispec::AllowOnceCommand, summary: "redeem an allow-once id (terminal and typed phrase)")
