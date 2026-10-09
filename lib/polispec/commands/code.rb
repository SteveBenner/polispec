#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../code/core"

module Polispec
  module Commands
    class CodeCommand
      USAGE = <<~TEXT.freeze
        usage: polispec code <verb> [options]
          detect <file>                          language of a file
          chain <file|language>                  the spec chain and rules for a language
          show <spec>                            every policy of a spec
          check <file> [--before FILE] [--json]  check a file; exit 1 when MUST rules block
          validate                               semantic validation of the pack
          baseline <repo> [--force]              record the per-repo violation baseline
          controls [--policy ID] [--spec PATH]   run every negative control
          generate rubocop|directives|skill      derive artifacts from the pack
          classify <policy-id|file>              propose execution.classified blocks
        options: --ref stable|main|worktree|<git ref>  --repo DIR  --json
      TEXT
      AUTHORING = %w[validate controls baseline generate classify show].freeze
      Options = Struct.new(:ref, :repo, :json, :before, :policy, :spec, :force, :stdout, :rest, keyword_init: true)

      def self.run(args)
        new.run(args)
      end

      def run(args)
        verb = args.first
        return usage unless verb && respond_to?("verb_#{verb}", true)

        opts = parse(args.drop(1), verb)
        send("verb_#{verb}", opts)
      rescue Code::Error => e
        warn "polispec code: #{e.message}"
        1
      end

      private

      def usage
        warn USAGE
        2
      end

      def parse(args, verb)
        opts = Options.new(ref: nil, repo: nil, json: false, before: nil, policy: nil, spec: nil, force: false, stdout: false, rest: [])
        list = args.dup
        until list.empty?
          arg = list.shift
          case arg
          when "--ref" then opts.ref = list.shift
          when "--repo" then opts.repo = list.shift
          when "--json" then opts.json = true
          when "--before" then opts.before = list.shift
          when "--policy" then opts.policy = list.shift
          when "--spec" then opts.spec = list.shift
          when "--force" then opts.force = true
          when "--stdout" then opts.stdout = true
          else opts.rest << arg
          end
        end
        opts.ref ||= ENV["POLISPEC_CODE_REF"] unless ENV["POLISPEC_CODE_REF"].to_s.empty?
        opts.ref ||= AUTHORING.include?(verb) ? Code::AUTHORING_REF : Code::DEFAULT_REF
        opts
      end

      def pack(opts)
        Code::Pack.load(ref: opts.ref, repo: opts.repo && File.expand_path(opts.repo))
      end

      def verb_detect(opts)
        return usage unless opts.rest.length == 1

        language = Code::Detector.new(pack(opts)).detect(File.expand_path(opts.rest.first))
        opts.json ? puts(JSON.generate("file" => opts.rest.first, "language" => language)) : puts(language)
        0
      end

      def verb_chain(opts)
        return usage unless opts.rest.length == 1

        loaded = pack(opts)
        target = opts.rest.first
        language = File.exist?(target) ? Code::Detector.new(loaded).detect(File.expand_path(target)) : target
        chain = Code::Chain.for(loaded, language)
        if opts.json
          puts JSON.generate("language" => language, "digest" => chain.digest, "specs" => chain.spec_paths, "rules" => chain.rules.map(&:id))
          return 0
        end
        puts "language #{language}  digest #{chain.digest}  pack #{loaded.source.label}"
        chain.specs.each do |spec|
          rules = chain.rules_of(spec)
          puts "#{spec.path} (#{spec.version}, #{rules.length} rules)"
          rules.each { |rule| puts "  [#{rule.id}] #{rule.level} #{rule.severity} #{rule.klass}  #{rule.title}" }
        end
        0
      end

      def verb_show(opts)
        return usage unless opts.rest.length == 1

        loaded = pack(opts)
        spec = loaded.specs[opts.rest.first]
        raise Code::Error, "no spec #{opts.rest.first} in #{loaded.source.label}" unless spec

        puts "#{spec.path} #{spec.version}  #{spec.data['summary']}"
        (spec.root ? spec.root.each_node.to_a : []).each do |node|
          if node.rule?
            puts "[#{node.id}] #{node.level} #{node.severity} #{node.klass} #{node.lifecycle}"
            puts "  #{Code.squash(node.statement)}"
            puts "  look for: #{Code.squash(node.lens['look_for'])}" if node.lens
            puts "  violation: #{Code.squash(node.lens['violation'])}" if node.lens
          else
            puts "== #{node.id}  #{node.title}"
          end
        end
        0
      end

      def verb_check(opts)
        return usage unless opts.rest.length == 1

        file = File.expand_path(opts.rest.first)
        raise Code::Error, "#{file} is not a file" unless File.file?(file)

        loaded = pack(opts)
        after = File.read(file).force_encoding(Encoding::UTF_8)
        before = opts.before ? File.read(File.expand_path(opts.before)).force_encoding(Encoding::UTF_8) : nil
        verdict = Code::Checker.new(loaded).check(file, after, before: before)
        if opts.json
          puts JSON.generate(verdict.to_h)
        else
          print_verdict(verdict)
        end
        verdict.blocked ? 1 : 0
      end

      def print_verdict(verdict)
        puts "#{verdict.file}: #{verdict.language}, chain #{verdict.chain_digest[7, 12]}, #{verdict.findings.length} findings, #{verdict.blocked ? 'BLOCKED' : 'not blocked'} (#{verdict.duration_ms} ms)"
        verdict.findings.each do |finding|
          tag = finding.baseline ? " baseline" : (finding.candidate ? " candidate" : "")
          puts "  #{finding.line || '-'}  [#{finding.policy}] #{finding.level} #{finding.severity}#{tag}  #{finding.message}"
        end
        verdict.errors.each { |error| warn "  enforcer error [#{error['policy']}] #{error['message']}" }
        verdict.notes.each { |note| warn "  note: #{note}" }
        puts "  deferred to review: #{verdict.deferred.map(&:id).join(', ')}" unless verdict.deferred.empty?
      end

      def verb_validate(opts)
        loaded = pack(opts)
        problems = Code::Validator.new(loaded).call
        if opts.json
          puts JSON.generate("ref" => loaded.source.label, "ok" => problems.empty?, "problems" => problems.map(&:to_h))
        elsif problems.empty?
          puts "#{loaded.source.label}: ok (#{loaded.specs.length} specs, #{loaded.nodes.length} policies)"
        else
          puts "#{loaded.source.label}: #{problems.length} problems"
          problems.each { |problem| puts "  #{problem}" }
        end
        problems.empty? ? 0 : 1
      end

      def verb_baseline(opts)
        return usage unless opts.rest.length == 1

        root = File.expand_path(opts.rest.first)
        toplevel = Code::Repo.root(root)
        raise Code::Error, "#{root} is not inside a git repository" unless toplevel

        Code::Baseline.scan(toplevel, pack(opts), force: opts.force)
        0
      end

      def verb_controls(opts)
        loaded = pack(opts)
        outcomes = Code::Controls.new(loaded).run(spec: opts.spec, policy: opts.policy)
        Code::Controls.record(loaded, outcomes) unless opts.spec || opts.policy
        failed = outcomes.select { |outcome| outcome.status == :fail }
        if opts.json
          puts JSON.generate("ref" => loaded.source.label, "ok" => failed.empty?, "controls" => outcomes.map { |outcome| { "policy" => outcome.rule.id, "status" => outcome.status, "message" => outcome.message } })
        else
          outcomes.each { |outcome| puts "#{outcome.status.to_s.upcase.ljust(4)} #{outcome.rule.id}  #{outcome.message}" }
          puts "#{loaded.source.label}: #{outcomes.count { |o| o.status == :ok }} ok, #{failed.length} failed, #{outcomes.count { |o| o.status == :skip }} skipped"
        end
        failed.empty? ? 0 : 1
      end

      def verb_generate(opts)
        what = opts.rest.first
        return usage unless %w[rubocop directives skill].include?(what)

        loaded = pack(opts)
        case what
        when "rubocop" then generate_rubocop(loaded, opts)
        when "directives" then generate_directives(loaded, opts)
        else puts Code::Generate.skill(loaded)
        end
        0
      end

      def generate_rubocop(loaded, opts)
        yaml = Code::Generate.rubocop(loaded)
        if opts.stdout || loaded.source.kind != :dir
          puts yaml
        else
          target = File.join(loaded.source.root, "enforcers", "rubocop", "base.yml")
          FileUtils.mkdir_p(File.dirname(target))
          File.write(target, yaml)
          puts target
        end
      end

      def generate_directives(loaded, opts)
        out = Code::Generate.directives(loaded)
        if opts.json
          puts JSON.generate(out)
          return
        end
        puts "=== AGENTS.md rows"
        out["rows"].each { |row| puts row }
        out["files"].each do |name, text|
          puts "=== #{name}"
          puts text
        end
      end

      def verb_classify(opts)
        return usage unless opts.rest.length == 1

        loaded = pack(opts)
        target = opts.rest.first
        rules =
          if loaded.nodes.key?(target)
            loaded.nodes[target].each_rule.to_a
          elsif loaded.specs.key?(target)
            loaded.specs[target].root.each_rule.to_a
          elsif File.file?(target)
            data = Schema::Document.load(target)
            ids = []
            walk = lambda do |node|
              next unless node.is_a?(Hash)

              ids << node["id"] unless node.key?("subpolicies")
              Array(node["subpolicies"]).each { |child| walk.call(child) }
            end
            walk.call(data["policy"])
            ids.map { |id| loaded.nodes[id] }.compact
          else
            raise Code::Error, "#{target} is neither a policy id, a spec path nor a file"
          end
        raise Code::Error, "the decide port is unavailable; classification needs it" unless Code::Decide.available?

        rules.each do |rule|
          proposal = Code::Classify.propose(rule)
          puts "# #{rule.id}"
          puts proposal ? YAML.dump("execution" => proposal).sub(/\A---\n/, "") : "unclassified: the decide port gave no answer"
        end
        0
      end
    end
  end

  CLI.register("code", Commands::CodeCommand, summary: "code specs: detect, chain, check, validate, controls, baseline, generate, classify")
end
