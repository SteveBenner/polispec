#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    class Controls
      Outcome = Struct.new(:rule, :status, :message, keyword_init: true)
      STATE_FILE = "controls.json".freeze

      def self.record(pack, outcomes)
        failed = outcomes.count { |outcome| outcome.status == :fail }
        path = File.join(Paths.state_dir, "code", STATE_FILE)
        existing = begin
          JSON.parse(File.read(path))
        rescue SystemCallError, JSON::ParserError
          {}
        end
        existing[pack.source.tree_id] = { "ref" => pack.source.ref, "ok" => failed.zero?, "failed" => failed, "total" => outcomes.length, "at" => Time.now.utc.iso8601 }
        existing = existing.to_a.last(20).to_h
        Code.write_atomic(path, JSON.pretty_generate(existing))
      rescue SystemCallError
        nil
      end

      def self.recorded(tree_id)
        JSON.parse(File.read(File.join(Paths.state_dir, "code", STATE_FILE)))[tree_id]
      rescue SystemCallError, JSON::ParserError
        nil
      end

      def initialize(pack)
        @pack = pack
        @runner = Runner.new(pack)
      end

      def run(spec: nil, policy: nil)
        rules = @pack.rules.select { |rule| candidate?(rule, spec, policy) }
        rules.map { |rule| evaluate(rule) }
      end

      private

      def candidate?(rule, spec, policy)
        return false unless rule.lifecycle == "active" && %w[harness hybrid contextual].include?(rule.klass)
        return false if policy && rule.id != policy
        return false if spec && rule.spec != spec && !rule.spec.start_with?("#{spec}/")
        return false if rule.klass == "contextual" && !rule.control

        true
      end

      def evaluate(rule)
        control = rule.control
        return Outcome.new(rule: rule, status: :fail, message: "no control declared") unless control
        return Outcome.new(rule: rule, status: :skip, message: "enforcer kind #{rule.enforcer && rule.enforcer['kind']} is not run by polispec") unless Checker.enforceable?(rule)

        bad = locate(rule, control["fixture"])
        good = locate(rule, control["compliant"] || control["fixture"].to_s.sub(".bad.", ".good."))
        return Outcome.new(rule: rule, status: :fail, message: "bad fixture #{control['fixture']} missing") unless bad
        return Outcome.new(rule: rule, status: :fail, message: "good fixture missing") unless good

        flagged = @runner.run([rule], @pack.read(bad).to_s, virtual(bad))
        return Outcome.new(rule: rule, status: :fail, message: "enforcer error: #{flagged.errors.first['message']}") unless flagged.errors.empty?

        expected = control.dig("expect", "line")
        if flagged.hits.empty?
          return Outcome.new(rule: rule, status: :fail, message: "survivor: #{bad} produced no violation of #{rule.id}")
        elsif expected && flagged.hits.none? { |hit| hit.line == expected }
          return Outcome.new(rule: rule, status: :fail, message: "#{bad} flagged lines #{flagged.hits.map(&:line).inspect}, expected line #{expected}")
        end

        clean = @runner.run([rule], @pack.read(good).to_s, virtual(good))
        return Outcome.new(rule: rule, status: :fail, message: "enforcer error on good fixture: #{clean.errors.first['message']}") unless clean.errors.empty?
        return Outcome.new(rule: rule, status: :fail, message: "#{good} was flagged at lines #{clean.hits.map(&:line).inspect}") unless clean.hits.empty?

        Outcome.new(rule: rule, status: :ok, message: "#{bad} flagged, #{good} clean")
      end

      def locate(rule, file)
        return nil if file.to_s.empty?

        [file, File.join("controls", rule.spec, file)].find { |candidate| @pack.exist?(candidate) }
      end

      def virtual(file)
        File.join("/polispec-controls", file.sub(/\.(bad|good)(\.[^.\/]+)\z/, '\2'))
      end
    end
  end
end
