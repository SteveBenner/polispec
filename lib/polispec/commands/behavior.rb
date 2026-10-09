require_relative "../behavior"

module Polispec
  class BehaviorCommand
    USAGE = "usage: polispec behavior <compile FILE|decide FILE EVENT FACTS.json>"

    def run(args)
      operation, path, *rest = args
      unless path && ((operation == "compile" && rest.empty?) || (operation == "decide" && rest.size == 2))
        warn USAGE
        return 2
      end
      doc = Behavior.load(path)
      output = if operation == "compile"
                 Behavior.compile(doc)
               else
                 { "digest" => Behavior.digest(doc), "decisions" => Behavior.decisions(doc, rest[0], JSON.parse(File.read(rest[1]))) }
               end
      puts JSON.pretty_generate(output)
      0
    rescue JSON::ParserError, SystemCallError, ArgumentError => e
      raise Polispec::Error, e.message
    end
  end
end

Polispec::CLI.register("behavior", Polispec::BehaviorCommand, summary: "compile scoped application policy or evaluate declarative deny rules; never grants authority")
