#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "tmpdir"
require_relative "packages"
require_relative "probes"
require_relative "journal"
require_relative "effect"

module Polispec
  class Plan
    SCHEMA = "polispec.plan/v1"
    FILE_LIMIT = 1_048_576
    TREE_LIMIT = 500
    LEDGER_LOOSEN_FIELDS = %w[status profile trust_ref repo policy roster worktree_globs].freeze
    LEDGER_PATH_LOOSEN_FIELDS = %w[status path kind policy].freeze
    LEDGER_TOP_LOOSEN = %w[defaults envs_root].freeze
    SECTIONS = %w[rules gates freezes modules hermetic].freeze
    SPEC = Struct.new(:kind, :package, :repo, :variant, :params, :id, :from, :file, keyword_init: true)
    Parsed = Struct.new(:spec, :confirm, :commit, :push, :checkouts, :with_stewardship, :dry, :json, keyword_init: true)
    Change = Struct.new(:dir, :reason)

    module Args
      TARGETS = "<package> --repo REPO [--variant V] [--param k=v]... | project:<id> [--from REF|worktree] | global [--from REF|worktree] | ledger --from FILE"
      VALUE_FLAGS = %w[--repo --variant --param --from --confirm].freeze
      SWITCHES = %w[--commit --push --checkouts --with-stewardship --dry-run --json].freeze
      APPLY_ONLY = %w[--confirm --commit --push --checkouts --with-stewardship --dry-run].freeze

      module_function

      def usage(verb)
        flags = verb == "apply" ? " [--confirm PLAN_ID] [--commit] [--push] [--checkouts] [--with-stewardship] [--dry-run]" : ""
        "usage: polispec #{verb} #{TARGETS}#{flags} [--json]"
      end

      def parse(args, verb)
        rest = args.dup
        values = Hash.new { |hash, key| hash[key] = [] }
        switches = []
        positional = []
        until rest.empty?
          arg = rest.shift
          flag, inline = arg.start_with?("--") ? arg.split("=", 2) : [arg, nil]
          if VALUE_FLAGS.include?(flag)
            value = inline || rest.shift
            raise Packages::Usage, "#{flag} needs a value" if value.nil?

            values[flag] << value
          elsif SWITCHES.include?(flag) && inline.nil?
            switches << flag
          elsif arg.start_with?("-")
            raise Packages::Usage, "unknown option #{arg}"
          else
            positional << arg
          end
        end
        raise Packages::Usage, "exactly one target is required" unless positional.length == 1

        used = (values.keys + switches) & APPLY_ONLY
        raise Packages::Usage, "#{used.first} applies to apply only" if verb == "plan" && !used.empty?

        spec = build_spec(positional.first, values)
        Parsed.new(spec: spec, confirm: values["--confirm"].last, commit: switches.include?("--commit"), push: switches.include?("--push"),
                   checkouts: switches.include?("--checkouts"), with_stewardship: switches.include?("--with-stewardship"),
                   dry: switches.include?("--dry-run"), json: switches.include?("--json"))
      end

      def build_spec(target, values)
        from = values["--from"].last
        case target
        when "global"
          SPEC.new(kind: :global, from: from)
        when "ledger"
          raise Packages::Usage, "ledger needs --from FILE" if from.nil?

          SPEC.new(kind: :ledger, file: File.expand_path(from))
        when /\Aproject:(.+)\z/
          SPEC.new(kind: :project, id: Regexp.last_match(1), from: from)
        else
          raise Packages::Usage, "#{target} needs --repo REPO" if values["--repo"].empty?

          params = values["--param"].each_with_object({}) do |item, memo|
            key, value = item.split("=", 2)
            raise Packages::Usage, "--param needs k=v, got #{item}" if value.nil? || key.empty?

            memo[key] = value
          end
          SPEC.new(kind: :package, package: target, repo: values["--repo"].last, variant: values["--variant"].last, params: params)
        end
      end
    end

    attr_reader :data, :runner, :artifacts

    def self.build(spec, options = {})
      new(spec, options).tap(&:build)
    end

    def self.compare_refs(repo, file, from, to)
      new(SPEC.new(kind: "compare")).send(:refs_changes, File.expand_path(repo.to_s), file.to_s, from.to_s, to.to_s)
    end

    def initialize(spec, options = {})
      @spec = spec
      @options = options
      @artifacts = {}
      @changes = []
      @diffs = []
      @probes = []
      @journal = []
      @notes = []
    end

    def plan_id
      @data["plan_id"]
    end

    def needs_confirm?
      @data["needs_confirm"]
    end

    def build
      parts = Probes.silently { send("build_#{@spec.kind}") }
      finalize(parts)
      self
    end

    def to_json(*)
      JSON.generate(@data)
    end

    def render_text(out = $stdout)
      out.puts "plan #{@data['plan_id']} #{@data['target']}"
      out.puts "classification: #{@data['classification']}; needs_confirm: #{@data['needs_confirm']}"
      out.puts "Takes effect: #{Effect.describe(@data['effects'])}" unless Array(@data["effects"]).empty?
      @data["reasons"].first(12).each { |reason| out.puts "  #{reason}" }
      out.puts "  ... #{@data['reasons'].length - 12} more (--json lists all)" if @data["reasons"].length > 12
      unless @data["notes"].empty?
        out.puts "notes:"
        @data["notes"].each { |note| out.puts "  #{note}" }
      end
      out.puts "files:"
      @data["files"].each do |file|
        out.puts "  #{file['action']} #{file['path']}"
        out.puts file["diff"].lines.map { |line| "    #{line}" }.join if %w[replace conflict].include?(file["action"]) && !file["diff"].empty?
      end
      out.puts "ledger: #{@data['ledger'] ? 'changes' : 'untouched'}"
      if @data["ledger"]
        out.puts "  before: #{@data['ledger']['before'] ? JSON.generate(@data['ledger']['before']) : 'none'}"
        out.puts "  after: #{@data['ledger']['after'] ? JSON.generate(@data['ledger']['after']) : 'none'}"
      end
      @data["policy_diff"].each { |entry| out.puts "policy #{entry['project']}: #{summary(entry)} (#{entry['digest']['before'] || '-'} -> #{entry['digest']['after'] || '-'})" }
      changed = @data["probes"].reject { |probe| probe["change"] == "same" }
      out.puts "probes: #{@data['probes'].length} judged, #{changed.length} changed"
      changed.each { |probe| out.puts "  #{probe['change']} #{probe['project']} #{probe['probe']}: #{probe['before']} -> #{probe['after']}" }
      journal_changed = @data["journal"].reject { |probe| probe["change"] == "same" }
      out.puts "journal: #{@data['journal'].length} replayed, #{journal_changed.length} changed"
      journal_changed.each { |probe| out.puts "  #{probe['change']} #{probe['project']} #{probe['probe']}: #{probe['before']} -> #{probe['after']}" }
      return unless @data["steps"]

      out.puts "steps (apply name = onboard name):"
      @data["steps"].each { |step, legacy| out.puts "  #{step} = #{legacy}" }
    end

    private

    def summary(entry)
      parts = SECTIONS.flat_map do |section|
        counts = entry[section].map { |kind, items| "#{kind == 'added' ? '+' : (kind == 'removed' ? '-' : '~')}#{items.length}" if items.any? }.compact
        counts.empty? ? [] : ["#{section} #{counts.join(' ')}"]
      end
      parts.empty? ? "no structural change" : parts.join(", ")
    end

    def effects_for(parts)
      project = parts[:target].to_s[/\Aproject:(.+)\z/, 1]
      Effect.classes("apply", "project" => project, "files" => Array(parts[:files]).select { |item| %w[add replace].include?(item["action"]) }.map { |item| item["path"] })
    rescue StandardError
      []
    end

    def canonical(value)
      case value
      when Hash then value.keys.map(&:to_s).sort.each_with_object({}) { |key, memo| memo[key] = canonical(value[key] || value[key.to_sym]) }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def finalize(parts)
      probes = @probes.flat_map { |entry| entry[:probes] }
      journal = @journal.flat_map { |entry| entry[:probes] }
      classification = classify(probes + journal)
      reasons = @changes.map { |change| "#{change.dir}: #{change.reason}" }.uniq
      needs = !%w[tightening neutral].include?(classification) || parts[:global] == true
      reasons << "global changes always need confirmation" if parts[:global]
      id = "plan_#{Digest::SHA256.hexdigest(JSON.generate(canonical('target' => parts[:target], 'proposed' => parts[:proposed], 'current' => parts[:current], 'classification' => classification)))[0, 24]}"
      @data = {
        "schema" => SCHEMA, "target" => parts[:target], "plan_id" => id, "files" => parts[:files] || [], "ledger" => parts[:ledger],
        "policy_diff" => @diffs, "probes" => probes, "journal" => journal, "classification" => classification, "needs_confirm" => needs,
        "reasons" => reasons, "steps" => parts[:steps], "notes" => @notes.uniq,
        "effects" => effects_for(parts)
      }
    end

    def classify(rows)
      rows.each do |row|
        next if row["change"] == "same" || @structural_only

        @changes << Change.new(row["change"] == "tighten" ? "tighten" : "loosen", "#{row['project']} probe #{row['probe']}: #{row['before']} -> #{row['after']}")
      end
      tight = @changes.any? { |change| change.dir == "tighten" }
      loose = @changes.any? { |change| change.dir == "loosen" }
      return "mixed" if tight && loose
      return "loosening" if loose
      return "tightening" if tight

      "neutral"
    end

    def probe_rows(entries)
      entries.flat_map { |entry| entry[:probes] }
    end

    def tree_entries(root, relative)
      base = relative.to_s.empty? ? root : File.join(root, relative)
      return {} unless File.directory?(base)

      files = Dir.glob(File.join(base, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) && !File.symlink?(path) && !path.include?("/.git/") }
      files = files.first(TREE_LIMIT)
      files.each_with_object({}) do |path, memo|
        next if File.size(path) > FILE_LIMIT

        memo[path.sub("#{base}/", "")] = File.read(path)
      end
    end

    def git_tree(repo, ref, relative)
      prefix = relative.to_s.empty? ? "" : "#{relative.sub(%r{/+\z}, '')}/"
      listing = Environments.git(repo, "ls-tree", "-r", "--name-only", ref, "--", relative.to_s.empty? ? "." : relative.to_s)
      return {} if listing.nil?

      listing.lines.map(&:chomp).first(TREE_LIMIT).each_with_object({}) do |path, memo|
        text = Environments.git(repo, "show", "#{ref}:#{path}")
        next if text.nil? || text.bytesize > FILE_LIMIT

        memo[prefix.empty? ? path : path.delete_prefix(prefix)] = text
      end
    end

    def file_rows(current, proposed, prefix = "")
      proposed.map do |path, text|
        old = current[path]
        action = old.nil? ? "add" : (old == text ? "unchanged" : "replace")
        { "path" => "#{prefix}#{path}", "action" => action, "diff" => action == "unchanged" ? "" : Packages.unified_diff("#{prefix}#{path}", old, text), "digest" => Packages.sha(text) }
      end
    end

    def digests(map)
      map.each_with_object({}) { |(path, text), memo| memo[path] = Packages.sha(text) }
    end

    def with_dir(files)
      Dir.mktmpdir("polispec-plan") do |dir|
        files.each do |relative, text|
          path = File.join(dir, relative)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, text)
        end
        yield dir
      end
    end

    def with_global(dir)
      previous = ENV["POLISPEC_GLOBAL"]
      ENV["POLISPEC_GLOBAL"] = dir
      Layers.reset!
      yield
    ensure
      previous.nil? ? ENV.delete("POLISPEC_GLOBAL") : ENV["POLISPEC_GLOBAL"] = previous
      Layers.reset!
    end

    KIND_OF_SECTION = { "rules" => "rule", "gates" => "gate", "freezes" => "freeze", "modules" => "module" }.freeze
    VERDICT_RANK = { "allow" => 0, "warn" => 1, "deny" => 2 }.freeze

    def refs_changes(repo, file, from, to)
      ledger = Ledger.load
      project = ledger.projects.find { |entry| entry.status != "retired" && File.expand_path(entry.repo) == repo && entry.policy == file }
      before, after, probes = Probes.silently do
        sides = project ? project_ref_sides(project, ledger, repo, file, from, to) : document_ref_sides(repo, file, from, to)
        [sides[0], sides[1], ref_probe_rows(sides[0], sides[1])]
      end
      entry = diff_sides(file, before, after)
      { "from" => from, "to" => to, "changes" => ref_change_rows(entry, before, after, probes) }
    end

    def ref_probe_rows(before, after)
      reference = after || before
      return [] unless reference && reference.cwd

      actions = Probes.generate(reference.policy, reference.cwd)
      Probes.compare(actions, Probes.outcomes(before, actions), Probes.outcomes(after, actions))
    end

    def project_ref_sides(project, ledger, repo, file, from, to)
      env_file = Environments.path_for(file)
      [from, to].map do |ref|
        text = Environments.git(repo, "show", "#{ref}:#{file}")
        next nil if text.nil?

        source = "bootstrap:#{ref}:plan"
        Probes.compose(project, ledger, text, Environments.git(repo, "show", "#{ref}:#{env_file}"), source: source, local: Layers.local_source(project, source))
      end
    end

    def document_ref_sides(repo, file, from, to)
      [from, to].map do |ref|
        text = Environments.git(repo, "show", "#{ref}:#{file}")
        next nil if text.nil?

        doc = Schema::Document.parse(text, "#{ref}:#{file}")
        doc = {} unless doc.is_a?(Hash)
        document_side(doc, text, repo)
      end
    end

    def document_side(doc, text, repo)
      gates = doc["gates"].is_a?(Hash) ? doc["gates"] : {}
      promotion = %w[to_test to_stable].to_h { |key| [key, { "gates" => Array(gates[key]) }] }
      policy = { "rules" => Array(doc["rules"]), "freezes" => Array(doc["freezes"]), "promotion" => promotion }
      modules = Array(doc["includes"]).map { |entry| entry.is_a?(Hash) ? entry["module"].to_s : entry.to_s }
      layer = Layers::Layer.new(name: "repo", rules: Array(doc["rules"]), modules: modules)
      chain = Layers::Chain.new(layers: [layer], errors: [], profile: nil, applied: [])
      Probes::Side.new(id: "document", policy: policy, digest: Packages.sha(text), cwd: nil, chain: chain)
    end

    def ref_change_rows(entry, before, after, probes)
      rows = []
      %w[modules rules gates freezes].each do |section|
        old = item_map(section, before)
        new = item_map(section, after)
        kind = KIND_OF_SECTION.fetch(section)
        {
          "added" => entry[section]["added"], "removed" => entry[section]["removed"], "changed" => entry[section]["changed"]
        }.each do |change, keys|
          keys.each do |key|
            rows << ref_change_row(kind, change, key, old[key], new[key], probes)
          end
        end
      end
      rows
    end

    def ref_change_row(kind, change, key, old, new, probes)
      id = key.sub(%r{\Arepo/}, "")
      classification = case change
                       when "added" then "tightening"
                       when "removed" then "loosening"
                       else ref_classification(kind, id, old, new, probes)
                       end
      { "kind" => kind, "change" => change, "id" => id, "classification" => classification, "summary" => ref_summary(kind, change, id, old, new), "before" => ref_text(old), "after" => ref_text(new) }
    end

    def ref_classification(kind, id, old, new, probes)
      if kind == "rule" && old.is_a?(Hash) && new.is_a?(Hash) && old["verdict"] != new["verdict"]
        return VERDICT_RANK.fetch(new["verdict"].to_s, 0) > VERDICT_RANK.fetch(old["verdict"].to_s, 0) ? "tightening" : "loosening"
      end

      short = id.split(%r{[/:]}).last
      related = probes.select { |row| [row["before"], row["after"]].any? { |text| text.to_s.split(" ", 2).last == short } }
      moved = related.map { |row| row["change"] }.reject { |value| value == "same" }
      return "neutral" if moved.empty?

      moved.include?("loosen") ? "loosening" : "tightening"
    end

    def ref_summary(kind, change, id, old, new)
      label = "#{kind.capitalize} #{id}"
      return "#{label} added" if change == "added"
      return "#{label} removed" if change == "removed"
      if kind == "rule" && old.is_a?(Hash) && new.is_a?(Hash) && old["verdict"] != new["verdict"]
        return "#{label} verdict #{old['verdict']} to #{new['verdict']}"
      end

      "#{label} changed"
    end

    def ref_text(value)
      return nil if value.nil?
      return value if value.is_a?(String)

      YAML.dump(value).sub(/\A---\n/, "")
    end

    def item_map(section, side)
      return {} unless side

      policy = side.policy
      case section
      when "rules"
        chain = side.chain
        layers = chain ? chain.layers : [Layers::Layer.new(name: "repo", rules: Array(policy["rules"]))]
        layers.each_with_object({}) do |layer, memo|
          Array(layer.rules).each_with_index do |rule, index|
            memo["#{layer.name}/#{rule['id'] || "rule[#{index}]"}"] = rule.reject { |key, _| key == "reason" }
          end
        end
      when "gates"
        %w[to_test to_stable].each_with_object({}) do |name, memo|
          section_body = (policy["promotion"] || {})[name]
          next unless section_body.is_a?(Hash)

          Array(section_body["gates"]).each { |gate| memo["#{name}:#{gate['id']}"] = gate }
          Array(section_body["preflight"]).each { |gate| memo["#{name}:preflight:#{gate['id']}"] = gate }
        end
      when "freezes"
        Array(policy["freezes"]).each_with_object({}) { |freeze, memo| memo[freeze["id"].to_s] = freeze }
      when "modules"
        chain = side.chain
        chain ? chain.layers.flat_map { |layer| layer.modules.map { |name| ["#{layer.name}:#{name}", name] } }.to_h : {}
      when "hermetic"
        hermetic = policy["hermetic"].is_a?(Hash) ? policy["hermetic"] : {}
        hermetic.each_with_object({}) do |(tier, config), memo|
          next unless config.is_a?(Hash)

          %w[isolate protected_roots].each { |key| Array(config[key]).each { |path| memo["#{tier}:#{key}:#{path}"] = path } }
        end
      else
        {}
      end
    end

    def diff_sides(id, before, after)
      entry = { "project" => id, "digest" => { "before" => before && before.digest, "after" => after && after.digest } }
      SECTIONS.each do |section|
        old = item_map(section, before)
        new = item_map(section, after)
        entry[section] = {
          "added" => (new.keys - old.keys).sort, "removed" => (old.keys - new.keys).sort,
          "changed" => (old.keys & new.keys).select { |key| old[key] != new[key] }.sort
        }
      end
      entry
    end

    def record_structure(entry, subject_probes)
      SECTIONS.each do |section|
        entry[section]["removed"].each { |item| @changes << Change.new("loosen", "#{entry['project']} removes #{section.chomp('s')} #{item}") }
        entry[section]["added"].each { |item| @changes << Change.new("tighten", "#{entry['project']} adds #{section.chomp('s')} #{item}") }
      end
      seen = subject_probes.flat_map { |row| [row["before"], row["after"]] }.map { |text| text.to_s.split(" ", 2).last }
      SECTIONS.each do |section|
        entry[section]["changed"].each do |item|
          id = item.split(%r{[/:]}).last
          next if seen.include?(id)

          @changes << Change.new("loosen", "#{entry['project']} changes #{section.chomp('s')} #{item} with no probe evidence")
        end
      end
    end

    def compare(id, before, after, journal_rows)
      reference = after || before
      return unless reference

      actions = Probes.generate(reference.policy, reference.cwd)
      rows = Probes.compare(actions, Probes.outcomes(before, actions), Probes.outcomes(after, actions)).map { |row| row.merge("project" => id) }
      replayed = journal_compare(id, before, after, journal_rows)
      @probes << { project: id, probes: rows }
      @journal << { project: id, probes: replayed }
      entry = diff_sides(id, before, after)
      @diffs << entry
      record_structure(entry, rows + replayed)
    end

    def journal_rows_for(id)
      Journal.recent.select { |row| row["project"] == id }
    end

    def journal_compare(id, before, after, rows)
      return [] if rows.empty?

      actions = Probes.journal_actions(rows)
      Probes.compare(actions, Probes.outcomes(before, actions), Probes.outcomes(after, actions)).map { |row| row.merge("project" => id) }
    end

    def build_package
      package = Packages.find(@spec.package)
      options = Packages::Runner::Options.new(repo: @spec.repo, variant: @spec.variant, params: @spec.params, commit: false, push: false, checkouts: false, dry: true, json: false)
      runner = Packages::Runner.new(package, options)
      runner.prepare
      @runner = runner
      files = runner.file_plan
      ledger = runner.ledger_effect
      existing = runner.ledger_before.project(runner.id)
      @changes << Change.new("tighten", "adds project #{runner.id} with status onboarding") if runner.kinds.include?("ledger") && !existing
      @changes << Change.new("tighten", "creates the starter ledger #{runner.ledger_before.path} with no projects") if runner.ledger_created?
      subject_for_package(runner, existing)
      @artifacts[:runner] = runner
      {
        target: "package:#{package.name}@#{package.version}:#{runner.variant}:#{runner.root}", files: files, ledger: ledger,
        proposed: runner.file_actions.to_h { |item| [item[:path], Packages.sha(item[:text])] }.merge("ledger_record" => "#{package.name}@#{package.version}:#{runner.variant}"),
        current: runner.file_actions.to_h { |item| [item[:path], item[:current] ? Packages.sha(item[:current]) : nil] },
        steps: Packages::LEGACY_STEP_NAMES
      }
    end

    def subject_for_package(runner, existing)
      return unless runner.policy_texts

      ledger = runner.proposed_ledger
      project = ledger.project(runner.id)
      return unless project

      root = runner.root
      policy_path = File.join(root, Packages::Runner::POLICY_FILE)
      before = nil
      if File.file?(policy_path)
        env_path = File.join(root, Packages::Runner::ENVIRONMENTS_FILE)
        before = Probes.compose(project, ledger, File.read(policy_path), File.file?(env_path) ? File.read(env_path) : nil, source: "file:#{policy_path}",
                                local: Layers.local_source(project, "file:#{policy_path}"))
      end
      finals = runner.final_files
      overlay = tree_entries(root, "specs/polispec").transform_keys { |name| "specs/polispec/#{name}" }.merge(finals)
      with_dir(overlay) do |dir|
        file = File.join(dir, Packages::Runner::POLICY_FILE)
        env_file = File.join(dir, Packages::Runner::ENVIRONMENTS_FILE)
        after = Probes.compose(project, ledger, File.read(file), File.file?(env_file) ? File.read(env_file) : nil, source: "file:#{file}",
                               local: Layers.local_source(project, "file:#{file}"))
        compare(runner.id, before, after, journal_rows_for(runner.id))
      end
    end

    def build_project
      ledger = Ledger.load
      project = ledger.project(@spec.id)
      raise Operator::Failure.new("unknown_project", "#{@spec.id} is not in the ledger") unless project
      raise Operator::Failure.new("project_retired", "#{project.id} is retired") if project.status == "retired"

      repo = File.expand_path(project.repo)
      dir = File.dirname(project.policy)
      dir = "" if dir == "."
      current_files = git_tree(repo, project.trust_ref, dir)
      from = @spec.from.to_s.empty? ? "worktree" : @spec.from
      proposed_files = from == "worktree" ? tree_entries(repo, dir) : git_tree(repo, from, dir)
      policy_name = File.basename(project.policy)
      raise Operator::Failure.new("policy_missing", "#{project.policy} is not present in #{from == 'worktree' ? repo : from}") unless proposed_files.key?(policy_name)

      env_name = File.basename(Environments.path_for(project.policy))
      env_name = "environments.yml" unless proposed_files.key?(env_name)
      before = Probes.resolved(project, ledger)
      local = from == "worktree" ? Layers.local_source(project, "file:#{File.join(repo, project.policy)}") : Layers.local_source(project, "bootstrap:#{from}:plan")
      after = Probes.compose(project, ledger, proposed_files[policy_name], proposed_files[env_name], source: from == "worktree" ? "file:#{File.join(repo, project.policy)}" : "bootstrap:#{from}:plan", local: local)
      compare(project.id, before, after, journal_rows_for(project.id))
      @notes.concat(Operator::Gates.unreachable_errors(after.policy).map { |message| "#{project.id}: #{message}" })
      files = file_rows(current_files, proposed_files, dir.empty? ? "" : "#{dir}/")
      @artifacts.merge!(project: project, repo: repo, dir: dir, from: from, proposed_files: proposed_files, files: files)
      {
        target: "project:#{project.id}", files: files,
        proposed: digests(proposed_files), current: digests(current_files)
      }
    end

    def build_global
      source = Layers.source
      raise Operator::Failure.new("global_unconfigured", "no global layer is configured (polispec.global.repo)") unless source

      ledger = Ledger.load
      if source.kind == :repo
        repo = source.repo
        current_files = git_tree(repo, source.ref, source.path)
        from = @spec.from.to_s.empty? ? "worktree" : @spec.from
        proposed_files = from == "worktree" ? tree_entries(repo, source.path) : git_tree(repo, from, source.path)
      else
        current_files = tree_entries(source.root, "")
        from = @spec.from.to_s
        raise Operator::Failure.new("global_from_required", "the global layer is a plain directory; plan global --from DIR") if from.empty? || from == "worktree"

        proposed_files = tree_entries(File.expand_path(from), "")
      end
      raise Operator::Failure.new("global_empty", "the proposed global layer holds no files") if proposed_files.empty?

      before_global = Layers.global
      projects = ledger.projects.reject { |project| project.status == "retired" }
      before = projects.to_h { |project| [project.id, Probes.resolved(project, ledger)] }
      with_dir(proposed_files) do |dir|
        with_global(dir) do
          after_global = Layers.global
          projects.each do |project|
            after = Probes.resolved(project, ledger)
            old = before[project.id]
            actions = Probes.generate(after.policy, after.cwd)
            rows = Probes.compare(actions, Probes.outcomes(old, actions), Probes.outcomes(after, actions)).map { |row| row.merge("project" => project.id) }
            journal_rows = journal_rows_for(project.id)
            replayed = if journal_rows.empty?
                         []
                       else
                         replay_actions = Probes.journal_actions(journal_rows)
                         Probes.compare(replay_actions, Probes.outcomes(old, replay_actions), Probes.outcomes(after, replay_actions)).map { |row| row.merge("project" => project.id) }
                       end
            @probes << { project: project.id, probes: rows }
            @journal << { project: project.id, probes: replayed }
            entry = diff_sides(project.id, old, after)
            @diffs << entry
            record_structure(entry, rows + replayed)
          end
          global_diff(before_global, after_global)
        end
      end
      @artifacts.merge!(source: source, from: from, proposed_files: proposed_files)
      {
        target: "global", files: file_rows(current_files, proposed_files, source.kind == :repo && !source.path.to_s.empty? ? "#{source.path}/" : ""),
        proposed: digests(proposed_files), current: digests(current_files), global: true
      }
    end

    def global_diff(before, after)
      old = global_items(before)
      new = global_items(after)
      entry = { "project" => "global", "digest" => { "before" => nil, "after" => nil } }
      SECTIONS.each { |section| entry[section] = { "added" => [], "removed" => [], "changed" => [] } }
      %w[rules modules hermetic].each do |section|
        o = old[section] || {}
        n = new[section] || {}
        entry[section] = { "added" => (n.keys - o.keys).sort, "removed" => (o.keys - n.keys).sort, "changed" => (o.keys & n.keys).select { |key| o[key] != n[key] }.sort }
      end
      @diffs << entry
      record_structure(entry, [])
    end

    def global_items(doc)
      return {} unless doc.is_a?(Hash)

      rules = {}
      Array(doc["rules"]).each_with_index { |rule, index| rules["global/#{rule['id'] || "rule[#{index}]"}"] = rule.reject { |key, _| key == "reason" } }
      (doc["modules"] || {}).each do |name, body|
        Array(body["rules"]).each_with_index { |rule, index| rules["#{name}/#{rule['id'] || "rule[#{index}]"}"] = rule.reject { |key, _| key == "reason" } }
      end
      roots = Array(doc["protected_roots"]).each_with_object({}) do |entry, memo|
        memo["root:#{entry['path'] || entry}"] = entry
      end
      protected_deletes = [doc] + (doc["modules"] || {}).values
      Layers.delete_protected_union(protected_deletes).each do |kind, paths|
        paths.each { |path| roots["delete:#{kind}:#{path}"] = path }
      end
      modules = (doc["modules"] || {}).keys.to_h { |name| [name, name] }
      profiles = (doc["profiles"] || {}).to_h { |name, list| ["profile:#{name}", list] }
      { "rules" => rules, "modules" => modules.merge(profiles), "hermetic" => roots }
    end

    def build_ledger
      current = Ledger.load
      result = Schema.validate_file("ledger", @spec.file)
      unless result.ok
        raise Operator::Failure.new("ledger_invalid", "#{@spec.file} does not validate", "problems" => result.errors.map { |error| "#{error.pointer} #{error.message}".strip })
      end

      proposed = Ledger.load(@spec.file)
      old_data = ledger_data(current.path)
      new_data = ledger_data(@spec.file)
      LEDGER_TOP_LOOSEN.each do |key|
        @changes << Change.new("loosen", "ledger #{key} changes") if old_data[key] != new_data[key]
      end
      old_entries = ledger_entries(old_data)
      new_entries = ledger_entries(new_data)
      (old_entries.keys - new_entries.keys).each do |id|
        @changes << Change.new("loosen", id.start_with?("path:") ? "ledger drops path #{id.delete_prefix('path:')}" : "ledger drops project #{id}")
      end
      changed_ids = []
      new_entries.each do |id, entry|
        old = old_entries[id]
        if id.start_with?("path:")
          name = id.delete_prefix("path:")
          if old.nil?
            changed_ids << id
            @changes << Change.new(entry["status"] == "onboarding" ? "tighten" : "loosen", "ledger adds path #{name} with status #{entry['status']}")
          else
            fields = LEDGER_PATH_LOOSEN_FIELDS.select { |field| old[field] != entry[field] }
            fields.each { |field| @changes << Change.new("loosen", "ledger changes #{field} of path #{name}") }
            changed_ids << id unless fields.empty?
          end
          next
        end
        if old.nil?
          changed_ids << id
          if entry["status"] == "onboarding"
            @changes << Change.new("tighten", "ledger adds project #{id} with status onboarding")
          else
            @changes << Change.new("loosen", "ledger adds project #{id} with status #{entry['status']}")
          end
          next
        end
        fields = LEDGER_LOOSEN_FIELDS.select { |field| old[field] != entry[field] }
        fields.each { |field| @changes << Change.new("loosen", "ledger changes #{field} of #{id}") }
        changed_ids << id unless fields.empty?
      end
      subjects = changed_ids.filter_map do |id|
        project = proposed.project(id)
        old_project = current.project(id)
        next nil unless project && project.status != "retired"

        [id, old_project && old_project.status != "retired" ? Probes.resolved(old_project, current) : nil, Probes.resolved(project, proposed)]
      end
      @structural_only = true
      subjects.each do |id, before, after|
        compare(id, before, after, journal_rows_for(id))
      end
      @changes.select! { |change| change.reason.start_with?("ledger ") }
      dropped = old_entries.keys - new_entries.keys
      @artifacts.merge!(file: @spec.file, bytes: File.read(@spec.file))
      {
        target: "ledger", files: [{ "path" => current.path, "action" => current.digest == "sha256:#{Digest::SHA256.hexdigest(File.read(@spec.file))}" ? "unchanged" : "replace", "diff" => Packages.unified_diff(current.path, File.file?(current.path) ? File.read(current.path) : "", File.read(@spec.file)), "digest" => Packages.sha(File.read(@spec.file)) }],
        ledger: { "before" => old_entries.slice(*(changed_ids + dropped)), "after" => new_entries.slice(*changed_ids) },
        proposed: { "ledger" => Packages.sha(File.read(@spec.file)) }, current: { "ledger" => current.digest }
      }
    end

    def ledger_entries(data)
      entries = Array(data["projects"]).to_h { |entry| [entry["id"], entry] }
      Array(data["paths"]).each { |entry| entries["path:#{entry['id']}"] = entry }
      entries
    end

    def ledger_data(path)
      return {} unless File.file?(path)

      data = Schema::Document.load(path)
      data.is_a?(Hash) ? data : {}
    end
  end
end
