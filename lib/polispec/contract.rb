#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "json"
require "time"
require "fileutils"
require "open3"
require "shellwords"
require "digest"
require_relative "canonical"
require_relative "chain"
require_relative "behavior"

module Polispec
  module Contract
    SCHEMA = "polispec.contract/v1"
    COMPILED = "polispec.contract.compiled/v1"
    DIR = "specs/polispec/contracts"
    VOCABULARY = "vocabulary.yml"
    APPROVALS = "approvals.jsonl"
    FLOOR = [0, 43, 0].freeze
    RUNNER_TIMEOUT = 30
    STRENGTH = { "deny" => 4, "block" => 3, "reroute" => 2, "report" => 1, "instruct" => 0 }.freeze
    LIFECYCLE_RANK = { "draft" => 0, "advise" => 1, "enforce" => 2 }.freeze
    Finding = Struct.new(:severity, :code, :contract, :message) do
      def to_h
        { "severity" => severity, "code" => code, "contract" => contract, "message" => message }
      end

      def error?
        severity == "error"
      end
    end

    module_function

    def finding(severity, code, contract, message)
      Finding.new(severity, code, contract, message)
    end

    def load(path)
      Schema::Document.load(path)
    end

    def contract?(data)
      data.is_a?(Hash) && data["schema"] == SCHEMA
    end

    def files(path)
      return [File.expand_path(path)] if File.file?(path)
      raise Polispec::Error, "#{path} is not a contract file or directory" unless File.directory?(path)

      Dir.glob(File.join(File.expand_path(path), "*.yml")).reject { |file| File.basename(file) == VOCABULARY }.sort
    end

    def contract_dir(path)
      File.directory?(path) ? File.expand_path(path) : File.dirname(File.expand_path(path))
    end

    def root_for(path, root = nil)
      return File.expand_path(root) if root

      dir = contract_dir(path)
      found = dir
      found = File.dirname(found) until File.exist?(File.join(found, ".git")) || found == File.dirname(found)
      File.exist?(File.join(found, ".git")) ? found : dir
    end

    def semantic_errors(data)
      errors = []
      seen = {}
      %w[positive negative].each do |kind|
        Array(data.dig("probes", kind)).each_with_index do |probe, index|
          id = probe["id"]
          errors << Schema::Error.new("/probes/#{kind}/#{index}/id", "duplicate probe id #{id}") if seen[id]
          seen[id] = true
        end
      end
      seen = {}
      Array(data["messages"]).each_with_index do |message, index|
        errors << Schema::Error.new("/messages/#{index}/message_id", "duplicate message_id #{message['message_id']}") if seen[message["message_id"]]
        seen[message["message_id"]] = true
        clause_ids = {}
        Array(message["clauses"]).each_with_index do |clause, position|
          errors << Schema::Error.new("/messages/#{index}/clauses/#{position}/id", "duplicate clause id #{clause['id']}") if clause_ids[clause["id"]]
          clause_ids[clause["id"]] = true
        end
      end
      Array(data.dig("precedence", "outranks")).each_with_index do |other, index|
        errors << Schema::Error.new("/precedence/outranks/#{index}", "a contract cannot outrank itself") if other == data["id"]
      end
      errors
    end

    def probes(contract)
      %w[positive negative].flat_map { |kind| Array(contract.dig("probes", kind)).map { |probe| probe.merge("kind" => kind) } }
    end

    def rules_by_id(behavior)
      behavior.fetch("rules").to_h { |rule| [rule["id"], rule] }
    end

    def message_texts(behavior)
      behavior.fetch("messages", {})
    end

    def directive_entry(contract, behavior)
      return nil unless contract["directive"]

      Behavior.directive_index(behavior.fetch("directives"))[contract["directive"]]
    end

    def body_sha(entry)
      return entry.dig("body_ref", "sha256") if entry["body_ref"]

      entry["body"] ? Digest::SHA256.hexdigest(entry["body"]) : nil
    end

    def referenced(contract, behavior)
      return { "directive" => nil, "rules" => [], "messages" => {} } unless behavior

      entry = directive_entry(contract, behavior)
      rules = rules_by_id(behavior)
      texts = message_texts(behavior)
      ids = []
      Array(contract["messages"]).each do |message|
        ids << message["message_id"]
        Array(message["clauses"]).each { |clause| ids << clause["text_ref"] }
      end
      {
        "directive" => entry ? { "row" => entry, "body_sha256" => body_sha(entry) } : nil,
        "rules" => contract["guards"].map { |guard| guard["rule"] }.uniq.sort.filter_map { |id| rules[id] },
        "messages" => ids.uniq.sort.each_with_object({}) { |id, memo| memo[id] = texts[id] if texts[id] }
      }
    end

    def hashed_document(contract)
      doc = Canonical.value(contract)
      doc["behavior"] = doc["behavior"].reject { |key, _| key == "sha256" } if doc["behavior"].is_a?(Hash)
      doc
    end

    def digest(contract, behavior)
      "sha256:#{Canonical.sha256(Canonical.json('contract' => hashed_document(contract), 'referenced' => referenced(contract, behavior)))}"
    end

    def load_behavior(contract, root, label)
      path = contract.dig("behavior", "path").to_s
      return [nil, [finding("error", "contract_ref_missing", label, "behavior path #{path.inspect} must be a repository-relative path without ..")]] unless Schema.safe_relative?(path)

      file = File.join(root, path)
      return [nil, [finding("error", "contract_ref_missing", label, "behavior document #{path} is missing under #{root}")]] unless File.file?(file)

      actual = Digest::SHA256.file(file).hexdigest
      out = []
      out << finding("error", "contract_ref_missing", label, "behavior document #{path} has sha256 #{actual}, the contract declares #{contract.dig('behavior', 'sha256')}") unless actual == contract.dig("behavior", "sha256")
      data = Behavior.load(file)
      return [nil, out << finding("error", "contract_ref_missing", label, "#{path} is not a polispec.behavior/v2 document")] unless Behavior.v2?(data)

      errors = Behavior.validate(data)
      return [nil, out << finding("error", "contract_ref_missing", label, "#{path} does not validate: #{errors.first(3).map { |error| "#{error.pointer} #{error.message}" }.join('; ')}")] unless errors.empty?

      [data, out]
    rescue Schema::Document::ParseError, SystemCallError, Polispec::Error => e
      [nil, out.to_a << finding("error", "contract_ref_missing", label, "cannot read #{path}: #{e.message}")]
    end

    def ref_findings(contract, behavior)
      id = contract["id"]
      out = []
      out << finding("error", "contract_ref_missing", id, "directive #{contract['directive']} is not in the behavior document") if contract["directive"] && directive_entry(contract, behavior).nil?
      rules = rules_by_id(behavior)
      texts = message_texts(behavior)
      harnesses = Array(contract.dig("scope", "harnesses"))
      contract["guards"].each_with_index do |guard, index|
        out << finding("error", "contract_ref_missing", id, "guard rule #{guard['rule']} is not in the behavior document") unless rules.key?(guard["rule"])
        extra = Array(guard["harnesses"]) - harnesses
        out << finding("error", "contract_schema", id, "/guards/#{index}/harnesses #{extra.join(', ')} not in scope.harnesses") if !harnesses.empty? && !extra.empty?
      end
      clause_ids = []
      Array(contract["messages"]).each do |message|
        out << finding("error", "contract_ref_missing", id, "message #{message['message_id']} is not in the behavior document") unless texts.key?(message["message_id"])
        Array(message["clauses"]).each do |clause|
          clause_ids << clause["id"]
          out << finding("error", "contract_ref_missing", id, "clause #{clause['id']} text_ref #{clause['text_ref']} is not a message in the behavior document") unless texts.key?(clause["text_ref"])
        end
      end
      probes(contract).each do |probe|
        (Array(probe.dig("expect", "clauses")) + Array(probe.dig("expect", "hidden"))).each do |clause|
          out << finding("error", "contract_schema", id, "probe #{probe['id']} names clause #{clause} that no message declares") unless clause_ids.include?(clause)
        end
      end
      harnesses.each do |harness|
        runs = contract["guards"].any? { |guard| guard["harnesses"].nil? || guard["harnesses"].include?(harness) }
        out << finding("info", "contract_advisory_on_harness", id, "no guard runs on #{harness}; the contract is advisory there") unless runs
      end
      events = probes(contract).map { |probe| probe["event"] }
      contract["guards"].each do |guard|
        rule = rules[guard["rule"]]
        out << finding("warn", "contract_untested", id, "no probe exercises event #{rule['event']} of guard #{guard['rule']}") if rule && !events.include?(rule["event"])
      end
      out
    end

    def load_vocabulary(path)
      return nil unless path && File.file?(path)

      Schema::Document.load(path)
    end

    def vocabulary_errors(vocabulary)
      Schema.validate("contract-vocabulary", vocabulary)
    end

    def value_ok?(value, type)
      case type
      when "string" then value.is_a?(String)
      when "number" then value.is_a?(Numeric)
      when "boolean" then value == true || value == false
      when "array" then value.is_a?(Array)
      else true
      end
    end

    def predicate_facts(predicate)
      return [] unless predicate.is_a?(Hash)
      return predicate["all"].flat_map { |item| predicate_facts(item) } if predicate["all"]
      return predicate["any"].flat_map { |item| predicate_facts(item) } if predicate["any"]

      [predicate["fact"]]
    end

    def vocabulary_findings(contract, vocabulary)
      id = contract["id"]
      out = []
      locations = vocabulary["locations"]
      if locations
        contract["guards"].each_with_index do |guard, index|
          out << finding("error", "contract_vocabulary", id, "/guards/#{index}/location #{guard['location']} is not in the vocabulary") unless locations.include?(guard["location"])
        end
      end
      declared = vocabulary["annotations"]
      if declared
        notes = contract["annotations"] || {}
        notes.each do |key, value|
          spec = declared[key]
          unless spec
            out << finding("error", "contract_vocabulary", id, "annotation #{key} is not in the vocabulary")
            next
          end
          out << finding("error", "contract_vocabulary", id, "annotation #{key} must be #{spec['type']}") unless value_ok?(value, spec["type"])
          allowed = spec["values"]
          out << finding("error", "contract_vocabulary", id, "annotation #{key} must be one of #{allowed.join(', ')}") if allowed && !(value.is_a?(Array) ? value : [value]).all? { |item| allowed.include?(item) }
        end
        declared.each { |key, spec| out << finding("error", "contract_vocabulary", id, "annotation #{key} is required") if spec["required"] && !notes.key?(key) }
      end
      facts = vocabulary["facts"]
      if facts
        named = []
        Array(contract["messages"]).each { |message| Array(message["clauses"]).each { |clause| named.concat(predicate_facts(clause["shown_when"])) if clause["shown_when"] } }
        probes(contract).each { |probe| (probe["facts"] || {}).each { |name, value| named << name; out.concat(fact_value_findings(id, probe, facts[name], name, value)) } }
        named.uniq.each { |name| out << finding("error", "contract_vocabulary", id, "fact #{name} is not in the vocabulary") unless facts.key?(name) }
      end
      roles = vocabulary.dig("approvals", "roles")
      out.concat(Array(vocabulary.dig("approvals", "required_roles")).reject { |role| roles.nil? || roles.include?(role) }.map { |role| finding("error", "contract_vocabulary", id, "required role #{role} is not in approvals.roles") })
      out
    end

    def fact_value_findings(id, probe, spec, name, value)
      return [] unless spec

      out = []
      out << finding("error", "contract_vocabulary", id, "probe #{probe['id']} fact #{name} must be #{spec['type']}") unless value_ok?(value, spec["type"])
      out << finding("error", "contract_vocabulary", id, "probe #{probe['id']} fact #{name} must be one of #{spec['values'].join(', ')}") if spec["values"] && !spec["values"].include?(value)
      out
    end

    def same?(left, right)
      left.class == right.class && left == right
    end

    def shown?(predicate, facts)
      return true if predicate.nil?
      return predicate["all"].all? { |item| shown?(item, facts) } if predicate.key?("all")
      return predicate["any"].any? { |item| shown?(item, facts) } if predicate.key?("any")

      name = predicate["fact"]
      present = facts.key?(name) && !facts[name].nil?
      return predicate["present"] == present if predicate.key?("present")
      return false unless present
      return same?(facts[name], predicate["equals"]) if predicate.key?("equals")

      predicate["in"].any? { |value| same?(facts[name], value) }
    end

    def message_for(contract, message_id)
      Array(contract["messages"]).find { |message| message["message_id"] == message_id }
    end

    def shown_clauses(contract, message_id, facts)
      message = message_for(contract, message_id)
      return [] unless message

      message["clauses"].select { |clause| shown?(clause["shown_when"], facts) }
    end

    def compose(contract, behavior, message_id, facts)
      message = message_for(contract, message_id)
      return nil unless message

      texts = shown_clauses(contract, message_id, facts).map { |clause| message_texts(behavior).fetch(clause["text_ref"])["text"] }
      message["compose"] == "list" ? texts.map { |text| "- #{text}" }.join("\n") : texts.join(" ")
    end

    def builtin?(contract, behavior)
      rules = rules_by_id(behavior)
      contract["guards"].all? { |guard| rules[guard["rule"]] && rules[guard["rule"]]["mode"] == "declarative" }
    end

    def builtin_outcome(contract, behavior, probe)
      facts = probe["facts"] || {}
      decisions = Behavior.decisions(behavior, probe["event"], facts).select { |decision| decision["missing_facts"].empty? }
      guard = contract["guards"].find { |item| decisions.any? { |decision| decision["rule"] == item["rule"] } }
      decision = guard && decisions.find { |item| item["rule"] == guard["rule"] }
      message_id = decision && decision["message_id"]
      { "verdict" => guard ? guard["decision"] : "allow", "message_id" => message_id,
        "clauses" => message_id ? shown_clauses(contract, message_id, facts).map { |clause| clause["id"] } : [] }
    end

    def subsequence?(wanted, actual)
      position = 0
      wanted.all? do |item|
        found = actual[position..].to_a.index(item)
        position += found + 1 if found
        !found.nil?
      end
    end

    def mismatches(probe, outcome)
      expect = probe["expect"]
      out = []
      out << "verdict #{outcome['verdict'].inspect}, expected #{expect['verdict']}" unless outcome["verdict"] == expect["verdict"]
      out << "message_id #{outcome['message_id'].inspect}, expected #{expect['message_id']}" if expect["message_id"] && outcome["message_id"] != expect["message_id"]
      shown = Array(outcome["clauses"])
      out << "clauses #{shown.inspect} do not include #{expect['clauses'].inspect} in order" if expect["clauses"] && !subsequence?(expect["clauses"], shown)
      hidden = Array(expect["hidden"]) & shown
      out << "clauses #{hidden.inspect} must be hidden" unless hidden.empty?
      out
    end

    def runner_lines(contract, behavior, probes)
      rules = rules_by_id(behavior)
      probes.map do |probe|
        guards = contract["guards"].map { |guard| { "rule" => guard["rule"], "location" => guard["location"], "binding" => rules.dig(guard["rule"], "binding") } }
        JSON.generate("contract" => contract["id"], "version" => contract["version"], "id" => probe["id"], "event" => probe["event"], "facts" => probe["facts"] || {}, "guards" => guards)
      end
    end

    def run_runner(command, requests, root)
      words = Shellwords.split(command.to_s)
      raise Polispec::Error, "the runner command is empty" if words.empty?

      input = requests.map { |request| request[:line] }.join("\n")
      input = "#{input}\n" unless input.empty?
      stdout = stderr = nil
      status = nil
      timed_out = false
      Open3.popen3(*words, chdir: root) do |stdin, out, err, thread|
        writer = Thread.new do
          begin
            stdin.write(input)
          rescue SystemCallError, IOError
            nil
          ensure
            begin
              stdin.close
            rescue IOError
              nil
            end
          end
        end
        readers = [Thread.new { out.read }, Thread.new { err.read }]
        if thread.join(RUNNER_TIMEOUT)
          status = thread.value
        else
          timed_out = true
          Process.kill("KILL", thread.pid) rescue nil
          thread.join
        end
        writer.kill
        stdout, stderr = readers.map { |reader| reader.join(1) && reader.value }
      end
      return requests.to_h { |request| [request, "the runner timed out after #{RUNNER_TIMEOUT} seconds"] } if timed_out
      return requests.to_h { |request| [request, "the runner exited #{status.exitstatus}: #{stderr.to_s.strip[0, 200]}"] } unless status.success?

      parsed = stdout.to_s.lines.map(&:strip).reject(&:empty?).map do |line|
        value = JSON.parse(line)
        value.is_a?(Hash) && value["id"] ? value : nil
      rescue JSON::ParserError
        nil
      end
      requests.to_h do |request|
        reply = parsed.find { |item| item && item["id"] == request[:probe]["id"] && (item["contract"].nil? || item["contract"] == request[:contract]["id"]) }
        [request, reply || "the runner printed no valid line for probe #{request[:probe]['id']}"]
      end
    rescue SystemCallError, Polispec::Error => e
      requests.to_h { |request| [request, "cannot start the runner: #{e.message}"] }
    end

    def probe_findings(entries, runner, root)
      out = []
      pending = []
      entries.each do |contract, behavior|
        enforce = contract["lifecycle"] == "enforce"
        probes(contract).each do |probe|
          if builtin?(contract, behavior)
            outcome = builtin_outcome(contract, behavior, probe)
            mismatches(probe, outcome).each { |detail| out << finding("error", "contract_probe_failed", contract["id"], "probe #{probe['id']}: #{detail}") }
          elsif runner
            pending << { contract: contract, behavior: behavior, probe: probe }
          else
            out << finding(enforce ? "error" : "warn", "contract_probe_unrun", contract["id"], "probe #{probe['id']} needs a native guard and no --runner was given")
          end
        end
      end
      return out if pending.empty?

      requests = pending.map { |item| item.merge(line: runner_lines(item[:contract], item[:behavior], [item[:probe]]).first) }
      run_runner(runner, requests, root).each do |request, reply|
        id = request[:contract]["id"]
        if reply.is_a?(String)
          out << finding("error", "contract_probe_failed", id, "probe #{request[:probe]['id']}: #{reply}")
        else
          outcome = { "verdict" => reply["verdict"], "message_id" => reply["message_id"], "clauses" => reply["clauses"] }
          mismatches(request[:probe], outcome).each { |detail| out << finding("error", "contract_probe_failed", id, "probe #{request[:probe]['id']}: #{detail}") }
        end
      end
      out
    end

    def scopes_overlap?(left, right)
      return false unless left.dig("scope", "application") == right.dig("scope", "application")

      %w[course assignment module step].all? do |key|
        a = left.dig("scope", key)
        b = right.dig("scope", key)
        a.nil? || b.nil? || a == b
      end && begin
        a = Array(left.dig("scope", "harnesses"))
        b = Array(right.dig("scope", "harnesses"))
        a.empty? || b.empty? || !(a & b).empty?
      end
    end

    def triggers_overlap?(left, right)
      left["trigger"].any? do |a|
        right["trigger"].any? do |b|
          kind_a, arg_a = a.split(":", 2)
          kind_b, arg_b = b.split(":", 2)
          next true if a == "always" || b == "always" || kind_a != kind_b
          next true if a == b

          %w[path tool].include?(kind_a) && (File.fnmatch?(arg_a.to_s, arg_b.to_s, File::FNM_EXTGLOB) || File.fnmatch?(arg_b.to_s, arg_a.to_s, File::FNM_EXTGLOB))
        end
      end
    end

    def precedes?(left, right)
      left.dig("precedence", "rank") != right.dig("precedence", "rank") ||
        Array(left.dig("precedence", "outranks")).include?(right["id"]) || Array(right.dig("precedence", "outranks")).include?(left["id"])
    end

    def conflicts(contracts)
      live = contracts.select { |contract| %w[advise enforce].include?(contract["lifecycle"]) }
      out = []
      live.combination(2) do |left, right|
        next unless scopes_overlap?(left, right) && triggers_overlap?(left, right) && !precedes?(left, right)

        clash = left["guards"].product(right["guards"]).find { |a, b| a["location"] == b["location"] && a["decision"] != b["decision"] }
        out << [left, right, clash] if clash
      end
      out
    end

    def conflict_findings(all, selected)
      ids = selected.map { |contract| contract["id"] }
      conflicts(all).filter_map do |left, right, (a, b)|
        next unless ids.include?(left["id"]) || ids.include?(right["id"])

        finding("error", "contract_conflict", left["id"], "#{left['id']} and #{right['id']} overlap at #{a['location']} with decisions #{a['decision']} and #{b['decision']} and neither precedes the other")
      end
    end

    def approvals_path(dir)
      File.join(dir, APPROVALS)
    end

    def approvals(dir)
      path = approvals_path(dir)
      return [] unless File.file?(path)

      File.readlines(path).map(&:strip).reject(&:empty?).map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end

    def approvals_intact?(dir)
      lines = approvals(dir)
      lines.none?(&:nil?) && Chain.broken_at(lines).nil?
    end

    def approval_state(contract, current, dir, vocabulary)
      lines = approvals(dir)
      return [false, "the approval chain in #{APPROVALS} is broken"] unless lines.none?(&:nil?) && Chain.broken_at(lines).nil?

      mine = lines.select { |line| line["contract"] == contract["id"] && line["digest"] == current }
      required = Array(vocabulary && vocabulary.dig("approvals", "required_roles"))
      roles = mine.map { |line| line["role"] }
      missing = required - roles
      return [false, "no approval recorded for digest #{current}"] if mine.empty?
      return [false, "approval from role #{missing.join(', ')} is missing for digest #{current}"] unless missing.empty?

      [true, nil]
    end

    def append_approval(dir, contract, current, actor, role)
      path = approvals_path(dir)
      FileUtils.mkdir_p(dir)
      File.open(path, File::RDWR | File::CREAT, 0o644) do |file|
        file.flock(File::LOCK_EX)
        lines = file.read.lines.map(&:strip).reject(&:empty?).map { |line| JSON.parse(line) }
        raise Polispec::Error, "the approval chain in #{APPROVALS} is broken" unless Chain.broken_at(lines).nil?

        entry = Chain.link({ "contract" => contract["id"], "version" => contract["version"], "digest" => current, "actor" => actor, "role" => role, "at" => Time.now.utc.iso8601 }, lines.last && lines.last["hash"])
        file.seek(0, IO::SEEK_END)
        file.write("#{JSON.generate(entry)}\n")
        entry
      end
    rescue JSON::ParserError
      raise Polispec::Error, "#{APPROVALS} holds a line that is not JSON"
    end

    def surface_ids(contract, behavior)
      entry = directive_entry(contract, behavior)
      names = []
      names.concat([entry["id"], entry["opcode"]].compact) if entry
      Array(contract["messages"]).each do |message|
        names << message["message_id"]
        Array(message["clauses"]).each { |clause| names << clause["text_ref"] }
      end
      behavior.fetch("surfaces", {}).select { |_id, spec| !(Array(spec["refs"]) & names).empty? }.keys
    end

    def drift_items(contract, behavior, root)
      require_relative "surfaces"
      ids = surface_ids(contract, behavior)
      return [] if ids.empty?

      Surfaces.drift(Behavior.compile(behavior, root: root), root: root, surfaces: ids)
    end

    def drift_findings(contract, behavior, root)
      drift_items(contract, behavior, root).map do |item|
        finding("error", "behavior_surface_drift", contract["id"], "surface #{item['surface']} #{item['target']} expected sha256 #{item['expected_sha256']} actual #{item['actual_sha256'] || 'missing'}")
      end
    rescue Polispec::Error, SystemCallError => e
      [finding("warn", "behavior_surface_drift", contract["id"], e.message)]
    end

    def check(path, root: nil, vocabulary: nil, runner: nil)
      require_relative "surfaces"
      dir = contract_dir(path)
      project_root = root_for(path, root)
      out = []
      loaded = []
      all = []
      files(path).each do |file|
        label = File.basename(file)
        begin
          data = load(file)
        rescue Schema::Document::ParseError => e
          out << finding("error", "contract_schema", label, e.message)
          next
        end
        errors = contract?(data) ? Schema.validate("contract", data) : [Schema::Error.new("/schema", "not a #{SCHEMA} document")]
        if errors.empty?
          loaded << data
        else
          errors.each { |error| out << finding("error", "contract_schema", data.is_a?(Hash) && data["id"] ? data["id"] : label, "#{error.pointer.empty? ? '/' : error.pointer} #{error.message}") }
        end
      end
      if File.directory?(path) || loaded.empty?
        all = loaded
      else
        all = Dir.glob(File.join(dir, "*.yml")).reject { |file| File.basename(file) == VOCABULARY }.sort.filter_map do |file|
          data = load(file) rescue nil
          data if contract?(data) && Schema.validate("contract", data).empty?
        end
        all = loaded if all.empty?
      end
      vocab_file = vocabulary || File.join(dir, VOCABULARY)
      vocab = nil
      if File.file?(vocab_file)
        vocab = load_vocabulary(vocab_file)
        errors = vocabulary_errors(vocab)
        errors.each { |error| out << finding("error", "contract_schema", File.basename(vocab_file), "#{error.pointer.empty? ? '/' : error.pointer} #{error.message}") }
        vocab = nil unless errors.empty?
      elsif !loaded.empty?
        out << finding("info", "vocabulary_absent", nil, "no vocabulary file; locations, annotations, and facts are not checked")
      end
      resolved = []
      loaded.each do |contract|
        behavior, found = load_behavior(contract, project_root, contract["id"])
        out.concat(found)
        next unless behavior

        out.concat(ref_findings(contract, behavior))
        out.concat(vocabulary_findings(contract, vocab)) if vocab
        resolved << [contract, behavior]
      end
      out.concat(probe_findings(resolved, runner, project_root))
      out.concat(conflict_findings(all, loaded))
      resolved.each do |contract, behavior|
        out.concat(drift_findings(contract, behavior, project_root))
        next unless contract["lifecycle"] == "enforce"

        ok, reason = approval_state(contract, digest(contract, behavior), dir, vocab)
        out << finding("error", "contract_unapproved", contract["id"], reason) unless ok
      end
      [out, loaded.map { |contract| contract["id"] }]
    end

    def export(path, root: nil)
      dir = contract_dir(path)
      project_root = root_for(path, root)
      rows = files(path).filter_map do |file|
        contract = load(file)
        errors = Schema.validate("contract", contract)
        raise Polispec::Error, "#{File.basename(file)}: #{errors.first.pointer} #{errors.first.message}" unless errors.empty?
        next unless %w[advise enforce].include?(contract["lifecycle"])

        behavior, found = load_behavior(contract, project_root, contract["id"])
        raise Polispec::Error, "#{contract['id']}: #{found.first.message}" unless behavior && found.none?(&:error?)

        current = digest(contract, behavior)
        {
          "id" => contract["id"], "version" => contract["version"], "lifecycle" => contract["lifecycle"], "digest" => current, "document" => contract,
          "behavior_digest" => Behavior.digest(behavior), "behavior_id" => behavior["id"],
          "approvals" => approvals(dir).compact.select { |line| line["contract"] == contract["id"] && line["digest"] == current }
        }
      end
      rows.sort_by { |row| row["id"] }
    end

    def bundle(rows)
      stripped = rows.map { |row| row.reject { |key, _| key == "behavior_id" } }
      { "schema" => COMPILED, "contracts" => stripped, "digest" => "sha256:#{Canonical.sha256(Canonical.json(stripped))}" }
    end

    def bundle_for_surface(compiled, root, refs)
      dir = File.join(root, DIR)
      return bundle([]) unless File.directory?(dir)

      id = compiled.fetch("policy")["id"]
      rows = export(dir, root: root).select { |row| row["behavior_id"] == id }
      unless refs.empty?
        rows = rows.select do |row|
          contract = row["document"]
          names = [contract["directive"]] + Array(contract["messages"]).flat_map { |message| [message["message_id"]] + message["clauses"].map { |clause| clause["text_ref"] } }
          !(refs & names.compact).empty?
        end
      end
      bundle(rows)
    end

    def reference_view(contract, behavior)
      { "document" => hashed_document(contract), "referenced" => referenced(contract, behavior) }
    end

    def classify(old, new, old_behavior, new_behavior)
      tight = []
      loose = []
      neutral = []
      return { "classification" => "tightening", "reasons" => ["contract #{new['id']} added"], "findings" => [] } if old.nil?

      old_rank = LIFECYCLE_RANK[old["lifecycle"]]
      new_rank = LIFECYCLE_RANK[new["lifecycle"]]
      if old["lifecycle"] != new["lifecycle"]
        if new["lifecycle"] == "retired" || (old_rank && new_rank && new_rank < old_rank)
          loose << "lifecycle #{old['lifecycle']} to #{new['lifecycle']}"
        else
          tight << "lifecycle #{old['lifecycle']} to #{new['lifecycle']}"
        end
      end
      old_guards = old["guards"].to_h { |guard| [guard["rule"], guard] }
      new_guards = new["guards"].to_h { |guard| [guard["rule"], guard] }
      (new_guards.keys - old_guards.keys).each { |rule| tight << "guard #{rule} added" }
      (old_guards.keys - new_guards.keys).each { |rule| loose << "guard #{rule} removed" }
      (old_guards.keys & new_guards.keys).each do |rule|
        before = old_guards[rule]
        after = new_guards[rule]
        if STRENGTH[after["decision"]] > STRENGTH[before["decision"]]
          tight << "guard #{rule} decision #{before['decision']} to #{after['decision']}"
        elsif STRENGTH[after["decision"]] < STRENGTH[before["decision"]]
          loose << "guard #{rule} decision #{before['decision']} to #{after['decision']}"
        elsif before != after
          neutral << "guard #{rule} changed"
        end
      end
      old_probes = probes(old).to_h { |probe| [probe["id"], probe] }
      new_probes = probes(new).to_h { |probe| [probe["id"], probe] }
      (new_probes.keys - old_probes.keys).each { |id| (new_probes[id]["kind"] == "negative" ? tight : neutral) << "#{new_probes[id]['kind']} probe #{id} added" }
      (old_probes.keys - new_probes.keys).each { |id| loose << "#{old_probes[id]['kind']} probe #{id} removed" }
      (old_probes.keys & new_probes.keys).each { |id| neutral << "probe #{id} changed" if old_probes[id] != new_probes[id] }
      clause_changes(old, new, tight, loose, neutral)
      findings = []
      before_view = reference_view(old, old_behavior)
      after_view = reference_view(new, new_behavior)
      guard_or_ref_changed = old["guards"] != new["guards"] || before_view["referenced"] != after_view["referenced"] || old["directive"] != new["directive"]
      findings << finding("error", "contract_version_unchanged", new["id"], "guards, rules, or the directive changed and version stays #{new['version']}") if guard_or_ref_changed && old["version"] == new["version"]
      findings << finding("warn", "contract_untested", new["id"], "a guard or the directive changed and no probe was added or changed") if guard_or_ref_changed && old["probes"] == new["probes"]
      if tight.empty? && loose.empty? && before_view != after_view && old["probes"] == new["probes"]
        loose << "contract #{new['id']} changed with no probe evidence"
      end
      neutral << "referenced behavior changed" if before_view["referenced"] != after_view["referenced"] && !neutral.include?("referenced behavior changed")
      kind = if !tight.empty? && !loose.empty? then "mixed"
             elsif !loose.empty? then "loosening"
             elsif !tight.empty? then "tightening"
             else "neutral"
             end
      { "classification" => kind, "reasons" => tight.map { |text| "tighten: #{text}" } + loose.map { |text| "loosen: #{text}" } + neutral.map { |text| "neutral: #{text}" }, "findings" => findings }
    end

    def clause_changes(old, new, tight, loose, neutral)
      before = clause_map(old)
      after = clause_map(new)
      (before.keys & after.keys).each do |key|
        old_when = before[key]["shown_when"]
        new_when = after[key]["shown_when"]
        next if old_when == new_when

        if old_when.nil? || (new_when && new_when["all"] && new_when["all"].include?(old_when))
          tight << "clause #{key} shown_when narrowed"
        elsif new_when.nil? || (old_when["all"] && old_when["all"].include?(new_when))
          loose << "clause #{key} shown_when widened"
        else
          neutral << "clause #{key} shown_when changed"
        end
      end
    end

    def clause_map(contract)
      Array(contract["messages"]).each_with_object({}) do |message, memo|
        message["clauses"].each { |clause| memo["#{message['message_id']}/#{clause['id']}"] = clause }
      end
    end
  end
end
