#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "socket"
require_relative "../delegate"
require_relative "../operator/tty"
require_relative "../operator/git"

module Polispec
  module Commands
    class Delegate
      USAGE = "usage: polispec delegate grant APP --projects P[,P] --verbs V[,V] --targets T[,T] [--flags F[,F]] [--json] | revoke APP | list [--json] | serve | unit [--json] | status [--json]"
      UNIT_PATH = "~/.config/systemd/user/polispec-delegate.service"
      Refused = Class.new(StandardError) do
        attr_reader :code, :status

        def initialize(code, message, status = 1)
          super(message)
          @code = code
          @status = status
        end
      end

      def run(args)
        args = args.dup
        verb = args.shift
        case verb
        when "grant" then grant(args)
        when "revoke" then revoke(args)
        when "list" then list(args)
        when "serve" then args.empty? ? serve : usage
        when "unit" then unit(args)
        when "status" then status(args)
        else usage
        end
      rescue Refused => e
        warn "polispec: #{e.code}: #{e.message}"
        e.status
      rescue Operator::Tty::NotTty => e
        warn "polispec: not_tty: #{e.message}"
        3
      rescue Operator::Tty::PhraseMismatch => e
        warn "polispec: confirmation_failed: #{e.message}"
        1
      end

      private

      def grants_module
        ::Polispec::Delegate::Grants
      end

      def usage
        warn USAGE
        2
      end

      def option(args, flag)
        index = args.index(flag)
        return nil unless index

        value = args[index + 1]
        args.slice!(index, 2)
        value
      end

      def csv(value)
        value.to_s.split(",").map(&:strip).reject(&:empty?).uniq
      end

      def serve
        ::Polispec::Delegate::Server.run
      end

      def grant(args)
        json = args.delete("--json")
        projects = option(args, "--projects")
        verbs = option(args, "--verbs")
        targets = option(args, "--targets")
        flags = option(args, "--flags")
        return usage unless args.length == 1 && projects && verbs && targets

        app = args.first
        raise Refused.new("sealed", "delegation is not available on a sealed plane", 3) if ::Polispec::Delegate.sealed?

        scope = Trace.step("validate grant", app: app) { build_scope(app, csv(projects), csv(verbs), csv(targets), flags.nil? ? ::Polispec::Delegate::FLAGS_DEFAULT : csv(flags)) }
        Trace.info("grant scope", app: scope["app"], projects: scope["projects"], verbs: scope["verbs"], targets: scope["targets"], flags: scope["flags"]) if Trace.on?
        prompt = "Grant #{app} the right to #{scope['verbs'].join('/')} #{scope['projects'].join('/')} to #{scope['targets'].join('/')} (flags #{scope['flags'].empty? ? 'none' : scope['flags'].join(' ')})."
        Operator::Tty.confirm!("grant delegation to #{app}", prompt: prompt)
        token = grants_module.new_token
        entry = scope.merge("token_sha256" => grants_module.digest(token), "granted_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"))
        existing = Trace.step("read grants") { grants_module.load }
        others = existing.grants.reject { |item| item["app"] == app }
        Trace.info("existing grants", count: existing.grants.length, replacing: existing.grants.length - others.length) if Trace.on?
        raise Refused.new("invalid", "at most #{::Polispec::Delegate::MAX_GRANTS} grants are allowed") if others.length >= ::Polispec::Delegate::MAX_GRANTS

        Trace.step("write grants.yml", grants: others.length + 1) { grants_module.write(others + [entry]) }
        if json
          puts JSON.generate("app" => app, "token" => token, "scope" => scope)
        else
          puts "token: #{token}"
          puts "Store this token in #{app}'s protected secrets; it is not shown again."
        end
        0
      end

      def build_scope(app, projects, verbs, targets, flags)
        raise Refused.new("invalid", "app must match #{::Polispec::Delegate::APP.source}") unless ::Polispec::Delegate::APP.match?(app)
        raise Refused.new("invalid", "verbs must be a non-empty subset of #{grants_module::VERBS.join(', ')}") if verbs.empty? || (verbs - grants_module::VERBS).any?
        raise Refused.new("edition_excluded", "exceptions verbs are not available in this edition (exceptions.delegate_promote)") if (verbs & grants_module::EXCEPTIONS_VERBS).any? && grants_module.exceptions_locked?
        raise Refused.new("invalid", "projects must not be empty") if projects.empty?

        ledger = Polispec::Ledger.load
        unknown = projects.reject { |id| ledger.project(id) }
        raise Refused.new("invalid", "unknown ledger project: #{unknown.join(', ')}") unless unknown.empty?

        normal = targets.map { |target| grants_module.normalize_target(target) }.uniq
        raise Refused.new("invalid", "targets must be a non-empty subset of test, stable") if normal.empty? || (normal - %w[test stable]).any?
        raise Refused.new("invalid", "flags must be within #{::Polispec::Delegate::FLAGS_ALLOWED.join(', ')}") if (flags - ::Polispec::Delegate::FLAGS_ALLOWED).any?

        { "app" => app, "verbs" => verbs, "projects" => projects, "targets" => normal, "flags" => flags }
      end

      def revoke(args)
        return usage unless args.length == 1

        app = args.first
        raise Refused.new("sealed", "delegation is not available on a sealed plane", 3) if ::Polispec::Delegate.sealed?

        existing = Trace.step("read grants") { grants_module.load }
        raise Refused.new("not_found", "no grant for #{app}") unless existing.grants.any? { |item| item["app"] == app }

        Operator::Tty.confirm!("revoke delegation from #{app}", prompt: "Revoke the delegation of #{app}.")
        Trace.step("write grants.yml", app: app) { grants_module.write(existing.grants.reject { |item| item["app"] == app }) }
        puts "polispec: delegation revoked from #{app}"
        0
      end

      def list(args)
        json = args.delete("--json")
        return usage unless args.empty?

        print_grants(json)
        0
      end

      def print_grants(json)
        loaded = Trace.step("read grants") { grants_module.load }
        Trace.info("grants read", count: loaded.grants.length, problems: loaded.problems.length) if Trace.on?
        scopes = loaded.grants.map { |grant| grants_module.public_scope(grant) }
        if json
          puts JSON.generate("grants" => scopes, "problems" => loaded.problems)
          return
        end

        puts "no delegation grants" if scopes.empty?
        scopes.each do |scope|
          puts "#{scope['app']}: verbs #{scope['verbs'].join(',')}; projects #{scope['projects'].join(',')}; targets #{scope['targets'].join(',')}; flags #{scope['flags'].join(',')}; granted #{scope['granted_at']}"
        end
        loaded.problems.each { |problem| warn "polispec: grants file problem: #{problem}" }
      end

      def unit(args)
        json = args.delete("--json")
        return usage unless args.empty?

        binary = File.join(Polispec::ROOT, "bin", "polispec")
        text = <<~UNIT
          [Unit]
          Description=polispec delegate runner

          [Service]
          ExecStart=#{binary} delegate serve
          Restart=on-failure
          KillMode=mixed
          TimeoutStopSec=30

          [Install]
          WantedBy=default.target
        UNIT
        commands = ["write the unit to #{UNIT_PATH}", "systemctl --user daemon-reload && systemctl --user enable --now polispec-delegate"]
        if json
          puts JSON.generate("unit" => text, "path" => UNIT_PATH, "commands" => commands)
        else
          puts text
          commands.each { |line| puts line }
        end
        0
      end

      def status(args)
        json = args.delete("--json")
        return usage unless args.empty?

        path = ::Polispec::Delegate.socket_path
        reply = Trace.step("ping runner", socket: (Trace.path(path) if Trace.on?)) { ping(path) }
        Trace.info("runner", running: !reply.nil?, version: reply && reply["version"]) if Trace.on?
        loaded = Trace.step("read grants") { grants_module.load }
        scopes = loaded.grants.map { |grant| grants_module.public_scope(grant) }
        if json
          puts JSON.generate("running" => !reply.nil?, "socket" => path, "version" => reply && reply["version"], "grants" => scopes, "problems" => loaded.problems)
        else
          puts reply ? "delegate runner: running (version #{reply['version']}) on #{path}" : "delegate runner: not running (#{path})"
          print_grants(false)
        end
        0
      end

      def ping(path)
        UNIXSocket.open(path) do |sock|
          sock.write("#{JSON.generate('op' => 'ping')}\n")
          return nil unless IO.select([sock], nil, nil, 3)

          reply = JSON.parse(sock.gets.to_s)
          reply.is_a?(Hash) && reply["ok"] ? reply : nil
        end
      rescue SystemCallError, JSON::ParserError, IOError, ArgumentError
        nil
      end
    end
  end
end

Polispec::CLI.register("delegate", Polispec::Commands::Delegate, summary: "let an application run granted promote and deploy commands through a local runner")
