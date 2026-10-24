#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../code/core"
require_relative "../lint"

module Polispec
  module Commands
    class CodeCommand
      USAGE = <<~TEXT.freeze
        usage: polispec code <verb> [options]
          detect <file>                          language of a file
          chain <file|language>                  the spec chain and rules for a language
          show <spec> [--type T] [--domain D]    every policy of a spec
          list [--type T] [--domain D] [--spec PATH]  policies with their type and domain
          check <file> [--before FILE] [--json]  check a file; exit 1 when MUST rules block
          validate                               semantic validation of the pack
          baseline <repo> [--force]              record the per-repo violation baseline
          controls [--policy ID] [--spec PATH]   run every negative control
          generate rubocop|directives|skill      derive artifacts from the pack
          classify <policy-id|file>              propose execution.classified blocks
        options: --ref stable|main|worktree|<git ref>  --repo DIR  --json
      TEXT
      AUTHORING = %w[validate controls baseline generate classify show list].freeze
      TYPES = %w[directive lint review contextual].freeze
      DOMAINS = %w[design accessibility performance code-quality code-meta security operations].freeze
      Options = Struct.new(:ref, :repo, :json, :before, :policy, :spec, :force, :stdout, :type, :domain, :rest, keyword_init: true)

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
        opts = Options.new(ref: nil, repo: nil, json: false, before: nil, policy: nil, spec: nil, force: false, stdout: false, type: nil, domain: nil, rest: [])
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
          when "--type" then opts.type = list.shift
          when "--domain" then opts.domain = list.shift
          else opts.rest << arg
          end
        end
        raise Code::Error, "unknown type #{opts.type}; one of #{TYPES.join(', ')}" if opts.type && !TYPES.include?(opts.type)
        raise Code::Error, "unknown domain #{opts.domain}; one of #{DOMAINS.join(', ')}" if opts.domain && !DOMAINS.include?(opts.domain)
        require_relative "../harness_controls/plane"
        plane = defined?(HarnessControls::Plane) && HarnessControls::Plane.respond_to?(:resolve) ? HarnessControls::Plane.resolve : { "status" => "unsealed" }
        raise Polispec::Error, "sealed authority is broken" if plane["status"] == "broken"
        opts.ref ||= ENV["POLISPEC_CODE_REF"] if plane["status"] == "unsealed" && !ENV["POLISPEC_CODE_REF"].to_s.empty?
        opts.ref ||= AUTHORING.include?(verb) ? Code::AUTHORING_REF : Code::DEFAULT_REF
        opts
      end

      def pack(opts)
        Trace.step("load spec pack", ref: opts.ref, repo: (Trace.path(File.expand_path(opts.repo)) if opts.repo && Trace.on?)) do
          loaded = Code::Pack.load(ref: opts.ref, repo: opts.repo && File.expand_path(opts.repo))
          Trace.info("pack loaded", source: loaded.source.label, specs: loaded.specs.length, policies: loaded.nodes.length) if Trace.on?
          loaded
        end
      end

      def verb_detect(opts)
        return usage unless opts.rest.length == 1

        detector = Code::Detector.new(pack(opts))
        language = Trace.step("detect language", file: (Trace.path(File.expand_path(opts.rest.first)) if Trace.on?)) { detector.detect(File.expand_path(opts.rest.first)) }
        Trace.info("language", language: language)
        opts.json ? puts(JSON.generate("file" => opts.rest.first, "language" => language)) : puts(language)
        0
      end

      def verb_chain(opts)
        return usage unless opts.rest.length == 1

        loaded = pack(opts)
        target = opts.rest.first
        language = File.exist?(target) ? Trace.step("detect language", file: (Trace.path(File.expand_path(target)) if Trace.on?)) { Code::Detector.new(loaded).detect(File.expand_path(target)) } : target
        chain = Trace.step("resolve spec chain", language: language) { Code::Chain.for(loaded, language) }
        Trace.info("chain", digest: chain.digest, specs: chain.spec_paths.length, rules: chain.rules.length) if Trace.on?
        if opts.json
          puts JSON.generate("language" => language, "digest" => chain.digest, "specs" => chain.spec_paths, "rules" => chain.rules.map(&:id))
          return 0
        end
        puts "language #{language}  digest #{chain.digest}  pack #{loaded.source.label}"
        chain.specs.each do |spec|
          rules = chain.rules_of(spec)
          puts "#{spec.path} (#{spec.version}, #{rules.length} rules)"
          rules.each do |rule|
            type, = loaded.type_of(rule)
            puts "  [#{rule.id}] #{rule.level} #{rule.severity} #{rule.klass} #{type || '-'} #{loaded.domain_of(rule) || '-'}  #{rule.title}"
          end
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
            type, = loaded.type_of(node)
            domain = loaded.domain_of(node)
            next if opts.type && opts.type != type
            next if opts.domain && opts.domain != domain

            puts "[#{node.id}] #{node.level} #{node.severity} #{node.klass} #{type || '-'} #{domain || '-'} #{node.lifecycle}"
            puts "  #{Code.squash(node.statement)}"
            puts "  look for: #{Code.squash(node.lens['look_for'])}" if node.lens
            puts "  violation: #{Code.squash(node.lens['violation'])}" if node.lens
          else
            puts "== #{node.id}  #{node.title}"
          end
        end
        0
      end

      def verb_list(opts)
        return usage unless opts.rest.empty?

        loaded = pack(opts)
        rows = []
        loaded.specs.values.sort_by { |spec| [spec.depth, spec.path] }.each do |spec|
          next if opts.spec && !spec.path.start_with?(opts.spec)

          (spec.root ? spec.root.each_rule.to_a : []).each do |rule|
            next unless rule.lifecycle == "active" && rule.active?

            type, source = loaded.type_of(rule)
            domain = loaded.domain_of(rule)
            next if opts.type && opts.type != type
            next if opts.domain && opts.domain != domain

            rows << [rule, type, source, domain]
          end
        end
        if opts.json
          policies = rows.map do |rule, type, source, domain|
            { "id" => rule.id, "spec" => rule.spec, "type" => type, "type_source" => source, "domain" => domain, "class" => rule.klass, "level" => rule.level, "severity" => rule.severity, "title" => rule.title }
          end
          puts JSON.generate("pack" => loaded.source.label, "count" => rows.length, "policies" => policies)
          return 0
        end
        rows.each do |rule, type, _source, domain|
          puts "#{type.to_s.ljust(10)} #{(domain || '-').ljust(13)} #{rule.level} #{rule.severity} [#{rule.id}] #{rule.title}"
        end
        puts "#{rows.length} policies"
        0
      end

      def verb_check(opts)
        return usage unless opts.rest.length == 1

        file = File.expand_path(opts.rest.first)
        raise Code::Error, "#{file} is not a file" unless File.file?(file)

        loaded = pack(opts)
        after = File.read(file).force_encoding(Encoding::UTF_8)
        before = opts.before ? File.read(File.expand_path(opts.before)).force_encoding(Encoding::UTF_8) : nil
        verdict = Trace.step("check file", file: (Trace.path(file) if Trace.on?), compared: !before.nil?) { Code::Checker.new(loaded).check(file, after, before: before) }
        Trace.info("check result", language: verdict.language, chain: verdict.chain_digest[7, 12], findings: verdict.findings.length, blocked: verdict.blocked, deferred: verdict.deferred.length, errors: verdict.errors.length) if Trace.on?
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
        problems = Trace.step("validate pack") { Code::Validator.new(loaded).call }
        Trace.info("validation", problems: problems.length)
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

        baseline_pack = pack(opts)
        Trace.step("scan baseline", repo: (Trace.path(toplevel) if Trace.on?), force: opts.force) { Code::Baseline.scan(toplevel, baseline_pack, force: opts.force) }
        0
      end

      def verb_controls(opts)
        loaded = pack(opts)
        raise Code::Error, "unknown policy id #{opts.policy}" if opts.policy && !loaded.nodes.key?(opts.policy)

        outcomes = Trace.step("run negative controls", spec: opts.spec, policy: opts.policy) { Code::Controls.new(loaded).run(spec: opts.spec, policy: opts.policy) }
        Trace.step("record controls") { Code::Controls.record(loaded, outcomes) } unless opts.spec || opts.policy
        failed = outcomes.select { |outcome| outcome.status == :fail }
        Trace.info("controls", ok: outcomes.count { |o| o.status == :ok }, failed: failed.length, skipped: outcomes.count { |o| o.status == :skip }) if Trace.on?
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
        else puts Trace.step("generate skill") { Code::Generate.skill(loaded) }
        end
        0
      end

      def generate_rubocop(loaded, opts)
        yaml = Trace.step("generate rubocop") { Code::Generate.rubocop(loaded) }
        if opts.stdout || loaded.source.kind != :dir
          puts yaml
        else
          target = File.join(loaded.source.root, "enforcers", "rubocop", "base.yml")
          Trace.step("write rubocop base.yml", path: (Trace.path(target) if Trace.on?)) do
            Lint.guard_write!(yaml, path: target)
            FileUtils.mkdir_p(File.dirname(target))
            File.write(target, yaml)
            Trace.info("wrote file", path: Trace.path(target), bytes: yaml.bytesize) if Trace.on?
          end
          puts target
        end
      end

      def generate_directives(loaded, opts)
        out = Trace.step("generate directives") { Code::Generate.directives(loaded) }
        Trace.info("generated", rows: out["rows"].length, files: out["files"].length) if Trace.on?
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
        raise Code::Error, "#{target} defines no policy rules in this pack; classify takes a policy id, a spec path or a spec.yml file" if rules.empty?
        raise Code::Error, "the decide port is unavailable; classification needs it" unless Code::Decide.available?

        Trace.info("classify targets", rules: rules.length) if Trace.on?
        rules.each do |rule|
          proposal = Trace.step("propose classification", policy: rule.id) { Code::Classify.propose(rule) }
          puts "# #{rule.id}"
          puts proposal ? YAML.dump("execution" => proposal).sub(/\A---\n/, "") : "unclassified: the decide port gave no answer"
        end
        0
      end
    end
  end

  CLI.register("code", Commands::CodeCommand, summary: "code specs: detect, chain, check, validate, controls, baseline, generate, classify")
end
