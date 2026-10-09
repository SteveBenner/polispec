#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "../operator/git"

module Polispec
  class OnboardCommand
    USAGE = "usage: polispec onboard <repo-path> --serves <real_users|internal|none> [--archetype service|distributed] [--id <id>] [--trust-ref stable] [--push] [--checkouts] [--dry-run] [--json]"
    SERVES = %w[real_users internal none].freeze
    ARCHETYPES = %w[service distributed].freeze
    ID_PATTERN = /\A[a-z0-9][a-z0-9-]{0,40}\z/.freeze
    TEMPLATES = File.join(ROOT, "templates", "onboard").freeze
    SPEC_DIR = "specs/polispec"
    POLICY_FILE = "#{SPEC_DIR}/policy.yml".freeze
    ENVIRONMENTS_FILE = "#{SPEC_DIR}/environments.yml".freeze
    ROSTER_FILE = "#{SPEC_DIR}/roster.yml".freeze
    DEFAULT_ENVS_ROOT = "~/.polispec/envs"
    Options = Struct.new(:repo, :serves, :archetype, :id, :trust_ref, :push, :checkouts, :dry, :json)
    Step = Struct.new(:step, :status, :detail)

    def self.run(args)
      new.run(args)
    end

    def run(args)
      options = parse(args)
      return usage unless options

      @options = options
      @steps = []
      begin
        perform
        finish(0)
      rescue Operator::Failure => e
        e.report(json: options.json)
        1
      end
    end

    private

    def usage
      warn USAGE
      2
    end

    def parse(args)
      rest = args.dup
      options = Options.new(nil, nil, "service", nil, "stable", false, false, false, false)
      until rest.empty?
        arg = rest.shift
        case arg
        when "--serves" then options.serves = rest.shift
        when "--archetype" then options.archetype = rest.shift
        when "--id" then options.id = rest.shift
        when "--trust-ref" then options.trust_ref = rest.shift
        when "--push" then options.push = true
        when "--checkouts" then options.checkouts = true
        when "--dry-run" then options.dry = true
        when "--json" then options.json = true
        when /\A-/ then return nil
        else
          return nil if options.repo
          options.repo = arg
        end
      end
      return nil unless options.repo && SERVES.include?(options.serves) && ARCHETYPES.include?(options.archetype)
      return nil if options.trust_ref.to_s.empty? || (options.id && options.id.empty?)

      options
    end

    def finish(status)
      if @options.json
        puts JSON.generate("project" => @id, "steps" => @steps.map { |step| { "step" => step.step, "status" => step.status, "detail" => step.detail } })
      end
      status
    end

    def note(step, status, detail)
      @steps << Step.new(step, status, detail)
      puts "#{step}: #{status} #{detail}" unless @options.json
    end

    def would(done)
      @options.dry ? "would" : done
    end

    def perform
      @root = repo_root
      @manifest = manifest_path
      @id = @options.id || default_id
      raise Operator::Failure.new("invalid_id", "#{@id} does not match #{ID_PATTERN.source}") unless ID_PATTERN.match?(@id)

      @today = Date.today.iso8601
      @ledger = Ledger.load
      if @options.serves != "real_users"
        manifest_step_light
        note("scaffold", "skipped", "no environments were scaffolded because the component does not serve real users")
        return
      end

      refuse_if_onboarded
      @git = Operator::Git.new(@root)
      @rendered = render_templates
      validate_rendered
      scaffold
      manifest_step
      ledger_step
      render_step
      branches_step
      checkouts_step
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

    def refuse_if_onboarded
      real = File.realpath(@root)
      clash = @ledger.projects.find do |project|
        project.id == @id || safe_realpath(File.expand_path(project.repo)) == real
      end
      return unless clash

      raise Operator::Failure.new("already_onboarded", "#{clash.id} is already in the ledger at #{clash.repo}", "ledger" => @ledger.path)
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

    def render_templates
      tokens = { "{{project}}" => @id, "{{date}}" => @today, "{{envs_root}}" => raw_envs_root, "{{repo_name}}" => File.basename(@root) }
      sources = {
        ENVIRONMENTS_FILE => File.join(TEMPLATES, @options.archetype, "environments.yml"),
        POLICY_FILE => File.join(TEMPLATES, @options.archetype, "policy.yml"),
        ROSTER_FILE => File.join(TEMPLATES, "roster.yml")
      }
      sources.each_with_object({}) do |(target, source), memo|
        text = File.read(source)
        tokens.each { |token, value| text = text.gsub(token, value) }
        memo[target] = text
      end
    rescue SystemCallError => e
      raise Operator::Failure.new("template_missing", e.message)
    end

    def validate_rendered
      problems = []
      env_data = nil
      begin
        env_data = Schema::Document.parse(@rendered[ENVIRONMENTS_FILE], ENVIRONMENTS_FILE)
        Schema.validate("environments", env_data).each { |error| problems << "#{ENVIRONMENTS_FILE}#{error.pointer} #{error.message}" }
        policy = Schema::Document.parse(@rendered[POLICY_FILE], POLICY_FILE)
        merged, finding = Environments.merge(policy, env_data)
        problems << "#{POLICY_FILE} #{finding['detail']}" if finding
        Schema.validate("policy", merged).each { |error| problems << "#{POLICY_FILE}#{error.pointer} #{error.message}" } if merged
        roster = Schema::Document.parse(@rendered[ROSTER_FILE], ROSTER_FILE)
        Schema.validate("roster", roster).each { |error| problems << "#{ROSTER_FILE}#{error.pointer} #{error.message}" }
      rescue Schema::Document::ParseError => e
        problems << e.message
      end
      raise Operator::Failure.new("scaffold_invalid", "rendered templates do not validate", "problems" => problems) unless problems.empty?
    end

    def scaffold
      written = []
      kept = []
      @rendered.each do |relative, text|
        path = File.join(@root, relative)
        if File.exist?(path)
          kept << relative
          next
        end
        written << relative
        next if @options.dry

        FileUtils.mkdir_p(File.dirname(path))
        atomic_write(path, text)
      end
      parts = []
      parts << "wrote #{written.join(', ')}" unless written.empty?
      parts << "kept #{kept.join(', ')}" unless kept.empty?
      note("1_scaffold", written.empty? ? "kept" : would("done"), parts.join("; "))
    end

    def atomic_write(path, text, mode = nil)
      temp = "#{path}.#{Process.pid}.tmp"
      File.write(temp, text)
      File.chmod(mode, temp) if mode
      File.rename(temp, path)
    end

    def pointer_block(with_serves)
      lines = []
      lines << "serves: #{@options.serves}" if with_serves
      lines.concat(["polispec:", "  project: #{@id}", "  environments: #{ENVIRONMENTS_FILE}"])
      lines.join("\n")
    end

    def manifest_step_light
      return note("2_manifest", "skipped", "no component manifest; pointer not written") unless @manifest

      text = File.read(@manifest)
      data = Schema::Document.parse(text, @manifest)
      return note("2_manifest", "kept", "#{File.basename(@manifest)} already has serves") if data.is_a?(Hash) && data.key?("serves")

      update_manifest(text, "serves: #{@options.serves}")
    rescue Schema::Document::ParseError => e
      note("2_manifest", "skipped", "#{File.basename(@manifest)} does not parse: #{e.message}")
    end

    def manifest_step
      return note("2_manifest", "skipped", "no component manifest; pointer not written") unless @manifest

      text = File.read(@manifest)
      data = Schema::Document.parse(text, @manifest)
      return note("2_manifest", "kept", "#{File.basename(@manifest)} already has a polispec pointer") if data.is_a?(Hash) && data.key?("polispec")

      update_manifest(text, pointer_block(!(data.is_a?(Hash) && data.key?("serves"))))
    rescue Schema::Document::ParseError => e
      note("2_manifest", "skipped", "#{File.basename(@manifest)} does not parse: #{e.message}")
    end

    def update_manifest(text, block)
      body = text.end_with?("\n") ? text : "#{text}\n"
      body = "#{body}\n" unless body.lines.last.to_s.strip.empty?
      updated = "#{body}#{block}\n"
      parsed = Schema::Document.parse(updated, @manifest)
      return note("2_manifest", "skipped", "#{File.basename(@manifest)} would not parse after the pointer is added; not written") unless parsed.is_a?(Hash)

      atomic_write(@manifest, updated, File.stat(@manifest).mode & 0o777) unless @options.dry
      note("2_manifest", would("done"), "pointer appended to #{File.basename(@manifest)}")
    rescue Schema::Document::ParseError
      note("2_manifest", "skipped", "#{File.basename(@manifest)} would not parse after the pointer is added; not written")
    end

    def home_relative(path)
      home = Dir.home
      path == home || path.start_with?("#{home}/") ? path.sub(home, "~") : path
    end

    def remote_url
      result = @git.run("remote", "get-url", "origin")
      result.ok? ? result.out.strip : nil
    end

    def ledger_entry
      repo = home_relative(@root)
      parent = home_relative(File.dirname(@root))
      lines = ["  - id: #{@id}", "    status: onboarding", "    repo: #{repo}"]
      remote = remote_url
      lines << "    remote: #{remote}" if remote && !remote.empty?
      lines.concat([
        "    worktree_globs: [#{parent}/.#{File.basename(@root)}-wt/*]", "    trust_ref: #{@options.trust_ref}",
        "    policy: #{POLICY_FILE}", "    roster: #{ROSTER_FILE}", "    related: []", "    onboarded: #{@today}"
      ])
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

    def ledger_step
      path = @ledger.path
      raise Operator::Failure.new("ledger_missing", "no ledger at #{path}; create it before onboarding") unless File.file?(path)

      original = File.read(path)
      updated = insert_entry(original, ledger_entry)
      data = Schema::Document.parse(updated, path)
      errors = Schema.validate("ledger", data)
      raise Operator::Failure.new("ledger_invalid", "the ledger with the new entry does not validate", "problems" => errors.map { |error| "#{error.pointer} #{error.message}".strip }) unless errors.empty?

      unless @options.dry
        backup = File.join(File.dirname(path), "#{File.basename(path)}.bak-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}")
        FileUtils.cp(path, backup, preserve: true)
        atomic_write(path, updated, File.stat(path).mode & 0o777)
      end
      note("3_ledger", would("done"), "#{@id} added to #{path} with status onboarding")
    rescue Schema::Document::ParseError => e
      raise Operator::Failure.new("ledger_invalid", e.message)
    end

    def render_step
      source =
        if @options.dry
          combined = Environments.combine(@rendered[POLICY_FILE], @rendered[ENVIRONMENTS_FILE], POLICY_FILE)
          AgentsRender::Source.new(combined.data, Schema::Document.parse(@rendered[ENVIRONMENTS_FILE], ENVIRONMENTS_FILE), @id)
        else
          AgentsRender.source_from_worktree(@root, POLICY_FILE)
        end
      rendered = AgentsRender.render(source)
      files = AgentsRender.plan(@root, rendered)
      files.each { |file| AgentsRender.apply(file) } unless @options.dry
      changed = files.select { |file| file[:changed] }.map { |file| file[:path].sub("#{@root}/", "") }
      note("4_render", changed.empty? ? "kept" : would("done"), changed.empty? ? "[ENVS] row and envs.md already current" : "rendered #{changed.join(', ')}")
    rescue Polispec::Error => e
      raise Operator::Failure.new("render_failed", e.message)
    end

    def branches_step
      test_branch = "test"
      trust = @options.trust_ref
      unless @git.rev("refs/heads/main")
        note("5_branches", "skipped", "no local main branch; create #{test_branch} and #{trust} by hand")
        return
      end

      created = [test_branch, trust].reject { |name| @git.rev("refs/heads/#{name}") }
      created.each { |name| @git.run!("branch", name, "main") } unless @options.dry
      detail = created.empty? ? "#{test_branch} and #{trust} already exist" : "created #{created.join(' and ')} at main"
      status, tail = push_outcome(test_branch, trust)
      done = status == "done" || !created.empty?
      note("5_branches", @options.dry ? "would" : (done ? "done" : "kept"), "#{detail}; #{tail}")
    end

    def push_outcome(test_branch, trust)
      command = "git -C #{Shellwords.escape(@root)} push origin #{test_branch} #{trust}"
      return ["next", "next: #{command}"] unless @options.push
      return ["skipped", "no origin remote; push by hand: #{command}"] if remote_url.nil?
      return ["done", command] if @options.dry

      result = @git.run!("push", "origin", test_branch, trust, code: "push_failed")
      ["done", "pushed #{test_branch} and #{trust}: #{result.tail}".strip]
    end

    def checkouts_step
      unless @options.checkouts
        note("6_checkouts", "next", "polispec deploy #{@id} test")
        return
      end

      remote = remote_url
      names = ["test", @options.trust_ref]
      present = remote && names.all? { |name| @git.run("ls-remote", "--exit-code", "--heads", "origin", name).ok? }
      unless present
        note("6_checkouts", "skipped", "test and #{@options.trust_ref} are not both on origin; push them first, then run polispec deploy #{@id} test")
        return
      end

      base = File.join(File.expand_path(raw_envs_root), @id)
      dirs = { "test" => File.join(base, "test"), @options.trust_ref => File.join(base, "stable") }
      return note("6_checkouts", "would", "clone #{dirs.values.join(' and ')} and install git hooks for test and prod") if @options.dry

      cloned = dirs.filter_map do |branch, dir|
        next if File.directory?(File.join(dir, ".git"))

        FileUtils.mkdir_p(File.dirname(dir))
        Operator::Git.clone(remote, dir)
        Operator::Git.new(dir).checkout_tracking(branch)
        dir
      end
      File.open(File::NULL, "w") { |sink| %w[test prod].each { |env| GitHook::Installer.new(@id, env, out: sink).install } }
      note("6_checkouts", cloned.empty? ? "kept" : "done", cloned.empty? ? "checkouts already present; hooks installed" : "cloned #{cloned.join(' and ')}; hooks installed for test and prod")
    end
  end
end

Polispec::CLI.register("onboard", Polispec::OnboardCommand, summary: "scaffold environments, policy and roster, point the manifest, ledger the repo and render [ENVS]")
