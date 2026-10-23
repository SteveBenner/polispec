#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module PersonalDefaults
    DIRS = %w[modules packages config rules skills].freeze
    FILE_LIMIT = 1_048_576
    MIN_ID = 4
    STARTER = "config/ledger.starter.yml"
    BOUNDARY = "(?![A-Za-z0-9_.-])"
    Token = Struct.new(:text, :source, :kind)

    module_function

    def findings(root: Polispec::ROOT, ledger: nil, home: Dir.home)
      root = File.expand_path(root)
      tokens = collect_tokens(ledger, home, starter_text(root))
      return [] if tokens.empty?

      hits = []
      files(root).each do |path|
        relative = path.sub("#{root}/", "")
        text = read(path)
        next if text.nil?

        scan(relative, text, tokens, hits)
      end
      hits
    rescue StandardError
      []
    end

    def collect_tokens(ledger, home, starter)
      tokens = ledger_tokens(ledger, home) + shelf_tokens(home) + operator_tokens
      tokens.reject { |token| dropped?(token, home, starter) }.uniq { |token| [token.text, token.kind] }
    end

    def dropped?(token, home, starter)
      text = token.text
      return true if text.empty? || %w[~ /].include?(text) || text == home || text == "#{home}/"

      starter.include?(text)
    end

    def starter_text(root)
      File.read(File.join(root, STARTER))
    rescue SystemCallError
      ""
    end

    def ledger_tokens(ledger, home)
      ledger ||= begin
        Ledger.load
      rescue StandardError
        nil
      end
      return [] unless ledger

      tokens = []
      ledger.projects.each do |project|
        id = project.id.to_s
        tokens << Token.new(id, "ledger project #{id}", :scalar) if id.length >= MIN_ID && id != "polispec"
        forms(project.repo, home).each { |form| tokens << Token.new(form, "ledger repo of #{id}", :substring) }
      end
      host = ledger.host.to_s
      tokens << Token.new(host, "ledger host", :substring) unless host.empty?
      tokens
    rescue StandardError
      []
    end

    def shelf_tokens(home)
      source = Layers.source
      return [] unless source

      dir = source.kind == :dir ? source.root : File.join(source.repo, source.path.to_s)
      top = source.kind == :repo ? source.repo : toplevel(dir)
      [[dir, "global shelf directory"], [top, "global shelf git toplevel"]].flat_map do |path, label|
        next [] if path.to_s.empty?

        forms(path, home).map { |form| Token.new(form, label, :substring) }
      end
    rescue StandardError
      []
    end

    def toplevel(dir)
      return nil unless File.directory?(dir)

      out, _err, status = Open3.capture3("git", "-C", dir, "rev-parse", "--show-toplevel")
      status.success? ? out.strip : nil
    rescue SystemCallError
      nil
    end

    def operator_tokens
      name = Engine::Settings.operator.to_s
      return [] if name.empty? || name == Engine::Settings::OPERATOR_DEFAULT

      [Token.new(name, "polispec.operator", :word)]
    rescue StandardError
      []
    end

    def forms(path, home)
      raw = path.to_s
      return [] if raw.empty?

      absolute = File.expand_path(raw)
      forms = [raw, absolute]
      forms << "~#{absolute[home.length..]}" if absolute.start_with?("#{home}/")
      forms.uniq
    end

    def files(root)
      DIRS.flat_map do |dir|
        base = File.join(root, dir)
        next [] unless File.directory?(base)

        Dir.glob(File.join(base, "**", "*"), File::FNM_DOTMATCH).select do |path|
          File.file?(path) && !File.symlink?(path) && File.size(path) <= FILE_LIMIT
        end
      end.sort
    end

    def read(path)
      text = File.binread(path).force_encoding(Encoding::UTF_8)
      text.valid_encoding? && !text.include?("\0") ? text : nil
    rescue SystemCallError
      nil
    end

    def scan(relative, text, tokens, hits)
      lines = text.lines
      scalars = yaml_scalars(relative, text)
      tokens.each do |token|
        case token.kind
        when :scalar
          next unless scalars.include?(token.text)

          index = lines.index { |line| line.include?(token.text) }
          hits << hit(relative, index, token) if index
        else
          pattern = pattern_for(token)
          lines.each_with_index { |line, index| hits << hit(relative, index, token) if line.match?(pattern) }
        end
      end
    end

    def pattern_for(token)
      escaped = Regexp.escape(token.text)
      if token.kind == :word
        Regexp.new("(?<![A-Za-z0-9_])#{escaped}(?![A-Za-z0-9_])", Regexp::IGNORECASE)
      else
        Regexp.new("#{escaped}#{BOUNDARY}")
      end
    end

    def hit(relative, index, token)
      { "file" => relative, "line" => index + 1, "token" => token.text, "source" => token.source }
    end

    def yaml_scalars(relative, text)
      return [] unless relative.end_with?(".yml", ".yaml")

      found = []
      document = YAML.safe_load(text, permitted_classes: [Date, Time, Symbol], aliases: true)
      walk(document, found)
      found
    rescue StandardError
      []
    end

    def walk(node, found)
      case node
      when Hash
        node.each do |key, value|
          found << key if key.is_a?(String)
          walk(value, found)
        end
      when Array
        node.each { |item| walk(item, found) }
      when String
        found << node
      end
    end
  end
end
