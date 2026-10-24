require_relative "../contract"
require_relative "../surfaces"
require_relative "../lint"
require_relative "../changes"

module Polispec
  class ContractCommand
    USAGE = <<~TEXT.freeze
      usage: polispec contract check FILE|DIR [--vocabulary FILE] [--runner CMD] [--root DIR] [--format text|json]
             polispec contract render FILE|DIR [--surface ID] [--root DIR] [--write]
             polispec contract digest FILE [--root DIR]
             polispec contract diff FILE|DIR --from REF [--root DIR] [--format text|json]
             polispec contract approve FILE --actor NAME --role ROLE [--root DIR]
             polispec contract export DIR [--out FILE] [--root DIR]
    TEXT
    VALUE_FLAGS = {
      "check" => %w[--vocabulary --runner --root --format],
      "render" => %w[--surface --root],
      "digest" => %w[--root],
      "diff" => %w[--from --root --format],
      "approve" => %w[--actor --role --root],
      "export" => %w[--out --root]
    }.freeze
    BOOLEAN_FLAGS = { "render" => %w[--write] }.freeze

    def run(args)
      args = args.dup
      operation = args.shift
      return usage unless VALUE_FLAGS.key?(operation)

      options = parse(operation, args)
      return usage unless options

      send("run_#{operation}", options)
    rescue JSON::ParserError, SystemCallError, ArgumentError, Schema::Document::ParseError => e
      raise Polispec::Error, e.message
    end

    private

    def usage
      warn USAGE
      2
    end

    def parse(operation, args)
      options = { positional: [] }
      until args.empty?
        arg = args.shift
        if VALUE_FLAGS[operation].include?(arg)
          value = args.shift
          return nil if value.nil? || value.empty?

          options[arg.delete_prefix("--").to_sym] = value
        elsif Array(BOOLEAN_FLAGS[operation]).include?(arg)
          options[arg.delete_prefix("--").to_sym] = true
        elsif arg.start_with?("-")
          return nil
        else
          options[:positional] << arg
        end
      end
      return nil unless options[:positional].length == 1
      return nil if options[:format] && !%w[text json].include?(options[:format])
      return nil if operation == "diff" && !options[:from]
      return nil if operation == "approve" && !(options[:actor] && options[:role])

      options[:path] = options[:positional].first
      options
    end

    def emit(findings, ids, options, label)
      errors = findings.count(&:error?)
      warnings = findings.count { |item| item.severity == "warn" }
      if options[:format] == "json"
        puts JSON.generate("ok" => errors.zero?, "contracts" => ids, "findings" => findings.map(&:to_h))
      else
        findings.each { |item| puts "#{item.severity} #{item.code}#{item.contract ? " #{item.contract}" : ''}: #{item.message}" }
        puts "polispec contract #{label}: #{ids.length} contract#{'s' unless ids.length == 1}, #{errors} error#{'s' unless errors == 1}, #{warnings} warning#{'s' unless warnings == 1}"
      end
      errors.zero? ? 0 : 1
    end

    def run_check(options)
      findings, ids = Contract.check(options[:path], root: options[:root], vocabulary: options[:vocabulary], runner: options[:runner])
      emit(findings, ids, options, "check")
    end

    def load_resolved(path, options)
      root = Contract.root_for(path, options[:root])
      contract = Contract.load(path)
      errors = Contract.contract?(contract) ? Schema.validate("contract", contract) : [Schema::Error.new("/schema", "not a #{Contract::SCHEMA} document")]
      raise Polispec::Error, errors.map { |error| "#{error.pointer} #{error.message}" }.join("; ") unless errors.empty?

      behavior, found = Contract.load_behavior(contract, root, contract["id"])
      raise Polispec::Error, found.map(&:message).join("; ") if behavior.nil?

      [contract, behavior, root, found]
    end

    def run_digest(options)
      return usage unless File.file?(options[:path])

      contract, behavior, = load_resolved(options[:path], options)
      puts Contract.digest(contract, behavior)
      0
    end

    def run_render(options)
      selected = options[:surface]
      pieces = Contract.files(options[:path]).flat_map do |file|
        contract, behavior, root = load_resolved(file, options)
        next [] if %w[draft retired].include?(contract["lifecycle"])

        compiled = Behavior.compile(behavior, root: root)
        ids = Contract.surface_ids(contract, behavior)
        ids &= [selected] if selected
        ids.map { |id| [id, compiled, root] }
      end
      pieces = pieces.uniq { |id, _compiled, root| [id, root] }
      raise Polispec::Error, "no surface references this contract#{" named #{selected}" if selected}" if pieces.empty?
      return usage if pieces.length > 1 && !options[:write] && !selected

      pieces.each do |id, compiled, root|
        text = Surfaces.render(compiled, id, root: root)
        unless options[:write]
          print text
          next
        end

        target = File.join(root, Surfaces.surface(compiled, id).fetch("target"))
        Lint.guard_write!(text, path: target, format: :text)
        FileUtils.mkdir_p(File.dirname(target))
        temp = "#{target}.#{Process.pid}.tmp"
        File.write(temp, text)
        File.rename(temp, target)
        puts "wrote #{target}"
      end
      0
    end

    def run_approve(options)
      return usage unless File.file?(options[:path])

      path = options[:path]
      findings, = Contract.check(path, root: options[:root])
      errors = findings.select(&:error?).reject { |item| %w[contract_unapproved behavior_surface_drift].include?(item.code) }
      unless errors.empty?
        errors.each { |item| warn "#{item.code}#{item.contract ? " #{item.contract}" : ''}: #{item.message}" }
        warn "polispec contract approve: refused, check reports #{errors.length} error#{'s' unless errors.length == 1}"
        return 1
      end
      contract, behavior, = load_resolved(path, options)
      dir = Contract.contract_dir(path)
      vocabulary = Contract.load_vocabulary(File.join(dir, Contract::VOCABULARY))
      roles = vocabulary && vocabulary.dig("approvals", "roles")
      raise Polispec::Error, "role #{options[:role]} is not in the vocabulary approvals.roles" if roles && !roles.include?(options[:role])

      before = Changes.epoch
      current = Contract.digest(contract, behavior)
      entry = Contract.append_approval(dir, contract, current, options[:actor], options[:role])
      Changes.record(kind: "contract_approval", subject: { "contract" => contract["id"], "version" => contract["version"], "digest" => current, "role" => options[:role] }, epoch_before: before, actor: options[:actor], effects: [])
      puts "approved #{contract['id']} #{contract['version']} #{current} as #{options[:role]} (#{entry['hash']})"
      0
    end

    def run_export(options)
      return usage unless File.directory?(options[:path])

      text = JSON.pretty_generate(Contract.bundle(Contract.export(options[:path], root: options[:root]).map { |row| row })).gsub(/\[\n\s*\]/, "[]").gsub(/\{\n\s*\}/, "{}")
      return (puts text; 0) unless options[:out]

      Lint.guard_write!("#{text}\n", path: options[:out], format: :json)
      FileUtils.mkdir_p(File.dirname(File.expand_path(options[:out])))
      File.write(options[:out], "#{text}\n")
      puts "wrote #{options[:out]}"
      0
    end

    def git_show(top, ref, relative)
      Environments.git(top, "show", "#{ref}:#{relative}")
    end

    def run_diff(options)
      path = options[:path]
      dir = Contract.contract_dir(path)
      top = Environments.git(dir, "rev-parse", "--show-toplevel").to_s.strip
      raise Polispec::Error, "#{path} is not in a git repository" if top.empty?

      top = File.realpath(top)
      relative_dir = File.realpath(dir).delete_prefix("#{top}/")
      root = Contract.root_for(path, options[:root])
      names = Contract.files(path).map { |file| File.basename(file) }
      if File.directory?(path)
        listing = Environments.git(top, "ls-tree", "--name-only", options[:from], "#{relative_dir}/").to_s.lines.map { |line| File.basename(line.strip) }
        names |= listing.select { |name| name.end_with?(".yml") && name != Contract::VOCABULARY }
      end
      rows = []
      findings = []
      names.sort.each do |name|
        old_text = git_show(top, options[:from], "#{relative_dir}/#{name}")
        old = old_text && Schema::Document.parse(old_text, "#{options[:from]}:#{name}")
        file = File.join(dir, name)
        new = File.file?(file) ? Contract.load(file) : nil
        if new.nil?
          rows << { "contract" => old["id"], "classification" => "loosening", "reasons" => ["loosen: contract #{old['id']} removed"] }
          next
        end
        errors = Schema.validate("contract", new)
        raise Polispec::Error, "#{name}: #{errors.first.pointer} #{errors.first.message}" unless errors.empty?

        new_behavior, = Contract.load_behavior(new, root, new["id"])
        old_behavior = nil
        if old
          text = git_show(top, options[:from], old.dig("behavior", "path").to_s)
          old_behavior = text && Schema::Document.parse(text, "#{options[:from]}:#{old.dig('behavior', 'path')}")
        end
        result = Contract.classify(old, new, old_behavior, new_behavior)
        findings.concat(result["findings"])
        rows << { "contract" => new["id"], "classification" => result["classification"], "reasons" => result["reasons"] }
      end
      overall = overall_classification(rows.map { |row| row["classification"] })
      if options[:format] == "json"
        puts JSON.generate("ok" => findings.none?(&:error?), "classification" => overall, "contracts" => rows, "findings" => findings.map(&:to_h))
      else
        rows.each do |row|
          puts "#{row['contract']}: #{row['classification']}"
          row["reasons"].each { |reason| puts "  #{reason}" }
        end
        findings.each { |item| puts "#{item.severity} #{item.code} #{item.contract}: #{item.message}" }
        puts "polispec contract diff: #{overall}"
      end
      findings.none?(&:error?) ? 0 : 1
    end

    def overall_classification(kinds)
      tight = kinds.any? { |kind| %w[tightening mixed].include?(kind) }
      loose = kinds.any? { |kind| %w[loosening mixed].include?(kind) }
      return "mixed" if tight && loose
      return "loosening" if loose
      return "tightening" if tight

      "neutral"
    end
  end
end

Polispec::CLI.register("contract", Polispec::ContractCommand, summary: "check, render, digest, diff, approve, and export versioned behavior contracts (polispec.contract/v1)")
