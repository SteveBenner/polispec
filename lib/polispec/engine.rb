#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "securerandom"
require_relative "classify/shell"

module Polispec
  module Engine
    Row = Struct.new(:action, :env, :verdict)
    Outcome = Struct.new(:verdict, :env, :action_class, :rows, keyword_init: true)
    ENV_NAMES = %w[prod test dev].freeze
    STORE_REF = /\A[a-z][a-z0-9+.-]*:/

    def self.store_ref?(value)
      text = value.to_s
      !text.start_with?("~", "/") && STORE_REF.match?(text)
    end

    module Settings
      KEY = "polispec.enforce"
      MODES = %w[advise enforce].freeze
      OPERATOR_KEY = "polispec.operator"
      OPERATOR_DEFAULT = "the operator".freeze
      LEDGER_KEY = "polispec.ledger"
      module_function

      def text(key, default)
        forced = ENV[env_name(key)].to_s.strip
        return forced unless forced.empty?

        machine = snapshot.dig("machine", key)
        machine.is_a?(String) && !machine.strip.empty? ? machine.strip : default
      end

      def operator
        text(OPERATOR_KEY, OPERATOR_DEFAULT)
      end

      def ledger_path
        text(LEDGER_KEY, nil)
      end

      def enforce_mode
        forced = ENV[env_name(KEY)].to_s.strip.downcase
        return forced if MODES.include?(forced)

        machine = snapshot.dig("machine", KEY)
        MODES.include?(machine) ? machine : "advise"
      end

      def env_name(key)
        "RPLUGIN_#{"#{ID}_#{key}".upcase.gsub(/[^A-Z0-9]+/, '_')}"
      end

      def snapshot
        base = ENV["XDG_STATE_HOME"]
        base = File.join(Dir.home, ".local", "state") if base.nil? || base.empty?
        data = JSON.parse(File.read(File.join(base, "rplugin", ID, "settings.resolved.json")))
        data.is_a?(Hash) ? data : {}
      rescue StandardError
        {}
      end
    end

    module Logs
      module_function

      def append(path, record)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |file| file.syswrite("#{JSON.generate(record)}\n") }
        record
      end

      def read(path)
        return [] unless File.file?(path)

        File.foreach(path).map { |line| parse(line) }.compact
      rescue SystemCallError
        []
      end

      def parse(line)
        data = JSON.parse(line)
        data.is_a?(Hash) ? data : nil
      rescue JSON::ParserError
        nil
      end
    end

    module Pauses
      module_function

      def active(ledger, project_id, now = Time.now)
        records = Logs.read(ledger.pauses_log).select do |record|
          record["project"] == project_id.to_s && parse(record["expires_at"]) && parse(record["expires_at"]) > now
        end
        records.max_by { |record| record["started_at"].to_s }
      end

      def start!(ledger, project_id, minutes, reason, now = Time.now)
        expires = now + (minutes * 60)
        record = {
          "project" => project_id.to_s, "minutes" => minutes, "reason" => reason, "actor" => "operator",
          "started_at" => now.utc.iso8601, "expires_at" => expires.utc.iso8601
        }
        Logs.append(ledger.pauses_log, record)
      end

      def parse(value)
        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end
    end

    module Passes
      TTL = 600
      module_function

      def digest(project_id, rows)
        material = [project_id.to_s, rows.map { |row| [row.action.action_class, row.env, row.action.raw.to_s] }]
        Digest::SHA256.hexdigest(JSON.generate(material))
      end

      def fold(ledger)
        Logs.read(ledger.allow_once_log).each_with_object({}) do |record, memo|
          id = record["id"]
          next unless id

          entry = (memo[id] ||= {})
          entry.merge!(record.reject { |key, _| key == "event" })
        end
      end

      def issue!(ledger, project_id, rows, verdict, now = Time.now)
        digest = digest(project_id, rows)
        reusable = fold(ledger).values.find do |entry|
          entry["project"] == project_id && entry["action_digest"] == digest && entry["redeemed_at"].nil? && Time.parse(entry["issued_at"]) + TTL > now
        end
        return reusable["id"] if reusable

        lead = rows.first
        id = "alo_#{SecureRandom.hex(6)}"
        Logs.append(ledger.allow_once_log, {
          "event" => "issued", "id" => id, "project" => project_id, "action_digest" => digest,
          "action_class" => lead.action.action_class, "env" => lead.env, "rule_id" => verdict.rule_id,
          "raw" => lead.action.raw.to_s[0, 300], "issued_at" => now.utc.iso8601
        })
        id
      end

      def redeem!(ledger, id, now = Time.now)
        entry = fold(ledger)[id]
        raise Polispec::Error, "unknown allow-once id #{id}" unless entry
        raise Polispec::Error, "#{id} was already consumed" if entry["consumed_at"]

        Logs.append(ledger.allow_once_log, { "event" => "redeemed", "id" => id, "project" => entry["project"], "redeemed_at" => now.utc.iso8601, "expires_at" => (now + TTL).utc.iso8601 })
        entry
      end

      def consume!(ledger, project_id, digest, session_id, now = Time.now)
        entry = fold(ledger).values.select { |item| usable?(item, project_id, digest, now) }.min_by { |item| item["redeemed_at"] }
        return nil unless entry

        Logs.append(ledger.allow_once_log, { "event" => "consumed", "id" => entry["id"], "project" => project_id, "consumed_at" => now.utc.iso8601, "session_id" => session_id })
        Events.emit("polispec.allow_once", project: project_id, id: entry["id"], action_class: entry["action_class"], rule_id: entry["rule_id"], redeemed_at: entry["redeemed_at"], consumed_by_session: session_id)
        entry
      end

      def usable?(item, project_id, digest, now)
        item["project"] == project_id && item["action_digest"] == digest && item["redeemed_at"] && item["consumed_at"].nil? &&
          Time.parse(item["redeemed_at"]) + TTL > now
      end
    end

    module Envs
      module_function

      def hint_of(action)
        raw = action.env_hint || {}
        stringify(raw)
      end

      def stringify(value)
        case value
        when Hash then value.each_with_object({}) { |(key, item), memo| memo[key.to_s] = stringify(item) }
        when Array then value.map { |item| stringify(item) }
        else value
        end
      end

      def owner(action, ledger, cwd)
        hint = hint_of(action)
        return ledger.project(hint["project"]) if hint["project"]

        paths = paths_of(hint)
        return located_project(paths, ledger, cwd) || spec_owner(paths, ledger, cwd) unless paths.empty?

        home = ledger.locate(cwd)
        home ? home.project : named_owner(hint, ledger)
      end

      def paths_of(hint)
        hint.flat_map do |key, value|
          if value.is_a?(Hash)
            paths_of(value)
          elsif key.to_s.end_with?("path") && value.is_a?(String) && !Polispec::Engine.store_ref?(value)
            [value]
          else
            []
          end
        end
      end

      def located_project(paths, ledger, cwd)
        paths.each do |path|
          found = ledger.project_for(absolute(path, cwd))
          return found if found
        end
        nil
      end

      def spec_owner(paths, ledger, cwd)
        ledger.projects.find do |project|
          next false unless project.status == "live"

          policy = PolicySource.load(project, ledger: ledger)[0]
          paths.any? { |path| by_spec_paths(canonical(absolute(path, cwd)), policy) }
        end
      end

      def named_owner(hint, ledger)
        unit = unit_name(first_value(hint, "unit"))
        db = first_value(hint, "db")
        return nil unless unit || db

        ledger.projects.find do |project|
          next false unless project.status == "live"

          policy = PolicySource.load(project, ledger: ledger)[0]
          environments(policy).values.any? { |spec| names_match?(spec, unit, db) }
        end
      end

      def names_match?(spec, unit, db)
        (unit && Array(spec["services"]).include?(unit)) || (db && Array((spec["data"] || {})["databases"]).include?(db))
      end

      def first_value(hint, key)
        return hint[key] if hint[key]

        hint.each_value do |value|
          next unless value.is_a?(Hash)

          found = first_value(value, key)
          return found if found
        end
        nil
      end

      def environments(policy)
        policy["environments"].is_a?(Hash) ? policy["environments"] : {}
      end

      def absolute(path, cwd)
        File.expand_path(path.to_s, cwd.to_s.empty? ? Dir.pwd : cwd.to_s)
      end

      def home_env(target, _ctx)
        target.env || "dev"
      end

      def cwd_env(policy, ledger, project_id, cwd)
        return "dev" if cwd.to_s.empty?

        located = ledger.locate(cwd)
        return "dev" unless located && located.project.id == project_id

        by_policy_checkout(canonical(absolute(cwd, cwd)), policy, nil) || "dev"
      end

      def for_action(action, target, ctx)
        hint = hint_of(action)
        return copy_env(hint, target, ctx) if action.action_class == "data.copy"

        for_hint(hint, target, ctx)
      end

      def copy_env(hint, target, ctx)
        source, destination = copy_sides(hint, target, ctx)
        destination || source || home_env(target, ctx)
      end

      SIDES = { "from" => %w[from src source], "to" => %w[to dst dest destination] }.freeze

      def copy_sides(hint, target, ctx)
        [side_env(hint, "from", target, ctx), side_env(hint, "to", target, ctx)]
      end

      def side_env(hint, side, target, ctx)
        SIDES[side].each do |name|
          value = hint[name]
          return value if value.is_a?(String) && ENV_NAMES.include?(value)
          return for_hint(value, target, ctx, fallback: false) if value.is_a?(Hash)

          flat = flat_side(hint, name)
          return for_hint(flat, target, ctx, fallback: false) if flat
        end
        nil
      end

      def flat_side(hint, name)
        flat = {}
        %w[env db path ref unit].each do |key|
          value = hint["#{name}_#{key}"]
          flat[key] = value if value
        end
        flat.empty? ? nil : flat
      end

      def for_hint(hint, target, ctx, fallback: true)
        policy = target.policy
        %i[explicit by_ref by_unit by_db by_secret by_path].each do |step|
          found = send(step, hint, policy, ctx)
          return found if found
        end
        fallback ? home_env(target, ctx) : nil
      end

      def explicit(hint, _policy, _ctx)
        ENV_NAMES.include?(hint["env"]) ? hint["env"] : nil
      end

      def by_ref(hint, policy, _ctx)
        ref = normalize_ref(hint["ref"])
        return nil if ref.nil?

        environments(policy).each { |name, spec| return name if spec["branch"] == ref }
        nil
      end

      def by_unit(hint, policy, _ctx)
        unit = unit_name(hint["unit"])
        return nil unless unit

        environments(policy).each { |name, spec| return name if Array(spec["services"]).include?(unit) }
        nil
      end

      def by_db(hint, policy, _ctx)
        db = hint["db"]
        return nil unless db

        environments(policy).each { |name, spec| return name if Array((spec["data"] || {})["databases"]).include?(db) }
        nil
      end

      def by_secret(hint, policy, _ctx)
        secret = hint["secret"] || (Polispec::Engine.store_ref?(hint["path"]) ? hint["path"] : nil)
        return nil unless secret

        ENV_NAMES.each do |name|
          spec = environments(policy)[name]
          return name if spec && Array(spec["secrets"]).any? { |glob| File.fnmatch?(glob, secret, File::FNM_PATHNAME) }
        end
        nil
      end

      def by_path(hint, policy, ctx)
        path = hint["path"]
        return nil if path.nil? || Polispec::Engine.store_ref?(path)

        abs = canonical(absolute(path, ctx[:cwd]))
        by_spec_paths(abs, policy) || by_policy_checkout(abs, policy, ctx) || dev_location(abs, policy, ctx)
      end

      def by_spec_paths(abs, policy)
        ENV_NAMES.each do |name|
          spec = environments(policy)[name]
          return name if spec && spec_path_hit?(abs, spec)
        end
        nil
      end

      def spec_path_hit?(abs, spec)
        dirs = Array((spec["data"] || {})["dirs"]).map { |dir| canonical(File.expand_path(dir)) }
        globs = (Array(spec["unit_files"]) + Array(spec["env_files"]) + Array(spec["secrets"])).reject { |glob| Polispec::Engine.store_ref?(glob) }
        dirs.any? { |dir| under?(abs, dir) } || globs.any? { |glob| File.fnmatch?(File.expand_path(glob), abs, File::FNM_PATHNAME | File::FNM_DOTMATCH) }
      end

      def by_policy_checkout(abs, policy, ctx)
        ENV_NAMES.each do |name|
          spec = environments(policy)[name]
          next unless spec

          checkout = checkout_root(spec, ctx)
          return name if checkout && under?(abs, checkout)
        end
        nil
      end

      def checkout_root(spec, ctx)
        value = spec["checkout"].to_s
        return nil if value.empty? || value == "repo"

        canonical(File.expand_path(value))
      end

      def dev_location(abs, policy, ctx)
        located = ctx[:ledger] && ctx[:ledger].locate(abs)
        return nil unless located
        return "dev" unless located.kind == :env_checkout

        env_for_checkout_dir(located.env.to_s, policy)
      end

      def env_for_checkout_dir(dir, policy)
        return dir if ENV_NAMES.include?(dir)

        named = ENV_NAMES.find { |name| (environments(policy)[name] || {})["branch"].to_s == dir }
        named || "prod"
      end

      def under?(path, root)
        path == root || path.start_with?("#{root}/")
      end

      def canonical(path)
        existing = path
        existing = File.dirname(existing) until File.exist?(existing) || existing == "/"
        joined = File.join(File.realpath(existing), path[existing.length..-1].to_s).sub(%r{/+\z}, "")
        joined.empty? ? "/" : joined
      rescue SystemCallError
        path
      end

      def unit_name(value)
        return nil if value.nil? || value.to_s.empty?

        value.to_s.sub(/\.service\z/, "").sub(/@.*\z/, "")
      end

      def normalize_ref(ref)
        return nil if ref.nil? || ref.to_s.strip.empty?

        text = ref.to_s.strip.sub(/\A\+/, "")
        text = text.split(":").last if text.include?(":")
        text = text.sub(%r{\Arefs/(heads|tags)/}, "").sub(%r{\Arefs/remotes/[^/]+/}, "").sub(%r{\A(origin|upstream)/}, "")
        text.empty? ? nil : text
      end

      def ref_for(action, env, target, ctx)
        explicit_ref = normalize_ref(hint_of(action)["ref"])
        return explicit_ref if explicit_ref

        spec = environments(target.policy)[env] || {}
        return spec["branch"] if %w[test prod].include?(env)

        current_branch(action, ctx)
      end

      def current_branch(action, ctx)
        return nil unless action.action_class == "git.rewrite"

        dir = hint_of(action)["path"] ? File.dirname(absolute(hint_of(action)["path"], ctx[:cwd])) : ctx[:cwd]
        out, status = Open3.capture2(PolicySource::GIT_ENV, "git", "-C", dir.to_s, "symbolic-ref", "--short", "-q", "HEAD", err: File::NULL)
        status.success? ? out.strip : nil
      rescue SystemCallError
        nil
      end

      def crossing(action, target, ctx)
        return [] unless action.action_class == "data.copy"

        source, destination = copy_sides(hint_of(action), target, ctx)
        destination ||= home_env(target, ctx)
        return [] if source.nil? || destination.nil? || source == destination

        classes = Array(environments(target.policy)[source] && environments(target.policy)[source]["data_classes"])
        defined = target.policy["data_classes"] || {}
        classes.select { |name| defined[name] && !Array(defined[name]["allowed_in"]).include?(destination) }
      end
    end

    module Locations
      Loc = Struct.new(:project, :env, :root) do
        def label
          project ? "#{project}/#{env}" : "outside any project"
        end
      end

      CLASSES = %w[fs.write data.write data.copy].freeze

      class Atlas
        def initialize(target, ctx)
          @target = target
          @ctx = ctx
          @ledger = ctx[:ledger]
          @cwd = ctx[:cwd].to_s
          @policies = {}
        end

        def origin
          locate_path(@cwd) || Loc.new(nil, nil, nil)
        end

        def destinations(action)
          hint = Envs.hint_of(action)
          case action.action_class
          when "fs.write" then [path_loc(hint)]
          when "data.write" then [named_loc(hint) || (hint["db"] || hint["unit"] ? nil : path_loc(hint))]
          when "data.copy" then [copy_loc(hint)]
          else []
          end.compact
        end

        private

        def ids
          @ids ||= (@ledger.projects.reject { |project| project.status == "retired" }.map(&:id) + [@target.project] + Array(@ctx[:policies]&.keys).map(&:to_s)).compact.uniq
        end

        def policy(id)
          @policies.fetch(id) { @policies[id] = load_policy(id) }
        end

        def load_policy(id)
          given = @ctx[:policies] && (@ctx[:policies][id] || @ctx[:policies][id.to_sym])
          found = given || (id == @target.project ? @target.policy : lookup(id))
          found.is_a?(Hash) ? found : {}
        rescue StandardError
          {}
        end

        def lookup(id)
          entry = @ledger.project(id)
          entry ? PolicySource.load(entry, ledger: @ledger)[0] : {}
        end

        def path_loc(hint)
          hint["path"] ? locate_path(hint["path"]) : nil
        end

        def named_loc(hint)
          unit = Envs.unit_name(hint["unit"])
          db = hint["db"]
          return nil unless unit || db

          ids.each do |id|
            Envs.environments(policy(id)).each do |name, spec|
              return Loc.new(id, name, nil) if spec.is_a?(Hash) && Envs.names_match?(spec, unit, db)
            end
          end
          nil
        end

        def copy_loc(hint)
          Envs::SIDES["to"].each do |name|
            value = hint[name]
            found = value.is_a?(String) ? (ENV_NAMES.include?(value) ? Loc.new(@target.project, value, nil) : nil) : side_loc(value || Envs.flat_side(hint, name))
            return found if found
          end
          nil
        end

        def side_loc(side)
          return nil unless side.is_a?(Hash)

          named_loc(side) || path_loc(side) || (ENV_NAMES.include?(side["env"]) ? Loc.new(@target.project, side["env"], nil) : nil)
        end

        def locate_path(path)
          return nil if path.to_s.empty? || Polispec::Engine.store_ref?(path)

          abs = Envs.canonical(Envs.absolute(path, @cwd))
          protected_loc(abs) || checkout_loc(abs)
        end

        def checkout_loc(abs)
          found = @ledger.locate(abs)
          return nil unless found

          env = found.kind == :env_checkout ? Envs.env_for_checkout_dir(found.env.to_s, policy(found.project.id)) : "dev"
          Loc.new(found.project.id, env, nil)
        end

        def protected_loc(abs)
          ids.each do |id|
            hermetic = policy(id)["hermetic"]
            next unless hermetic.is_a?(Hash)

            hermetic.each do |env, spec|
              next unless spec.is_a?(Hash)

              Array(spec["protected_roots"]).each do |root|
                canonical = Envs.canonical(File.expand_path(root.to_s))
                return Loc.new(id, env.to_s, canonical) if Envs.under?(abs, canonical)
              end
            end
          end
          nil
        end
      end

      module_function

      def crossing(action, target, ctx)
        return nil unless CLASSES.include?(action.action_class) && ctx[:ledger] && !ctx[:cwd].to_s.empty?

        atlas = Atlas.new(target, ctx)
        origin = atlas.origin
        atlas.destinations(action).each do |loc|
          next unless (loc.project != origin.project || loc.env != origin.env) && (loc.env == "prod" || loc.root)

          return "#{action.action_class} from #{origin.label} into #{loc.label}#{loc.root ? " (protected root #{loc.root})" : ''}"
        end
        nil
      end
    end

    module Destructive
      module_function

      def of?(action, ctx)
        return true if Envs.hint_of(action)["destructive"] == true
        return false unless action.action_class == "data.write"

        cwd = Envs.hint_of(action)["path"] || ctx[:cwd]
        Classify::Shell.destructive_command?(action.raw.to_s, cwd.to_s.empty? ? Dir.pwd : cwd.to_s)
      rescue StandardError
        false
      end
    end

    module Match
      module_function

      def rule?(match, action, env, target, ctx)
        return false unless match.is_a?(Hash)
        return false unless (match.keys - %w[env class ref crosses destructive]).empty?

        env_ok?(match, env) && class_ok?(match, action) && ref_ok?(match, action, env, target, ctx) && crosses_ok?(match, action, target, ctx) && destructive_ok?(match, action, ctx)
      end

      def env_ok?(match, env)
        match["env"].nil? || match["env"] == env
      end

      def class_ok?(match, action)
        match["class"].nil? || Array(match["class"]).include?(action.action_class)
      end

      def ref_ok?(match, action, env, target, ctx)
        return true if match["ref"].nil?

        Array(match["ref"]).include?(Envs.ref_for(action, env, target, ctx))
      end

      def crosses_ok?(match, action, target, ctx)
        return true if match["crosses"].nil?

        Array(match["crosses"]).any? do |kind|
          kind == "location" ? !Locations.crossing(action, target, ctx).nil? : !Envs.crossing(action, target, ctx).empty?
        end
      end

      def destructive_ok?(match, action, ctx)
        return true if match["destructive"].nil?

        Destructive.of?(action, ctx) == (match["destructive"] == true)
      end
    end

    NEXT_STEPS = {
      prod_git: "Only %<operator>s moves production: ask %<operator>s to run `polispec promote %<project>s --to stable` from a terminal.",
      prod_ops: "Ask %<operator>s to run `polispec deploy %<project>s stable` or `polispec promote %<project>s --to stable` from a terminal.",
      prod_fs: "Make the change in the dev checkout and promote it through test; the production checkout is not edited by agents.",
      prod_secret: "Ask %<operator>s; production secrets are not readable by agents.",
      test_git: "Land the change on main, then run `polispec promote %<project>s --to test`.",
      copy: "Copy only data classes the destination environment allows (deidentified or synthetic data into test and dev).",
      policy: "Policy files take effect only after promotion to stable; edit them on main and promote.",
      warn: "Get explicit confirmation from the user first (use the question tool).",
      generic: "Ask %<operator>s how to proceed."
    }.freeze
    GIT_CLASSES = %w[git.commit git.push git.tag git.merge git.rewrite git.branch release.publish].freeze

    class << self
      def evaluate(actions, target, ctx = {})
        explain(actions, target, ctx).verdict
      end

      def explain(actions, target, ctx = {})
        now = ctx[:now] || Time.now
        context = ctx.merge(now: now)
        paused = pause_for(target, context)
        return paused if paused

        rows = actions.map { |action| judge(action, target, context) }
        settle(rows, target, context)
      end

      def next_step(action_class, env, project, level)
        key = step_key(action_class, env, level)
        format(NEXT_STEPS[key], project: project, operator: Settings.operator)
      end

      private

      def step_key(action_class, env, level)
        return :copy if action_class == "data.copy"
        return :policy if action_class == "policy.edit"
        return :warn if level == "warn"

        env_step(action_class, env)
      end

      def env_step(action_class, env)
        return :prod_git if env == "prod" && GIT_CLASSES.include?(action_class)
        return :prod_ops if env == "prod" && %w[service.control service.config deploy promote].include?(action_class)
        return :prod_fs if env == "prod" && action_class == "fs.write"
        return :prod_secret if env == "prod" && action_class == "secrets.read"
        return :test_git if env == "test" && GIT_CLASSES.include?(action_class)

        :generic
      end

      def pause_for(target, ctx)
        return nil unless ctx[:ledger]

        record = Pauses.active(ctx[:ledger], target.project, ctx[:now])
        return nil unless record

        verdict = Verdict.new(level: "allow", rule_id: "POLISPEC-PAUSE", reason: "polispec is paused for #{target.project} until #{record['expires_at']} (#{record['reason']})")
        Outcome.new(verdict: verdict, env: target.env, action_class: nil, rows: [])
      end

      def judge(action, target, ctx)
        env = Envs.for_action(action, target, ctx)
        verdict = frozen(action, env, target, ctx) || by_rule(action, env, target, ctx)
        Row.new(action, env, cleared(verdict, action, env, target, ctx))
      end

      def frozen(action, env, target, ctx)
        return nil unless action.action_class == "promote" && env == "prod"

        window = Freeze.active(target.policy, "promote.to_stable", now: ctx[:now], project: project_of(target, ctx)).first
        return nil unless window

        Verdict.new(level: "deny", rule_id: window.id, reason: "promotion to stable is frozen: #{window.label} (env #{env}, #{action.action_class}: #{clip(action.raw)})",
                    next_step: "Wait for the freeze to end, or ask #{Settings.operator}.")
      end

      def by_rule(action, env, target, ctx)
        rule = Array(target.policy["rules"]).find { |candidate| Match.rule?(candidate["match"] || {}, action, env, target, ctx) }
        return build(nil, "NO-RULE", "allow", action, env, target) unless rule

        build(rule_reason(rule, action, target, ctx), rule["id"], rule["verdict"], action, env, target)
      end

      def rule_reason(rule, action, target, ctx)
        reason = rule["reason"]
        return reason unless Array((rule["match"] || {})["crosses"]).include?("location")

        note = Locations.crossing(action, target, ctx)
        note ? [reason || "#{rule['verdict']} by #{rule['id']}", note].join("; ") : reason
      end

      def build(reason, rule_id, level, action, env, target)
        base = reason || "#{level} by #{rule_id}"
        base = "#{base}; ledger defaults apply because the stable policy is missing or invalid" if target.policy["defaults"]
        Verdict.new(
          level: level, rule_id: rule_id, reason: "#{base} (env #{env}, #{action.action_class}: #{clip(action.raw)})",
          next_step: level == "allow" ? nil : next_step(action.action_class, env, target.project, level)
        )
      end

      def cleared(verdict, action, env, target, ctx)
        return verdict unless action.action_class == "secrets.read" && !verdict.deny?

        roster = roster_for(target, ctx)
        cap = roster && (roster["environments"] || {})[env]
        return verdict unless cap

        roles = Array(cap["roles"])
        return verdict if roles.include?("*") || (!roles.empty? && ctx[:role].nil?) || (ctx[:role] && roles.include?(ctx[:role]))

        Verdict.new(level: "deny", rule_id: "R-ROSTER-ENV", reason: "the roster clears no matching role for #{env} secrets (env #{env}, secrets.read: #{clip(action.raw)})",
                    next_step: next_step("secrets.read", env, target.project, "deny"))
      end

      def roster_for(target, ctx)
        return ctx[:roster] if ctx.key?(:roster)

        project = ctx[:ledger] && ctx[:ledger].project(target.project)
        project ? PolicySource.load_roster(project) : nil
      end

      def project_of(target, ctx)
        ctx[:ledger] ? ctx[:ledger].project(target.project) : nil
      end

      def settle(rows, target, ctx)
        worst = Verdict.worst(rows.map(&:verdict))
        lead = rows.find { |row| row.verdict.equal?(worst) }
        worst = settle_warn(rows, worst, target, ctx) if worst.warn?
        Outcome.new(verdict: worst, env: lead ? lead.env : target.env, action_class: lead ? lead.action.action_class : nil, rows: rows)
      end

      def settle_warn(rows, worst, target, ctx)
        ledger = ctx[:ledger]
        return worst unless ledger

        warns = rows.select { |row| row.verdict.warn? }
        digest = Passes.digest(target.project, warns)
        if Passes.consume!(ledger, target.project, digest, ctx[:session_id], ctx[:now])
          return Verdict.new(level: "allow", rule_id: worst.rule_id, reason: "allow-once redeemed by the operator: #{worst.reason}")
        end
        worst.allow_once_id = Passes.issue!(ledger, target.project, warns, worst, ctx[:now]) if ctx[:issue_allow_once]
        worst
      end

      def clip(raw)
        text = raw.to_s.gsub(/\s+/, " ").strip
        text.length > 200 ? "#{text[0, 197]}..." : text
      end
    end
  end
end
