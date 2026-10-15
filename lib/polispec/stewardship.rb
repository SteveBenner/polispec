#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "operator/git"

module Polispec
  module Stewardship
    RULE_ID = "polispec-stewardship"
    PLUGIN_ID = "polispec"
    Step = Struct.new(:number, :status, :detail) do
      def line
        "stewardship_#{number}: #{status} #{detail}"
      end

      def to_h
        { "step" => "stewardship_#{number}", "status" => status, "detail" => detail }
      end
    end

    module_function

    def rplugin_bin
      override = ENV["RPLUGIN_BIN"].to_s
      override.empty? ? File.expand_path("~/.rplugin/bin/rplugin") : File.expand_path(override)
    end

    def plugins_home
      value = ENV["RPLUGINS_HOME"].to_s
      File.expand_path(value.empty? ? "~/.rplugins" : value)
    end

    def store_link
      File.join(plugins_home, PLUGIN_ID)
    end

    def ensure!(out: $stdout, quiet: false)
      steps = []
      [[1, method(:rule_step)], [2, method(:runtime_step)], [3, method(:pin_step)]].each do |number, action|
        step = action.call(number)
        steps << step
        out.puts step.line unless quiet
        next unless step.status == "failed"

        raise Operator::Failure.new("stewardship_failed", "stewardship_#{step.number} failed; nothing was applied")
      end
      steps
    end

    def rule_shipped?(root)
      manifest = YAML.safe_load(File.read(File.join(root, "polispec.rplugin.yml")), permitted_classes: [], aliases: false)
      entry = Array(manifest.dig("contents", "rules")).find { |item| item.is_a?(Hash) && item["id"] == RULE_ID }
      entry && entry["path"].is_a?(String) && File.file?(File.join(root, entry["path"]))
    rescue SystemCallError, Psych::Exception, NoMethodError
      false
    end

    def stored_root
      link = store_link
      File.exist?(link) ? File.realpath(link) : nil
    rescue SystemCallError
      nil
    end

    def rule_step(number)
      return Step.new(number, "failed", "the running polispec at #{Runtime.root} does not ship the #{RULE_ID} rule") unless rule_shipped?(Runtime.root)

      stored = stored_root
      return Step.new(number, "ok", "#{RULE_ID} is installed through #{store_link}") if stored && rule_shipped?(stored)

      result = rplugin("install", Runtime.root)
      return Step.new(number, "failed", "rplugin install #{Runtime.root} failed: #{result[:tail]}") unless result[:ok]

      Step.new(number, "installed", "rplugin install #{Runtime.root}")
    end

    def runtime_step(number)
      kind = Runtime.kind
      return Step.new(number, "ok", "R-POLISPEC-RUNTIME protects #{Runtime.root} (runtime #{kind})") if %w[clone pinned].include?(kind)

      Step.new(number, "failed", "the runtime protected root is not active for a #{kind} runtime")
    end

    def pin_step(number)
      return Step.new(number, "ok", "runtime is pinned at #{Runtime.commit.to_s[0, 12]}") if Runtime.pinned?

      tag = "v#{Polispec.version}"
      git = Operator::Git.new(Runtime.root)
      commit = git.rev("refs/tags/#{tag}")
      return Step.new(number, "failed", "tag #{tag} does not exist in #{Runtime.root}") unless commit

      version = git.show(commit, "VERSION").to_s.strip
      return Step.new(number, "failed", "tag #{tag} carries VERSION #{version.empty? ? 'none' : version}, not #{Polispec.version}") unless version == Polispec.version

      stored = stored_root
      if stored && File.basename(stored) == commit && File.basename(File.dirname(File.dirname(stored))) == ".pinned"
        return Step.new(number, "ok", "#{store_link} is already pinned at #{tag} (#{commit[0, 12]})")
      end

      result = rplugin("install", Runtime.root, "--ref", tag)
      return Step.new(number, "failed", "rplugin install #{Runtime.root} --ref #{tag} failed: #{result[:tail]}") unless result[:ok]

      Step.new(number, "installed", "pinned #{tag} -> #{commit[0, 12]}")
    end

    def rplugin(*args)
      bin = rplugin_bin
      return { ok: false, tail: "#{bin} is not executable" } unless File.executable?(bin)

      out, err, status = Open3.capture3(bin, *args)
      { ok: status.success?, tail: Operator::Git.tail([err, out].reject(&:empty?).join("\n"), 5) }
    rescue SystemCallError => e
      { ok: false, tail: e.message }
    end
  end
end
