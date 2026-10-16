#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "operator/git"
require_relative "native_pin"

module Polispec
  module Stewardship
    RULE_ID = "polispec-stewardship"
    RULES_SURFACE_SINCE = Gem::Version.new("1.15.0")
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

    def rplugin?
      File.executable?(rplugin_bin)
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

    def check
      [rule_step(1, check: true), runtime_step(2), pin_step(3, check: true)]
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

    def claude_home
      value = [ENV["RPLUGIN_CLAUDE_HOME"], ENV["CLAUDE_CONFIG_DIR"]].map(&:to_s).find { |item| !item.empty? }
      File.expand_path(value || "~/.claude")
    end

    def claude_rule_link
      File.join(claude_home, "rules", "rplugin", PLUGIN_ID, "#{RULE_ID}.md")
    end

    def rules_surface?
      result = rplugin("version")
      return false unless result[:ok]

      Gem::Version.new(result[:tail].to_s.strip.split.last.to_s) >= RULES_SURFACE_SINCE
    rescue ArgumentError
      false
    end

    def claude_link_missing?
      Dir.exist?(claude_home) && rules_surface? && !File.file?(claude_rule_link)
    end

    def native_root
      current = NativePin.current_link
      File.exist?(current) ? current : Runtime.root
    end

    def native_rule_links
      %w[polispec.md polispec-stewardship.md].map do |name|
        [File.join(claude_home, "rules", "polispec", name), File.join(native_root, "rules", name)]
      end
    end

    def native_rule_step(number, check)
      unless Dir.exist?(claude_home)
        return Step.new(number, "ok", "no Claude Code home; the rule reaches other harnesses through the polispec skill")
      end

      links = native_rule_links
      return Step.new(number, "ok", "#{RULE_ID} is linked under #{File.join(claude_home, 'rules', 'polispec')}") if links.all? { |link, _| File.file?(link) }

      paths = links.map(&:first).join(", ")
      return Step.new(number, "missing", "would link #{paths}") if check

      stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      links.each do |link, target|
        FileUtils.mkdir_p(File.dirname(link))
        FileUtils.mv(link, "#{link}.polispec-backup-#{stamp}") if File.exist?(link) && !File.symlink?(link)
        File.delete(link) if File.symlink?(link)
        File.symlink(target, link)
      end
      return Step.new(number, "failed", "could not link #{paths}") unless links.all? { |link, _| File.file?(link) }

      Step.new(number, "installed", "linked #{paths}")
    end

    def native_pinned_at_tag?
      current = NativePin.current_link
      return false unless File.symlink?(current)

      commit = Operator::Git.new(Runtime.root).rev("refs/tags/#{pin_tag}")
      commit && File.basename(File.readlink(current)) == commit && NativePin.release_valid?(File.join(NativePin.releases_dir, commit))
    rescue SystemCallError
      false
    end

    def native_pin_step(number, check)
      return Step.new(number, "ok", "runtime is pinned at #{Runtime.commit.to_s[0, 12]}") if Runtime.pinned?
      return Step.new(number, "ok", "#{NativePin.current_link} is already pinned at #{pin_tag}") if native_pinned_at_tag?
      return Step.new(number, "missing", "#{Runtime.kind} runtime #{Runtime.root} is not pinned; would run polispec pin --ref #{pin_tag}") if check

      result = NativePin.pin!(ref: pin_tag)
      native_rule_links.each do |link, target|
        next unless File.symlink?(link) && File.readlink(link) != target && File.readlink(link).start_with?("#{Runtime.root}/")

        File.delete(link)
        File.symlink(target, link)
      end
      Step.new(number, "installed", "pinned #{pin_tag} -> #{result['commit'][0, 12]} at #{NativePin.current_link}")
    rescue Polispec::Error => e
      Step.new(number, "failed", e.message)
    end

    def rule_step(number, check: false)
      return native_rule_step(number, check) unless rplugin?

      return Step.new(number, "failed", "the running polispec at #{Runtime.root} does not ship the #{RULE_ID} rule") unless rule_shipped?(Runtime.root)

      stored = stored_root
      if stored && rule_shipped?(stored)
        return Step.new(number, "ok", "#{RULE_ID} is installed through #{store_link}") unless claude_link_missing?
        return Step.new(number, "ok", "#{claude_rule_link} is absent; step 3 links it when it pins #{pin_tag}") if pin_pending?
        return Step.new(number, "missing", "#{claude_rule_link} is absent; would run rplugin install #{PLUGIN_ID}") if check

        result = rplugin("install", PLUGIN_ID)
        return Step.new(number, "failed", "rplugin install #{PLUGIN_ID} failed: #{result[:tail]}") unless result[:ok]
        return Step.new(number, "failed", "rplugin install #{PLUGIN_ID} did not link #{claude_rule_link}") unless File.file?(claude_rule_link)

        return Step.new(number, "installed", "linked #{claude_rule_link}")
      end
      return Step.new(number, "missing", "#{store_link} does not ship #{RULE_ID}; would run rplugin install #{Runtime.root}") if check

      result = rplugin("install", Runtime.root)
      return Step.new(number, "failed", "rplugin install #{Runtime.root} failed: #{result[:tail]}") unless result[:ok]

      Step.new(number, "installed", "rplugin install #{Runtime.root}")
    end

    def runtime_step(number)
      kind = Runtime.kind
      return Step.new(number, "ok", "R-POLISPEC-RUNTIME protects #{Runtime.root} (runtime #{kind})") if %w[clone pinned].include?(kind)

      Step.new(number, "failed", "the runtime protected root is not active for a #{kind} runtime")
    end

    def pin_tag
      "v#{Polispec.version}"
    end

    def pinned_at?(commit)
      stored = stored_root
      stored && File.basename(stored) == commit && File.basename(File.dirname(File.dirname(stored))) == ".pinned"
    end

    def pin_pending?
      return false if Runtime.pinned?

      commit = Operator::Git.new(Runtime.root).rev("refs/tags/#{pin_tag}")
      !(commit && pinned_at?(commit))
    end

    def pin_step(number, check: false)
      return native_pin_step(number, check) unless rplugin?

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

      return Step.new(number, "missing", "#{Runtime.kind} runtime #{Runtime.root} is not pinned; would run rplugin install #{Runtime.root} --ref #{tag}") if check

      result = rplugin("install", Runtime.root, "--ref", tag)
      return Step.new(number, "failed", "rplugin install #{Runtime.root} --ref #{tag} failed: #{result[:tail]}") unless result[:ok]
      return Step.new(number, "failed", "pinned #{tag} but #{claude_rule_link} is still absent") if claude_link_missing?

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
