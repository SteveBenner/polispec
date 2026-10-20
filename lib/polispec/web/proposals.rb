#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "date"
require "etc"
require "json"
require "monitor"
require "open3"
require "securerandom"
require "stringio"
require "tmpdir"
require "yaml"
require_relative "../plan"
require_relative "../registration"
require_relative "../description"
require_relative "../changes"
require_relative "../sessions"
require_relative "../author"
require_relative "../commands/apply"
require_relative "views"

module Polispec
  module Web
    module Proposals
      REF_PREFIX = "refs/polispec/proposals".freeze
      KEEP_SECONDS = 7 * 24 * 3600
      MAX_RECORDS = 200
      MAX_TEXT = 1_048_576
      PLAN_ID = /\Aplan_[0-9a-f]{24}\z/.freeze
      STATUSES = %w[onboarding live retired].freeze
      TYPED_KINDS = %w[move reorder regroup status].freeze
      SCHEMA_KINDS = { "project" => "policy", "path" => "module", "global" => "global", "module" => "module" }.freeze
      GIT_ENV = {
        "GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_INDEX_FILE" => nil, "GIT_OPTIONAL_LOCKS" => "0",
        "GIT_AUTHOR_NAME" => "polispec web", "GIT_AUTHOR_EMAIL" => "polispec@localhost",
        "GIT_COMMITTER_NAME" => "polispec web", "GIT_COMMITTER_EMAIL" => "polispec@localhost"
      }.freeze
      STATUS_MAP = {
        "confirm_required" => [422, "confirm_required"], "plan_changed" => [409, "conflict"], "conflict" => [409, "conflict"],
        "unknown_project" => [404, "not_found"], "path_unknown" => [404, "not_found"], "unknown_entry" => [404, "not_found"],
        "unknown_plan" => [404, "not_found"], "not_on_main" => [409, "conflict"], "not_on_ref" => [409, "conflict"],
        "already_applied" => [409, "conflict"], "project_retired" => [409, "conflict"], "already_retired" => [409, "conflict"],
        "sealed_authority" => [403, "sealed_authority"], "runtime_behind" => [409, "runtime_behind"], "edition_restricted" => [403, "disabled"], "invalid" => [422, "invalid"]
      }.freeze

      Target = Struct.new(:kind, :id, :project, :repo, :ref, :file, :schema_kind, :scope, keyword_init: true)
      Prepared = Struct.new(:spec, :target, :repo, :ref, :project_id, :force, :change_kind, :file, :label, :extra_files, keyword_init: true)
      Record = Struct.new(:plan_id, :spec, :repo, :ref, :file, :project_id, :force, :change_kind, :requires, :applied, :data, :created, :target_label, :trust_ref, keyword_init: true)
      Section = Struct.new(:header, :stop, :items, :inline)

      MONITOR = Monitor.new
      @records = {}
      @order = []
      @pruned = false

      class << self
        def synchronize(&block)
          return yield if MONITOR.mon_owned?

          Views::QUIET.synchronize { MONITOR.synchronize(&block) }
        end

        def actor_name
          "web:#{Etc.getpwuid(Process.uid).name}"
        rescue StandardError
          "web"
        end

        def with_actor
          previous = ENV["POLISPEC_ACTOR"]
          return yield unless previous.to_s.strip.empty?

          ENV["POLISPEC_ACTOR"] = actor_name
          yield
        ensure
          ENV.delete("POLISPEC_ACTOR") if previous.to_s.strip.empty?
        end

        def describe(error)
          code = error.respond_to?(:code) ? error.code.to_s : "invalid"
          payload = error.respond_to?(:payload) ? error.payload : {}
          status, kind = STATUS_MAP.fetch(code, [422, code.empty? ? "invalid" : code])
          extra = { code: code }
          problems = Array(payload["problems"])
          extra[:findings] = problems.map { |item| item.is_a?(Hash) ? item : { "code" => "schema", "message" => item.to_s } } unless problems.empty?
          payload.each do |key, value|
            next if %w[problems output_tail].include?(key.to_s) || !(value.is_a?(String) || value.is_a?(Numeric))

            extra[key.to_sym] = value
          end
          extra[:reason] = code if kind == "disabled"
          [status, kind, error.message, extra]
        end

        def git(repo, *args, env: {}, stdin: nil)
          out, err, status = Open3.capture3(GIT_ENV.merge(env), "git", "-C", repo, *args, stdin_data: stdin.to_s)
          return out if status.success?

          raise Operator::Failure.new("proposal_failed", "git #{args.first} failed in #{repo}", "output_tail" => Operator::Git.tail([err, out].join("\n")))
        rescue SystemCallError => e
          raise Operator::Failure.new("proposal_failed", "git is not available: #{e.message}")
        end

        def git_read(repo, *args)
          Environments.git(repo, *args)
        end

        def label
          "#{Time.now.to_i}-#{SecureRandom.hex(4)}"
        end

        def proposals_dir
          dir = File.join(Web.dir, "proposals")
          FileUtils.mkdir_p(dir, mode: 0o700)
          dir
        end

        def proposal_file(text, name)
          file = File.join(proposals_dir, "#{name}.ledger.yml")
          File.write(file, text)
          File.chmod(0o600, file)
          file
        end

        def parse_yaml(text)
          doc = YAML.safe_load(text, permitted_classes: [Date, Time], aliases: false)
          unless doc.is_a?(Hash)
            raise Operator::Failure.new("invalid", "the YAML is not one mapping document", "problems" => [{ "code" => "yaml_invalid", "message" => "the document is not a mapping" }])
          end

          Schema::Document.normalize(doc)
        rescue Psych::SyntaxError => e
          raise Operator::Failure.new("invalid", "the YAML does not parse: #{e.problem}", "problems" => [{ "code" => "yaml_invalid", "message" => e.problem.to_s, "line" => e.line, "col" => e.column }])
        rescue Psych::Exception => e
          raise Operator::Failure.new("invalid", "the YAML does not parse: #{e.message}", "problems" => [{ "code" => "yaml_invalid", "message" => e.message }])
        end

        def ledger
          Ledger.load
        end

        def resolve_target(kind, id)
          kind = kind.to_s
          id = id.to_s
          case kind
          when "project" then project_target(id)
          when "global", "module", "path" then shelf_target(kind, id)
          else raise Operator::Failure.new("unsupported_target", "plans cannot target #{kind.empty? ? 'an empty kind' : kind}; use project, path, global, module or ledger")
          end
        end

        def project_target(id)
          current = ledger
          project = current.project(id)
          raise Operator::Failure.new("unknown_project", "#{id} is not in the ledger") unless project
          raise Operator::Failure.new("project_retired", "#{id} is retired") if project.status == "retired"

          repo = File.expand_path(project.repo)
          ref = [project.trust_ref, "main"].uniq.find { |branch| !git_read(repo, "show", "#{branch}:#{project.policy}").nil? }
          raise Operator::Failure.new("policy_missing", "#{project.policy} is not on #{project.trust_ref} in #{project.repo}") unless ref

          Target.new(kind: "project", id: id, project: project, repo: repo, ref: ref, file: project.policy, schema_kind: "policy", scope: :project)
        end

        def shelf_target(kind, id)
          source = Layers.source
          raise Operator::Failure.new("global_unconfigured", "no global layer is configured (polispec.global.repo)") unless source
          raise Operator::Failure.new("global_not_repo", "the global layer is a plain directory; plans need polispec.global.repo and an unset POLISPEC_GLOBAL") unless source.kind == :repo

          relative = case kind
                     when "global" then "global.yml"
                     when "module"
                       raise Operator::Failure.new("invalid", "#{id} is not a module name") unless Layers::MODULE_NAME.match?(id)

                       "modules/#{id}.yml"
                     else
                       entry = ledger.path_entry(id)
                       raise Operator::Failure.new("path_unknown", "#{id} is not a registered path") unless entry

                       entry.policy.to_s
                     end
          file = [source.path.to_s, relative].reject(&:empty?).join("/")
          Target.new(kind: kind, id: id, project: nil, repo: source.repo, ref: source.ref, file: file, schema_kind: SCHEMA_KINDS.fetch(kind), scope: :global)
        end

        def current_text(target)
          git_read(target.repo, "show", "#{target.ref}:#{target.file}")
        end

        def sha(text)
          Packages.sha(text)
        end

        def commit_files(repo, base_ref, files)
          name = label
          ref = "#{REF_PREFIX}/#{name}"
          Dir.mktmpdir("polispec-web") do |dir|
            env = { "GIT_INDEX_FILE" => File.join(dir, "index") }
            git(repo, "read-tree", base_ref, env: env)
            files.each do |path, text|
              blob = git(repo, "hash-object", "-w", "--stdin", stdin: text).strip
              git(repo, "update-index", "--add", "--cacheinfo", "100644,#{blob},#{path}", env: env)
            end
            tree = git(repo, "write-tree", env: env).strip
            parent = git(repo, "rev-parse", "--verify", "#{base_ref}^{commit}").strip
            commit = git(repo, "commit-tree", tree, "-p", parent, "-m", "polispec web proposal #{name}").strip
            git(repo, "update-ref", ref, commit)
          end
          ref
        end

        def drop_ref(repo, ref)
          return if repo.nil? || ref.nil?

          Open3.capture3(GIT_ENV, "git", "-C", repo, "update-ref", "-d", ref)
        rescue SystemCallError
          nil
        end

        def prune_once
          return if @pruned

          @pruned = true
          repos = ledger.projects.map { |project| File.expand_path(project.repo) }
          source = Layers.source
          repos << source.repo if source && source.kind == :repo
          cutoff = Time.now.to_i - KEEP_SECONDS
          repos.uniq.each { |repo| prune_repo(repo, cutoff) }
        rescue StandardError
          nil
        end

        def prune_repo(repo, cutoff)
          listing = git_read(repo, "for-each-ref", "--format=%(refname) %(committerdate:unix)", REF_PREFIX)
          return unless listing

          listing.lines.each do |line|
            ref, stamp = line.split(" ", 2)
            drop_ref(repo, ref) if stamp.to_i < cutoff
          end
        end

        def validated(target, text)
          if text.to_s.strip.empty? || text.bytesize > MAX_TEXT
            raise Operator::Failure.new("invalid", "the proposed YAML is empty or larger than #{MAX_TEXT} bytes")
          end

          doc = parse_yaml(text)
          declared = Schema.kind_for(doc)
          if declared && declared != target.schema_kind
            raise Operator::Failure.new("invalid", "the document declares schema #{Schema.schema_id(declared)}, but #{target.kind} #{target.id} takes #{Schema.schema_id(target.schema_kind)}")
          end

          errors = target.kind == "project" ? policy_errors(target, text) : Schema.validate(target.schema_kind, doc).map(&:to_h)
          unless errors.empty?
            raise Operator::Failure.new("invalid", "the proposed #{target.kind} #{target.id} does not validate", "problems" => errors.first(50).map { |error| { "code" => "schema", "path" => error["pointer"], "message" => error["message"] } })
          end
          if target.kind == "project" && doc["project"] != target.id
            raise Operator::Failure.new("invalid", "the proposed policy names project #{doc['project'].inspect}, not #{target.id}")
          end

          doc
        end

        def environments_text(target)
          dir = File.dirname(target.file)
          git_read(target.repo, "show", "#{target.ref}:#{dir == '.' ? '' : "#{dir}/"}#{Environments::FILE}")
        end

        def policy_errors(target, text)
          combined = Environments.combine(text, environments_text(target), target.file)
          Array(combined.errors)
        end

        def description_gate!(old_text, doc)
          return unless Description.ahead_of_runtime?
          return if doc["description"].nil?

          old = old_text ? (parse_yaml(old_text) rescue {}) : {}
          return if old["description"] == doc["description"]

          raise Operator::Failure.new("description_not_allowed", "readers of this rulebook run a polispec older than 0.34.0; a description makes it invalid there")
        end

        def base_gate!(target, change)
          base = change["base"]
          return unless base.is_a?(Hash)

          current = current_text(target)
          return if current.nil?

          digest = sha(current)
          given = [base["digest"], base["etag"]].map { |item| item.to_s.delete('"') }.reject(&:empty?)
          return if given.empty? || given.include?(digest)

          raise Operator::Failure.new("conflict", "#{target.kind}/#{target.id} changed since the draft was opened", "digest" => digest)
        end

        def rule_ids(doc)
          ids = Array(doc["rules"]).map { |rule| rule.is_a?(Hash) ? rule["id"] : nil }
          (doc["modules"].is_a?(Hash) ? doc["modules"].values : []).each do |body|
            ids.concat(Array(body.is_a?(Hash) ? body["rules"] : nil).map { |rule| rule.is_a?(Hash) ? rule["id"] : nil })
          end
          ids.compact.map(&:to_s)
        end

        def structural_gate!(kind, old_doc, new_doc)
          return unless %w[reorder regroup].include?(kind)

          unless rule_ids(old_doc).sort == rule_ids(new_doc).sort
            raise Operator::Failure.new("invalid", "a #{kind} must not add or remove rules; use replace for that")
          end
          return unless kind == "reorder"

          rest = ->(doc) { doc.reject { |key, _| key == "rules" } }
          raise Operator::Failure.new("invalid", "a reorder changes only the order of the rules") unless rest.call(old_doc) == rest.call(new_doc)
        end

        def lines_of(text)
          text.to_s.lines.map(&:chomp)
        end

        def section_of(lines, name)
          header = lines.index { |line| line.match?(/\A#{Regexp.escape(name)}:(\s|\z)/) }
          return nil unless header

          inline = lines[header].match?(/\A#{Regexp.escape(name)}:\s*\[\s*\]\s*(#.*)?\z/)
          stop = ((header + 1)...lines.length).find { |index| line = lines[index]; !line.strip.empty? && !line.start_with?(" ", "\t", "-", "#") } || lines.length
          stop -= 1 while stop > header + 1 && lines[stop - 1].strip.empty?
          starts = ((header + 1)...stop).select { |index| lines[index].match?(/\A\s*- /) }
          indent = starts.map { |index| lines[index][/\A\s*/].length }.min
          starts = starts.select { |index| lines[index][/\A\s*/].length == indent }
          items = starts.each_with_index.map { |start, at| [start, at + 1 < starts.length ? starts[at + 1] : stop] }
          Section.new(header, stop, items, inline)
        end

        def item_id(name, chunk)
          text = chunk.join("\n")
          return text[/\bid:\s*["']?([A-Za-z0-9_.:-]+)/, 1] if name == "rules"

          text[/\bmodule:\s*["']?([a-z0-9-]+)/, 1] || text[/\A\s*-\s+["']?([a-z0-9-]+)["']?\s*\z/, 1]
        end

        def find_item(lines, name, id)
          section = section_of(lines, name)
          return nil unless section

          found = section.items.find { |start, stop| item_id(name, lines[start...stop]) == id }
          found ? [section, found] : nil
        end

        def remove_item(text, name, id)
          lines = lines_of(text)
          found = find_item(lines, name, id)
          raise Operator::Failure.new("unknown_item", "#{id} is not in #{name}") unless found

          _section, (start, stop) = found
          chunk = lines[start...stop]
          lines.slice!(start...stop)
          rest = section_of(lines, name)
          lines[rest.header] = "#{name}: []" if rest && rest.items.empty? && !rest.inline
          [lines.join("\n") + "\n", chunk]
        end

        def reindent(chunk, indent)
          base = chunk.first[/\A\s*/].length
          chunk.map { |line| line.strip.empty? ? line : "#{' ' * indent}#{line[base..]}" }
        end

        def insert_item(text, name, chunk, position)
          lines = lines_of(text)
          section = section_of(lines, name)
          if section.nil?
            lines << "" unless lines.empty? || lines.last.strip.empty?
            lines << "#{name}:"
            lines.concat(reindent(chunk, 2))
            return lines.join("\n") + "\n"
          end

          indent = section.items.empty? ? 2 : lines[section.items.first[0]][/\A\s*/].length
          fresh = reindent(chunk, indent)
          if section.inline
            lines[section.header] = "#{name}:"
            lines.insert(section.header + 1, *fresh)
            return lines.join("\n") + "\n"
          end

          at = section.stop
          where = position.is_a?(Hash) ? position["where"].to_s : "end"
          anchor = position.is_a?(Hash) ? position["rule"].to_s : ""
          if %w[before after].include?(where) && !anchor.empty?
            target = section.items.find { |start, stop| item_id(name, lines[start...stop]) == anchor }
            raise Operator::Failure.new("unknown_item", "#{anchor} is not in #{name}") unless target

            at = where == "before" ? target[0] : target[1]
          end
          lines.insert(at, *fresh)
          lines.join("\n") + "\n"
        end

        def upsert_include(text, name, with, remove)
          lines = lines_of(text)
          found = find_item(lines, "includes", name)
          if remove
            raise Operator::Failure.new("unknown_item", "#{name} is not included") unless found

            return remove_item(text, "includes", name).first
          end

          entry = with.empty? ? ["  - #{name}"] : ["  - { module: #{name}, with: #{JSON.generate(with)} }"]
          if found
            _section, (start, stop) = found
            lines.slice!(start...stop)
            lines.insert(start, *entry)
            return lines.join("\n") + "\n"
          end

          anchor = lines.index { |line| line.match?(/\Arules:(\s|\z)/) } || lines.length
          if section_of(lines, "includes")
            insert_item(text, "includes", entry, nil)
          else
            lines.insert(anchor, "includes:", *entry)
            lines.join("\n") + "\n"
          end
        end

        def example_files(name)
          dir = File.join(ROOT, "examples")
          single = File.join(dir, "policy.#{name}.yml")
          return { policy: single, environments: File.join(dir, "environments.#{name}.yml") } if File.file?(single)

          folder = File.join(dir, name, "policy.yml")
          return { policy: folder, environments: File.join(dir, name, "environments.yml") } if File.file?(folder)

          raise Operator::Failure.new("unknown_item", "no example named #{name}")
        end

        def prepare(target, change)
          unless target.is_a?(Hash) && change.is_a?(Hash)
            raise Operator::Failure.new("invalid", "target and change are required")
          end

          return [prepare_ledger(target, change)] if target["kind"].to_s == "ledger"
          return prepare_move(target, change) if change["kind"].to_s == "move"

          [prepare_edit(target, change)]
        end

        def prepare_edit(target, change)
          kind = change["kind"].to_s
          unless %w[replace compose reorder regroup].include?(kind)
            raise Operator::Failure.new("unsupported_change", "unsupported change kind #{kind.empty? ? '(none)' : kind}")
          end

          if kind == "compose" && change["compose"].is_a?(Hash) && change["compose"]["package"]
            return prepare_package(target, change["compose"])
          end

          tgt = resolve_target(target["kind"], target["id"])
          old_text = current_text(tgt)
          base_gate!(tgt, change)
          extra = {}
          text = case kind
                 when "compose" then compose_text(tgt, change, old_text, extra)
                 else change["yaml"].to_s
                 end
          text += "\n" unless text.end_with?("\n")
          finish_edit(tgt, kind, text, old_text, extra)
        end

        def finish_edit(tgt, kind, text, old_text, extra = {})
          doc = validated(tgt, text)
          description_gate!(old_text, doc)
          structural_gate!(kind, parse_yaml(old_text), doc) if old_text && %w[reorder regroup].include?(kind)
          files = { tgt.file => text }
          extra.each { |path, body| files[path] = body }
          ref = commit_files(tgt.repo, tgt.ref, files)
          spec = if tgt.scope == :project
                   Plan::SPEC.new(kind: :project, id: tgt.id, from: ref)
                 else
                   Plan::SPEC.new(kind: :global, from: ref)
                 end
          Prepared.new(spec: spec, target: tgt, repo: tgt.repo, ref: ref, project_id: tgt.project&.id, force: tgt.scope == :global || TYPED_KINDS.include?(kind), change_kind: kind, file: tgt.file)
        end

        def compose_text(tgt, change, old_text, extra)
          compose = change["compose"]
          raise Operator::Failure.new("invalid", "compose needs a module, package or example name") unless compose.is_a?(Hash)

          with = compose["with"].is_a?(Hash) ? compose["with"] : {}
          return example_text(tgt, compose["example"].to_s, extra) if compose["example"]

          name = compose["module"].to_s
          raise Operator::Failure.new("invalid", "compose needs a module, package or example name") if name.empty?

          base = change["yaml"].is_a?(String) && !change["yaml"].strip.empty? ? change["yaml"] : old_text
          raise Operator::Failure.new("policy_missing", "#{tgt.file} is not on #{tgt.ref}") if base.nil?

          upsert_include(base, name, with, compose["remove"] == true)
        end

        def example_text(tgt, name, extra)
          raise Operator::Failure.new("invalid", "an example composes into a project policy only") unless tgt.scope == :project

          files = example_files(name)
          policy = File.read(files[:policy]).sub(/^project:.*$/, "project: #{JSON.generate(tgt.id)}")
          if File.file?(files[:environments])
            dir = File.dirname(tgt.file)
            relative = File.basename(Environments.path_for(tgt.file))
            extra[dir == "." ? relative : "#{dir}/#{relative}"] = File.read(files[:environments])
          end
          policy
        end

        def prepare_package(target, compose)
          raise Operator::Failure.new("invalid", "a package composes into a project") unless target["kind"].to_s == "project"

          project = ledger.project(target["id"].to_s)
          raise Operator::Failure.new("unknown_project", "#{target['id']} is not in the ledger") unless project

          with = compose["with"].is_a?(Hash) ? compose["with"].each_with_object({}) { |(key, value), memo| memo[key.to_s] = value } : {}
          variant = with.delete("variant")
          params = with.each_with_object({}) { |(key, value), memo| memo[key] = value.is_a?(String) ? value : JSON.generate(value) }
          spec = Plan::SPEC.new(kind: :package, package: compose["package"].to_s, repo: File.expand_path(project.repo), variant: variant&.to_s, params: params)
          Prepared.new(spec: spec, target: nil, repo: nil, ref: nil, project_id: project.id, force: false, change_kind: "compose", file: nil)
        end

        def prepare_move(target, change)
          item = change["item"]
          from = change["from"].is_a?(Hash) ? change["from"] : target
          to = change["to"]
          raise Operator::Failure.new("invalid", "a move needs item, from and to") unless item.is_a?(Hash) && to.is_a?(Hash)

          type = item["type"].to_s
          name = { "rule" => "rules", "module" => "includes" }[type]
          raise Operator::Failure.new("unsupported_change", "a move relocates a rule or a module include") unless name

          source = resolve_target(from["kind"], from["id"])
          destination = move_destination(source, to)
          if source.repo == destination.repo
            raise Operator::Failure.new("unsupported_change", "the source and the destination share a repository; plan each side with replace")
          end

          source_text = current_text(source)
          removed, chunk = remove_item(source_text, name, item["id"].to_s)
          destination_text = current_text(destination)
          if find_item(lines_of(destination_text), name, item["id"].to_s)
            raise Operator::Failure.new("id_collision", "#{item['id']} already exists in #{destination.kind} #{destination.id}")
          end

          inserted = insert_item(destination_text, name, chunk, to["position"])
          first = finish_edit(destination, "move", inserted, destination_text)
          second = finish_edit(source, "move", removed, source_text)
          first.force = true
          second.force = true
          [first, second]
        rescue Operator::Failure
          [first, second].compact.each { |prepared| drop_ref(prepared.repo, prepared.ref) }
          raise
        end

        def move_destination(source, to)
          case to["scope"].to_s
          when "global" then resolve_target("global", "global")
          when "project"
            raise Operator::Failure.new("invalid", "a move to a project names the project") if to["project"].to_s.empty?

            resolve_target("project", to["project"])
          when "local"
            id = to["project"].to_s.empty? && source.kind == "project" ? source.id : to["project"].to_s
            raise Operator::Failure.new("invalid", "a project-local move names the project") if id.empty?

            resolve_target("project", id)
          else raise Operator::Failure.new("invalid", "a move goes to the local, global or project scope")
          end.tap do |destination|
            if destination.kind == source.kind && destination.id == source.id
              raise Operator::Failure.new("invalid", "the destination is the source; use reorder")
            end
          end
        end

        def prepare_ledger(target, change)
          unless change["kind"].to_s == "status"
            raise Operator::Failure.new("unsupported_change", "a ledger change is a status change")
          end

          id = change["id"].to_s
          status = change["status"].to_s
          raise Operator::Failure.new("invalid", "status must be one of #{STATUSES.join(', ')}") unless STATUSES.include?(status)

          current = ledger
          raise Operator::Failure.new("unknown_entry", "#{id} is not in the ledger") unless current.entry(id)

          text = Registration.current_text(current)
          edited = set_status(text, id, status)
          raise Operator::Failure.new("ledger_edit_unsupported", "could not set the status of #{id} in #{current.path}") unless edited

          Registration.validated(edited, current.path)
          file = proposal_file(edited, "status-#{id}-#{label}")
          Prepared.new(spec: Plan::SPEC.new(kind: :ledger, file: file), target: nil, repo: nil, ref: nil, project_id: nil, force: true, change_kind: "status", file: file)
        end

        def set_status(text, id, status)
          rows = text.lines
          start = rows.index { |line| line.match?(/\A  - id: #{Regexp.escape(id)}\s*\z/) }
          return nil if start.nil?

          stop = ((start + 1)...rows.length).find { |index| rows[index].match?(/\A  - /) || (!rows[index].strip.empty? && !rows[index].start_with?(" ", "\t")) } || rows.length
          at = (start...stop).find { |index| rows[index].match?(/\A    status:/) }
          return nil if at.nil?

          rows[at] = "    status: #{status}\n"
          rows.join
        end

        def register_preview(body, dry: false)
          synchronize { with_actor { register_preview_locked(body, dry: dry) } }
        end

        def register_preview_locked(body, dry: false)
          raise Operator::Failure.new("invalid", "path, kind and id are required") unless body.is_a?(Hash) && body["path"].is_a?(String)

          current = ledger
          description = body["description"].is_a?(String) ? body["description"] : nil
          id, text = Registration.propose_register(current, body["path"], id: body["id"].to_s.empty? ? nil : body["id"].to_s, kind: body["kind"].to_s.empty? ? "directory" : body["kind"].to_s, description: description, dry: dry)
          entry = Registration.entry_lines(id: id, kind: body["kind"].to_s.empty? ? "directory" : body["kind"].to_s, path: File.expand_path(body["path"]), description: description)
          { id: id, text: text, yaml: "paths:\n#{entry.join("\n")}\n", description: description }
        end

        def register_plan(body, dry: false)
          synchronize do
            with_actor do
              preview = register_preview_locked(body, dry: dry)
              file = Registration.proposal_file(preview[:id], preview[:text])
              prepared = Prepared.new(spec: Plan::SPEC.new(kind: :ledger, file: file), target: nil, repo: nil, ref: nil, project_id: nil, force: false, change_kind: "register", file: file)
              [preview, store(build_record(prepared))]
            end
          end
        end

        def build_record(prepared)
          plan = Plan.build(prepared.spec)
          data = plan.data
          Record.new(plan_id: data["plan_id"], spec: prepared.spec, repo: prepared.repo, ref: prepared.ref, file: prepared.file, project_id: prepared.project_id,
                     force: prepared.force || data["needs_confirm"] == true, change_kind: prepared.change_kind, requires: nil, applied: false, data: data,
                     created: Time.now.to_i, target_label: data["target"], trust_ref: prepared.target&.project&.trust_ref)
        rescue StandardError
          drop_ref(prepared.repo, prepared.ref)
          raise
        end

        def store(record)
          @records[record.plan_id] = record
          @order.delete(record.plan_id)
          @order << record.plan_id
          while @order.length > MAX_RECORDS
            old = @records.delete(@order.shift)
            drop_ref(old.repo, old.ref) if old && !old.applied
          end
          record
        end

        def create(target, change)
          synchronize do
            prune_once
            prepared = with_actor { prepare(target, change) }
            records = []
            begin
              prepared.each { |item| records << with_actor { build_record(item) } }
            rescue StandardError
              prepared.each { |item| drop_ref(item.repo, item.ref) }
              raise
            end
            records[1].requires = records[0].plan_id if records.length == 2
            records.each { |record| store(record) }
            records
          end
        end

        def fetch(plan_id)
          synchronize { @records[plan_id.to_s] }
        end

        def active_sessions
          Sessions.active(3600)
        rescue StandardError
          []
        end

        def effects_payload(effects, project_id)
          sessions = active_sessions
          payload = {}
          %w[next_call new_session reload trust].each do |name|
            entry = Array(effects).find { |item| item["class"] == name }
            unless entry
              payload[name] = { "affected" => false, "count" => 0, "sessions" => [] }
              next
            end

            reached = sessions
            if name == "new_session" && project_id
              reached = sessions.select { |session| session["projects"].is_a?(Hash) && session["projects"].key?(project_id) }
            end
            ids = reached.map { |session| session["session_id"] }
            payload[name] = { "affected" => true, "count" => ids.length, "sessions" => ids, "scope" => entry["scope"] }
          end
          payload
        end

        def sealed?
          require_relative "../harness_controls/plane"
          HarnessControls::Plane.resolve["status"] == "active"
        rescue StandardError
          false
        end

        def present(record)
          data = record.data
          needs = data["needs_confirm"] == true || record.force == true
          reasons = data["reasons"].dup
          reasons << "#{record.change_kind} changes need the plan id typed" if record.force && data["needs_confirm"] != true && !reasons.include?("#{record.change_kind} changes need the plan id typed")
          sessions = effects_payload(data["effects"], record.project_id)
          operator_only = sealed? && %w[ledger global].include?(record.spec.kind.to_s)
          out = {
            "plan_id" => record.plan_id, "target" => data["target"], "classification" => data["classification"], "needs_confirm" => needs, "reasons" => reasons,
            "files" => data["files"].map { |file| file.slice("path", "action", "diff", "digest") }, "ledger" => data["ledger"], "policy_diff" => data["policy_diff"],
            "probes" => data["probes"].map { |row| row.merge("env" => row["probe"].to_s[/\(([^()]+)\)\z/, 1]) }, "journal" => data["journal"],
            "effects" => sessions, "active_sessions" => sessions.values.map { |entry| entry["count"] }.max.to_i, "notes" => data["notes"],
            "operator_only" => operator_only, "applied" => record.applied == true, "change_kind" => record.change_kind
          }
          out["operator_command"] = "polispec plane status" if operator_only
          out["repo"] = record.repo if record.repo
          out["requires"] = record.requires if record.requires
          out
        end

        def apply_args(record)
          spec = record.spec
          base = case spec.kind
                 when :project then ["project:#{spec.id}", "--from", spec.from]
                 when :global then ["global", "--from", spec.from]
                 when :ledger then ["ledger", "--from", spec.file]
                 else
                   list = [spec.package, "--repo", spec.repo]
                   list.push("--variant", spec.variant) if spec.variant
                   Hash(spec.params).each { |key, value| list.push("--param", "#{key}=#{value}") }
                   list
                 end
          base + ["--confirm", record.plan_id, "--json"]
        end

        def capture
          out = StringIO.new
          err = StringIO.new
          previous = [$stdout, $stderr]
          $stdout = out
          $stderr = err
          status = yield
          [status, out.string, err.string]
        ensure
          $stdout, $stderr = previous
        end

        def parse_report(text)
          text.lines.reverse.each do |line|
            parsed = JSON.parse(line)
            return parsed if parsed.is_a?(Hash)
          rescue JSON::ParserError
            next
          end
          nil
        end

        def gate!(record, confirm)
          needs = record.force == true
          given = confirm.to_s
          if given.empty?
            raise Operator::Failure.new("confirm_required", "this plan needs its id typed: send confirm #{record.plan_id}", "plan_id" => record.plan_id) if needs
          elsif given != record.plan_id
            if PLAN_ID.match?(given)
              raise Operator::Failure.new("plan_changed", "the plan changed since #{given}; it is #{record.plan_id}", "plan_id" => record.plan_id)
            end

            raise Operator::Failure.new("confirm_required", "the confirmation does not match the plan id", "plan_id" => record.plan_id)
          end
        end

        def apply(plan_id, confirm)
          synchronize do
            record = @records[plan_id.to_s]
            raise Operator::Failure.new("unknown_plan", "no plan #{plan_id}; create it again") unless record
            raise Operator::Failure.new("conflict", "plan #{plan_id} is already applied") if record.applied

            if record.requires
              first = @records[record.requires]
              raise Operator::Failure.new("conflict", "apply the destination plan #{record.requires} first", "plan_id" => record.requires) unless first && first.applied
            end
            gate!(record, confirm)
            main_gate!(record)
            if sealed? && %w[ledger global].include?(record.spec.kind.to_s)
              raise Operator::Failure.new("sealed_authority", "the sealed plane owns the global layer and the ledger; change the sealed source and reseal")
            end

            with_actor { run_apply(record) }
          end
        end

        def main_gate!(record)
          return unless record.spec.kind == :project && record.trust_ref && record.trust_ref != "main"

          Array(record.data["files"]).each do |file|
            next unless %w[add replace].include?(file["action"])

            on_main = git_read(record.repo, "show", "main:#{file['path']}")
            on_trust = git_read(record.repo, "show", "#{record.trust_ref}:#{file['path']}")
            next if on_main.nil? || on_main == on_trust || sha(on_main) == file["digest"]

            raise Operator::Failure.new("conflict", "main holds unpromoted changes to #{file['path']}; promote or reconcile them before applying", "path" => file["path"])
          end
        end

        def run_apply(record)
          before = Changes.epoch
          status, out, err = capture { ApplyCommand.run(apply_args(record)) }
          report = parse_report(out)
          unless status == 0 && report && report["ok"] != false
            failure = report && report["error"].is_a?(Hash) ? report["error"] : nil
            raise Operator::Failure.new(failure ? failure["code"] : "apply_failed", failure ? failure["message"] : (err.strip.empty? ? "apply failed" : err.strip), failure ? failure["payload"] || {} : {})
          end

          record.applied = true
          drop_ref(record.repo, record.ref)
          after = Changes.epoch
          change = Changes.records.reverse.find { |item| item["kind"] == "apply" && item.dig("subject", "plan_id") == record.plan_id }
          result = {
            "plan_id" => record.plan_id, "commit" => head_commit(record), "change_id" => change && change["id"], "epoch_before" => change ? change["epoch_before"] : before,
            "epoch_after" => change ? change["epoch_after"] : after, "committed" => Array(report["committed"])
          }
          command = promotion_command(record)
          result["operator_command"] = command if command
          result
        end

        def head_commit(record)
          return nil unless record.repo

          Environments.git(record.repo, "rev-parse", "HEAD").to_s.strip
        end

        def promotion_command(record)
          return nil unless record.project_id && record.trust_ref && record.trust_ref != "main"

          "polispec promote #{record.project_id} --to stable"
        end

        def preview(target, change)
          synchronize do
            prepared = with_actor { prepare(target, change) }
            begin
              prepared.map { |item| Plan.build(item.spec).data }
            ensure
              prepared.each { |item| drop_ref(item.repo, item.ref) }
            end
          end
        end

        def blast(target, change)
          datas = preview(target, change)
          rows = datas.flat_map { |data| data["journal"] }
          projects = rows.group_by { |row| row["project"] }.map do |project, list|
            weight = ->(row) { row["probe"].to_s[/ x(\d+)\z/, 1].to_i.nonzero? || 1 }
            sum = ->(selector) { list.select(&selector).map(&weight).inject(0, :+) }
            moved = list.reject { |row| row["change"] == "same" }
            flip = moved.find { |row| row["change"] == "loosen" } || moved.first
            {
              "project" => project, "replayed" => list.map(&weight).inject(0, :+), "stricter" => sum.call(->(row) { row["change"] == "tighten" }),
              "looser" => sum.call(->(row) { row["change"] == "loosen" }), "unchanged" => sum.call(->(row) { row["change"] == "same" }),
              "largest_flip" => flip ? "#{flip['probe'].to_s.sub(/ x\d+\z/, '')}: #{flip['before']} -> #{flip['after']}" : nil
            }
          end
          { "days" => Judgments::WINDOW_SECONDS / 86_400, "rows_replayed" => projects.map { |item| item["replayed"] }.inject(0, :+), "projects" => projects.sort_by { |item| item["project"].to_s } }
        end

        def author_target(context)
          file = context[:target_file].to_s
          if file.include?("/")
            kind, id = file.split("/", 2)
            return { "kind" => kind, "id" => id }
          end
          project = context[:project].to_s
          project.empty? ? nil : { "kind" => "project", "id" => project }
        end

        def author_planner
          lambda do |kind:, yaml:, doc:, context:|
            target = author_target(context)
            next nil unless target

            data = preview(target, { "kind" => "replace", "yaml" => yaml }).first
            changed = data["probes"].reject { |row| row["change"] == "same" }.length
            { classification: data["classification"], needs_confirm: data["needs_confirm"] == true, reasons: data["reasons"].first(6), probes_changed: changed, target: data["target"] }
          end
        end
      end
    end
  end
end
