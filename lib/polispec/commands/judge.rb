#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../judge"
require_relative "../judge/stats"

module Polispec
  module Commands
    class Judge
      USAGE = "usage: polispec judge serve | status | stop | unit | stats [--since DURATION] [--json]   (DURATION: Ns, Nm, Nh or Nd, default 1h)"

      def run(args)
        verb, *rest = args
        return stats(rest) if verb == "stats"
        return usage unless args.length == 1

        case verb
        when "serve" then ::Polispec::Judge::Server.run
        when "status" then status
        when "stop" then stop
        when "unit" then unit
        else usage
        end
      end

      private

      def usage
        warn USAGE
        2
      end

      def stats(options)
        since = ::Polispec::Judge::Stats::DEFAULT_SINCE
        json = false
        seen = false
        queue = options.dup
        until queue.empty?
          option = queue.shift
          case option
          when "--json" then json = true
          when "--since"
            return usage if seen || queue.empty?

            seen = true
            since = queue.shift
          else return usage
          end
        end
        gatherer = ::Polispec::Judge::Stats.new(home: ::Polispec::State.home, since: since)
        report = gatherer.report
        puts json ? JSON.generate(report) : gatherer.render(report)
        0
      rescue ArgumentError => e
        warn "polispec: judge stats: #{e.message}"
        usage
      end

      def unit
        print ::Polispec::Judge::UNIT
        0
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
        puts "workers: #{state['workers']}" if state["workers"]
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

Polispec::CLI.register("judge", Polispec::Commands::Judge, summary: "resident judge for guard hook calls: serve, status, stop, unit, stats")
