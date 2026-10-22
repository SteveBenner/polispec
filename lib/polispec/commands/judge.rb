#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../judge"

module Polispec
  module Commands
    class Judge
      USAGE = "usage: polispec judge serve | status | stop"

      def run(args)
        verb = args.first
        return usage unless args.length == 1

        case verb
        when "serve" then ::Polispec::Judge::Server.run
        when "status" then status
        when "stop" then stop
        else usage
        end
      end

      private

      def usage
        warn USAGE
        2
      end

      def status
        state = ::Polispec::Judge.read_state
        unless state
          puts "polispec judge: not running (no #{::Polispec::Judge.state_path})"
          return 1
        end
        listening = ::Polispec::Judge.listening?(state)
        puts "port: #{state['port']}"
        puts "token: #{state['token']}"
        puts "pid: #{state['pid']}"
        puts "runtime: #{state['runtime']}"
        puts "version: #{state['version']}"
        puts "started: #{state['started']}"
        puts "listening: #{listening ? 'yes' : 'no'}"
        listening ? 0 : 1
      end

      def stop
        state = ::Polispec::Judge.read_state
        pid = state && state["pid"]
        unless pid.is_a?(Integer) && pid.positive?
          puts "polispec judge: not running"
          return 0
        end
        Process.kill("TERM", pid)
        puts "polispec judge: stopped #{pid}"
        0
      rescue Errno::ESRCH
        File.delete(::Polispec::Judge.state_path) if File.file?(::Polispec::Judge.state_path)
        puts "polispec judge: not running (removed stale #{::Polispec::Judge.state_path})"
        0
      rescue SystemCallError => e
        warn "polispec: judge stop failed: #{e.message}"
        1
      end
    end
  end
end

Polispec::CLI.register("judge", Polispec::Commands::Judge, summary: "resident judge for guard hook calls: serve, status, stop")
