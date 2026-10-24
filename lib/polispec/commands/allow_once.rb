#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../harness_controls/plane"
require_relative "../harness_controls/authorizations"

module Polispec
  class AllowOnceCommand
    USAGE = "usage: polispec allow-once <alo_id>"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      id = args.first
      return usage unless args.length == 1 && id.to_s.match?(/\Aalo_[0-9a-f]{12}\z/)

      plane = Trace.step("check sealed plane") { HarnessControls::Plane.resolve }
      Trace.info("plane status", status: plane["status"])
      raise Polispec::Error, "sealed authority is broken" if plane["status"] == "broken"
      if plane["status"] == "active"
        result = Trace.step("redeem protected authorization", id: id) { HarnessControls::Authorizations.redeem(id) }
        puts "polispec: #{id} redeemed through protected authorization records"
        return result ? 0 : 1
      end
      ledger = nil
      entry = nil
      Trace.step("load allow-once entry", id: id) do
        ledger = Ledger.load
        entry = Engine::Passes.fold(ledger)[id]
        raise Polispec::Error, "unknown allow-once id #{id}" unless entry
        raise Polispec::Error, "#{id} was already consumed" if entry["consumed_at"]
      end
      Trace.info("entry found", project: entry["project"], env: entry["env"], action_class: entry["action_class"], rule: entry["rule_id"])

      Operator::Tty.confirm!("allow-once #{id}", prompt: describe(entry))
      Trace.step("redeem allow-once", id: id) { Engine::Passes.redeem!(ledger, id) }
      Events.emit("polispec.allow_once", project: entry["project"], id: id, action_class: entry["action_class"], rule_id: entry["rule_id"], redeemed_at: Time.now.utc.iso8601, consumed_by_session: nil)
      puts "polispec: #{id} redeemed; the matching call is allowed once within #{Engine::Passes::TTL / 60} minutes"
      0
    rescue Operator::Tty::NotTty => e
      warn "polispec: not_tty: #{e.message}"
      1
    rescue Operator::Tty::PhraseMismatch => e
      warn "polispec: confirmation_failed: #{e.message}"
      1
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
