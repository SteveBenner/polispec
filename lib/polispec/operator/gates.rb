#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "io/console"
require "securerandom"
require "find"
require_relative "git"
require_relative "../validate_profiles"

module Polispec
  module Operator
    module Gates
      DEFAULT_TIMEOUT = 900
      BUILTINS = %w[clean_tree version_homes_agree sha_ran_on_test sha_ran_on not_frozen soaked health_required logs_quiet requires_live].freeze
      TIERS = { "test" => "test", "stable" => "prod", "prod" => "prod" }.freeze
      LOGS_COUNT_KEY = "polispec.logs.count_command"
      LOGS_WINDOW_MINUTES = 120
      LOGS_COUNT_TIMEOUT = 60
      ENV_NAME = /\A[a-z0-9][a-z0-9-]{0,40}\z/
      JSON_HOMES = %w[.codex-plugin/plugin.json .claude-plugin/plugin.json].freeze

      Project = Struct.new(:ledger, :entry, :policy, :source, :digest, :repo, keyword_init: true) do
        def id
          entry.id
        end

        def promotion
          policy["promotion"]
        end

        def environment(key)
          policy["environments"][key]
        end

        def hermetic(tier)
          config = (policy["hermetic"] || {})[tier]
          config.is_a?(Hash) ? config : nil
        end
      end

      Context = Struct.new(:project, :git, :sha, :version, :tag, :to, keyword_init: true) do
        def vars
          @stable_tag ||= Polispec::Operator::Gates.stable_tag(project, git).to_s
          { "sha" => sha, "VERSION" => version, "project" => project.id, "tag" => tag, "stable_tag" => @stable_tag }
        end
      end

      Execution = Struct.new(:code, :output, :duration_ms, :timed_out, :violation) do
        def ok?
          code.zero? && !timed_out
        end

        def tail
          Polispec::Operator::Git.tail(output)
        end
      end

      class Hermetic
        MAX_ENTRIES = 200_000

        attr_reader :scratch, :env, :violations, :truncated

        def self.for(project, tier, id)
          config = project.hermetic(tier)
          return nil unless config && (Array(config["isolate"]).any? || Array(config["protected_roots"]).any?)

          new(config, id).tap(&:prepare)
        end

        def initialize(config, id)
          @isolate = Array(config["isolate"])
          @roots = Array(config["protected_roots"]).map { |root| File.expand_path(Polispec::Operator::Gates.expand_home(root)) }
          @scratch = File.join(Polispec::Operator::Gates.polispec_home, "scratch", id)
          @env = {}
          @violations = []
          @truncated = []
        end

        def prepare
          FileUtils.mkdir_p(File.dirname(scratch), mode: 0o700)
          FileUtils.mkdir_p(scratch, mode: 0o700)
          @isolate.each do |name|
            path = File.join(scratch, name.downcase)
            FileUtils.mkdir_p(path, mode: 0o700)
            @env[name] = path
          end
        end

        def exec(argv, chdir:, env: {}, timeout: DEFAULT_TIMEOUT)
          before = @roots.map { |root| fingerprint(root) }
          execution = Polispec::Operator::Gates.exec(argv, chdir: chdir, env: env.merge(@env), timeout: timeout)
          after = @roots.map { |root| fingerprint(root) }
          changed = @roots.each_index.select { |index| before[index] != after[index] }.map { |index| @roots[index] }
          unless changed.empty?
            execution.violation = "wrote outside its location: #{changed.join(', ')}"
            @violations << execution.violation
          end
          execution
        end

        def violation
          violations.first
        end

        def finish
          kept = !prune
          { "scratch" => scratch, "kept" => kept, "truncated" => truncated.uniq }
        end

        private

        def prune
          directories = Dir.glob(File.join(scratch, "**", "*"), File::FNM_DOTMATCH).select { |path| File.directory?(path) && !File.symlink?(path) }
          directories.sort_by { |path| -path.length }.each do |path|
            Dir.rmdir(path)
          rescue SystemCallError
            nil
          end
          Dir.rmdir(scratch)
          true
        rescue SystemCallError
          false
        end

        def fingerprint(root)
          return "absent" unless File.exist?(root) || File.symlink?(root)

          entries = []
          Find.find(root) do |path|
            stat = File.lstat(path)
            next if stat.directory?

            entries << [path.delete_prefix(root), stat.size, (stat.mtime.to_i * 1_000_000_000) + stat.mtime.nsec].join("\0")
            if entries.length >= MAX_ENTRIES
              @truncated << root
              break
            end
          rescue SystemCallError
            next
          end
          Digest::SHA256.hexdigest(entries.sort.join("\n"))
        end
      end

      module_function

      def polispec_home
        base = ENV["POLISPEC_HOME"].to_s
        File.expand_path(base.empty? ? "~/.polispec" : base)
      end

      def tier_for(name)
        TIERS.fetch(name.to_s)
      end

      def name_list(names)
        return names.first.to_s if names.length < 2

        "#{names[0..-2].join(', ')}#{',' if names.length > 2} or #{names.last}"
      end

      def env_key(name)
        name.to_s == "stable" ? "prod" : name.to_s
      end

      def row_env(name)
        name.to_s == "prod" ? "stable" : name.to_s
      end

      def tier_of(project, name)
        config = project.environment(env_key(name))
        tier = config.is_a?(Hash) ? config["tier"] : nil
        tier || TIERS.fetch(name.to_s)
      end

      def env_names_errors(policy)
        declared = (policy["environments"] || {}).keys
        errors = []
        declared.each do |name|
          errors << "environment name #{name.inspect} is reserved for the prod alias" if name == "stable"
          errors << "environment name #{name.inspect} must match #{ENV_NAME.source}" unless ENV_NAME.match?(name.to_s)
        end
        usable = declared + ["stable"]
        (policy["promotion"] || {}).each do |key, config|
          match = key.to_s.match(/\Ato_(.+)\z/)
          if match.nil?
            errors << "promotion.#{key} must be named to_<env>"
            next
          end
          errors << "promotion.#{key} names an environment the policy does not declare" unless usable.include?(match[1])
          errors << "promotion.#{key} needs a from" unless config.is_a?(Hash) && config["from"].is_a?(String) && !config["from"].empty?
        end
        promotion = (policy["promotion"] || {}).values.select { |config| config.is_a?(Hash) }
        promotion.flat_map { |config| Array(config["gates"]) + Array(config["preflight"]) }.each do |gate|
          next unless gate.is_a?(Hash) && gate["env"]

          errors << "gate #{gate['id']} names env #{gate['env'].inspect}, which the policy does not declare" unless usable.include?(gate["env"].to_s) || gate["env"] == "prod"
        end
        errors
      end

      def env_dir_name(env)
        env.to_s == "prod" ? "stable" : env.to_s
      end

      def active_dir(project, env)
        File.join(envs_root(project.ledger), project.id, env_dir_name(env))
      end

      def env_file_vars(project, env)
        key = env_dir_name(env) == "stable" ? "prod" : env_dir_name(env)
        config = project.environment(key)
        raise Failure.new("unknown_env", "env_from names #{env.inspect}, which the policy does not declare") unless config.is_a?(Hash)

        Array(config["env_files"]).flat_map { |pattern| Dir.glob(File.expand_path(expand_home(pattern))).sort }.each_with_object({}) do |path, vars|
          vars.merge!(parse_env_file(path))
        end
      end

      def parse_env_file(path)
        File.readlines(path, chomp: true).each_with_object({}) do |line, vars|
          text = line.strip
          next if text.empty? || text.start_with?("#")

          key, value = text.sub(/\Aexport\s+/, "").split("=", 2)
          next if value.nil? || !key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

          value = value.strip
          value = value[1..-2] if value.length >= 2 && value[0] == value[-1] && %w[" '].include?(value[0])
          vars[key] = value
        end
      rescue SystemCallError => e
        raise Failure.new("env_file_unreadable", "cannot read env file #{path}: #{e.class}")
      end

      def stable_tag(project, git)
        branch = project.environment("prod")["branch"]
        tip = git.rev("origin/#{branch}")
        tip ? git.latest_tag(git.tags_at(tip)) : nil
      end

      def health_required_errors(policy)
        (policy["environments"] || {}).filter_map do |name, config|
          deploy = config.is_a?(Hash) ? config["deploy"] : nil
          next unless deploy.is_a?(Hash)
          next unless Array(deploy["steps"]).any? || Array(deploy["activate"]).any?
          next if deploy["health"].is_a?(Hash)

          "env #{name} deploys without a health check; G-TESTED can never pass"
        end
      end

      def now_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
      end

      def new_id(prefix)
        "#{prefix}_#{SecureRandom.hex(10)}"
      end

      def interactive?
        return false unless $stdin.tty?

        !IO.console.nil?
      rescue SystemCallError, IOError
        false
      end

      def actor
        interactive? ? "operator" : "agent"
      end

      def require_terminal!(what)
        return if interactive?

        raise Failure.new("not_tty", "#{what} needs an interactive terminal")
      end

      def confirm!(phrase)
        Polispec::Operator::Tty.confirm!(phrase)
      rescue Failure
        raise
      rescue StandardError => e
        raise Failure.new("confirmation_failed", e.message.to_s.empty? ? "typed phrase rejected" : e.message)
      end

      def interpolate(text, vars)
        text.to_s.gsub(/\{(sha|VERSION|project|tag|stable_tag)\}/) { vars[Regexp.last_match(1)].to_s }
      end

      def envs_root(ledger)
        override = ENV["POLISPEC_ENVS_ROOT"]
        override && !override.empty? ? File.expand_path(override) : ledger.envs_root
      end

      def load_project(id, bootstrap_from: nil)
        ledger = Polispec::Ledger.load
        entry = ledger.project(id)
        raise Failure.new("unknown_project", "no project #{id.inspect} in #{ledger.path}") unless entry
        raise Failure.new("retired_project", "project #{id} is retired") if entry.status == "retired"

        repo = File.expand_path(entry.repo)
        raise Failure.new("repo_missing", "project #{id} repo #{repo} is not a git checkout") unless File.exist?(File.join(repo, ".git"))

        policy, source, digest = Polispec::PolicySource.load(entry)
        if source == "defaults" && bootstrap_from && Polispec::PolicySource.missing?(entry)
          Git.new(repo).fetch
          found = Polispec::PolicySource.bootstrap(entry, "origin/#{bootstrap_from}")
          policy, source, digest = found.policy, found.source, found.digest if found
        end
        usable = policy.is_a?(Hash) && policy["promotion"].is_a?(Hash) && policy["environments"].is_a?(Hash)
        raise Failure.new("policy_unavailable", "project #{id} has no usable promotion policy (source #{source})", "policy_source" => source) unless usable

        problems = health_required_errors(policy) + env_names_errors(policy) + Polispec::ValidateProfiles.errors(policy, entry, ledger: ledger)
        raise Failure.new("policy_invalid", problems.join("; "), "policy_source" => source, "errors" => problems) unless problems.empty?

        Project.new(ledger: ledger, entry: entry, policy: policy, source: source, digest: digest, repo: repo)
      end

      def with_lock(name)
        FileUtils.mkdir_p(State.home, mode: 0o700)
        File.open(File.join(State.home, "operator-#{name}.lock"), File::RDWR | File::CREAT, 0o600) do |file|
          raise Failure.new("locked", "another operator command holds #{name}") unless file.flock(File::LOCK_EX | File::LOCK_NB)

          yield
        end
      end

      def exec(argv, chdir:, env: {}, timeout: DEFAULT_TIMEOUT)
        started = now_ms
        output = +""
        code = 1
        timed_out = false
        Open3.popen2e(env, *argv, chdir: chdir) do |stdin, out, waiter|
          stdin.close
          reader = Thread.new { out.read }
          if waiter.join(timeout)
            code = waiter.value.exitstatus || 1
          else
            timed_out = true
            terminate(waiter)
          end
          reader.join(3)
          output = reader.alive? ? "" : reader.value.to_s
          reader.kill
        end
        Execution.new(code, output, now_ms - started, timed_out)
      rescue SystemCallError => e
        Execution.new(127, "#{argv.first}: #{e.message}", now_ms - started, false)
      end

      def terminate(waiter)
        Process.kill("TERM", waiter.pid)
        return if waiter.join(5)

        Process.kill("KILL", waiter.pid)
      rescue SystemCallError
        nil
      end

      def argv_for(command, vars)
        Shellwords.split(interpolate(command, vars)).map { |word| expand_home(word) }
      end

      def expand_home(word)
        home = Dir.home
        word.gsub(/\$\{HOME\}|\$HOME(?![A-Za-z0-9_])/) { home }.sub(%r{\A~(?=/|\z)}) { home }
      end

      def version_at(git, sha)
        text = git.show(sha, "VERSION")
        version = text.to_s.strip
        raise Failure.new("no_version", "VERSION is missing or empty at #{sha[0, 12]}") if version.empty?

        version
      end

      def effective_gates(project, to)
        listed = Array(project.promotion["to_#{to}"]["gates"])
        return listed unless to == "stable"

        required = [
          { "id" => "G-TESTED", "builtin" => "sha_ran_on", "alias" => %w[sha_ran_on sha_ran_on_test] },
          { "id" => "G-FREEZE", "builtin" => "not_frozen", "alias" => %w[not_frozen] }
        ]
        present = listed.map { |gate| gate["builtin"] }
        required.reject { |gate| (gate["alias"] & present).any? }.map { |gate| gate.reject { |key, _| key == "alias" } } + listed
      end

      def run_all(gates, context)
        gates.map do |gate|
          started = now_ms
          gate["builtin"] ? builtin(gate, context) : command(gate, context)
          result = { "id" => gate["id"], "result" => "pass", "duration_ms" => now_ms - started }
          result["hermetic"] = false if gate["hermetic"] == false && !gate["builtin"]
          result
        end
      end

      def command(gate, context)
        argv = argv_for(gate["run"], context.vars)
        raise Failure.new("gate_failed", "gate #{gate['id']} has an empty command", "gate_id" => gate["id"]) if argv.empty?

        chdir, extra = gate_location(gate, context)

        guard = gate["hermetic"] == false ? nil : Hermetic.for(context.project, tier_of(context.project, context.to), new_id("gate"))
        execution = guard ? guard.exec(argv, chdir: chdir, env: extra, timeout: DEFAULT_TIMEOUT) : exec(argv, chdir: chdir, env: extra)
        guard&.finish
        if execution.violation
          raise Failure.new("gate_failed", "gate #{gate['id']} #{execution.violation}", "gate_id" => gate["id"], "command" => argv.join(" "), "output_tail" => execution.tail)
        end
        return if execution.ok?

        reason = execution.timed_out ? "timed out" : "exited #{execution.code}"
        raise Failure.new("gate_failed", "gate #{gate['id']} #{reason}", "gate_id" => gate["id"], "command" => argv.join(" "), "output_tail" => execution.tail)
      end

      def gate_location(gate, context)
        own = context.to
        chdir = context.project.repo
        if gate["run_in"] == "active"
          chdir = active_dir(context.project, own)
          raise Failure.new("gate_failed", "gate #{gate['id']}: no active #{own} checkout at #{chdir}", "gate_id" => gate["id"]) unless File.directory?(chdir)
        end
        extra = gate["env_from"] ? env_file_vars(context.project, gate["env_from"]) : {}
        [chdir, extra.merge(gate_env(context))]
      rescue Failure => e
        raise e if e.code == "gate_failed"

        raise Failure.new("gate_failed", "gate #{gate['id']}: #{e.message}", "gate_id" => gate["id"])
      end

      def gate_env(context)
        { "POLISPEC_PROJECT" => context.project.id, "POLISPEC_SHA" => context.sha, "POLISPEC_VERSION" => context.version.to_s, "POLISPEC_TAG" => context.tag.to_s }
      end

      def builtin(gate, context)
        name = gate["builtin"]
        raise Failure.new("gate_failed", "unknown builtin #{name}", "gate_id" => gate["id"]) unless BUILTINS.include?(name)

        send("gate_#{name}", gate, context)
      end

      def gate_clean_tree(gate, context)
        return unless context.git.dirty?

        status = context.git.run!("status", "--short", "--untracked-files=no").out
        raise Failure.new("gate_failed", "gate #{gate['id']}: the working tree has uncommitted changes", "gate_id" => gate["id"], "output_tail" => Git.tail(status))
      end

      def gate_version_homes_agree(gate, context)
        homes = version_homes(context.git, context.sha, context.version)
        odd = homes.reject { |_, value| value == context.version }
        return if odd.empty?

        listing = homes.map { |path, value| "#{path}=#{value}" }.join("\n")
        raise Failure.new("gate_failed", "gate #{gate['id']}: version homes disagree", "gate_id" => gate["id"], "output_tail" => listing)
      end

      def version_homes(git, sha, version)
        homes = { "VERSION" => version }
        git.root_entries(sha).grep(/\.rplugin\.yml\z/).each do |path|
          data = Polispec::Schema::Document.parse(git.show(sha, path).to_s, path)
          homes[path] = data["version"].to_s if data.is_a?(Hash) && data.key?("version")
        rescue Polispec::Error
          homes[path] = "unparseable"
        end
        JSON_HOMES.each do |path|
          text = git.show(sha, path)
          next unless text

          data = JSON.parse(text)
          homes[path] = data["version"].to_s if data.is_a?(Hash) && data.key?("version")
        rescue JSON::ParserError
          homes[path] = "unparseable"
        end
        homes
      end

      def gate_sha_ran_on_test(gate, context)
        gate_sha_ran_on(gate.merge("env" => "test"), context)
      end

      def gate_env_name(gate)
        name = (gate["env"] || "test").to_s
        raise Failure.new("gate_failed", "gate #{gate['id']}: env #{name.inspect} is not an environment name", "gate_id" => gate["id"]) unless name == "prod" || ENV_NAME.match?(name)

        row_env(name)
      end

      def gate_sha_ran_on(gate, context)
        env = gate_env_name(gate)
        return if ran_on?(context.project.id, context.sha, env)

        raise Failure.new("untested_sha", "#{context.sha[0, 12]} never passed the #{env} health check", "gate_id" => gate["id"], "sha" => context.sha)
      end

      def ran_on?(project, sha, env)
        State.read_jsonl("deploys").any? do |row|
          row["project"] == project && row["env"] == env && row["sha"] == sha && row["health"] == "ok"
        end
      end

      def ran_on_test?(project, sha)
        ran_on?(project, sha, "test")
      end

      def gate_soaked(gate, context)
        hours = gate["hours"]
        raise Failure.new("gate_failed", "gate #{gate['id']}: soaked needs an integer hours option", "gate_id" => gate["id"]) unless hours.is_a?(Integer) && hours.positive?

        env = gate_env_name(gate)
        rows = State.read_jsonl("deploys").select do |row|
          row["project"] == context.project.id && row["env"] == env && row["sha"] == context.sha
        end
        cutoff = Time.now.utc - (hours * 3600)
        index = rows.index { |row| row["health"] == "ok" && recorded_at(row)&.<=(cutoff) }
        later_other = index && rows[(index + 1)..].any? { |row| row["health"] != "ok" }
        return if index && !later_other

        detail = if index.nil?
          rows.any? { |row| row["health"] == "ok" } ? "its newest healthy #{env} deploy is under #{hours} h old" : "it has no healthy #{env} deploy"
        else
          "a later #{env} deploy of it was not healthy"
        end
        raise Failure.new("not_soaked", "#{context.sha[0, 12]} has not soaked on #{env} for #{hours} h: #{detail}", "gate_id" => gate["id"], "sha" => context.sha, "hours" => hours)
      end

      def recorded_at(row)
        Time.parse(row["at"].to_s).utc
      rescue ArgumentError
        nil
      end

      def gate_health_required(gate, context)
        problems = health_required_errors(candidate_policy(context))
        return if problems.empty?

        raise Failure.new("gate_failed", "gate #{gate['id']}: #{problems.join('; ')}", "gate_id" => gate["id"], "output_tail" => problems.join("\n"))
      end

      def candidate_policy(context)
        text = context.git.show(context.sha, context.project.entry.policy)
        return context.project.policy unless text

        data = Polispec::Schema::Document.parse(text, "#{context.sha[0, 12]}:#{context.project.entry.policy}")
        data.is_a?(Hash) ? data : context.project.policy
      rescue Polispec::Error
        context.project.policy
      end

      def gate_logs_quiet(gate, context)
        services = Array(gate["services"])
        unless services.any? && services.all? { |name| name.is_a?(String) && !name.empty? }
          raise Failure.new("gate_failed", "gate #{gate['id']}: logs_quiet needs a services list", "gate_id" => gate["id"])
        end

        window = gate.fetch("window_minutes", LOGS_WINDOW_MINUTES)
        allowed = gate.fetch("max_over_baseline", 0)
        unless window.is_a?(Integer) && window.positive? && allowed.is_a?(Integer) && allowed >= 0
          raise Failure.new("gate_failed", "gate #{gate['id']}: window_minutes must be a positive integer and max_over_baseline a non-negative integer", "gate_id" => gate["id"])
        end

        words = logs_count_words(gate)
        env = deployed_env(context)
        deployed = last_healthy_deploy_time(context, env)
        raise Failure.new("gate_failed", "gate #{gate['id']}: #{context.sha[0, 12]} has no healthy #{env} deploy to measure from", "gate_id" => gate["id"]) unless deployed

        span = window * 60
        if Time.now.utc < deployed + span
          raise Failure.new("logs_in_window", "gate #{gate['id']}: still in window; #{env} deploy at #{deployed.iso8601} needs #{window} min of logs", "gate_id" => gate["id"])
        end

        noisy = services.filter_map do |service|
          after = logs_count(gate, words, service, deployed, deployed + span, context)
          before = logs_count(gate, words, service, deployed - span, deployed, context)
          "#{service}: #{after} after against #{before} before" if after > before + allowed
        end
        return if noisy.empty?

        raise Failure.new("logs_not_quiet", "gate #{gate['id']}: logs grew after the #{env} deploy (#{noisy.join('; ')})", "gate_id" => gate["id"], "output_tail" => noisy.join("\n"))
      end

      def logs_count_words(gate)
        template = Polispec::Engine::Settings.text(LOGS_COUNT_KEY, nil)
        if template.nil?
          raise Failure.new("gate_failed", "gate #{gate['id']}: setting #{LOGS_COUNT_KEY} is not set, so logs_quiet fails closed", "gate_id" => gate["id"])
        end

        words = Shellwords.split(template)
        raise Failure.new("gate_failed", "gate #{gate['id']}: setting #{LOGS_COUNT_KEY} is empty", "gate_id" => gate["id"]) if words.empty?

        words
      rescue ArgumentError => e
        raise Failure.new("gate_failed", "gate #{gate['id']}: setting #{LOGS_COUNT_KEY} does not parse: #{e.message}", "gate_id" => gate["id"])
      end

      def logs_count(gate, words, service, from, to, context)
        values = { "{service}" => service, "{since}" => from.utc.iso8601, "{until}" => to.utc.iso8601 }
        argv = words.map { |word| expand_home(values.reduce(word) { |text, (token, value)| text.gsub(token, value) }) }
        execution = exec(argv, chdir: context.project.repo, timeout: LOGS_COUNT_TIMEOUT)
        reason = execution.timed_out ? "timed out" : "exited #{execution.code}"
        unless execution.ok?
          raise Failure.new("gate_failed", "gate #{gate['id']}: the logs count command #{reason} for #{service} (fails closed)", "gate_id" => gate["id"], "output_tail" => execution.tail)
        end

        text = execution.output.strip
        unless text.match?(/\A\d+\z/)
          raise Failure.new("gate_failed", "gate #{gate['id']}: the logs count command printed a non-integer for #{service} (fails closed)", "gate_id" => gate["id"], "output_tail" => execution.tail)
        end

        text.to_i
      end

      def deployed_env(context)
        from = (context.project.promotion["to_#{context.to}"] || {})["from"].to_s
        environments = context.project.policy["environments"] || {}
        key = environments.key?(from) ? from : environments.find { |_, config| config.is_a?(Hash) && config["branch"] == from }&.first
        key.nil? || key == "dev" ? "test" : row_env(key)
      end

      def last_healthy_deploy_time(context, env)
        row = State.read_jsonl("deploys").select do |candidate|
          candidate["project"] == context.project.id && candidate["env"] == env && candidate["sha"] == context.sha && candidate["health"] == "ok"
        end.last
        row && recorded_at(row)
      end

      def gate_requires_live(gate, context)
        other = gate["project"]
        raise Failure.new("gate_failed", "gate #{gate['id']}: requires_live needs a project option", "gate_id" => gate["id"]) unless other.is_a?(String) && !other.empty?

        minimum = required_version(gate, context)
        row = State.read_jsonl("deploys").select { |candidate| candidate["project"] == other && %w[stable prod].include?(candidate["env"]) }.last
        raise Failure.new("not_live", "gate #{gate['id']}: #{other} has no prod deploy record", "gate_id" => gate["id"]) unless row
        unless row["health"] == "ok"
          raise Failure.new("not_live", "gate #{gate['id']}: the newest prod deploy of #{other} (#{row['tag'] || row['sha'].to_s[0, 12]}) has health #{row['health']}", "gate_id" => gate["id"])
        end

        live = Gem::Version.new(row["tag"].to_s.sub(/\Av/, ""))
        return if live >= minimum

        raise Failure.new("not_live", "gate #{gate['id']}: #{other} runs #{row['tag']} in prod, below the required #{minimum}", "gate_id" => gate["id"], "required" => minimum.to_s)
      rescue ArgumentError
        raise Failure.new("not_live", "gate #{gate['id']}: the newest prod deploy of #{gate['project']} carries no usable version tag", "gate_id" => gate["id"])
      end

      def required_version(gate, context)
        direct = gate["min_version"]
        return Gem::Version.new(direct.to_s.sub(/\Av/, "")) if direct

        path = gate["min_version_from"]
        key = gate["min_version_key"]
        unless path.is_a?(String) && !path.empty? && key.is_a?(String) && !key.empty?
          raise Failure.new("gate_failed", "gate #{gate['id']}: requires_live needs min_version, or min_version_from with min_version_key", "gate_id" => gate["id"])
        end

        text = context.git.show(context.sha, path)
        raise Failure.new("gate_failed", "gate #{gate['id']}: #{path} does not exist at #{context.sha[0, 12]}", "gate_id" => gate["id"]) unless text

        data = Polispec::Schema::Document.parse(text, path)
        value = key.split(".").reduce(data) { |node, part| node.is_a?(Hash) ? node[part] : nil }
        raise Failure.new("gate_failed", "gate #{gate['id']}: #{path} has no #{key}", "gate_id" => gate["id"]) if value.nil?

        Gem::Version.new(value.to_s.sub(/\Av/, ""))
      rescue Failure
        raise
      rescue Polispec::Error, ArgumentError => e
        raise Failure.new("gate_failed", "gate #{gate['id']}: cannot read the minimum version: #{e.message}", "gate_id" => gate["id"])
      end

      def gate_not_frozen(gate, context)
        windows = Array(Polispec::Freeze.active(context.project.policy, "promote.to_#{context.to}"))
        return if windows.empty?

        first = windows.first
        raise Failure.new("frozen", "promotion is frozen by #{field(first, 'id')}", "gate_id" => gate["id"], "freeze_id" => field(first, "id"), "until" => field(first, "until"))
      end

      def field(window, name)
        return window[name] || window[name.to_sym] if window.respond_to?(:key?)

        window.respond_to?(name) ? window.public_send(name) : nil
      end
    end
  end
end
