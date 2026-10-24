#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../harness_controls/plane"

module Polispec
  class PauseCommand
    MAX_MINUTES = 240
    USAGE = "usage: polispec pause <project> --minutes N --reason TEXT"

    def self.run(args)
      new.run(args)
    end

    def run(args)
      project_id, minutes, reason = parse(args)
      return usage unless project_id && minutes && reason

      ledger = nil
      project = nil
      Trace.step("load project", project: project_id) do
        ledger = Ledger.load
        project = ledger.project(project_id)
        raise Polispec::Error, "#{project_id} is not in the ledger" unless project
      end

      capped = [minutes, MAX_MINUTES].min
      Trace.info("pause length", requested_minutes: minutes, minutes: capped)
      Operator::Tty.confirm!("pause #{project.id}", prompt: "Pause the guard for #{project.id} for #{capped} minutes (reason: #{reason}).")
      record = Trace.step("record pause", project: project.id) { Engine::Pauses.start!(ledger, project.id, capped, reason) }
      Trace.info("pause recorded", project: project.id, minutes: capped, expires_at: record["expires_at"])
      Events.emit("polispec.pause", project: project.id, minutes: capped, reason: reason, expires_at: record["expires_at"], actor: "operator")
      puts "polispec: #{project.id} paused until #{record['expires_at']}#{" (capped from #{minutes})" if capped != minutes}"
      0
    rescue Operator::Tty::NotTty => e
      warn "polispec: not_tty: #{e.message}"
      1
    rescue Operator::Tty::PhraseMismatch => e
      warn "polispec: confirmation_failed: #{e.message}"
      1
    end

    private

    def parse(args)
      args = args.dup
      minutes = option(args, "--minutes")
      reason = option(args, "--reason")
      project_id = args.first
      return [nil, nil, nil] unless args.length == 1 && minutes.to_s.match?(/\A\d+\z/) && minutes.to_i.positive? && !reason.to_s.strip.empty?

      [project_id, minutes.to_i, reason.to_s.strip]
    end

    def option(args, flag)
      index = args.index(flag)
      return nil unless index

      value = args[index + 1]
      args.slice!(index, 2)
      value
    end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("pause", Polispec::PauseCommand, summary: "pause the guard for a project (terminal and typed phrase)")
