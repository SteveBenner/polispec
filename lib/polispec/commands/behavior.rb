require_relative "../behavior"
require_relative "../packages"
require_relative "../surfaces"
require_relative "../lint"

module Polispec
  class BehaviorCommand
    USAGE = <<~TEXT.freeze
      usage: polispec behavior compile FILE [--out json] [--root DIR]
             polispec behavior export-package NAME
             polispec behavior decide FILE EVENT FACTS.json
             polispec behavior render FILE --surface ID [--root DIR] [--write]
             polispec behavior drift FILE [--root DIR] [--surface ID]... [--json]
             polispec behavior lint FILE [--root DIR] [--corpus GLOB]... [--json]
    TEXT

    def run(args)
      args = args.dup
      operation = args.shift
      path = args.shift
      if operation == "export-package"
        return usage unless path && args.empty?

        return export_package(path)
      end
      return usage unless path && %w[compile decide render drift lint].include?(operation)

      options = parse(args)
      return usage unless options

      case operation
      when "compile" then compile(path, options)
      when "decide" then decide(path, options)
      when "render" then render(path, options)
      when "drift" then drift(path, options)
      else lint(path, options)
      end
    rescue JSON::ParserError, SystemCallError, ArgumentError => e
      raise Polispec::Error, e.message
    end

    private

    def usage
      warn USAGE
      2
    end

    def parse(args)
      options = { surfaces: [], corpus: [], positional: [] }
      until args.empty?
        arg = args.shift
        case arg
        when "--json" then options[:json] = true
        when "--write" then options[:write] = true
        when "--root" then options[:root] = args.shift
        when "--surface" then options[:surfaces] << args.shift
        when "--corpus" then options[:corpus] << args.shift
        when "--out" then options[:out] = args.shift
        else options[:positional] << arg
        end
      end
      return nil if options[:root] == "" || options[:surfaces].any? { |value| value.nil? || value.empty? } || options[:corpus].any? { |value| value.nil? || value.empty? }
      return nil if options.key?(:out) && options[:out] != "json"

      options
    end

    def root_for(path, options)
      return File.expand_path(options[:root]) if options[:root]

      dir = File.dirname(File.expand_path(path))
      found = dir
      found = File.dirname(found) until File.exist?(File.join(found, ".git")) || found == File.dirname(found)
      File.exist?(File.join(found, ".git")) ? found : dir
    end

    def compiled_for(path, options)
      Trace.step("compile behavior", path: (Trace.path(File.expand_path(path)) if Trace.on?)) do
        data = Trace.step("load behavior document") { Behavior.load(path) }
        compiled = Behavior.compile(data, root: root_for(path, options))
        if Trace.on?
          policy = compiled["policy"] || {}
          Trace.info("compiled", schema: compiled["schema"], digest: compiled["digest"], directives: Array(policy["directives"]).length, surfaces: policy.fetch("surfaces", {}).length)
        end
        compiled
      end
    end

    def emit(output)
      puts JSON.pretty_generate(output).gsub(/\[\n\s*\]/, "[]").gsub(/\{\n\s*\}/, "{}")
    end

    def compile(path, options)
      return usage unless options[:positional].empty?

      emit(compiled_for(path, options))
      0
    end

    def export_package(name)
      package = Trace.step("find package", package: name) { Packages.find(name) }
      text = package.read("behavior.yml")
      raise Polispec::Error, "package #{name} has no behavior.yml" unless text

      data = Schema::Document.parse(text, "packages/#{name}/behavior.yml")
      if Behavior.v2?(data) && (Array(data["directives"]).any? { |entry| entry.key?("body_ref") } || !data.fetch("surfaces", {}).empty?)
        raise Polispec::Error, "export-package does not support behavior v2 body references or surfaces"
      end
      emit(Behavior.compile(data))
      0
    end

    def decide(path, options)
      return usage unless options[:positional].size == 2

      doc = Trace.step("load behavior document", path: (Trace.path(File.expand_path(path)) if Trace.on?)) { Behavior.load(path) }
      decisions = Trace.step("decide", event: options[:positional][0]) { Behavior.decisions(doc, options[:positional][0], JSON.parse(File.read(options[:positional][1]))) }
      Trace.info("decisions", count: decisions.length)
      emit("digest" => Behavior.digest(doc), "decisions" => decisions)
      0
    end

    def render(path, options)
      return usage unless options[:positional].empty? && options[:surfaces].size == 1

      root = root_for(path, options)
      compiled = compiled_for(path, options)
      surface_id = options[:surfaces].first
      text = Trace.step("render surface", surface: surface_id) { Surfaces.render(compiled, surface_id, root: root) }
      Trace.info("rendered", surface: surface_id, bytes: text.bytesize, sha: Digest::SHA256.hexdigest(text)) if Trace.on?
      unless options[:write]
        print text
        return 0
      end

      target = File.join(root, Surfaces.surface(compiled, surface_id).fetch("target"))
      Trace.step("write surface", path: (Trace.path(target) if Trace.on?)) do
        Lint.guard_write!(text, path: target, format: :text)
        FileUtils.mkdir_p(File.dirname(target))
        temp = "#{target}.#{Process.pid}.tmp"
        File.write(temp, text)
        File.rename(temp, target)
      end
      puts "wrote #{target}"
      0
    end

    def drift(path, options)
      return usage unless options[:positional].empty?

      root = root_for(path, options)
      compiled = compiled_for(path, options)
      found = Trace.step("check drift", surfaces: options[:surfaces]) { Surfaces.drift(compiled, root: root, surfaces: options[:surfaces].empty? ? nil : options[:surfaces]) }
      if Trace.on?
        found.each { |item| Trace.info("drifted", surface: item["surface"], target: item["target"], expected: item["expected_sha256"].to_s[0, 12], actual: item["actual_sha256"].to_s[0, 12]) }
        Trace.info("drift result", drifted: found.length)
      end
      if options[:json]
        puts JSON.generate("ok" => found.empty?, "drift" => found)
      elsif found.empty?
        puts "no drift"
      else
        found.each { |item| puts "drift #{item['surface']} #{item['target']} expected #{item['expected_sha256']} actual #{item['actual_sha256'] || 'missing'}" }
      end
      found.empty? ? 0 : 1
    end

    def lint(path, options)
      return usage unless options[:positional].empty?

      root = root_for(path, options)
      files = options[:corpus].flat_map { |glob| Dir.glob(File.join(root, glob)) }.select { |file| File.file?(file) }.sort.uniq
      compiled = compiled_for(path, options)
      Trace.info("corpus files", count: files.length) if Trace.on?
      found = Trace.step("lint corpus", files: files.length) { Surfaces.lint(compiled, files, root: root) }
      Trace.info("lint result", findings: found.length) if Trace.on?
      if options[:json]
        puts JSON.generate("ok" => found.empty?, "findings" => found)
      elsif found.empty?
        puts "no restatements"
      else
        found.each { |item| puts "#{item['source']}: restates #{item['directive']} (#{item['overlap']}): #{item['sentence']}" }
      end
      found.empty? ? 0 : 1
    end
  end
end

Polispec::CLI.register("behavior", Polispec::BehaviorCommand, summary: "compile v1 or v2 behavior policy, render and drift-check generated surfaces, lint restated rules, evaluate declarative deny rules; never grants authority")
