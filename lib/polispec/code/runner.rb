#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "open3"
require "timeout"
require_relative "../plugin_store"

module Polispec
  module Code
    Hit = Struct.new(:rule, :line, :message, keyword_init: true)

    class Runner
      Result = Struct.new(:hits, :errors, :recorded, :indeterminate, keyword_init: true)
      INDETERMINATE_EXIT = 3

      class Indeterminate < StandardError; end

      DEFAULT_BUDGET_MS = 3000
      RUBOCOP_BUDGET_MS = 8000
      DEPARTMENT_PLUGINS = { "Performance" => "rubocop-performance", "Rails" => "rubocop-rails", "RSpec" => "rubocop-rspec", "Minitest" => "rubocop-minitest" }.freeze

      def initialize(pack)
        @pack = pack
        @checkers = {}
      end

      def run(rules, text, path)
        result = Result.new(hits: [], errors: [], recorded: [], indeterminate: [])
        rubocop = []
        rules.each do |rule|
          enforcer = rule.enforcer
          next unless enforcer

          case enforcer["kind"]
          when "ripper" then guarded(result, rule) { ripper(rule, text, path) }
          when "grep" then guarded(result, rule) { grep(rule, text) }
          when "script" then guarded(result, rule) { script(rule, text, path) }
          when "rubocop" then rubocop << rule
          else result.recorded << rule
          end
        end
        run_rubocop(result, rubocop, text, path) unless rubocop.empty?
        result
      end

      def rubocop_config(rules)
        config = { "AllCops" => { "DisabledByDefault" => true, "NewCops" => "disable", "SuggestExtensions" => false } }
        plugins = []
        rules.each do |rule|
          cop = rule.enforcer["cop"].to_s
          next if cop.empty?

          entry = config[cop] || { "Enabled" => true }
          entry = entry.merge(rule.enforcer["config"]) if rule.enforcer["config"].is_a?(Hash)
          config[cop] = entry
          plugin = DEPARTMENT_PLUGINS[cop.split("/").first]
          plugins << plugin if plugin
        end
        config = { "plugins" => plugins.uniq }.merge(config) unless plugins.empty?
        config
      end

      private

      def guarded(result, rule)
        budget = (rule.enforcer["budget_ms"] || DEFAULT_BUDGET_MS) / 1000.0
        Timeout.timeout(budget) do
          Array(yield).each do |line, message|
            result.hits << Hit.new(rule: rule, line: line.nil? ? nil : line.to_i, message: message.to_s)
          end
        end
      rescue Timeout::Error
        result.errors << error(rule, "enforcer exceeded its budget")
      rescue Indeterminate => e
        result.indeterminate << error(rule, e.message)
      rescue StandardError, ScriptError => e
        result.errors << error(rule, "#{e.class}: #{e.message.to_s[0, 200]}")
      end

      def error(rule, message)
        { "policy" => rule.id, "enforcer" => rule.enforcer["kind"], "message" => Code.squash(message) }
      end

      def plugin_roots(rule)
        ref = rule.enforcer["ref"].to_s
        rule.requires.to_h do |entry|
          id = entry["plugin"].to_s
          root = PluginStore.root(id)
          raise Error, "enforcer #{ref} requires plugin #{id}, not installed at #{PluginStore.path(id)}" unless root

          [PluginStore.env_name(id), root]
        end
      end

      def ripper(rule, text, path)
        plugin_roots(rule)
        checker = checker_for(rule)
        out = checker.call(text, path, rule.enforcer["config"])
        Array(out).map do |item|
          item.is_a?(Hash) ? [item["line"] || item[:line], item["message"] || item[:message] || rule.title] : [item[0], item[1] || rule.title]
        end
      end

      def checker_for(rule)
        ref = rule.enforcer["ref"].to_s
        real = @pack.source.materialize(ref)
        raise Error, "enforcer #{ref} not found in the pack" unless real

        @checkers[real] ||= begin
          wrapper = Module.new
          load(real, wrapper)
          resolve_checker(wrapper)
        end
      end

      def resolve_checker(wrapper)
        target = Object.new.extend(wrapper)
        target = wrapper.constants.map { |name| wrapper.const_get(name) }.find { |const| const.respond_to?(:check) } unless target.respond_to?(:check, true)
        raise Error, "enforcer script defines no check(source, path)" unless target

        method = target.method(:check)
        arity = method.arity
        lambda do |text, path, config|
          arity == 2 || arity == -2 ? method.call(text, path) : method.call(text, path, config)
        end
      end

      def grep(rule, text)
        regexp = Regexp.new(rule.enforcer["pattern"].to_s)
        hits = []
        text.each_line.with_index(1) { |line, index| hits << [index, rule.title] if regexp.match?(line.chomp) }
        hits
      end

      def script(rule, text, path)
        ref = rule.enforcer["ref"].to_s
        real = @pack.source.materialize(ref)
        raise Error, "enforcer #{ref} not found in the pack" unless real

        File.chmod(0o700, real) if @pack.source.kind == :dir && !File.executable?(real)
        out, err, status = capture(plugin_roots(rule), [real, path, *Array(rule.enforcer["args"])], text, nil, (rule.enforcer["budget_ms"] || DEFAULT_BUDGET_MS) / 1000.0)
        if status.exitstatus == INDETERMINATE_EXIT && out.strip.empty? && rule.enforcer["on_indeterminate"] == "warn" && rule.blocking_level?
          detail = Code.squash(err.to_s)[0, 200]
          raise Indeterminate, detail.empty? ? "enforcer exited 3 with no verdict" : detail
        end
        raise Error, "script exited #{status.exitstatus}: #{err.to_s[0, 160]}" unless status.success? || !out.strip.empty?

        out.each_line.map do |line|
          data = begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
          data.is_a?(Hash) ? [data["line"], data["message"] || rule.title] : nil
        end.compact
      end

      def run_rubocop(result, rules, text, path)
        by_cop = rules.group_by { |rule| rule.enforcer["cop"].to_s }
        output = Timeout.timeout(RUBOCOP_BUDGET_MS / 1000.0) { rubocop_offenses(rules, text, path) }
        output.each do |offense|
          Array(by_cop[offense["cop_name"]]).each do |rule|
            result.hits << Hit.new(rule: rule, line: offense.dig("location", "line"), message: offense["message"].to_s)
          end
        end
      rescue Timeout::Error
        rules.each { |rule| result.errors << error(rule, "rubocop exceeded its budget") }
      rescue StandardError => e
        rules.each { |rule| result.errors << error(rule, "rubocop: #{e.message.to_s[0, 200]}") }
      end

      def rubocop_offenses(rules, text, path)
        gemfile = pinned_gemfile
        raise Error, "polispec-specs has no Gemfile; rubocop enforcers are skipped" unless gemfile

        config = rubocop_config_file(rules)
        cops = rules.map { |rule| rule.enforcer["cop"].to_s }.reject(&:empty?).uniq
        env, prefix, home = rubocop_command(gemfile)
        command = prefix + ["-c", config, "--only", cops.join(","), "--stdin", path, "--format", "json", "--no-color", "--cache", "false", "--no-server"]
        budget = RUBOCOP_BUDGET_MS / 1000.0
        out = nil
        2.times do |attempt|
          out, err, status = capture(env, command, text, home, budget)
          break if out.lstrip.start_with?("{")
          raise Error, "rubocop failed (#{status.exitstatus}): #{err.to_s[0, 160]}" unless attempt.zero? && err.to_s.include?("RuboCop::Server")

          capture(env, prefix + ["--stop-server"], "", home, budget)
        end
        json = out.split(/^={20}$/).first.to_s
        data = JSON.parse(json)
        Array(data["files"]).flat_map { |file| Array(file["offenses"]) }
      end

      def rubocop_config_file(rules)
        base = "enforcers/rubocop/base.yml"
        return @pack.source.materialize(base) if @pack.exist?(base)

        yaml = YAML.dump(rubocop_config(rules))
        target = File.join(Paths.pack_cache_dir, "rubocop-#{Digest::SHA256.hexdigest(yaml)[0, 20]}.yml")
        Code.write_atomic(target, yaml) unless File.file?(target)
        target
      end

      def pinned_gemfile
        source = @pack.source
        return (File.file?(File.join(@pack.repo, "Gemfile")) ? File.join(@pack.repo, "Gemfile") : nil) unless source.kind == :git
        return nil unless source.exist?("Gemfile")

        dir = File.join(Paths.pack_cache_dir, "gemfile-#{source.tree_id}")
        %w[Gemfile Gemfile.lock].each do |name|
          target = File.join(dir, name)
          next if File.file?(target) || !source.exist?(name)

          Code.write_atomic(target, source.read(name), 0o600)
        end
        File.join(dir, "Gemfile")
      end

      def rubocop_command(gemfile)
        env = { "BUNDLE_GEMFILE" => gemfile, "GEM_HOME" => nil, "GEM_PATH" => nil, "RUBYOPT" => nil }
        vendored = File.join(@pack.repo, "vendor", "bundle")
        env["BUNDLE_PATH"] = vendored if File.directory?(vendored) && File.dirname(gemfile) != @pack.repo
        bin = ruby_bin_for(@pack.repo)
        env["PATH"] = "#{bin}:#{ENV['PATH']}" if bin
        bundle = bin ? File.join(bin, "bundle") : "bundle"
        [env, [bundle, "exec", "rubocop"], File.dirname(gemfile)]
      end

      def capture(env, command, stdin_data, chdir, budget)
        input_read, input_write = IO.pipe
        out_read, out_write = IO.pipe
        err_read, err_write = IO.pipe
        options = { in: input_read, out: out_write, err: err_write, pgroup: true }
        options[:chdir] = chdir if chdir
        pid = Process.spawn(env, *command, **options)
        [input_read, out_write, err_write].each(&:close)
        feeder = Thread.new { feed(input_write, stdin_data) }
        out = drain(out_read)
        err = drain(err_read)
        waiter = Process.detach(pid)
        raise Timeout::Error, "command exceeded its budget" unless waiter.join(budget)

        kill_group(pid)
        [out.value, err.value, waiter.value]
      ensure
        kill_group(pid) if pid
        [input_read, input_write, out_read, out_write, err_read, err_write].compact.each { |stream| stream.close unless stream.closed? }
        feeder&.join(0.1)
      end

      def feed(stream, text)
        stream.write(text.to_s)
      rescue Errno::EPIPE, IOError
        nil
      ensure
        stream.close unless stream.closed?
      end

      def drain(stream)
        thread = Thread.new do
          stream.read
        rescue IOError
          ""
        end
        thread.report_on_exception = false
        thread
      end

      def kill_group(pid)
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def ruby_bin_for(repo)
        forced = ENV["POLISPEC_SPECS_RUBY_BIN"].to_s
        return forced unless forced.empty?

        abis = Dir.glob(File.join(repo, "vendor", "bundle", "ruby", "*")).map { |dir| File.basename(dir) }
        return nil if abis.empty?

        candidates = Dir.glob(File.expand_path("~/.rubies/ruby-*/bin/ruby")).sort.reverse
        candidates.map { |ruby| File.dirname(ruby) }.find do |bin|
          version = File.basename(File.dirname(bin)).sub("ruby-", "").split(".")
          abis.include?("#{version[0]}.#{version[1]}.0")
        end
      end
    end
  end
end
