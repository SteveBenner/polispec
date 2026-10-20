#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "stringio"
require "tempfile"
require_relative "operator/git"
require_relative "registration"

module Polispec
  module Packages
    class Usage < Polispec::Error; end

    NAME_PATTERN = /\A[a-z0-9][a-z0-9-]{0,40}\z/.freeze
    STEP_KINDS = %w[files manifest ledger render commit branches push checkouts].freeze
    LEGACY_STEP_NAMES = {
      "files" => "1_scaffold", "manifest" => "2_manifest", "ledger" => "3_ledger", "render" => "4_render",
      "commit" => "4b_commit", "branches" => "5_branches", "push" => "5_branches", "checkouts" => "6_checkouts"
    }.freeze
    COMMIT_MESSAGES = { "environment-control" => "Add the polispec scaffold" }.freeze
    SHIPPED = File.join(ROOT, "packages").freeze

    Step = Struct.new(:kind, :param, :equals)

    class Package
      attr_reader :data, :origin

      def initialize(data, origin, reader)
        @data = data
        @origin = origin
        @reader = reader
      end

      def name
        data["name"]
      end

      def version
        data["version"]
      end

      def summary
        data["summary"]
      end

      def params
        data["params"].is_a?(Hash) ? data["params"] : {}
      end

      def variants
        data["variants"].is_a?(Hash) ? data["variants"] : {}
      end

      def default_variant
        data["default_variant"]
      end

      def read(relative)
        @reader.call(relative)
      end

      def steps
        Array(data["steps"]).map do |entry|
          if entry.is_a?(String)
            Step.new(entry, nil, nil)
          else
            condition = entry["when"]
            Step.new(entry["kind"], condition && condition["param"], condition && condition["equals"])
          end
        end
      end

      def active?(step, values)
        step.param.nil? || values[step.param].to_s == step.equals.to_s
      end

      def active_steps(values)
        steps.select { |step| active?(step, values) }
      end

      def file_map(variant)
        map = {}
        (variant ? (variants[variant] || {})["files"] : nil).to_h.each { |target, source| map[target] = source }
        data["files"].to_h.each { |target, source| map[target] = source unless map.key?(target) }
        Array(data["modules"]).each { |module_name| map["specs/polispec/modules/#{module_name}.yml"] = "modules/#{module_name}.yml" }
        map
      end
    end

    module_function

    def sha(text)
      "sha256:#{Digest::SHA256.hexdigest(text)}"
    end

    def find(name)
      raise Operator::Failure.new("package_missing", "package #{name} does not exist") unless NAME_PATTERN.match?(name.to_s)

      hits = []
      shipped = File.join(SHIPPED, name, "package.yml")
      hits << ["shipped", ->(relative) { read_file(File.join(SHIPPED, name, relative)) }] if File.file?(shipped)
      store = Layers.store
      hits << ["global", ->(relative) { store.read("packages/#{name}/#{relative}") }] if store && store.read("packages/#{name}/package.yml")
      raise Operator::Failure.new("package_missing", "package #{name} does not exist in #{SHIPPED} or the global shelf") if hits.empty?
      raise Operator::Failure.new("package_ambiguous", "package #{name} is ambiguous", "sources" => hits.map(&:first)) if hits.length > 1

      origin, reader = hits.first
      build(name, origin, reader)
    end

    def build(name, origin, reader)
      text = reader.call("package.yml")
      data = Schema::Document.parse(text, "packages/#{name}/package.yml")
      problems = Schema.validate("package", data).map { |error| "#{error.pointer} #{error.message}".strip }
      problems << "/name must equal #{name}" if problems.empty? && data["name"] != name
      raise Operator::Failure.new("package_invalid", "package #{name} does not validate", "problems" => problems) unless problems.empty?

      Package.new(data, origin, reader)
    rescue Schema::Document::ParseError => e
      raise Operator::Failure.new("package_invalid", e.message)
    end

    def read_file(path)
      File.file?(path) ? File.read(path) : nil
    rescue SystemCallError
      nil
    end

    def latest_version(name)
      find(name).version
    rescue Polispec::Error
      nil
    end

    def newer?(offered, recorded)
      Gem::Version.new(offered.to_s) > Gem::Version.new(recorded.to_s)
    rescue ArgumentError
      false
    end

    def resolve_params(package, given)
      declared = package.params
      unknown = given.keys - declared.keys
      raise Usage, "unknown param #{unknown.first}; #{package.name} declares #{declared.keys.join(', ')}" unless unknown.empty?

      values = {}
      declared.each do |name, body|
        raw = given.key?(name) ? given[name] : body["default"]
        next if raw.nil?

        value = given.key?(name) ? coerce(name, body["type"], raw) : raw
        raise Usage, "param #{name} must be one of #{body['allowed'].join(', ')}" if body["allowed"] && !body["allowed"].include?(value)

        values[name] = value
      end
      values
    end

    def coerce(name, type, raw)
      case type
      when "integer" then Integer(raw, 10)
      when "number" then Float(raw)
      when "boolean"
        raise ArgumentError unless %w[true false].include?(raw)

        raw == "true"
      when "list" then raw.split(",").map(&:strip).reject(&:empty?)
      else raw
      end
    rescue ArgumentError, TypeError
      raise Usage, "param #{name} must be a #{type}"
    end

    def resolve_variant(package, requested)
      return nil if package.variants.empty? && requested.nil?
      raise Usage, "#{package.name} has no variants" if package.variants.empty?

      name = requested || package.default_variant
      raise Usage, "unknown variant #{name}; #{package.name} offers #{package.variants.keys.join(', ')}" unless package.variants.key?(name)

      name
    end

    def unified_diff(path, before, after)
      return "" if before == after

      old = Tempfile.new("polispec-old")
      new = Tempfile.new("polispec-new")
      old.write(before.to_s)
      new.write(after.to_s)
      old.flush
      new.flush
      out, = Open3.capture2("diff", "-u", "--label", "a/#{path}", "--label", "b/#{path}", old.path, new.path, err: File::NULL)
      out
    rescue SystemCallError
      (before.to_s.lines.map { |line| "-#{line}" } + after.to_s.lines.map { |line| "+#{line}" }).join
    ensure
      old&.close!
      new&.close!
    end

    class Runner
      ID_PATTERN = Packages::NAME_PATTERN
      SPEC_DIR = "specs/polispec"
      POLICY_FILE = "#{SPEC_DIR}/policy.yml".freeze
      ENVIRONMENTS_FILE = "#{SPEC_DIR}/environments.yml".freeze
      ROSTER_FILE = "#{SPEC_DIR}/roster.yml".freeze
      MODULES_DIR = "#{SPEC_DIR}/modules/".freeze
      DEFAULT_ENVS_ROOT = "~/.polispec/envs"
      Options = Struct.new(:repo, :variant, :params, :commit, :push, :checkouts, :dry, :json, :extra, keyword_init: true)
      Note = Struct.new(:step, :status, :detail)

      attr_reader :package, :id, :root, :rendered, :record, :notes, :variant, :params

      def initialize(package, options)
        @package = package
        @options = options
        @variant = Packages.resolve_variant(package, options.variant)
        @explicit = options.params.dup
        @params = Packages.resolve_params(package, options.params)
        @notes = []
        @touched = []
      end

      def run
        perform
        finish
        0
      rescue Operator::Failure => e
        e.report(json: @options.json)
        1
      end

      def finish
        return unless @options.json

        puts JSON.generate({ "project" => @id, "steps" => @notes.map { |note| { "step" => note.step, "status" => note.status, "detail" => note.detail } } }.merge(@options.extra || {}))
      end

      def prepare
        return if @prepared

        @root = repo_root
        @manifest = manifest_path
        @id = @params["id"].to_s.empty? ? default_id : @params["id"]
        raise Operator::Failure.new("invalid_id", "#{@id} does not match #{ID_PATTERN.source}") unless ID_PATTERN.match?(@id)

        @today = Date.today.iso8601
        @ledger = Ledger.load
        @active = package.active_steps(@params)
        @kinds = @active.map(&:kind)
        @git = Operator::Git.new(@root)
        @prepared = true
        refuse_if_applied if @kinds.include?("ledger")
        if @kinds.include?("files")
          @rendered = render_files
          validate_rendered
        end
        @ledger_update = ledger_text(expected_digests) if @kinds.include?("ledger")
      end

      def perform
        prepare
        deferred = []
        package.steps.each do |step|
          if @active.include?(step)
            send("step_#{step.kind}")
          elsif step.kind == "files"
            deferred << ["files", "skipped", "no environments were scaffolded because the component does not serve real users"]
          end
        end
        deferred.each { |step, status, detail| note(step, status, detail) }
      end

      def file_actions
        @file_actions ||= (@rendered || {}).map do |relative, text|
          path = File.join(@root, relative)
          current = File.file?(path) ? File.read(path) : nil
          recorded = @record && @record.dig("files", relative)
          action =
            if !File.exist?(path) then "add"
            elsif current == text then "unchanged"
            elsif recorded && Packages.sha(current.to_s) == recorded then "replace"
            else "conflict"
            end
          { path: relative, action: action, text: text, current: current, recorded: recorded }
        end
      end

      def file_plan
        file_actions.map do |item|
          diff = item[:action] == "unchanged" ? "" : Packages.unified_diff(item[:path], item[:current], item[:text])
          { "path" => item[:path], "action" => item[:action], "diff" => diff, "digest" => Packages.sha(item[:text]) }
        end
      end

      def record_digests
        file_actions.each_with_object({}) do |item, memo|
          case item[:action]
          when "add", "replace", "unchanged" then memo[item[:path]] = Packages.sha(item[:text])
          when "conflict" then memo[item[:path]] = item[:recorded] if item[:recorded]
          end
        end
      end

      def ledger_effect
        return nil unless @kinds.include?("ledger")

        before_data = File.file?(@ledger.path) ? Schema::Document.load(@ledger.path) : {}
        before = Array(before_data["projects"]).find { |entry| entry["id"] == @id }
        after_data = Schema::Document.parse(@ledger_update, @ledger.path)
        after = Array(after_data["projects"]).find { |entry| entry["id"] == @id }
        { "before" => before, "after" => after }
      end

      def kinds
        @kinds
      end

      def ledger_created?
        @ledger_created == true
      end

      def ledger_before
        @ledger
      end

      def proposed_ledger
        return @ledger unless @ledger_update

        Ledger.new(Schema::Document.parse(@ledger_update, @ledger.path), path: @ledger.path)
      end

      def final_files
        file_actions.each_with_object({}) do |item, memo|
          memo[item[:path]] = %w[add replace].include?(item[:action]) ? item[:text] : (item[:current] || item[:text])
        end
      end

      def upgrade?
        @upgrade == true
      end

      def serves
        @params["serves"]
      end

      def policy_texts
        return nil unless @rendered && @rendered[POLICY_FILE]

        [planned_text(POLICY_FILE), planned_text(ENVIRONMENTS_FILE)]
      end

      def project_entry
        entry_for_ledger
      end

      private

      def usage_error(message)
        raise Usage, message
      end

      def note(step, status, detail)
        @notes << Note.new(step, status, detail)
        puts "#{step}: #{status} #{detail}" unless @options.json
      end

      def would(done)
        @options.dry ? "would" : done
      end

      def tense(past, plan)
        @options.dry ? plan : past
      end

      def repo_root
        out, status = Open3.capture2(Environments::GIT_ENV, "git", "-C", File.expand_path(@options.repo), "rev-parse", "--show-toplevel", err: File::NULL)
        raise Operator::Failure.new("not_a_git_repo", "#{@options.repo} is not a git repository") unless status.success?

        File.realpath(out.strip)
      rescue SystemCallError
        raise Operator::Failure.new("not_a_git_repo", "#{@options.repo} is not a git repository")
      end

      def manifest_path
        Dir.glob(File.join(@root, "*.rstack_component.yml")).sort.first || Dir.glob(File.join(@root, "*.rplugin.yml")).sort.first
      end

      def default_id
        sanitize(manifest_name || File.basename(@root))
      end

      def sanitize(text)
        text.downcase.gsub(/[^a-z0-9-]/, "-")
      end

      def manifest_name
        return nil unless @manifest

        data = Schema::Document.load(@manifest)
        data.is_a?(Hash) && data["name"].is_a?(String) && !data["name"].empty? ? data["name"] : nil
      rescue Schema::Document::ParseError
        nil
      end

      def refuse_if_applied
        real = File.realpath(@root)
        clash = @ledger.projects.find do |project|
          project.id == @id || safe_realpath(File.expand_path(project.repo)) == real
        end
        return unless clash

        record = clash.id == @id && safe_realpath(File.expand_path(clash.repo)) == real ? clash.packages.find { |item| item["name"] == package.name } : nil
        raise Operator::Failure.new("already_onboarded", "#{clash.id} is already in the ledger at #{clash.repo}", "ledger" => @ledger.path) unless record

        recorded = record["version"].to_s
        if recorded == package.version
          raise Operator::Failure.new("already_applied", "#{package.name} #{package.version} is already applied to #{clash.id}", "ledger" => @ledger.path)
        end
        unless Packages.newer?(package.version, recorded)
          raise Operator::Failure.new("downgrade_refused", "#{package.name} #{recorded} recorded for #{clash.id} is newer than #{package.version}", "ledger" => @ledger.path)
        end

        @record = record
        @upgrade = true
      end

      def safe_realpath(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end

      def raw_envs_root
        data = Schema::Document.load(@ledger.path)
        data.is_a?(Hash) && data["envs_root"].is_a?(String) ? data["envs_root"] : DEFAULT_ENVS_ROOT
      rescue Schema::Document::ParseError
        DEFAULT_ENVS_ROOT
      end

      def envs_root_value
        @explicit.key?("envs_root") ? @params["envs_root"] : raw_envs_root
      end

      def render_files
        tokens = { "{{project}}" => @id, "{{date}}" => @today, "{{envs_root}}" => envs_root_value, "{{repo_name}}" => File.basename(@root) }
        @params.each { |name, value| tokens["{{#{name}}}"] ||= value.to_s }
        tokens["{{id}}"] = @id
        package.file_map(@variant).each_with_object({}) do |(target, source), memo|
          text = package.read(source)
          raise Operator::Failure.new("template_missing", "#{package.name}/#{source} is missing") if text.nil?

          tokens.each { |token, value| text = text.gsub(token, value) }
          memo[target] = text
        end
      end

      def validate_rendered
        problems = []
        env_data = nil
        begin
          if @rendered[ENVIRONMENTS_FILE]
            env_data = Schema::Document.parse(@rendered[ENVIRONMENTS_FILE], ENVIRONMENTS_FILE)
            Schema.validate("environments", env_data).each { |error| problems << "#{ENVIRONMENTS_FILE}#{error.pointer} #{error.message}" }
          end
          if @rendered[POLICY_FILE]
            policy = Schema::Document.parse(@rendered[POLICY_FILE], POLICY_FILE)
            merged, finding = Environments.merge(policy, env_data)
            problems << "#{POLICY_FILE} #{finding['detail']}" if finding
            Schema.validate("policy", merged).each { |error| problems << "#{POLICY_FILE}#{error.pointer} #{error.message}" } if merged
          end
          if @rendered[ROSTER_FILE]
            roster = Schema::Document.parse(@rendered[ROSTER_FILE], ROSTER_FILE)
            Schema.validate("roster", roster).each { |error| problems << "#{ROSTER_FILE}#{error.pointer} #{error.message}" }
          end
          @rendered.each do |target, text|
            next unless target.start_with?(MODULES_DIR)

            built = Layers.build_raw(File.basename(target, ".yml"), Schema::Document.parse(text, target), text, :local)
            problems << "#{target} #{built}" if built.is_a?(String)
          end
        rescue Schema::Document::ParseError => e
          problems << e.message
        end
        raise Operator::Failure.new("scaffold_invalid", "rendered templates do not validate", "problems" => problems) unless problems.empty?
      end

      def atomic_write(path, text, mode = nil)
        temp = "#{path}.#{Process.pid}.tmp"
        File.write(temp, text)
        File.chmod(mode, temp) if mode
        File.rename(temp, path)
      end

      def step_files
        written = []
        replaced = []
        kept = []
        conflicts = []
        file_actions.each do |item|
          path = File.join(@root, item[:path])
          case item[:action]
          when "add"
            written << item[:path]
            @touched << item[:path]
            next if @options.dry

            FileUtils.mkdir_p(File.dirname(path))
            atomic_write(path, item[:text])
          when "replace"
            replaced << item[:path]
            @touched << item[:path]
            atomic_write(path, item[:text], File.stat(path).mode & 0o777) unless @options.dry
          when "conflict"
            conflicts << item[:path]
            kept << item[:path]
          else
            kept << item[:path]
          end
        end
        parts = []
        parts << "#{tense('wrote', 'write')} #{written.join(', ')}" unless written.empty?
        parts << "#{tense('replaced', 'replace')} #{replaced.join(', ')}" unless replaced.empty?
        unless kept.empty?
          parts << (written.empty? && replaced.empty? ? "#{kept.join(', ')} already present" : "kept #{kept.join(', ')}")
        end
        parts << "#{conflicts.join(', ')} edited since #{@record['version']}, left untouched" if @upgrade && !conflicts.empty?
        note("files", written.empty? && replaced.empty? ? "kept" : would("done"), parts.join("; "))
      end

      def pointer_block(with_serves)
        lines = []
        lines << "serves: #{serves}" if with_serves
        lines.concat(["polispec:", "  project: #{@id}", "  environments: #{ENVIRONMENTS_FILE}"])
        lines.join("\n")
      end

      def step_manifest
        return note("manifest", "skipped", "no component manifest; pointer not written") unless @manifest

        text = File.read(@manifest)
        data = Schema::Document.parse(text, @manifest)
        full = serves.nil? || serves == "real_users"
        if full
          return note("manifest", "kept", "#{File.basename(@manifest)} already has a polispec pointer") if data.is_a?(Hash) && data.key?("polispec")

          update_manifest(text, pointer_block(!serves.nil? && !(data.is_a?(Hash) && data.key?("serves"))))
        else
          return note("manifest", "kept", "#{File.basename(@manifest)} already has serves") if data.is_a?(Hash) && data.key?("serves")

          update_manifest(text, "serves: #{serves}")
        end
      rescue Schema::Document::ParseError => e
        note("manifest", "skipped", "#{File.basename(@manifest)} does not parse: #{e.message}")
      end

      def update_manifest(text, block)
        body = text.end_with?("\n") ? text : "#{text}\n"
        body = "#{body}\n" unless body.lines.last.to_s.strip.empty?
        updated = "#{body}#{block}\n"
        parsed = Schema::Document.parse(updated, @manifest)
        return note("manifest", "skipped", "#{File.basename(@manifest)} would not parse after the pointer is added; not written") unless parsed.is_a?(Hash)

        atomic_write(@manifest, updated, File.stat(@manifest).mode & 0o777) unless @options.dry
        @touched << @manifest.sub("#{@root}/", "")
        note("manifest", would("done"), @options.dry ? "append pointer to #{File.basename(@manifest)}" : "pointer appended to #{File.basename(@manifest)}")
      rescue Schema::Document::ParseError
        note("manifest", "skipped", "#{File.basename(@manifest)} would not parse after the pointer is added; not written")
      end

      def home_relative(path)
        home = Dir.home
        path == home || path.start_with?("#{home}/") ? path.sub(home, "~") : path
      end

      def remote_url
        result = @git.run("remote", "get-url", "origin")
        result.ok? ? result.out.strip : nil
      end

      def entry_for_ledger
        repo = home_relative(@root)
        parent = home_relative(File.dirname(@root))
        lines = ["  - id: #{@id}", "    status: onboarding", "    repo: #{repo}"]
        remote = remote_url
        lines << "    remote: #{remote}" if remote && !remote.empty?
        lines.concat([
          "    worktree_globs: [#{parent}/.#{File.basename(@root)}-wt/*]", "    trust_ref: #{@params['trust_ref'] || 'stable'}",
          "    policy: #{POLICY_FILE}", "    roster: #{ROSTER_FILE}", "    related: []", "    onboarded: #{@today}",
          "    owner: #{Registration.owner_flow}", "    registered_by: #{JSON.generate(Registration.actor)}"
        ])
        lines
      end

      def record_lines(digests)
        lines = ["      - name: #{package.name}"]
        lines << "        variant: #{@variant}" if @variant
        lines.concat(["        version: #{package.version}", "        applied_at: #{@today}"])
        unless digests.empty?
          lines << "        files:"
          digests.each { |path, digest| lines << "          #{path}: #{digest}" }
        end
        lines
      end

      def insert_entry(text, entry)
        lines = text.lines
        lines[-1] = "#{lines[-1]}\n" if !lines.empty? && !lines[-1].end_with?("\n")
        start = lines.index { |line| line.start_with?("projects:") }
        return "#{lines.join}projects:\n#{entry.join("\n")}\n" if start.nil?

        if lines[start].strip == "projects: []"
          lines[start] = "projects:\n"
          return (lines[0..start] + entry.map { |line| "#{line}\n" } + lines[(start + 1)..]).join
        end

        stop = ((start + 1)...lines.length).find { |index| !lines[index].strip.empty? && !lines[index].start_with?(" ", "\t") } || lines.length
        last = (stop - 1).downto(start) { |index| break index unless lines[index].strip.empty? }
        (lines[0..last] + entry.map { |line| "#{line}\n" } + lines[(last + 1)..]).join
      end

      def replace_record(text, lines_for_record)
        lines = text.lines.map(&:chomp)
        start = lines.index { |line| line.match?(/\A  - id: #{Regexp.escape(@id)}\s*\z/) }
        raise Operator::Failure.new("ledger_invalid", "#{@id} is not in the ledger") unless start

        stop = ((start + 1)...lines.length).find { |index| lines[index].match?(/\A  - /) || lines[index].match?(/\A\S/) } || lines.length
        last = (stop - 1).downto(start) { |index| break index unless lines[index].strip.empty? }
        header = ((start + 1)..last).find { |index| lines[index].match?(/\A    packages:/) }
        if header.nil?
          lines.insert(last + 1, "    packages:", *lines_for_record)
        else
          lines[header] = "    packages:" if lines[header].match?(/\A    packages:\s*\[\s*\]\s*\z/)
          block_end = ((header + 1)..last).find { |index| !lines[index].start_with?("      ") && !lines[index].strip.empty? } || last + 1
          item = ((header + 1)...block_end).find { |index| lines[index].match?(/\A      - name: #{Regexp.escape(package.name)}\s*\z/) }
          if item
            item_end = ((item + 1)...block_end).find { |index| lines[index].match?(/\A      - /) } || block_end
            lines[item...item_end] = lines_for_record
          else
            lines.insert(block_end, *lines_for_record)
          end
        end
        "#{lines.join("\n")}\n"
      end

      def expected_digests
        @rendered ? @rendered.transform_values { |text| Packages.sha(text) } : {}
      end

      def ledger_text(digests)
        path = @ledger.path
        @ledger_created = false
        if File.file?(path)
          original = File.read(path)
        else
          raise Operator::Failure.new("ledger_missing", "the sealed plane names #{path} and it is missing; ask the operator") if Ledger.sealed_ledger?

          original = Ledger.starter_text
          @ledger_created = true
        end
        guard_runtime unless @upgrade
        updated = @upgrade ? replace_record(original, record_lines(digests)) : insert_entry(original, entry_for_ledger + ["    packages:"] + record_lines(digests))
        data = Schema::Document.parse(updated, path)
        errors = Schema.validate("ledger", data)
        raise Operator::Failure.new("ledger_invalid", "the ledger with the new entry does not validate", "problems" => errors.map { |error| "#{error.pointer} #{error.message}".strip }) unless errors.empty?

        updated
      rescue Schema::Document::ParseError => e
        raise Operator::Failure.new("ledger_invalid", e.message)
      end

      def guard_runtime
        return unless Registration.runtime_behind?

        Registration.refuse_behind! unless @options.dry
        return if @behind_noted

        @behind_noted = true
        note("ledger", "note", Registration.behind_note.sub(/\Anote: /, ""))
      end

      def step_ledger
        path = @ledger.path
        updated = ledger_text(record_digests)
        if @ledger_created
          unless @options.dry
            FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
            atomic_write(path, updated, 0o600)
          end
          note("ledger", would("done"), @options.dry ? "create #{path} (starter ledger, no projects yet)" : "created #{path} (starter ledger)")
        elsif !@options.dry
          backup = File.join(File.dirname(path), "#{File.basename(path)}.bak-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}")
          FileUtils.cp(path, backup, preserve: true)
          atomic_write(path, updated, File.stat(path).mode & 0o777)
        end
        if @upgrade
          note("ledger", would("done"), @options.dry ? "record #{package.name} #{package.version} for #{@id} in #{path}" : "#{package.name} #{package.version} recorded for #{@id} in #{path}")
        else
          note("ledger", would("done"), @options.dry ? "add #{@id} to #{path} with status onboarding" : "#{@id} added to #{path} with status onboarding")
        end
      end

      def planned_text(relative)
        path = File.join(@root, relative)
        File.exist?(path) ? File.read(path) : @rendered[relative]
      end

      def step_render
        source =
          if @options.dry
            combined = Environments.combine(planned_text(POLICY_FILE), planned_text(ENVIRONMENTS_FILE), POLICY_FILE)
            AgentsRender::Source.new(combined.data, Schema::Document.parse(planned_text(ENVIRONMENTS_FILE), ENVIRONMENTS_FILE), @id)
          else
            AgentsRender.source_from_worktree(@root, POLICY_FILE)
          end
        rendered = AgentsRender.render(source)
        files = AgentsRender.plan(@root, rendered)
        files.each { |file| AgentsRender.apply(file) } unless @options.dry
        changed = files.select { |file| file[:changed] }.map { |file| file[:path].sub("#{@root}/", "") }
        @touched.concat(changed)
        note("render", changed.empty? ? "kept" : would("done"), changed.empty? ? "[ENVS] row and envs.md already current" : "#{tense('rendered', 'render')} #{changed.join(', ')}")
      rescue Polispec::Error => e
        raise Operator::Failure.new("render_failed", e.message)
      end

      def commit_message
        COMMIT_MESSAGES[package.name] && !@upgrade ? COMMIT_MESSAGES[package.name] : "Apply #{package.name} #{package.version}"
      end

      def step_commit
        return unless @options.commit

        paths = @touched.uniq
        return note("commit", "skipped", "apply #{@options.dry ? 'would write' : 'wrote'} no files, so there is nothing to commit") if paths.empty?

        branch = @git.run("symbolic-ref", "--quiet", "--short", "HEAD").out.strip
        unless branch == "main"
          note("commit", "skipped", "HEAD is #{branch.empty? ? 'detached' : branch}, not main, so nothing #{@options.dry ? 'would be' : 'was'} committed; run: #{commit_command}")
          return
        end

        if @options.dry
          @commit_planned = true
          return note("commit", "would", "commit #{paths.join(', ')} on main as '#{commit_message}'")
        end

        @git.run!("add", "--", *paths, code: "commit_failed")
        @git.run!("commit", "--quiet", "-m", commit_message, "--", *paths, code: "commit_failed")
        note("commit", "done", "committed #{paths.join(', ')} on main")
      end

      def step_branches
        test_branch = "test"
        trust = @params["trust_ref"]
        unless @git.rev("refs/heads/main")
          note("branches", "skipped", "no local main branch; create #{test_branch} and #{trust} by hand")
          return
        end

        if @commit_planned && !scaffold_on_main?
          created = [test_branch, trust].reject { |name| @git.rev("refs/heads/#{name}") }
          _status, tail = push_outcome(test_branch, trust)
          detail = created.empty? ? "#{test_branch} and #{trust} already exist" : "create #{created.join(' and ')} at main after the commit"
          note("branches", "would", "#{detail}; #{tail}")
          return
        end

        unless scaffold_on_main?
          note("branches", "skipped", "the scaffold is not committed on main, so #{test_branch} and #{trust} are not created yet; run: #{commit_command} && git -C #{Shellwords.escape(@root)} branch #{test_branch} main && git -C #{Shellwords.escape(@root)} branch #{trust} main && git -C #{Shellwords.escape(@root)} push origin main #{test_branch} #{trust}")
          return
        end
        created = [test_branch, trust].reject { |name| @git.rev("refs/heads/#{name}") }
        created.each { |name| @git.run!("branch", name, "main") } unless @options.dry
        detail = created.empty? ? "#{test_branch} and #{trust} already exist" : "#{tense('created', 'create')} #{created.join(' and ')} at main"
        status, tail = push_outcome(test_branch, trust)
        done = status == "done" || !created.empty?
        note("branches", @options.dry ? "would" : (done ? "done" : "kept"), "#{detail}; #{tail}")
      end

      def step_push
        nil
      end

      def scaffold_on_main?
        targets = @rendered ? @rendered.keys : [POLICY_FILE, ENVIRONMENTS_FILE, ROSTER_FILE]
        targets.all? { |relative| @git.run("cat-file", "-e", "refs/heads/main:#{relative}").ok? }
      end

      def commit_command
        "git -C #{Shellwords.escape(@root)} add specs AGENTS.md .agents && git -C #{Shellwords.escape(@root)} commit -m '#{commit_message}'"
      end

      def push_outcome(test_branch, trust)
        refs = @options.commit ? ["main", test_branch, trust] : [test_branch, trust]
        command = "git -C #{Shellwords.escape(@root)} push origin #{refs.join(' ')}"
        return ["next", "next: #{command}"] unless @options.push && @kinds.include?("push")
        return ["skipped", "no origin remote; push by hand: #{command}"] if remote_url.nil?
        return ["done", command] if @options.dry

        result = @git.run!("push", "origin", *refs, code: "push_failed")
        ["done", "pushed #{refs.join(', ')}: #{result.tail}".strip]
      end

      def step_checkouts
        unless @options.checkouts
          note("checkouts", "next", "polispec deploy #{@id} test")
          return
        end

        trust = @params["trust_ref"]
        remote = remote_url
        names = ["test", trust]
        present = remote && names.all? { |name| @git.run("ls-remote", "--exit-code", "--heads", "origin", name).ok? }
        unless present
          note("checkouts", "skipped", "test and #{trust} are not both on origin; push them first, then run polispec deploy #{@id} test")
          return
        end

        base = File.join(File.expand_path(envs_root_value), @id)
        dirs = { "test" => File.join(base, "test"), trust => File.join(base, "stable") }
        return note("checkouts", "would", "clone #{dirs.values.join(' and ')} and install git hooks for test and prod") if @options.dry

        cloned = dirs.filter_map do |branch, dir|
          next if File.directory?(File.join(dir, ".git"))

          FileUtils.mkdir_p(File.dirname(dir))
          Operator::Git.clone(remote, dir)
          Operator::Git.new(dir).checkout_tracking(branch)
          dir
        end
        installed = %w[test prod].map do |env|
          report = StringIO.new
          GitHook::Installer.new(@id, env, out: report).install
          report.string.lines.map(&:strip).reject(&:empty?)
        end.flatten
        installed.each { |line| note("checkouts", "hook", "#{GitHook::HOOKS.join(', ')}: #{line}") }
        note("checkouts", cloned.empty? ? "kept" : "done", cloned.empty? ? "checkouts already present; hooks installed" : "cloned #{cloned.join(' and ')}; hooks installed for test and prod")
      end
    end
  end
end
