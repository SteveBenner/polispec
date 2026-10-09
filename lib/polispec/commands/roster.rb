#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Commands
    class RosterCommand
      USAGE = <<~TEXT.freeze
        usage: polispec roster resolve <project> (--role R | --pipeline P --phase X) [--env E] [--roster FILE] [--json]
               polispec roster check <project> --pipeline P --profile <file|-> [--env E] [--roster FILE] [--json]
      TEXT

      def self.run(args)
        new.run(args)
      end

      def run(args)
        args = args.dup
        verb = args.shift
        opts = parse(args)
        return usage unless opts && %w[resolve check].include?(verb)

        roster, digest = load_roster(opts)
        return fail_with(opts, roster) if digest.nil?

        verb == "resolve" ? resolve(opts, roster, digest) : check(opts, roster)
      rescue Roster::Unknown, Polispec::Error => e
        fail_with(opts || {}, e.message)
      end

      private

      def parse(args)
        opts = { json: false }
        positional = []
        until args.empty?
          arg = args.shift
          case arg
          when "--json" then opts[:json] = true
          when "--role", "--pipeline", "--phase", "--profile", "--env", "--roster"
            value = args.shift
            return nil if value.nil?

            opts[arg.delete_prefix("--").to_sym] = value
          when /\A-./ then return nil
          else positional << arg
          end
        end
        return nil unless positional.length == 1

        opts[:project] = positional.first
        opts
      end

      def usage
        warn USAGE
        2
      end

      def load_roster(opts)
        bytes = opts[:roster] ? read_file(opts[:roster]) : trust_blob(opts[:project])
        data = Schema::Document.parse(bytes, opts[:roster] || "roster")
        errors = Schema.validate("roster", data)
        return ["roster is invalid: #{errors.map { |e| "#{e.pointer.empty? ? '/' : e.pointer} #{e.message}" }.join('; ')}", nil] unless errors.empty?
        return ["roster project #{data['project']} does not match #{opts[:project]}", nil] unless data["project"] == opts[:project]

        [data, "sha256:#{Digest::SHA256.hexdigest(bytes)}"]
      rescue Schema::Document::ParseError => e
        [e.message, nil]
      end

      def read_file(path)
        File.read(File.expand_path(path))
      rescue SystemCallError => e
        raise Polispec::Error, "cannot read #{path}: #{e.message}"
      end

      def trust_blob(id)
        project = Ledger.load.project(id)
        raise Polispec::Error, "project #{id} is not in the ledger" unless project

        out, err, status = Open3.capture3("git", "-C", File.expand_path(project.repo), "show", "#{project.trust_ref}:#{project.roster}")
        raise Polispec::Error, "cannot read #{project.trust_ref}:#{project.roster} in #{project.repo}: #{err.strip}" unless status.success?

        out
      end

      def resolve(opts, roster, digest)
        result = Roster.resolve(roster, role: opts[:role], pipeline: opts[:pipeline], phase: opts[:phase], env: opts[:env] || "dev", digest: digest)
        if opts[:json]
          puts JSON.generate(result)
        else
          puts "default: #{JSON.generate(result['default'])}"
          puts "bounds: #{JSON.generate(result['bounds'])}"
          puts "env_allowed (#{opts[:env] || "dev"}): #{result['env_allowed']}"
          puts "roster_digest: #{digest}"
        end
        0
      end

      def check(opts, roster)
        return usage unless opts[:pipeline] && opts[:profile]

        text = opts[:profile] == "-" ? $stdin.read : read_file(opts[:profile])
        profile = Schema::Document.parse(text, opts[:profile])
        violations = Roster.check(roster, opts[:pipeline], profile, env: opts[:env])
        if opts[:json]
          puts JSON.generate("ok" => violations.empty?, "violations" => violations)
        elsif violations.empty?
          puts "ok"
        else
          violations.each { |v| puts "#{v['phase']}.#{v['field']} = #{v['value'].inspect}  (#{v['bound']})" }
        end
        violations.empty? ? 0 : 1
      end

      def fail_with(opts, message)
        if opts[:json]
          puts JSON.generate("ok" => false, "error" => message)
        else
          warn "polispec: #{message}"
        end
        1
      end
    end
  end

  CLI.register("roster", Commands::RosterCommand, summary: "resolve a role or phase assignment and check a profile against bounds")
end
