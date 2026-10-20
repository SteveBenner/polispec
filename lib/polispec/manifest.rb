#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "etc"
require "json"
require "socket"
require "fileutils"
require_relative "operator/git"
require_relative "operator/tty"
require_relative "changes"
require_relative "description"
require_relative "policy_source"
require_relative "probes"
require_relative "commands/doctor"

module Polispec
  module Manifest
    SCHEMA = "polispec.manifest/v1"
    INDEX_SCHEMA = "polispec.index/v1"
    APP_FILE = "polispec.app.yml"
    MANIFEST_FILE = "polispec.manifest.json"
    BADGE_FILE = ".polispec/badge.svg"
    INDEX_DIR = "/var/lib/polispec/index"
    USER_PATTERN = /\A[A-Za-z_][A-Za-z0-9_.-]{0,63}\z/
    COMMIT_MESSAGE = "Update the polispec manifest"
    SUMMARY_LIMIT = 200

    module_function

    def user
      Etc.getpwuid(Process.uid)&.name.to_s
    rescue StandardError
      ""
    end

    def host_short(ledger)
      name = ledger.host.to_s
      name = Socket.gethostname.to_s.split(".").first.to_s if name.empty?
      name.empty? ? "workstation" : name
    rescue StandardError
      "workstation"
    end

    def home_relative(path)
      return nil if path.to_s.empty?

      home = File.expand_path("~")
      expanded = File.expand_path(path.to_s)
      return "~" if expanded == home
      return "~/#{expanded.delete_prefix("#{home}/")}" if expanded.start_with?("#{home}/")

      "~"
    end

    def source_text(value)
      text = value.to_s
      return nil if text.empty?
      return "dir:#{home_relative(text.delete_prefix('dir:'))}" if text.start_with?("dir:")

      text
    end

    def owner_of(entry)
      owner = entry.owner
      return { "uid" => nil, "name" => "unknown" } unless owner.is_a?(Hash) && !owner["name"].to_s.empty?

      { "uid" => owner["uid"].is_a?(Integer) ? owner["uid"] : nil, "name" => owner["name"].to_s }
    end

    def summary_of(description)
      text = description.to_s.strip.gsub(/\s+/, " ")
      return nil if text.empty?

      first = text[/\A.*?[.!?](?=\s|\z)/m] || text
      first.length > SUMMARY_LIMIT ? "#{first[0, SUMMARY_LIMIT - 1]}…" : first
    end

    def badge_url(id)
      "/api/v1/badge/#{id}.svg"
    end

    def for(id, ledger: nil)
      ledger ||= Ledger.load
      project = ledger.project(id)
      return project_manifest(ledger, project) if project

      entry = ledger.path_entry(id)
      return path_manifest(ledger, entry) if entry

      raise Operator::Failure.new("unknown_entry", "#{id} is neither a ledger project nor a registered path")
    end

    def index(ledger: nil)
      ledger ||= Ledger.load
      projects = ledger.projects.reject { |entry| entry.status == "retired" }.map do |project|
        { "id" => project.id, "kind" => "project", "status" => project.status, "owner" => owner_of(project),
          "description" => project.description, "summary" => summary_of(project.description), "policy_digest" => policy_digest(ledger, project) }
      end
      paths = ledger.paths.reject { |entry| entry.status == "retired" }.map do |entry|
        { "id" => entry.id, "kind" => "path", "status" => entry.status, "owner" => owner_of(entry),
          "description" => entry.description, "summary" => summary_of(entry.description), "policy_digest" => nil }
      end
      { "schema" => INDEX_SCHEMA, "user" => user, "host" => host_short(ledger), "generated_at" => Time.now.utc.iso8601, "entries" => projects + paths }
    end

    def policy_digest(ledger, project)
      return nil if project.status == "retired"

      PolicySource.resolve(project, ledger: ledger).digest
    rescue StandardError
      nil
    end

    def project_manifest(ledger, project)
      loaded = project.status == "retired" ? nil : safely { PolicySource.resolve(project, ledger: ledger) }
      declared, declared_errors = declared_for(project)
      manifest = {
        "schema" => SCHEMA, "id" => project.id, "kind" => "project", "status" => project.status, "owner" => owner_of(project),
        "description" => project.description, "host" => host_short(ledger), "edition" => Editions.current.to_s,
        "enforce" => Engine::Settings.enforce_mode.to_s,
        "policy" => { "source" => loaded&.source, "digest" => loaded&.digest, "trust_ref" => project.trust_ref },
        "environments" => environments_for(project, loaded),
        "layers" => layers_for(ledger, project, loaded),
        "roster" => roster_for(project),
        "promotions" => promotions_for(project.id),
        "findings" => findings_for(ledger, project),
        "badge_url" => badge_url(project.id), "declared" => declared
      }
      manifest["declared_errors"] = declared_errors unless declared_errors.empty?
      manifest
    end

    def path_manifest(ledger, entry)
      {
        "schema" => SCHEMA, "id" => entry.id, "kind" => "path", "path_kind" => entry.kind, "path" => home_relative(entry.path),
        "status" => entry.status, "owner" => owner_of(entry), "description" => entry.description, "host" => host_short(ledger),
        "edition" => Editions.current.to_s, "enforce" => Engine::Settings.enforce_mode.to_s,
        "environments" => {}, "layers" => path_layers(ledger, entry), "roster" => {}, "promotions" => {},
        "findings" => group_findings(description_findings(ledger, entry.id)),
        "badge_url" => badge_url(entry.id), "declared" => nil
      }
    end

    def safely
      yield
    rescue StandardError
      nil
    end

    def environments_for(project, loaded)
      policy = loaded&.policy
      return {} unless policy.is_a?(Hash)

      Engine::Envs.environments(policy).each_with_object({}) do |(name, spec), memo|
        next unless spec.is_a?(Hash)

        memo[name.to_s] = { "branch" => spec["branch"], "tier" => spec["tier"], "policy_digest" => loaded.digest }
      end
    end

    def layers_for(ledger, project, loaded)
      chain = safely do
        probe = Probes.resolved(project, ledger)
        probe.chain
      end
      shown = chain ? chain.to_h : {}
      layers = Array(shown["layers"]).map do |row|
        { "layer" => row["layer"], "source" => source_text(row["source"]), "digest" => row["digest"],
          "rules" => row["rules"].to_i, "modules" => Array(row["modules"]).map(&:to_s) }
      end
      packages = project.packages.map do |item|
        { "name" => item["name"], "version" => item["version"], "variant" => item["variant"], "applied_at" => item["applied_at"] }
      end
      { "profile" => shown["profile"], "effective_digest" => shown["effective_digest"], "layers" => layers, "packages" => packages }
    end

    def path_layers(ledger, entry)
      chain = safely { Layers.load(nil, nil, ledger: ledger) }
      rows = chain ? chain.layers.select { |layer| layer.name.to_s.include?(entry.id) } : []
      layers = rows.map do |layer|
        { "layer" => layer.name, "source" => source_text(layer.source), "digest" => layer.digest,
          "rules" => Array(layer.rules).length, "modules" => Array(layer.modules).map(&:to_s) }
      end
      { "profile" => nil, "effective_digest" => nil, "layers" => layers, "packages" => [] }
    end

    def roster_for(project)
      roster = safely { PolicySource.load_roster(project) }
      return {} unless roster.is_a?(Hash) && roster["roles"].is_a?(Hash)

      roster["roles"].each_with_object({}) do |(name, slot), memo|
        next unless slot.is_a?(Hash)

        memo[name.to_s] = (slot["default"].is_a?(Hash) ? slot["default"] : slot).slice("harness", "model", "effort")
      end
    end

    def promotions_for(id)
      rows = State.read_jsonl("promotions").select { |row| row["project"] == id }
      rows.each_with_object({}) do |row, memo|
        memo[row["to"].to_s] = { "tag" => row["tag"], "sha" => row["to_sha"], "at" => row["at"], "actor" => row["actor"] }
      end
    end

    def findings_for(ledger, project)
      list = []
      doctor = DoctorCommand.new
      doctor.send(:check_project, ledger, project, list) if project.status != "retired"
      list.concat(description_findings(ledger, project.id))
      group_findings(list.select { |item| item["project"].nil? || item["project"] == project.id })
    rescue StandardError => e
      group_findings([{ "kind" => "manifest_unchecked", "detail" => "#{e.class}: #{e.message}"[0, 300], "severity" => "info" }])
    end

    def description_findings(ledger, id)
      Description.doctor_findings(ledger).select { |item| item["project"] == id }
    rescue StandardError
      []
    end

    def group_findings(list)
      grouped = { "error" => [], "warn" => [], "info" => [] }
      list.each do |item|
        severity = item["severity"].to_s
        severity = "error" unless %w[warn info].include?(severity)
        grouped[severity] << { "kind" => item["kind"].to_s, "detail" => item["detail"] }
      end
      grouped
    end

    def declared_for(project)
      return [nil, []] if project.status == "retired"

      git = Operator::Git.new(File.expand_path(project.repo))
      text = safely { git.show(project.trust_ref, APP_FILE) }
      return [nil, []] if text.nil?

      data = Schema::Document.parse(text, APP_FILE)
      errors = Schema.validate("app", data)
      return [data, []] if errors.empty?

      [nil, errors.map { |error| "#{error.pointer} #{error.message}".strip }]
    rescue Schema::Document::ParseError => e
      [nil, [e.message]]
    end

    def validate!(kind, data)
      errors = Schema.validate(kind, data)
      return data if errors.empty?

      raise Operator::Failure.new("#{kind}_invalid", "the generated #{kind} does not validate", "problems" => errors.map { |error| "#{error.pointer} #{error.message}".strip })
    end

    def escape(text)
      text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;").gsub("'", "&#39;")
    end

    def badge_svg(manifest)
      left = "polispec"
      right = "#{manifest['status']} · #{manifest['enforce']}"
      left_width = (left.length * 7) + 12
      right_width = (right.length * 7) + 12
      total = left_width + right_width
      label = escape("#{left}: #{right}")
      [
        %(<svg xmlns="http://www.w3.org/2000/svg" width="#{total}" height="20" role="img" aria-label="#{label}">),
        %(<title>#{label}</title>),
        %(<rect width="#{left_width}" height="20" fill="#3b4048"/>),
        %(<rect x="#{left_width}" width="#{right_width}" height="20" fill="#59616d"/>),
        %(<g fill="#ffffff" font-family="Verdana,DejaVu Sans,sans-serif" font-size="11" text-anchor="middle">),
        %(<text x="#{left_width / 2.0}" y="14">#{escape(left)}</text>),
        %(<text x="#{left_width + (right_width / 2.0)}" y="14">#{escape(right)}</text>),
        "</g>",
        "</svg>"
      ].join("\n") + "\n"
    end

    def manifest_json(manifest)
      "#{JSON.pretty_generate(manifest)}\n"
    end

    def write(id, ledger: nil)
      ledger ||= Ledger.load
      project = ledger.project(id)
      unless project
        entry = ledger.path_entry(id)
        raise Operator::Failure.new("not_a_repo", "#{id} is a path entry with no repository; --write needs a ledger project") if entry

        raise Operator::Failure.new("unknown_entry", "#{id} is not in the ledger")
      end
      raise Operator::Failure.new("retired_project", "#{id} is retired") if project.status == "retired"

      repo = File.expand_path(project.repo)
      raise Operator::Failure.new("repo_missing", "#{repo} is not a git checkout") unless File.exist?(File.join(repo, ".git"))

      git = Operator::Git.new(repo)
      branch = git.current_branch
      raise Operator::Failure.new("not_on_main", "HEAD is #{branch || 'detached'}, not main; --write commits on main only", "repo" => repo) unless branch == "main"

      staged = git.run!("diff", "--cached", "--name-only", code: "stage_failed").out.lines.map(&:chomp)
      raise Operator::Failure.new("index_dirty", "the index already has staged changes; commit or unstage them first", "staged" => staged) unless staged.empty?

      before = Changes.epoch
      manifest = validate!("manifest", self.for(id, ledger: ledger))
      paths = [MANIFEST_FILE, BADGE_FILE]
      write_atomic(File.join(repo, MANIFEST_FILE), manifest_json(manifest))
      write_atomic(File.join(repo, BADGE_FILE), badge_svg(manifest))
      git.run!("add", "--", *paths, code: "stage_failed")
      changed = git.run!("diff", "--cached", "--name-only", "--", *paths, code: "stage_failed").out.lines.map(&:chomp)
      return { "id" => id, "committed" => [], "detail" => "the manifest is already current" } if changed.empty?

      git.run!("commit", "--quiet", "-m", COMMIT_MESSAGE, "--", *changed, code: "commit_failed")
      sha = git.rev("HEAD")
      Changes.record(kind: "apply", subject: { "manifest" => id, "action" => "write", "sha" => sha }, epoch_before: before, effects: [])
      { "id" => id, "committed" => changed, "sha" => sha, "detail" => "committed #{changed.join(', ')}" }
    end

    def write_atomic(path, text, mode = nil)
      FileUtils.mkdir_p(File.dirname(path))
      temp = "#{path}.#{Process.pid}.tmp"
      File.write(temp, text)
      File.chmod(mode, temp) if mode
      File.rename(temp, path)
    end

    def index_path(name = user)
      raise Operator::Failure.new("user_invalid", "the current user name #{name.inspect} is not usable as an index file name") unless name.to_s.match?(USER_PATTERN)

      File.join(INDEX_DIR, "#{name}.json")
    end

    def phrase(verb, name = user)
      "#{verb} polispec index for #{name}"
    end

    def require_terminal!(verb)
      return if Operator::Tty.terminal?

      raise Operator::Failure.new("not_tty", "#{verb} polispec index needs an interactive terminal (a TTY on stdin and a controlling console); an agent shell cannot run it")
    end

    def confirm!(verb, name)
      Operator::Tty.confirm!(phrase(verb, name), prompt: "#{verb.capitalize} the polispec index for #{name} at #{index_path(name)}.")
    rescue Operator::Tty::NotTty => e
      raise Operator::Failure.new("not_tty", e.message)
    rescue Operator::Tty::PhraseMismatch => e
      raise Operator::Failure.new("confirmation_failed", e.message)
    end

    def publish(ledger: nil)
      require_terminal!("publish")
      name = user
      target = index_path(name)
      unless File.directory?(INDEX_DIR) && File.writable?(INDEX_DIR)
        raise Operator::Failure.new("index_dir_unavailable", "#{INDEX_DIR} must exist and be writable by #{name}; polispec does not create it", "dir" => INDEX_DIR)
      end

      document = validate!("index", index(ledger: ledger))
      confirm!("publish", name)
      before = Changes.epoch
      write_atomic(target, "#{JSON.pretty_generate(document)}\n", 0o644)
      Changes.record(kind: "apply", subject: { "index" => name, "action" => "publish" }, epoch_before: before, effects: [])
      { "published" => target, "entries" => document["entries"].length }
    end

    def unpublish
      require_terminal!("unpublish")
      name = user
      target = index_path(name)
      raise Operator::Failure.new("not_published", "no index file for #{name} at #{target}", "path" => target) unless File.file?(target)

      confirm!("unpublish", name)
      before = Changes.epoch
      File.delete(target)
      Changes.record(kind: "apply", subject: { "index" => name, "action" => "unpublish" }, epoch_before: before, effects: [])
      { "unpublished" => target }
    end
  end
end
