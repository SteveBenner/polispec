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
      Behavior.compile(Behavior.load(path), root: root_for(path, options))
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
      package = Packages.find(name)
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

      doc = Behavior.load(path)
      emit("digest" => Behavior.digest(doc), "decisions" => Behavior.decisions(doc, options[:positional][0], JSON.parse(File.read(options[:positional][1]))))
      0
    end

    def render(path, options)
      return usage unless options[:positional].empty? && options[:surfaces].size == 1

      root = root_for(path, options)
      compiled = compiled_for(path, options)
      surface_id = options[:surfaces].first
      text = Surfaces.render(compiled, surface_id, root: root)
      unless options[:write]
        print text
        return 0
      end

      target = File.join(root, Surfaces.surface(compiled, surface_id).fetch("target"))
      Lint.guard_write!(text, path: target, format: :text)
      FileUtils.mkdir_p(File.dirname(target))
      temp = "#{target}.#{Process.pid}.tmp"
      File.write(temp, text)
      File.rename(temp, target)
      puts "wrote #{target}"
      0
    end

    def drift(path, options)
      return usage unless options[:positional].empty?

      root = root_for(path, options)
      found = Surfaces.drift(compiled_for(path, options), root: root, surfaces: options[:surfaces].empty? ? nil : options[:surfaces])
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
      found = Surfaces.lint(compiled_for(path, options), files, root: root)
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
