require_relative "../harness_controls/language"
require_relative "../harness_controls/lifecycle"

module Polispec
  class HarnessCommand
    USAGE = "usage: polispec harness grammar|parse|plan|install|verify|uninstall|scan ... [--json]"

    def self.run(args)
      new.run(args)
    end

    def run(arguments)
      json = arguments.include?("--json")
      args = arguments.dup
      json = take_flag!(args, "--json")
      operation = args.shift
      raise_usage unless %w[grammar parse plan install verify uninstall scan].include?(operation)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      data = send("run_#{operation}", args)
      operation_id = data.is_a?(Hash) && data["operation_id"] || operation_id(operation, data)
      result = envelope(true, operation, operation_id, data, findings_from(data))
      render(result, json)
      0
    rescue Usage
      if json
        render(envelope(false, operation || "harness", nil, nil, [finding("usage", USAGE, "cli", "Use the documented command and option order.")]), true)
        2
      else
        usage
      end
    rescue HarnessControls::Language::ParseError => error
      result = envelope(false, operation || "parse", nil, error.to_h, [finding(error.code, error.message, "grammar", "Correct the input at byte offset #{error.offset}; suggestions: #{error.suggestions.join(', ')}")])
      render(result, json)
      1
    rescue HarnessControls::Lifecycle::Failure => error
      result = envelope(false, operation || "harness", nil, error.data, error.findings.empty? ? [finding(error.code, error.message, "lifecycle", "Resolve the reported lifecycle prerequisite and retry.")] : error.findings)
      render(result, json)
      error.exit_status
    rescue Polispec::Error, Psych::Exception, JSON::ParserError, SystemCallError => error
      result = envelope(false, operation || "harness", nil, nil, [finding("operation_failed", error.message, "harness", "Correct the input or prerequisite and retry.")])
      render(result, json)
      1
    end

    private

    def run_grammar(args)
      raise_usage unless args.empty?
      {
        "syntax" => "when agent VERB OBJECT [where KEY = JSON_VALUE [and KEY = JSON_VALUE ...]] then EFFECT [with JSON_OBJECT] [because JSON_STRING]",
        "schedule_syntax" => "when schedule JSON_STRING then verify CONTROL_ID [because JSON_STRING]",
        "verbs" => HarnessControls::Language::VERBS,
        "objects" => HarnessControls::Language::OBJECTS,
        "effects" => HarnessControls::Language::EFFECTS,
        "predicates" => HarnessControls::Language::MATCH_KEYS,
        "pairs" => HarnessControls::Language::PAIRS.map { |pair, action| { "verb" => pair[0], "object" => pair[1], "action" => action } },
        "limits" => { "input_bytes" => HarnessControls::Language::MAX_INPUT_BYTES, "controls" => 256, "hook_input_bytes" => 65_536, "hook_seconds" => 10 },
        "examples" => [
          "when agent write file where path = \"/tmp/polispec-control-fixtures/*\" then deny because \"protect synthetic files\"",
          "when schedule \"*-*-* 04:30:00\" then verify ctl_example"
        ]
      }
    end

    def run_parse(args)
      file = option!(args, "--file")
      if file
        raise_usage unless args.empty?
        text = bounded_read(file)
      else
        raise_usage unless args.length == 1
        text = args.first
      end
      Controls.parse(text)
    end

    def run_plan(args)
      file, context = planning_arguments(args, dry_run: false)
      document = load_document(file)
      HarnessControls::Lifecycle.plan(document, context.delete("harness"), context)
    end

    def run_install(args)
      file, context = planning_arguments(args, dry_run: true)
      dry_run = context.delete("dry_run")
      document = load_document(file)
      planned = HarnessControls::Lifecycle.plan(document, context.delete("harness"), context)
      return { "operation_id" => planned["operation_id"], "dry_run" => true, "plan" => planned, "findings" => planned["findings"] } if dry_run
      unless HarnessControls::Features.enabled?("harness_controls")
        raise HarnessControls::Lifecycle::Failure.new("feature_disabled", "harness mutation remains disabled during construction", exit_status: 3, data: planned)
      end
      HarnessControls::Lifecycle.install(planned, { "scope" => planned["scope"] })
    end

    def run_verify(args)
      raise_usage unless args.length == 1 && valid_id?(args.first)
      result = HarnessControls::Lifecycle.verify(args.first)
      unless result["integrity"] && result["ownership"]
        raise HarnessControls::Lifecycle::Failure.new("verification_failed", "installed artifact integrity or ownership verification failed", data: result, findings: result["findings"])
      end
      if result["requested_edition"] == "lock" && result["certified"] != true
        raise HarnessControls::Lifecycle::Failure.new("lock_prerequisites_unmet", "lock remains inactive because required evidence is incomplete", exit_status: 3, data: result, findings: result["findings"])
      end
      result
    end

    def run_uninstall(args)
      installation_id = args.shift
      raise_usage unless installation_id && valid_id?(installation_id)
      values = strict_options(args, %w[--owner --scope --project --state-home --dry-run])
      owner = values["--owner"]
      scope = values["--scope"]
      project = values["--project"]
      state_home = values["--state-home"]
      dry_run = values["--dry-run"] == true
      raise_usage if !owner && [scope, project, state_home].any?
      if owner
        raise_usage unless %w[user project].include?(scope)
        raise_usage unless state_home.nil? || absolute_path?(state_home)
        if scope == "project"
          raise_usage unless project && absolute_path?(project)
        else
          raise_usage if project
        end
      end
      unless HarnessControls::Features.enabled?("harness_controls")
        raise HarnessControls::Lifecycle::Failure.new("feature_disabled", "harness mutation remains disabled during construction", exit_status: 3) unless dry_run
      end
      HarnessControls::Lifecycle.uninstall(installation_id, owner: owner, scope: scope, project: project && File.expand_path(project), state_home: state_home && File.expand_path(state_home), dry_run: dry_run)
    end

    def run_scan(args)
      harness = option!(args, "--harness")
      raise_usage unless args.empty?
      raise Polispec::Error, "unknown harness backend #{harness}" if harness && !HarnessControls::Backends.names.include?(harness)
      result = HarnessControls::Lifecycle.scan({ "requested_edition" => HarnessControls::Lifecycle.edition })
      result["harness"] = harness if harness
      failed = Array(result["findings"]).find { |row| row.is_a?(Hash) && row["code"] == "environment_scan_failed" }
      raise HarnessControls::Lifecycle::Failure.new("environment_scan_failed", failed["detail"], exit_status: 3, data: result, findings: result["findings"]) if failed
      result
    end

    def planning_arguments(args, dry_run:)
      file = args.shift
      raise_usage unless file && !file.start_with?("--")
      values = strict_options(args, dry_run ? %w[--harness --scope --project --dry-run] : %w[--harness --scope --project])
      harness = values["--harness"]
      scope = values["--scope"]
      raise_usage unless harness && scope && %w[user project managed].include?(scope)
      raise Polispec::Error, "unknown harness backend #{harness}" unless HarnessControls::Backends.names.include?(harness)
      project = values["--project"]
      if scope == "project"
        raise_usage unless project && absolute_path?(project)
      elsif project
        raise_usage
      end
      context = { "harness" => harness, "scope" => scope, "edition" => HarnessControls::Lifecycle.edition }
      context["project"] = File.expand_path(project) if project
      context["dry_run"] = values["--dry-run"] == true if dry_run
      [file, context]
    end

    def strict_options(args, allowed)
      values = {}
      until args.empty?
        option = args.shift
        raise_usage unless allowed.include?(option) && !values.key?(option)
        if option == "--dry-run"
          values[option] = true
        else
          value = args.shift
          raise_usage if value.nil? || value.start_with?("--")
          values[option] = value
        end
      end
      values
    end

    def option!(args, option)
      positions = args.each_index.select { |index| args[index] == option }
      raise_usage if positions.length > 1
      return nil if positions.empty?
      index = positions.first
      value = args[index + 1]
      raise_usage if value.nil? || value.start_with?("--")
      args.slice!(index, 2)
      value
    end

    def take_flag!(args, flag)
      count = args.count(flag)
      raise_usage if count > 1
      args.delete(flag)
      count == 1
    end

    def load_document(path)
      data = YAML.safe_load(bounded_read(path), aliases: false)
      errors = Controls.validate(data)
      unless errors.empty?
        first = errors.first
        raise HarnessControls::Lifecycle::Failure.new("invalid_control", "invalid control document at #{first['pointer']}: #{first['message']}")
      end
      data
    end

    def bounded_read(path)
      content = File.binread(path, HarnessControls::Language::MAX_INPUT_BYTES + 1)
      raise Polispec::Error, "input exceeds #{HarnessControls::Language::MAX_INPUT_BYTES} bytes" if content.bytesize > HarnessControls::Language::MAX_INPUT_BYTES
      raise Polispec::Error, "input is not valid UTF-8" unless content.force_encoding(Encoding::UTF_8).valid_encoding?
      content
    end

    def valid_id?(value)
      value.match?(/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/)
    end

    def absolute_path?(value)
      value.is_a?(String) && value.start_with?("/") && !value.include?("\0")
    end

    def findings_from(data)
      data.is_a?(Hash) ? Array(data["findings"]) : []
    end

    def envelope(ok, operation, operation_id, data, findings)
      { "schema" => "polispec.harness.result/v1", "ok" => ok, "operation" => operation, "operation_id" => operation_id, "edition" => safe_edition, "data" => data, "findings" => findings }
    end

    def safe_edition
      return @edition if instance_variable_defined?(:@edition)
      @edition = HarnessControls::Lifecycle.edition
    rescue StandardError
      @edition = nil
    end

    def operation_id(operation, data)
      "op_#{Digest::SHA256.hexdigest(JSON.generate([operation, canonical(data)]))[0, 24]}"
    end

    def canonical(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
          source = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          result[key] = canonical(value[source])
        end
      when Array
        value.map { |item| canonical(item) }
      else
        value
      end
    end

    def finding(code, detail, capability, next_step)
      { "code" => code, "detail" => detail, "control_id" => nil, "harness" => nil, "capability" => capability, "next_step" => next_step }
    end

    def render(result, json)
      json ? puts(JSON.generate(result)) : puts(JSON.pretty_generate(result))
    end

    def raise_usage
      raise Usage
    end

    class Usage < StandardError; end

    def usage
      warn USAGE
      2
    end
  end
end

Polispec::CLI.register("harness", Polispec::HarnessCommand, summary: "plan, install, verify, uninstall and scan native harness controls")
