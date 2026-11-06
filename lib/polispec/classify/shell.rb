#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "strscan"
require "shellwords"
require "timeout"

module Polispec
  module Classify
    module Shell
      MAX_DEPTH = 6
      SHELLS = %w[bash sh zsh dash ksh mksh ash csh tcsh fish].freeze
      INTERPRETERS = %w[ruby python python3 perl node php lua irb].freeze
      EMBED_VERBS = %w[git gh systemctl service psql pg_dump pg_dumpall pg_restore createdb dropdb rm mv cp tee sudo bash sh kill pkill killall polispec rake gem].freeze
      OPERATORS = ["&>>", "<<<", "<<-", ">>", "<<", "&&", "||", "|&", ";;", ">&", "<&", ">|", "&>", "<>", ";", "|", "&", "(", ")", "<", ">"].freeze
      REDIRECT_OPS = %w[> >> >| &> &>> <> >& < << <<- <<< <&].freeze
      WORD_STOP = " \t\n;&|()<>".freeze
      KEYWORDS = %w[if then else elif fi do done while until { } ! time coproc].freeze
      CLAUSES = %w[for case select function esac in].freeze
      ASSIGNMENT = /\A[A-Za-z_][A-Za-z0-9_]*=/.freeze
      CODE_FLAG = /\A-[A-Za-z]*c[A-Za-z]*\z/.freeze
      SQL_NOISE = %r{--[^\n]*|/\*.*?\*/|\bE'(?:[^'\\]|\\.|'')*'|'(?:[^']|'')*'|"(?:[^"]|"")*"|(\$[A-Za-z_]*\$).*?\1}mi.freeze
      SQL_CLIENTS = %w[psql].freeze
      SQL_FEEDERS = %w[echo printf cat].freeze
      MAX_SQL_FILE = 1_000_000
      MAX_SCRIPT_FILE = 1_000_000
      SHELL_SHEBANG = %r{\A#!\s*(?:\S*/)?(?:env\s+(?:-\S+\s+)*)?(?:bash|sh|zsh|dash|ksh|ash)(?:\s|\z)}.freeze
      SHELL_VALUE_OPTS = %w[-o +o -O +O --rcfile --init-file].freeze
      SOURCE_BUILTINS = %w[source .].freeze
      MAX_FOLLOWED_COMMANDS = 1000
      FOLLOW_DEADLINE = 0.5
      MAX_GLOB = 256
      STATIC_PRINTERS = %w[echo printf].freeze
      PARAM_FORM = /\A([A-Za-z_][A-Za-z0-9_]*)(%%|%|##|#|:-|:=|-|=)(.*)\z/m.freeze
      MAX_PARAM_PATTERN = 64
      GLOB_DEADLINE = 0.5
      GLOB_TOTAL = 0.5
      MAX_NESTING = 16
      MAX_PARAM_VALUE = 4096
      MAX_LOOP_PASSES = 16
      MAX_LOOP_TEXT = 16_384
      LOOP_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze
      LOOP_PATTERN_CHARS = /[{}*?\[]/.freeze
      UNREADABLE = "line could not be read"
      FRESH_TEMP_NAME = "tmp.XXXXXXXXXX".freeze
      MAX_ALTERNATE_COMMANDS = 16
      SAFE_PATH_PROGRAMS = %w[pwd dirname basename realpath readlink mktemp date whoami id hostname uname].freeze
      PATH_WRITERS = %w[rm rmdir unlink shred touch mkdir chmod chown chgrp truncate tee install ln mv cp rsync scp rename cd pushd].freeze
      GLOB_WRITERS = %w[rm rmdir unlink shred touch mkdir chmod chown chgrp truncate tee install ln mv cp rsync scp rename patch dd sed perl curl wget tar unzip gzip gunzip bzip2 xz find].freeze
      GLOB_READERS = %w[cat head tail less more bat tac nl od xxd hexdump strings base64 base32 grep egrep fgrep rg ag awk gawk mawk nawk cut sort uniq wc diff cmp comm jq yq file stat source . openssl gpg sqlite3 zip zcat zgrep zless bzcat xzcat rev paste shuf bash sh zsh dash ksh ash].freeze
      GLOB_PROGRAMS = (GLOB_WRITERS + GLOB_READERS + %w[git]).freeze
      AWKS = %w[awk gawk mawk nawk].freeze
      INLINE_HAZARD = /system\(|\bsystem\s+["']|popen|subprocess|os\.exec|spawn\(|Open3|exec\(|rmtree|rm_rf|os\.remove|os\.unlink|shell_exec/.freeze
      INLINE_BACKTICK_RUNTIMES = %w[ruby perl irb].freeze
      QUOTING = ["'", '"', "\\", "$", "`", "~"].freeze
      INLINE_BACKTICK = /(?:[=(,;{]\s*|\b(?:puts|print|say|p)\s+)`[^`\n]*\S\s[^`\n]*`/.freeze
      BRACE_LIST = /\{[^{}]*(?:,|\.\.)[^{}]*\}/.freeze

      class Word < String
        attr_accessor :dynamic, :has_glob, :subst, :subst_lead, :param_form, :unresolved, :alternates

        def dynamic?
          dynamic ? true : false
        end

        def glob?
          has_glob ? true : false
        end

        def unsafe_subst?
          subst ? true : false
        end
      end

      Redirect = Struct.new(:op, :fd, :target, :body) do
        def write?
          %w[> >> >| &> &>> <> >&].include?(op)
        end

        def read?
          %w[< <>].include?(op)
        end

        def here?
          %w[<< <<- <<<].include?(op)
        end
      end

      Command = Struct.new(:argv, :cwd, :redirects, :env, :pipeline, :index, :text, :sudo, :host, :xargs, :syntax_only, :recursive, :reads, keyword_init: true) do
        def name
          File.basename(argv.first.to_s)
        end

        def args
          argv.drop(1)
        end

        def upstream
          pipeline ? pipeline.first(index) : []
        end

        def downstream
          pipeline ? pipeline.drop(index + 1) : []
        end

        def piped_in?
          index.to_i.positive?
        end
      end

      FollowBudget = Struct.new(:count, :started, :exceeded) do
        def spend
          self.started ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
          self.count += 1
          self.exceeded = true if count > MAX_FOLLOWED_COMMANDS || Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > FOLLOW_DEADLINE
          !exceeded
        end

        def start
          self.started ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      Script = Struct.new(:commands, :text, :opaque, :followed, :unparsed, :sourced)
      GATE_OVERRIDE = /\bPOLISPEC_TTY_CONFINE=/.freeze

      module_function

      def parse(text, cwd, depth = 0, vars = nil)
        text = readable(text)
        holder = []
        Thread.current[:polispec_glob_spent] = 0.0 if depth.zero?
        parse_text(text, cwd, depth, vars, holder)
      rescue ArgumentError, EncodingError, RegexpError, SystemStackError
        salvage(holder.first, text)
      end

      def salvage(parser, text)
        return Script.new([], text.to_s, false, [], [UNREADABLE], []) unless parser

        Script.new(parser.commands.dup, text.to_s, parser.opaque, parser.followed.dup, (parser.unparsed + [UNREADABLE]).uniq, parser.sourced.dup)
      end

      def safe_expand(path, base)
        text = path.to_s.delete("\0")
        File.expand_path(text, base.to_s)
      rescue ArgumentError
        File.expand_path(File.join(".", text), base.to_s)
      end

      def readable(text)
        text = text.to_s
        text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
        text.scrub("\uFFFD")
      end

      def parse_text(text, cwd, depth, vars, holder = nil)
        vars ||= default_vars(cwd)
        initial = vars.dup
        parser = Parser.new(text, cwd, vars, depth)
        holder << parser if holder
        commands = parser.run
        passes = loop_choices(parser, text, depth).map do |choice|
          again = Parser.new(text, cwd, initial.dup, depth)
          again.loop_choice = choice
          again.run
          again
        end
        parsers = passes.empty? ? [parser] : passes
        commands = parsers.flat_map(&:commands).uniq { |cmd| command_key(cmd) } unless passes.empty?
        nested = embedded_scripts(commands, depth)
        override = text.to_s.match?(GATE_OVERRIDE) ? ["operator gate override"] : []
        inline = commands.any? { |cmd| inline_hazard?(cmd) } ? ["inline code runs or deletes"] : []
        Script.new(commands + nested.flat_map(&:commands), text.to_s, parsers.any?(&:opaque) || nested.any?(&:opaque), (parsers.flat_map(&:followed) + nested.flat_map(&:followed)).uniq, (parsers.flat_map(&:unparsed) + nested.flat_map(&:unparsed) + override + inline).uniq, (parsers.flat_map(&:sourced) + nested.flat_map { |script| Array(script.sourced) }).uniq)
      end

      def loop_choices(parser, text, depth)
        return [] if depth.positive? || text.to_s.bytesize > MAX_LOOP_TEXT

        used = parser.loops.each_with_index.select do |(name, values), _index|
          values && text.to_s.match?(/\$\{?#?#{name}\b/)
        end
        return [] if used.empty? || used.map { |(_, values), _| values.length }.inject(:*) > MAX_LOOP_PASSES

        lists = used.map { |(_, values), index| values.map { |value| [index, value] } }
        lists.first.product(*lists.drop(1)).map(&:to_h)
      end

      def command_key(cmd)
        redirects = Array(cmd.redirects).map { |redirect| [redirect.op, redirect.fd, redirect.target.to_s, redirect.body.to_s] }
        [cmd.argv.map(&:to_s), cmd.cwd, redirects, cmd.env.to_h.map { |key, value| [key, value.to_s] }, cmd.sudo, cmd.host, cmd.xargs]
      end

      def inline_hazard?(cmd)
        name = cmd.name
        programs = awk_program(cmd) if AWKS.include?(name)
        programs = inline_code(cmd) if INTERPRETERS.include?(name)
        Array(programs).any? do |code|
          code = code.to_s
          code.match?(INLINE_HAZARD) || (INLINE_BACKTICK_RUNTIMES.include?(name) && code.match?(INLINE_BACKTICK))
        end
      end

      def awk_program(cmd)
        args = cmd.args.map(&:to_s)
        return nil if args.include?("-f")

        rest = args.dup
        until rest.empty?
          arg = rest.shift
          if %w[-F -v].include?(arg)
            rest.shift
          elsif arg == "--"
            return [rest.first].compact
          elsif !arg.start_with?("-")
            return [arg]
          end
        end
        nil
      end

      def expand_word(word, cwd)
        return [word] unless word.respond_to?(:glob?) && word.glob?
        return nil if word.dynamic?

        found = []
        patterns = braces(word.to_s)
        return nil if patterns.nil?

        patterns.each do |pattern|
          hits = glob_hits(pattern, cwd)
          return nil if hits.nil?

          found.concat(hits.empty? ? [pattern] : hits)
          return nil if found.length > MAX_GLOB
        end
        found.uniq
      end

      def glob_hits(pattern, cwd)
        return [] unless pattern.match?(/[*?\[]/)

        remaining = GLOB_TOTAL - glob_spent
        return nil unless remaining.positive?

        base = File.directory?(cwd.to_s) ? cwd.to_s : Dir.pwd
        hits = []
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          Timeout.timeout([GLOB_DEADLINE, remaining].min) do
            Dir.glob(pattern.gsub(/\*{2,}/, "*"), base: base) do |hit|
              hits << readable(hit)
              return nil if hits.length > MAX_GLOB
            end
          end
        ensure
          Thread.current[:polispec_glob_spent] = glob_spent + Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        end
        hits
      rescue Timeout::Error, SystemCallError, ArgumentError, EncodingError
        nil
      end

      def glob_spent
        Thread.current[:polispec_glob_spent] || 0.0
      end

      def braces(text, budget = [0])
        match = BRACE_LIST.match(text)
        return [text] unless match

        budget[0] += 1
        return nil if budget[0] > MAX_GLOB

        choices = brace_choices(match[0][1..-2])
        return [text] unless choices

        out = []
        choices.each do |choice|
          expanded = braces(text[0...match.begin(0)] + choice + text[match.end(0)..], budget)
          return nil if expanded.nil?

          out.concat(expanded)
          return nil if out.length > MAX_GLOB
        end
        out
      end

      def brace_choices(inner)
        if inner.include?(",")
          inner.split(",", -1)
        elsif (range = inner.match(/\A(-?\d+)\.\.(-?\d+)\z/))
          first = range[1].to_i
          last = range[2].to_i
          return nil if (last - first).abs >= MAX_GLOB

          (first <= last ? (first..last).to_a : first.downto(last).to_a).map(&:to_s)
        elsif (range = inner.match(/\A([A-Za-z])\.\.([A-Za-z])\z/))
          (range[1]..range[2]).to_a
        end
      end

      def default_vars(cwd)
        { "HOME" => Dir.home, "PWD" => cwd.to_s }
      end

      def embedded_scripts(commands, depth)
        if depth >= MAX_DEPTH
          deep = commands.any? { |cmd| !embedded_sources(cmd).empty? }
          return deep ? [Script.new([], "", false, [], ["nesting too deep"])] : []
        end

        commands.flat_map do |cmd|
          embedded_sources(cmd).map do |source|
            script = parse(source, cmd.cwd, depth + 1)
            script.unparsed -= [Parser::UNTERMINATED] unless SHELLS.include?(cmd.name)
            script
          end
        end
      end

      def embedded_sources(cmd)
        bodies = cmd.redirects.select(&:here?).map { |redirect| redirect.op == "<<<" ? redirect.target : redirect.body }.compact
        return [] if cmd.syntax_only && bodies.none? { |body| body.match?(/\$\(|`/) }
        return bodies if SHELLS.include?(cmd.name)
        return [] unless INTERPRETERS.include?(cmd.name)
        operand = cmd.args.first
        if operand && !operand.start_with?("-") && !(operand.respond_to?(:dynamic?) && operand.dynamic?) && File.file?(safe_expand(operand, cmd.cwd))
          return []
        end

        (inline_code(cmd) + bodies).flat_map { |code| shell_strings(code) }
      end

      def inline_code(cmd)
        args = cmd.args
        args.each_index.select { |i| %w[-e -c -E -r].include?(args[i]) }.map { |i| args[i + 1] }.compact
      end

      def shell_strings(code)
        runs(code).filter_map do |run|
          verb = run.first.to_s.strip.split(/\s+/).first
          next unless EMBED_VERBS.include?(File.basename(verb.to_s))

          run.length > 1 ? run.shelljoin : run.first
        end
      end

      def runs(code)
        found = []
        code.scan(/(["'])((?:\\.|(?!\1).)*)\1/m) { found << [Regexp.last_match.begin(0), Regexp.last_match.end(0), Regexp.last_match(2)] }
        found.chunk_while { |a, b| code[a[1]...b[0]].match?(/\A\s*,\s*\z/) }.map { |chunk| chunk.map(&:last) }
      end

      def destructive_command?(text, cwd)
        parse(text, cwd).commands.any? do |cmd|
          SQL_CLIENTS.include?(cmd.name) && sql_inputs(cmd).any? { |sql| destructive_sql?(sql) }
        end
      end

      def sql_inputs(cmd)
        inputs = option_values(cmd.args, "-c", "--command")
        inputs.concat(cmd.redirects.filter_map { |redirect| redirect_sql(redirect, cmd.cwd) })
        option_values(cmd.args, "-f", "--file").each { |file| inputs << read_sql(file, cmd.cwd) }
        inputs.concat(cmd.upstream.select { |up| SQL_FEEDERS.include?(up.name) }.map { |up| up.args.join(" ") })
        inputs.compact
      end

      def redirect_sql(redirect, cwd)
        if redirect.here? then redirect.op == "<<<" ? redirect.target : redirect.body
        elsif redirect.read? then read_sql(redirect.target, cwd)
        end
      end

      def read_sql(file, cwd)
        path = File.expand_path(file.to_s, cwd.to_s)
        File.file?(path) && File.size(path) <= MAX_SQL_FILE ? readable(File.read(path)) : nil
      rescue SystemCallError, ArgumentError
        nil
      end

      def syntax_invocation(words)
        return nil unless %w[bash sh dash].include?(File.basename(words.first.to_s))

        rest = words.drop(1)
        noexec = false
        code = false
        stdin = false
        until rest.empty?
          arg = rest.first
          return nil if arg.respond_to?(:dynamic?) && arg.dynamic?
          if arg == "--"
            rest.shift
            break
          end
          break if arg == "-" || !arg.start_with?("-", "+")

          rest.shift
          if %w[-o +o].include?(arg)
            return nil unless rest.shift == "noexec"

            noexec = arg == "-o"
          elsif arg.match?(/\A[-+][neuxvfcs]+\z/)
            flags = arg[1..]
            noexec = arg.start_with?("-") if flags.include?("n")
            code = true if flags.include?("c") && arg.start_with?("-")
            stdin = true if flags.include?("s") && arg.start_with?("-")
          else
            return nil
          end
        end
        return nil unless noexec

        { file: code || stdin ? nil : rest.first }
      end

      def script_operand(args)
        rest = args.dup
        until rest.empty?
          arg = rest.shift
          return rest.first if arg.to_s == "--"
          return nil if arg.to_s.match?(/\A-[A-Za-z]*s[A-Za-z]*\z/)

          if SHELL_VALUE_OPTS.include?(arg.to_s)
            rest.shift
          elsif !arg.to_s.start_with?("-", "+")
            return arg
          end
        end
        nil
      end

      def shell_script?(path)
        return false unless File.file?(path) && File.executable?(path)

        head = File.open(path, "rb") { |io| io.read(256) }.to_s
        head.start_with?("#!") ? SHELL_SHEBANG.match?(head) : File.extname(path) == ".sh"
      rescue SystemCallError
        false
      end

      def read_script(path)
        File.file?(path) && File.readable?(path) && File.size(path) <= MAX_SCRIPT_FILE ? readable(File.read(path)) : nil
      rescue SystemCallError, ArgumentError
        nil
      end

      def option_values(args, short, long)
        values = []
        args.each_with_index do |arg, i|
          values << args[i + 1] if (arg == short || arg == long) && args[i + 1]
          values << arg.delete_prefix("#{long}=") if arg.start_with?("#{long}=")
          values << arg.delete_prefix(short) if arg.start_with?(short) && arg.length > short.length && !arg.start_with?("--")
        end
        values
      end

      def destructive_sql?(sql)
        sql.to_s.gsub(SQL_NOISE, " ").split(";").any? { |statement| destructive_statement?(statement) }
      end

      def destructive_statement?(statement)
        return true if statement.match?(/\A\s*(?:truncate|drop)\b/i) || statement.match?(/\balter\b.*\bdrop\b/im)

        unguarded?(statement, /(?:\A\s*|\)\s*)delete\s+from\b/i) || unguarded?(statement, /(?:\A\s*|\)\s*)update\b.*?\bset\b/im)
      end

      def unguarded?(statement, opener)
        found = opener.match(statement)
        found ? !statement[found.end(0)..].match?(/\bwhere\b/i) : false
      end

      class Parser
        Segment = Struct.new(:words, :redirects, :pending, :start)

        ANSI_SIMPLE = { "a" => "\a", "b" => "\b", "e" => "\e", "E" => "\e", "f" => "\f", "n" => "\n", "r" => "\r", "t" => "\t", "v" => "\v", "\\" => "\\", "'" => "'", '"' => '"' }.freeze
        UNTERMINATED = "unterminated quote or heredoc".freeze
        POLISPEC_OVERRIDE = /\A(?:POLISPEC_(?:LEDGER|GLOBAL|HOME|STATE_HOME|SETTINGS|SPECS_REPO|OPERATOR|ENFORCE)|RPLUGIN_POLISPEC_\w*ENFORCE)\z/.freeze
        GIT_OVERRIDE = /\A(?:alias\.|core\.(?:sshcommand|hookspath|fsmonitor|pager|gitproxy)|remote\.|url\.)/i.freeze
        GIT_REF_MOVERS = %w[push reset clean checkout switch restore stash rebase merge pull am cherry-pick revert update-ref branch tag read-tree].freeze
        HEAD_HAZARDS = %w[stop restart kill disable mask].freeze
        HEAD_HAZARD_FLAG = /\A-(?:[a-zA-Z]*[rR][a-zA-Z]*f|[a-zA-Z]*f[a-zA-Z]*[rR])[a-zA-Z]*\z/.freeze
        GIT_GLOBAL_VALUE = %w[-C --git-dir --work-tree --namespace --super-prefix --attr-source].freeze
        GIT_PUSH_VALUE = %w[-o --push-option --repo --receive-pack --exec].freeze

        attr_reader :commands, :opaque, :followed, :unparsed, :sourced, :loops
        attr_writer :loop_choice
        attr_accessor :vars, :cwd, :written, :unknown_writes, :switched, :recursive

        def initialize(text, cwd, vars, depth, budget = nil, following = false)
          @budget = budget || FollowBudget.new(0, nil, false)
          @following = following
          @s = text
          @ss = StringScanner.new(text)
          @cwd = cwd.to_s.empty? ? Dir.pwd : cwd.to_s
          @vars = vars
          @vars[:tmpdir_named] = true if text.to_s.include?("TMPDIR")
          @depth = depth
          @commands = []
          @loops = []
          @loop_choice = nil
          @pipe = nil
          @heredocs = []
          @tok_start = 0
          @quoted = false
          @opaque = false
          @written = {}
          @unknown_writes = false
          @followed = []
          @sourced = []
          @unparsed = []
          @exported = {}
          @switched = false
          @links = {}
          @previous = nil
          @recursive = false
          @nesting = 0
          @case_frames = []
        end

        def run
          parse_list(false)
          commands
        end

        def parse_nested(source, following = @following, vars: nil, recursive: @recursive)
          return (source.to_s.strip.empty? ? nil : mark_unparsed!("nesting too deep")) if @depth >= MAX_DEPTH

          child = Parser.new(source.to_s, @cwd, @vars.dup.merge(vars || {}), @depth + 1, @budget, following)
          child.switched = @switched
          child.recursive = recursive
          begin
            child.run
          ensure
            @commands.concat(child.commands)
            absorb(child)
          end
        end

        def absorb(child)
          @opaque ||= child.opaque
          @followed.concat(child.followed)
          @sourced.concat(child.sourced)
          @unparsed.concat(child.unparsed - @unparsed)
          @switched ||= child.switched
        end

        def parse_sourced(source)
          child = Parser.new(source.to_s, @cwd, @vars.dup, @depth + 1, @budget, true)
          child.written = @written.dup
          child.unknown_writes = @unknown_writes
          child.switched = @switched
          begin
            child.run
          ensure
            @commands.concat(child.commands)
            absorb(child)
          end
          @vars = child.vars
          @cwd = child.cwd
          @written = child.written
          @unknown_writes = child.unknown_writes
        end

        def mark_opaque!
          @opaque = true
        end

        def mark_unparsed!(reason)
          @unparsed << reason unless @unparsed.include?(reason)
          nil
        end

        def set_cwd(dir)
          @cwd = resolve(dir) || @cwd
        end

        private

        def halt_following
          mark_opaque!
          @ss.terminate
          nil
        end

        def resolve(file)
          Shell.safe_expand(file, @cwd)
        end

        def new_segment
          Segment.new([], [], nil, nil)
        end

        def parse_list(paren)
          seg = new_segment
          loop do
            tok = next_token
            case tok[0]
            when :eof
              emit(seg, false)
              mark_unparsed!(UNTERMINATED) unless @heredocs.empty?
              return
            when :word then add_word(seg, tok[1])
            when :redir then seg.pending = tok
            when :nl
              emit(seg, false)
              seg = new_segment
              read_heredocs
            when :op
              seg = handle_op(seg, tok[1])
              return if tok[1] == ")" && paren
            end
          end
        end

        def handle_op(seg, op)
          emit(seg, %w[| |&].include?(op))
          subshell if op == "("
          new_segment
        end

        def subshell
          return too_nested unless @nesting < MAX_NESTING

          saved = [@cwd, @vars.dup, @pipe, @previous]
          @pipe = nil
          @nesting += 1
          begin
            parse_list(true)
          ensure
            @nesting -= 1
          end
          @cwd, @vars, @pipe, @previous = saved
        end

        def nested_list
          return too_nested unless @nesting < MAX_NESTING

          saved = [@cwd, @vars.dup, @pipe, @heredocs, @previous]
          @pipe = nil
          @heredocs = []
          @nesting += 1
          begin
            parse_list(true)
          ensure
            @nesting -= 1
          end
          @cwd, @vars, @pipe, @heredocs, @previous = saved
        end

        def too_nested
          mark_unparsed!("nesting too deep")
          @ss.terminate
          nil
        end

        def add_word(seg, word)
          seg.start ||= @tok_start
          @prev_word = word.to_s
          return seg.words << word unless seg.pending

          redirect = Redirect.new(seg.pending[1], seg.pending[2], word, nil)
          seg.redirects << redirect
          @heredocs << [redirect, word.to_s, seg.pending[1] == "<<-", @quoted] if %w[<< <<-].include?(seg.pending[1])
          seg.pending = nil
        end

        def next_token
          skip_blanks
          start = @ss.pos
          token = scan_token
          @tok_start = start
          token
        end

        def scan_token
          loop do
            return [:eof] if @ss.eos?

            if @ss.peek(1) == "\n"
              @ss.getch
              return [:nl]
            end
            return [:word, process_substitution] if @ss.check(/[<>]\(/)

            token = arithmetic_command || operator_token || word_token
            return token if token
          end
        end

        def peek_char
          byte = @ss.peek(1)
          return byte if byte.empty? || byte.getbyte(0) < 0x80

          @ss.check(/./m) || byte
        end

        def skip_blanks
          loop do
            if @ss.skip(/[ \t]+/) || @ss.skip(/\\\n/)
              next
            elsif @ss.check(/#/)
              @ss.skip(/[^\n]*/)
            else
              break
            end
          end
        end

        def operator_token
          fd = @ss.scan(/\d+(?=[<>])/)
          chunk = @ss.peek(3)
          op = OPERATORS.find { |candidate| chunk.start_with?(candidate) }
          return nil unless op

          @ss.pos += op.length
          REDIRECT_OPS.include?(op) ? [:redir, op, fd] : [:op, op]
        end

        def word_token
          start = @ss.pos
          word = read_word
          return [:word, word] if @quoted || !word.empty?

          @ss.getch if @ss.pos == start
          nil
        end

        def process_substitution
          start = @ss.pos
          @ss.pos += 2
          nested_list
          word = Word.new(@s.byteslice(start...@ss.pos))
          word.dynamic = true
          word
        end

        def read_word
          word = Word.new("")
          @quoted = false
          @unq = +""
          @unsafe = false
          @lead = nil
          loop do
            char = peek_char
            break if char.empty? || WORD_STOP.include?(char)

            consume(word, char)
          end
          word.has_glob = @unq.match?(/[*?\[]/) || @unq.match?(BRACE_LIST)
          word.subst = @unsafe
          word.subst_lead = @lead == :unsafe
          word
        end

        def consume(word, char)
          @unq << (QUOTING.include?(char) ? "\0" : char)
          @lead ||= :plain unless ["$", "`", '"'].include?(char)
          case char
          when "'" then single_quoted(word)
          when '"' then double_quoted(word)
          when "\\" then escaped(word)
          when "$" then dollar(word)
          when "`" then backtick(word)
          when "~" then tilde(word)
          else word << @ss.getch
          end
        end

        def single_quoted(word)
          @quoted = true
          @ss.getch
          word << (@ss.scan(/[^']*/) || "")
          mark_unparsed!(UNTERMINATED) if @ss.eos?
          @ss.getch
        end

        def double_quoted(word)
          @quoted = true
          @ss.getch
          loop do
            return mark_unparsed!(UNTERMINATED) if @ss.eos?

            char = peek_char
            return @ss.getch if char == '"'

            dq_char(word, char)
          end
        end

        def dq_char(word, char)
          case char
          when "\\" then dq_escape(word)
          when "$" then dollar(word, true)
          when "`" then backtick(word, true)
          else word << @ss.getch
          end
        end

        def dq_escape(word)
          @ss.getch
          nxt = @ss.getch.to_s
          return if nxt == "\n"

          word << "\\" unless "\"\\$`".include?(nxt)
          word << nxt
        end

        def escaped(word)
          @ss.getch
          nxt = @ss.getch.to_s
          word << nxt unless nxt == "\n"
          @quoted = true
        end

        def tilde(word)
          at_start = word.empty?
          @ss.getch
          ahead = peek_char
          boundary = @ss.eos? || WORD_STOP.include?(ahead) || ahead == "/"
          word << (at_start && boundary ? @vars.fetch("HOME", Dir.home) : "~")
        end

        def dollar(word, in_quotes = false)
          @ss.getch
          if !in_quotes && @ss.check(/'/)
            ansi_c(word)
          elsif !in_quotes && @ss.check(/"/)
            double_quoted(word)
          elsif @ss.check(/\(\(/)
            arithmetic(word)
          elsif @ss.check(/\(/)
            command_substitution(word, in_quotes)
          elsif @ss.check(/\{/)
            braced(word)
          else
            plain_variable(word)
          end
        end

        def ansi_c(word)
          @quoted = true
          @ss.getch
          cut = false
          loop do
            return mark_unparsed!(UNTERMINATED) if @ss.eos?

            char = @ss.getch
            return if char == "'"

            piece = char == "\\" ? ansi_escape : char
            cut ||= piece.include?("\0")
            word << piece unless cut
          end
        end

        def ansi_escape
          nxt = @ss.getch
          return "\\" if nxt.nil?
          return ANSI_SIMPLE[nxt] if ANSI_SIMPLE.key?(nxt)

          case nxt
          when /[0-7]/ then byte_char(((nxt + (@ss.scan(/[0-7]{1,2}/) || "")).to_i(8)) & 0xFF)
          when "x" then (digits = @ss.scan(/\h{1,2}/)) ? byte_char(digits.to_i(16)) : "\\x"
          when "u" then unicode_char(@ss.scan(/\h{1,4}/), "\\u")
          when "U" then unicode_char(@ss.scan(/\h{1,8}/), "\\U")
          when "c" then (ctrl = @ss.getch) ? byte_char(ctrl.ord & 0x1f) : "\\c"
          else "\\#{nxt}"
          end
        end

        def byte_char(value)
          [value].pack("C").force_encoding(Encoding::UTF_8).scrub("?")
        end

        def unicode_char(digits, literal)
          return literal unless digits

          [digits.to_i(16)].pack("U").scrub("\uFFFD")
        rescue RangeError
          "#{literal}#{digits}"
        end

        def balanced_parens
          out = +""
          depth = 0
          until @ss.eos?
            char = @ss.getch
            out << char
            depth += 1 if char == "("
            depth -= 1 if char == ")"
            break if depth.zero?
          end
          out
        end

        def pure_arithmetic?(span, for_clause = false)
          return false unless span.start_with?("((") && span.end_with?("))")
          return false if !for_clause && span.include?(";")

          inner_closes_last?(span)
        end

        def inner_closes_last?(span)
          depth = 0
          limit = span.length - 2
          span.each_char.with_index do |char, i|
            depth += 1 if char == "("
            depth -= 1 if char == ")"
            return false if i >= 2 && i < limit && depth < 2
          end
          true
        end

        def arithmetic_inner(span)
          span.end_with?(")") ? span[1..-2].to_s : span[1..].to_s
        end

        def arithmetic_body(span, for_clause = false)
          return nested_substitutions(span) if pure_arithmetic?(span, for_clause)

          parse_nested(arithmetic_inner(span))
          mark_unparsed!("arithmetic with commands")
        end

        def arithmetic(word)
          arithmetic_body(balanced_parens)
          word << "0"
          word.dynamic = true
        end

        def arithmetic_command
          return nil unless @ss.check(/\(\(/)

          depth = 0
          span = nil
          @ss.rest.each_char.with_index do |char, i|
            depth += 1 if char == "("
            depth -= 1 if char == ")"
            next unless depth.zero?

            span = @ss.rest[0..i]
            break
          end
          return nil unless span&.end_with?("))")

          @ss.pos += span.bytesize
          arithmetic_body(span, @prev_word == "for")
          [:word, Word.new(span)]
        end

        def nested_substitutions(text, respect_single = true)
          text = text.b
          i = 0
          while i < text.length
            char = text[i]
            if char == "\\"
              i += 2
            elsif char == "'" && respect_single
              close = text.index("'", i + 1)
              i = close ? close + 1 : text.length
            elsif char == "$" && text[i + 1] == "("
              i = substitution_at(text, i + 1)
            elsif char == "`"
              i = backtick_at(text, i)
            else
              i += 1
            end
          end
        end

        def substitution_at(text, open)
          depth = 0
          i = open
          while i < text.length
            char = text[i]
            if char == "\\"
              i += 1
            elsif char == "("
              depth += 1
            elsif char == ")"
              depth -= 1
              break if depth.zero?
            end
            i += 1
          end
          span = text[open..i].to_s.force_encoding(Encoding::UTF_8).scrub("�")
          if span.start_with?("((")
            arithmetic_body(span)
          else
            parse_nested(span.end_with?(")") ? span[1..-2] : span[1..])
          end
          i + 1
        end

        def backtick_at(text, start)
          inner = String.new(encoding: Encoding::BINARY)
          i = start + 1
          while i < text.length
            char = text[i]
            break if char == "`"

            if char == "\\" && text[i + 1] == "`"
              i += 1
              char = "`"
            end
            inner << char
            i += 1
          end
          parse_nested(inner.force_encoding(Encoding::UTF_8).scrub("�"))
          i + 1
        end

        def command_substitution(word, in_quotes = false)
          start = @ss.pos - 1
          @ss.getch
          saved = [@quoted, @unq, @unsafe, @lead]
          before = @commands.length
          nested_list
          inner = @commands[before..].to_a
          @quoted, @unq, @unsafe, @lead = saved
          literal = static_literal(inner, in_quotes)
          return word << literal if literal

          note_substitution(inner)
          word << @s.byteslice(start...@ss.pos)
          word.dynamic = true
        end

        def static_literal(inner, in_quotes)
          return nil unless inner.length == 1

          cmd = inner.first
          return fresh_temp_path(cmd, in_quotes) if cmd.name == "mktemp"
          return nil unless STATIC_PRINTERS.include?(cmd.name) && cmd.redirects.empty? && cmd.env.empty? && !cmd.sudo
          return nil if cmd.args.any? { |arg| dynamic_word?(arg) || (arg.respond_to?(:glob?) && arg.glob?) }

          args = cmd.args.map(&:to_s)
          text = cmd.name == "echo" ? echo_text(args) : printf_text(args)
          return nil unless text

          text = text.sub(/\n+\z/, "")
          return nil if !in_quotes && text.match?(/[\s*?\[]/)

          text
        end

        def fresh_temp_path(cmd, in_quotes)
          return nil if @vars[:tmpdir_named] || !cmd.redirects.empty? || !cmd.env.empty? || cmd.sudo
          return nil if cmd.args.any? { |arg| dynamic_word?(arg) } || !(cmd.args.empty? || cmd.args.map(&:to_s) == ["-d"])

          base = ENV.fetch("TMPDIR", "").empty? ? "/tmp" : ENV.fetch("TMPDIR")
          text = File.join(base, FRESH_TEMP_NAME)
          !in_quotes && text.match?(/[\s*?\[]/) ? nil : text
        end

        def echo_text(args)
          rest = args.dup
          flags = []
          flags << rest.shift while rest.first.to_s.match?(/\A-[neE]+\z/)
          return nil if flags.any? { |flag| flag.include?("e") }

          rest.join(" ")
        end

        def printf_text(args)
          return nil if args.empty? || args.first.start_with?("-")

          format = args.first
          return nil if format.gsub("%%", "").gsub("%s", "").include?("%") || format.gsub("\\n", "").include?("\\")

          format = format.gsub("\\n", "\n")
          slots = format.scan(/%s/).length
          values = args.drop(1)
          return format.gsub("%%", "%") if slots.zero?

          rounds = [(values.length.to_f / slots).ceil, 1].max
          out = +""
          rounds.times do |round|
            taken = values[(round * slots), slots].to_a
            line = format.gsub("%%", "\0")
            line = line.gsub("%s") { taken.shift.to_s }
            out << line.gsub("\0", "%")
          end
          out
        end

        def note_substitution(inner)
          unsafe = inner.any? { |cmd| !safe_path_command?(cmd) }
          @unsafe ||= unsafe
          @lead ||= unsafe ? :unsafe : :plain
        end

        def safe_path_command?(cmd)
          return true if SAFE_PATH_PROGRAMS.include?(cmd.name)

          cmd.name == "git" && cmd.args.map(&:to_s).reject { |arg| arg.start_with?("-") }.first == "rev-parse"
        end

        def braced(word)
          @ss.getch
          body = braced_body
          nested_substitutions(body)
          name = body.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) ? body : nil
          return append_variable(word, name, "${#{body}}") if name

          value = parameter_value(body)
          return word << value if value

          word << "${#{body}}"
          word.dynamic = true
          word.param_form = true
        end

        def parameter_value(body)
          match = PARAM_FORM.match(body)
          return nil unless match

          name, op, arg = match.captures
          return nil unless @vars.key?(name)
          return nil if arg.match?(/[$`\\'"]/)

          value = @vars[name].to_s
          case op
          when "%", "%%" then strip_pattern(value, arg, true, op == "%%")
          when "#", "##" then strip_pattern(value, arg, false, op == "##")
          when ":-", ":=" then value.empty? ? assign_default(name, op, arg) : value
          else value
          end
        end

        def assign_default(name, op, arg)
          @vars[name] = arg if op == ":="
          arg
        end

        def strip_pattern(value, pattern, suffix, longest)
          linear = linear_strip(value, pattern, suffix, longest)
          return linear unless linear.nil?
          return nil if value.bytesize > MAX_PARAM_VALUE || pattern.length > MAX_PARAM_PATTERN || pattern.count("*") > 4 || pattern.include?("[")

          regex = /\A#{pattern.each_char.map { |char| char == "*" ? ".*" : (char == "?" ? "." : Regexp.escape(char)) }.join}\z/m
          indexes = (0..value.length).to_a
          if suffix
            hit = (longest ? indexes : indexes.reverse).find { |at| regex.match?(value[at..]) }
            hit ? value[0...hit] : value
          else
            hit = (longest ? indexes.reverse : indexes).find { |at| regex.match?(value[0...at]) }
            hit ? value[hit..] : value
          end
        end

        def linear_strip(value, pattern, suffix, longest)
          return nil if pattern.include?("?") || pattern.include?("[") || pattern.count("*") > 1
          return nil if pattern.include?("*") && !pattern.start_with?("*") && !pattern.end_with?("*")

          star = pattern.include?("*")
          literal = pattern.delete("*")
          lead = star && pattern.start_with?("*")
          if suffix
            if !star
              value.end_with?(literal) ? value[0, value.length - literal.length] : value
            elsif lead
              return value unless value.end_with?(literal)

              longest ? "" : value[0, value.length - literal.length]
            else
              at = longest ? value.index(literal) : value.rindex(literal)
              at ? value[0, at] : value
            end
          elsif !star
            value.start_with?(literal) ? value[literal.length..].to_s : value
          elsif lead
            at = longest ? value.rindex(literal) : value.index(literal)
            at ? value[(at + literal.length)..].to_s : value
          else
            return value unless value.start_with?(literal)

            longest ? "" : value[literal.length..].to_s
          end
        end

        def braced_body
          body = +""
          depth = 1
          until @ss.eos?
            char = @ss.getch
            if char == "\\"
              body << char << @ss.getch.to_s
            elsif char == "$" && @ss.check(/\(/)
              body << char << balanced_parens
            elsif char == "$" && @ss.check(/\{/)
              body << char << @ss.getch
              depth += 1
            elsif char == "}"
              depth -= 1
              break if depth.zero?

              body << char
            else
              body << char
            end
          end
          body
        end

        def plain_variable(word)
          name = @ss.scan(/[A-Za-z_][A-Za-z0-9_]*/)
          return append_variable(word, name, "$#{name}") if name

          special = @ss.scan(/[?$!@*#\-0-9]/)
          return word << "$" unless special
          return word << @vars[special].to_s if @vars.key?(special)

          word << "$#{special}"
          word.dynamic = true
          word.unresolved = true
        end

        def append_variable(word, name, literal)
          if name && @vars.key?(name)
            word << @vars[name].to_s
          else
            word << literal
            word.dynamic = true
            word.unresolved = true
            values = name && @vars[:alternates]&.fetch(name, nil)
            (word.alternates ||= {})[literal] = values if values
          end
        end

        def backtick(word, in_quotes = false)
          start = @ss.pos
          @ss.getch
          inner = +""
          until @ss.eos?
            char = @ss.getch
            break if char == "`"

            char = @ss.getch if char == "\\" && @ss.peek(1) == "`"
            inner << char
          end
          saved = [@quoted, @unq, @unsafe, @lead]
          before = @commands.length
          parse_nested(inner)
          inner_commands = @commands[before..].to_a
          @quoted, @unq, @unsafe, @lead = saved
          literal = static_literal(inner_commands, in_quotes)
          return word << literal if literal

          note_substitution(inner_commands)
          word << @s.byteslice(start...@ss.pos)
          word.dynamic = true
        end

        def read_heredocs
          @heredocs.each do |redirect, delim, strip, quoted|
            lines = []
            found = false
            until @ss.eos?
              line = @ss.scan(/[^\n]*\n?/)
              check = line.chomp
              check = check.sub(/\A\t+/, "") if strip
              if check == delim
                found = true
                break
              end

              lines << line
            end
            mark_unparsed!(UNTERMINATED) unless found
            redirect.body = lines.join
            nested_substitutions(redirect.body, false) unless quoted
          end
          @heredocs.clear
        end

        def emit(seg, piped)
          @prev_word = nil
          finish_segment(seg)
          @pipe = nil unless piped
        end

        def finish_segment(seg)
          return if seg.words.empty? && seg.redirects.empty?

          text = @s.byteslice((seg.start || @tok_start)...@tok_start).to_s.strip
          words = seg.words.dup
          env = take_assignments(words)
          strip_keywords(words)
          while drop_variable_heads(words)
            mark_unparsed!("assignment after a variable") unless take_assignments(words).empty?
            strip_keywords(words)
            note_dropped_head(words)
          end
          return set_variables(env) if words.empty? && seg.redirects.empty?
          return add_command([], seg.redirects, env, text, false) if words.empty?

          if words.first.to_s == "function"
            words = words.drop(2)
            words.shift while %w[( ) {].include?(words.first.to_s)
            return keep_redirects(seg.redirects, env, text, false) if words.empty?
          elsif CLAUSES.include?(words.first.to_s)
            note_clause(words)
            return keep_redirects(seg.redirects, env, text, false)
          end

          dispatch(words, seg.redirects, env, text)
        end

        def note_loop(words)
          name = words[1].to_s
          return unless name.match?(LOOP_NAME)

          @vars.delete(name)
          values = words[2].to_s == "in" ? words.drop(3) : []
          literal = values.any? && values.none? { |word| word.dynamic? || word.has_glob || word.to_s.match?(LOOP_PATTERN_CHARS) }
          index = @loops.length
          @loops << [name, literal ? values.map(&:to_s) : nil]
          @vars[name] = @loop_choice[index] if @loop_choice&.key?(index)
        end

        VARIABLE_HEAD = /\A\$(?:{[^{}]*}|[A-Za-z_][A-Za-z0-9_]*)\z/.freeze

        def drop_variable_heads(words)
          dropped = false
          while words.length > 1 && variable_head?(words.first)
            words.shift
            dropped = true
          end
          dropped
        end

        def note_dropped_head(words)
          first = words.first.to_s
          if GIT_REF_MOVERS.include?(first)
            words.unshift("git")
          elsif HEAD_HAZARDS.include?(first) || first.match?(HEAD_HAZARD_FLAG)
            mark_unparsed!("command name from a variable")
          end
        end

        def variable_head?(word)
          word.respond_to?(:dynamic?) && word.dynamic? && (word.unresolved || word.param_form) && word.to_s.match?(VARIABLE_HEAD)
        end

        def strip_keywords(words)
          while KEYWORDS.include?(words.first.to_s)
            keyword = words.shift.to_s
            words.shift while keyword == "time" && %w[-p --].include?(words.first.to_s)
          end
        end

        def keep_redirects(redirects, env, text, sudo)
          add_command([], redirects, env, text, sudo) unless redirects.empty?
          nil
        end

        def take_assignments(words)
          env = {}
          while words.first&.match?(ASSIGNMENT)
            word = words.shift
            name, value = word.split("=", 2)
            val = Word.new(value.to_s)
            val.dynamic = word.dynamic?
            env[name] = val
          end
          env
        end

        def set_variables(env)
          mark_unparsed!("cd under CDPATH") unless env["CDPATH"].to_s.empty?
          env.each { |name, value| assign_variable(name, value.dynamic? ? nil : value.to_s) }
        end

        def assign_variable(name, value)
          (@case_frames.last[name] ||= [@vars[name]]) << value unless @case_frames.empty?
          @vars[:alternates]&.delete(name)
          value ? @vars[name] = value : @vars.delete(name)
        end

        def note_clause(words)
          case words.first.to_s
          when "case" then @case_frames << {}
          when "esac" then close_case(@case_frames.pop)
          when "for", "select"
            @vars[:alternates]&.delete(words[1].to_s)
            note_loop(words)
          end
        end

        def close_case(frame)
          frame.to_h.each do |name, values|
            known = values.compact.uniq
            next if known.length < 2 && values.drop(1).all?

            @vars.delete(name)
            (@vars[:alternates] ||= {})[name] = known unless known.empty?
          end
        end

        def alternate_commands(cmd)
          slots = (cmd.argv + cmd.redirects.map(&:target)).select { |word| word.respond_to?(:alternates) && word.alternates }
          slots.flat_map { |word| word.alternates.flat_map { |literal, values| values.map { |value| alternate_command(cmd, word, literal, value) } } }.first(MAX_ALTERNATE_COMMANDS)
        end

        def alternate_command(cmd, word, literal, value)
          text = word.to_s.sub(literal) { value }
          swapped = Word.new(text)
          swapped.dynamic = word.alternates.length > 1 || text.match?(/[$`]/)
          copy = cmd.dup
          copy.argv = cmd.argv.map { |item| item.equal?(word) ? swapped : item }
          copy.redirects = cmd.redirects.map { |item| item.target.equal?(word) ? Redirect.new(item.op, item.fd, swapped, item.body) : item }
          copy
        end

        def dispatch(words, redirects, env, text)
          sudo = false
          xargs = false
          reads = []
          loop do
            return keep_redirects(redirects, env, text, sudo) if words.empty?
            break if syntax_invocation(words, env)

            handler = Wrappers.handler_for(words)
            break unless handler

            sudo ||= %w[sudo doas].include?(File.basename(words.first))
            xargs ||= File.basename(words.first) == "xargs"
            reads.concat(Wrappers.xargs_files(words)) if File.basename(words.first) == "xargs"
            words = Wrappers.public_send(handler, words, self, env)
            return keep_redirects(redirects, env, text, sudo) if words.nil?
          end
          finalize(words, redirects, env, text, sudo, xargs, reads)
        end

        def finalize(words, redirects, env, text, sudo, xargs = false, reads = [])
          name = File.basename(words.first)
          if %w[cd pushd].include?(name)
            keep_redirects(redirects, env, text, sudo)
            return change_directory(words, env)
          end
          if %w[export declare local readonly typeset].include?(name)
            keep_redirects(redirects, env, text, sudo)
            return export_variables(words)
          end
          return keep_redirects(redirects, env, text, sudo) if follow_source(words, redirects, env, sudo, xargs)

          forget_assigned(words)
          git_sequence(words, env) if name == "git"

          syntax = syntax_invocation(words, env)
          host = !syntax && follow_script(words) == :followed
          runs_elsewhere(words, redirects)
          added = add_command(words, redirects, env, text, sudo, xargs, reads)
          added.host = true if host && added
          added.syntax_only = true if syntax && added
          find_exec(words) if name == "find" && added
          shell_stdin(words, redirects, added) if SHELLS.include?(name) && added && !syntax
        end

        READ_VALUE_LETTERS = %w[d i n N p t u].freeze

        ELSEWHERE_NAMES = %w[parallel ssh mosh tmux screen at batch systemd-run docker podman].freeze
        ELSEWHERE_CLASSES = %w[git.push git.tag git.rewrite git.branch git.merge git.commit release.publish service.control service.config fs.delete].freeze
        SSH_VALUE_OPTS = %w[-p -i -l -o -F -J -L -R -D -b -c -e -m -O -Q -S -W -w -B -E -I -B].freeze
        TMUX_COMMANDS = %w[send-keys send new-session new new-window neww split-window splitw respawn-pane respawnp respawn-window respawnw run-shell run if-shell if].freeze
        DOCKER_VALUE_OPTS = %w[-e --env -u --user -w --workdir --env-file --detach-keys].freeze

        def runs_elsewhere(words, redirects)
          name = File.basename(words.first.to_s)
          return unless ELSEWHERE_NAMES.include?(name)

          texts = delegated_texts(name, words.drop(1).map(&:to_s), redirects)
          hit = texts.any? { |text| probe_commands(text).any? { |cmd| elsewhere_program?(cmd) } }
          mark_unparsed!("runs a command elsewhere") if hit
        end

        def elsewhere_program?(cmd)
          return true if cmd.name == "kill"

          %w[git gh systemctl fs].any? do |name|
            family = Classify::Registry.family(name)
            next false unless family

            Array(family.classify(cmd)).flatten.compact.any? { |action| ELSEWHERE_CLASSES.include?(action.action_class) }
          end
        rescue StandardError
          false
        end

        def probe_commands(text)
          return [] if text.to_s.strip.empty? || @depth >= MAX_DEPTH

          Parser.new(text.to_s, @cwd, @vars.dup, @depth + 1, FollowBudget.new(0, nil, false), false).run
        rescue StandardError
          []
        end

        def delegated_texts(name, args, redirects)
          bodies = redirects.select(&:here?).map { |redirect| redirect.op == "<<<" ? redirect.target : redirect.body }.compact.map(&:to_s)
          case name
          when "ssh", "mosh" then [ssh_command(args)].compact + bodies
          when "parallel" then args.reject { |arg| arg.start_with?("-") } + [args.reject { |arg| arg.start_with?("-") }.join(" ")]
          when "tmux" then tmux_commands(args)
          when "docker", "podman" then docker_command(args)
          when "at", "batch" then bodies + [args.reject { |arg| arg.start_with?("-") }.join(" ")]
          else
            positional = args.reject { |arg| arg.start_with?("-") }
            positional.each_index.map { |at| positional.drop(at).join(" ") }
          end
        end

        def ssh_command(args)
          rest = args.dup
          host = false
          until rest.empty?
            arg = rest.shift
            if arg == "--"
              host = true
            elsif arg.start_with?("-") && arg.length > 1
              rest.shift if SSH_VALUE_OPTS.include?(arg)
            elsif host || !arg.start_with?("-")
              return rest.join(" ")
            end
          end
          nil
        end

        def tmux_commands(args)
          at = args.index { |arg| TMUX_COMMANDS.include?(arg) }
          return [] unless at

          rest = args.drop(at + 1).reject { |arg| arg.start_with?("-") }
          rest + [rest.join(" ")]
        end

        def docker_command(args)
          at = args.index("exec")
          return [] unless at

          rest = args.drop(at + 1)
          positional = []
          until rest.empty?
            arg = rest.shift
            if arg.start_with?("-")
              rest.shift if DOCKER_VALUE_OPTS.include?(arg)
            else
              positional << arg
              positional.concat(rest)
              break
            end
          end
          [positional.drop(1).join(" ")]
        end

        def forget_assigned(words)
          args = words.drop(1).map(&:to_s)
          case File.basename(words.first.to_s)
          when "printf"
            at = args.index("-v")
            @vars.delete(args[at + 1]) if at && args[at + 1]
          when "read"
            read_names(args).each { |name| @vars.delete(name) }
            @vars.delete("REPLY")
          when "mapfile", "readarray"
            args.each { |arg| @vars.delete(arg) if arg.match?(LOOP_NAME) }
            @vars.delete("MAPFILE")
          end
        end

        def read_names(args)
          rest = args.dup
          names = []
          until rest.empty?
            arg = rest.shift
            if arg == "--"
              names.concat(rest)
              break
            elsif arg.match?(/\A-[A-Za-z]+\z/)
              last = arg[-1]
              names << rest.shift if last == "a"
              rest.shift if READ_VALUE_LETTERS.include?(last)
            elsif !arg.start_with?("-")
              names << arg
            end
          end
          names.compact
        end

        def find_exec(words)
          args = words.drop(1).map(&:to_s)
          root = args.take_while { |arg| !arg.start_with?("-") && !%w[( ! ,].include?(arg) }.first || "."
          index = 0
          while index < args.length
            if %w[-exec -execdir -ok -okdir].include?(args[index])
              stop = index + 1
              stop += 1 until stop >= args.length || [";", "+"].include?(args[stop])
              clause = args[(index + 1)...stop]
              parse_nested(clause.map { |arg| arg.gsub("{}", root) }.shelljoin, vars: nil, recursive: true) unless clause.empty?
              index = stop
            end
            index += 1
          end
        end

        def shell_stdin(words, redirects, added)
          return unless Shell.script_operand(words.drop(1)).nil? && added.piped_in?
          return if redirects.any? { |redirect| redirect.read? || redirect.here? }

          upstream = added.upstream.last
          if upstream && %w[echo printf].include?(upstream.name) && upstream.args.none? { |arg| dynamic_word?(arg) }
            text = upstream.args.map(&:to_s).reject { |arg| arg.start_with?("-") }.join(" ")
            parse_nested(text) unless text.strip.empty?
          else
            mark_unparsed!("shell reads generated text")
          end
        end

        def git_sequence(words, env = {})
          args = words.drop(1).map(&:to_s)
          overrides = []
          until args.empty?
            arg = args.shift
            if arg == "-c" || arg == "--config-env"
              overrides << args.shift.to_s
            elsif arg.start_with?("--config-env=")
              overrides << arg.split("=", 2).last
            elsif GIT_GLOBAL_VALUE.include?(arg)
              args.shift
            elsif !arg.start_with?("-")
              args.unshift(arg)
              break
            end
          end
          mark_unparsed!("git configuration override") if overrides.any? { |value| GIT_OVERRIDE.match?(value) }
          sub = args.shift
          read_only = defined?(Polispec::Classify::Git) && Polispec::Classify::Git::READ_ONLY.include?(sub)
          mark_unparsed!("polispec override on git") if polispec_override?(env) && !read_only
          mark_unparsed!("repository path from a variable") if GIT_REF_MOVERS.include?(sub) && git_path_variable?(words, sub)
          @switched = true if %w[checkout switch].include?(sub) && !args.include?("--")
          mark_unparsed!("push after a branch switch") if sub == "push" && @switched && push_unnamed?(args)
        end

        def git_path_variable?(words, sub)
          words.drop(1).each_with_index.any? do |word, index|
            break false if word.to_s == sub

            text = word.to_s
            target = %w[-C --git-dir --work-tree].include?(text) ? words[index + 2] : (text.start_with?("--git-dir=", "--work-tree=") ? word : nil)
            target.respond_to?(:dynamic?) && target.dynamic?
          end
        end

        def polispec_override?(env)
          names = env.keys.map(&:to_s) + @exported.keys
          names.any? { |name| POLISPEC_OVERRIDE.match?(name) }
        end

        def push_unnamed?(args)
          positional = []
          rest = args.dup
          until rest.empty?
            arg = rest.shift
            if arg == "--"
              positional.concat(rest)
              break
            elsif arg.start_with?("-") && arg.length > 1
              rest.shift if GIT_PUSH_VALUE.include?(arg)
            else
              positional << arg
            end
          end
          refspecs = positional.drop(1)
          refspecs.empty? || refspecs.any? { |spec| spec.sub(/\A\+/, "").split(":", -1).include?("HEAD") }
        end

        def syntax_invocation(words, env)
          return nil unless (env.keys & %w[BASH_ENV ENV SHELLOPTS BASHOPTS]).empty?

          Shell.syntax_invocation(words)
        end

        def follow_script(words)
          file = script_target(words)
          return unless file
          return mark_opaque! if dynamic_word?(file) || @depth >= MAX_DEPTH || @budget.exceeded

          path = resolve(file)
          return mark_opaque! unless path

          body = written_body(path)
          return mark_opaque! if body == :unknown

          from_disk = body.nil?
          body ||= Shell.read_script(path)
          return mark_opaque! unless body

          note_followed(path) if from_disk
          @budget.start
          parse_nested(body, true)
          :followed
        end

        def follow_source(words, redirects, env, sudo, xargs)
          return false unless SOURCE_BUILTINS.include?(words.first.to_s)

          file = words[1]
          plain = redirects.empty? && env.empty? && !sudo && !xargs && @pipe.to_a.empty?
          return mark_opaque! && false unless plain && file && !dynamic_word?(file) && @depth < MAX_DEPTH && !@budget.exceeded

          path = resolve(file)
          return mark_opaque! && false unless path

          body = written_body(path)
          return mark_opaque! && false if body == :unknown

          from_disk = body.nil?
          body ||= Shell.read_script(path)
          return mark_opaque! && false unless body

          note_followed(path) if from_disk
          @sourced << path
          @budget.start
          parse_sourced(body)
          true
        end

        def note_followed(path)
          @followed << path
          real = File.realpath(path)
          @followed << real unless real == path
        rescue SystemCallError
          nil
        end

        def script_target(words)
          first = words.first
          return Shell.script_operand(words.drop(1)) if SHELLS.include?(File.basename(first.to_s))
          return nil if dynamic_word?(first) || !first.to_s.include?("/")

          path = resolve(first)
          return mark_opaque! && nil unless path

          first if @written.key?(path) || Shell.shell_script?(path)
        end

        def written_body(path)
          entry = @written[path]
          return (@unknown_writes ? :unknown : nil) if entry.nil?
          return :unknown if entry == :unknown

          body = entry.op == "<<<" ? "#{entry.target}\n" : entry.body
          body || :unknown
        end

        def record_writes(cmd)
          here = cmd.redirects.reverse.find(&:here?)
          catted = cmd.name == "cat" && cmd.args.empty?
          cmd.redirects.select(&:write?).each do |redirect|
            next if redirect.op == ">&" || redirect.target.to_s.match?(/\A(?:\d+|-)\z/)

            record_write(redirect.target, catted && %w[> >|].include?(redirect.op) ? here : nil)
          end
          return unless cmd.name == "tee"

          append = cmd.args.any? { |arg| %w[-a --append].include?(arg.to_s) }
          cmd.args.reject { |arg| arg.to_s.start_with?("-") }.each { |arg| record_write(arg, append ? nil : here) }
        end

        def record_write(target, source)
          return @unknown_writes = true if target.nil? || dynamic_word?(target)

          path = resolve(target)
          return @unknown_writes = true unless path

          @written[path] = source || :unknown
        end

        def dynamic_word?(word)
          word.respond_to?(:dynamic?) && word.dynamic?
        end

        def change_directory(words, env = {})
          target = words.drop(1).reject { |arg| arg.start_with?("-") && arg != "-" }.first
          target ||= @vars.fetch("HOME", Dir.home)
          if target.respond_to?(:dynamic?) && target.dynamic?
            mark_unparsed!("path from a substitution") if substituted_path?(target)
            mark_unparsed!("path from a parameter expansion") if parameter_path?(target)
            return
          end
          mark_unparsed!("cd under CDPATH") if cdpath_applies?(target, env)
          if glob_word?(target)
            list = Shell.expand_word(target, @cwd)
            return mark_unparsed!("path pattern too wide") if list.nil? || list.length > 1

            target = list.first
          end
          return enter(@previous) if target == "-"

          enter(resolve(target))
        end

        def cdpath_applies?(target, env)
          return false if target == "-" || target.to_s.start_with?("/", "./", "../") || %w[. ..].include?(target.to_s)

          [env["CDPATH"], @vars["CDPATH"], ENV.fetch("CDPATH", nil)].any? { |value| !value.to_s.empty? }
        end

        def enter(dir)
          return unless dir

          @previous = @cwd
          @cwd = dir
          @vars["OLDPWD"] = @previous
          @vars["PWD"] = @cwd
        end

        def export_variables(words)
          words.drop(1).each do |word|
            @exported[word.to_s] = true if File.basename(words.first.to_s) == "export" && word.to_s.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
            next unless word.match?(ASSIGNMENT)

            name, value = word.split("=", 2)
            next assign_variable(name, nil) if word.respond_to?(:dynamic?) && word.dynamic?

            mark_unparsed!("cd under CDPATH") if name == "CDPATH" && !value.to_s.empty?
            @vars[name] = value.to_s
            @exported[name] = true if File.basename(words.first.to_s) == "export"
          end
        end

        def add_command(words, redirects, env, text, sudo, xargs = false, reads = [])
          first = words.first
          mark_unparsed!("command name from a substitution") if first.respond_to?(:dynamic?) && first.dynamic? && first.match?(/\A(?:\$\(|`)/)
          words = expand_globs(words)
          redirects = expand_redirects(redirects)
          note_path_operands(words, redirects)
          note_git_paths(words)
          distrust_written_patch(words)
          words, redirects = apply_links(words, redirects) unless @links.empty?
          @pipe ||= []
          cmd = Command.new(argv: words, cwd: @cwd, redirects: redirects, env: env, pipeline: @pipe, index: @pipe.length, text: text, sudo: sudo, xargs: xargs, recursive: @recursive, reads: reads)
          return halt_following unless !@following || @budget.spend

          @pipe << cmd
          @commands << cmd
          @commands.concat(alternate_commands(cmd))
          record_writes(cmd)
          record_links(cmd)
          cmd
        end

        def expand_globs(words)
          name = File.basename(words.first.to_s)
          return words unless GLOB_PROGRAMS.include?(name) && words.drop(1).any? { |word| glob_word?(word) }

          out = [words.first]
          words.drop(1).each do |word|
            unless glob_word?(word)
              out << word
              next
            end
            list = Shell.expand_word(word, @cwd)
            if list.nil?
              mark_unparsed!("path pattern too wide") if GLOB_WRITERS.include?(name)
              out << word
            else
              list.each { |path| out << Word.new(path) }
            end
          end
          out
        end

        def expand_redirects(redirects)
          return redirects unless redirects.any? { |redirect| redirect.write? && glob_word?(redirect.target) }

          redirects.flat_map do |redirect|
            next [redirect] unless redirect.write? && glob_word?(redirect.target)

            list = Shell.expand_word(redirect.target, @cwd)
            if list.nil?
              mark_unparsed!("path pattern too wide")
              [redirect]
            else
              list.map { |path| Redirect.new(redirect.op, redirect.fd, Word.new(path), redirect.body) }
            end
          end
        end

        def glob_word?(word)
          word.respond_to?(:glob?) && word.glob?
        end

        def note_path_operands(words, redirects)
          writer = PATH_WRITERS.include?(File.basename(words.first.to_s))
          return unless writer || redirects.any?(&:write?)

          operands = (writer ? words.drop(1).reject { |word| word.start_with?("-") } : []) + redirects.select(&:write?).map(&:target)
          mark_unparsed!("path from a substitution") if operands.any? { |word| substituted_path?(word) }
          mark_unparsed!("path from a parameter expansion") if operands.any? { |word| parameter_path?(word) }
        end

        GIT_PATH_OPTIONS = %w[-C --git-dir --work-tree].freeze
        GIT_VALUE_OPTIONS = %w[-c --namespace --super-prefix --attr-source --config-env --exec-path].freeze

        def distrust_written_patch(words)
          return unless File.basename(words.first.to_s) == "git" && words.include?("apply")

          words.drop(words.index("apply") + 1).each do |word|
            next if word.start_with?("-") || !word.respond_to?(:dynamic=)

            word.dynamic = true if @unknown_writes || @written.key?(resolve(word))
          end
        end

        def note_git_paths(words)
          return unless File.basename(words.first.to_s) == "git"

          rest = words.drop(1)
          index = 0
          while index < rest.length && rest[index].start_with?("-")
            word = rest[index]
            if GIT_PATH_OPTIONS.include?(word)
              note_git_operand(rest[index + 1])
              index += 2
            elsif word.start_with?("--git-dir=", "--work-tree=")
              note_git_operand(word)
              index += 1
            else
              index += GIT_VALUE_OPTIONS.include?(word) ? 2 : 1
            end
          end
        end

        def note_git_operand(word)
          return unless word.respond_to?(:dynamic?) && word.dynamic?

          if substituted_path?(word) || (word.unsafe_subst? && !parameter_path?(word))
            mark_unparsed!("path from a substitution")
          elsif parameter_path?(word)
            mark_unparsed!("path from a parameter expansion")
          end
        end

        def parameter_path?(word)
          word.respond_to?(:param_form) && word.param_form ? true : false
        end

        def substituted_path?(word)
          word.respond_to?(:unsafe_subst?) && word.unsafe_subst? && (word.subst_lead || word.start_with?("/", "~"))
        end

        def apply_links(words, redirects)
          mapped = words.each_with_index.map { |word, i| i.zero? || word.start_with?("-") ? word : through_link(word) }
          moved = redirects.map do |redirect|
            redirect.target.nil? || redirect.here? ? redirect : Redirect.new(redirect.op, redirect.fd, through_link(redirect.target), redirect.body)
          end
          [mapped, moved]
        end

        def through_link(word)
          return word if word.respond_to?(:dynamic?) && word.dynamic?

          abs = resolve(word)
          return word unless abs

          @links.each do |link, target|
            return Word.new(File.join(target, abs[link.length..])) if abs == link || abs.start_with?("#{link}/")
          end
          word
        end

        def record_links(cmd)
          return unless cmd.name == "ln"

          pos, flags = split_operands(cmd.args)
          return unless flags.any? { |flag| flag.match?(/\A-[A-Za-z]*s/) || flag == "--symbolic" } && pos.length >= 2

          link = resolve(pos.last)
          return unless link

          link = File.join(link, File.basename(pos.first.to_s)) if File.directory?(link) || pos.last.to_s.end_with?("/")
          return if dynamic_word?(pos.first)

          @links[link] = Shell.safe_expand(pos.first, File.dirname(link))
        end

        def split_operands(args)
          flags = []
          pos = []
          args.each { |arg| (arg.start_with?("-") && arg.length > 1 && !pos.include?("--") ? flags : pos) << arg }
          [pos, flags]
        end
      end

      module Wrappers
        TABLE = {
          "sudo" => :sudo, "doas" => :sudo, "env" => :env, "nohup" => :plain, "time" => :time,
          "command" => :command, "builtin" => :plain, "exec" => :exec, "busybox" => :plain, "toybox" => :plain, "script" => :script, "nice" => :nice, "ionice" => :nice,
          "timeout" => :timeout, "stdbuf" => :stdbuf, "setsid" => :plain, "unbuffer" => :plain,
          "xargs" => :xargs, "flock" => :flock, "eval" => :eval_command,
          "chrt" => :pinned, "taskset" => :pinned, "unshare" => :unshare, "chroot" => :chroot, "watch" => :watch, "xvfb-run" => :xvfb_run
        }.freeze
        SUDO_LONG_VALUE = %w[--user --group --host --prompt --close-from --chroot --role --type --command-timeout --other-user --login-class --chdir].freeze
        UNSHARE_VALUE = %w[-R --root -w --wd -S -G --propagation --setgroups --map-user --map-group --map-users --map-groups].freeze
        XVFB_VALUE = %w[-e -f -n -p -s -w --error-file --auth-file --server-num --xauth-protocol --server-args --wait].freeze
        SUDO_VALUE_LETTERS = %w[u g h p C U T r t D R].freeze

        module_function

        def handler_for(words)
          name = File.basename(words.first.to_s)
          return :shell if SHELLS.include?(name) && words.drop(1).any? { |arg| arg.match?(CODE_FLAG) }

          TABLE[name]
        end

        def shell(words, parser, _env)
          args = words.drop(1)
          idx = args.index { |arg| arg.match?(CODE_FLAG) }
          if idx
            rest = args.drop(idx + 1)
            rest.shift if rest.first == "--"
            parser.parse_nested(rest.first, vars: positional_vars(rest.drop(1))) if rest.first
          end
          nil
        end

        def positional_vars(positional)
          values = positional.drop(1).map(&:to_s)
          bound = { "@" => values.join(" "), "*" => values.join(" "), "#" => values.length.to_s }
          values.first(9).each_with_index { |value, i| bound[(i + 1).to_s] = value }
          bound["0"] = positional.first.to_s unless positional.empty?
          bound
        end

        def exec(words, _parser, _env)
          skip_options(words.drop(1), %w[-a])
        end

        def time(words, _parser, _env)
          skip_options(words.drop(1), %w[-f -o --format --output])
        end

        def script(words, parser, _env)
          args = words.drop(1).map(&:to_s)
          args.each_with_index do |arg, i|
            value = if arg == "--command" || arg.match?(/\A-[A-Za-z]*c\z/) then args[i + 1]
                    elsif arg.start_with?("--command=") then arg.split("=", 2).last
                    end
            next unless value

            parser.parse_nested(value)
            return nil
          end
          parser.mark_unparsed!("script without a command")
          nil
        end

        def eval_command(words, parser, _env)
          parser.mark_opaque!
          parser.parse_nested(words.drop(1).join(" "))
          nil
        end

        def plain(words, _parser, _env)
          rest = words.drop(1)
          rest = rest.drop(1) while rest.first.to_s.start_with?("-") && rest.length > 1
          rest
        end

        def command(words, _parser, _env)
          rest = words.drop(1)
          return nil if rest.first.to_s.match?(/\A-[vV]/)

          rest.drop_while { |arg| arg == "-p" }
        end

        def sudo(words, parser, env)
          rest = skip_sudo_options(words.drop(1), parser)
          while rest.first.to_s.match?(ASSIGNMENT)
            name, value = rest.shift.split("=", 2)
            env[name] = value.to_s
          end
          rest
        end

        def env(words, parser, env)
          rest = words.drop(1)
          loop do
            first = rest.first.to_s
            if first == "-S" || first == "--split-string" || first.start_with?("--split-string=") || (first.start_with?("-S") && !first.start_with?("--"))
              return env_split(rest, parser)
            elsif %w[-C --chdir].include?(first)
              parser.set_cwd(rest[1])
              rest = rest.drop(2)
            elsif first.start_with?("--chdir=")
              parser.set_cwd(first.split("=", 2).last)
              rest = rest.drop(1)
            elsif first.start_with?("-C") && first.length > 2 && !first.start_with?("--")
              parser.set_cwd(first[2..])
              rest = rest.drop(1)
            elsif first == "-u"
              rest = rest.drop(2)
            elsif first.start_with?("-") && first != "-"
              rest = rest.drop(1)
            elsif first.match?(ASSIGNMENT)
              name, value = rest.first.split("=", 2)
              env[name] = value.to_s
              rest = rest.drop(1)
            else
              break
            end
          end
          rest
        end

        def skip_sudo_options(args, parser = nil)
          args = args.dup
          while args.first.to_s.start_with?("-") && args.first != "--"
            opt = args.shift.to_s
            if opt.start_with?("--")
              name, inline = opt.split("=", 2)
              value = inline || (SUDO_LONG_VALUE.include?(name) ? args.shift : nil)
              parser&.set_cwd(value) if name == "--chdir" && value
              next
            end

            letters = opt[1..].chars
            at = letters.index { |letter| SUDO_VALUE_LETTERS.include?(letter) }
            next unless at

            value = at == letters.length - 1 ? args.shift : opt[(at + 2)..]
            parser&.set_cwd(value) if letters[at] == "D" && value
          end
          args.shift if args.first == "--"
          args
        end

        def env_split(rest, parser)
          first = rest.first.to_s
          if first.start_with?("--split-string=")
            value = first.split("=", 2).last
            tail = rest.drop(1)
          elsif first == "-S" || first == "--split-string"
            value = rest[1].to_s
            tail = rest.drop(2)
          else
            value = first.delete_prefix("-S").delete_prefix("=")
            tail = rest.drop(1)
          end
          parser.parse_nested([value, *tail.map { |arg| Shellwords.escape(arg.to_s) }].join(" "))
          nil
        end

        def pinned(words, _parser, _env)
          args = words.drop(1)
          return nil if args.any? { |arg| %w[-p --pid].include?(arg.to_s) }

          skip_options(args, []).drop(1)
        end

        def unshare(words, _parser, _env)
          skip_options(words.drop(1), UNSHARE_VALUE)
        end

        def chroot(words, _parser, _env)
          skip_options(words.drop(1), %w[--userspec --groups]).drop(1)
        end

        def watch(words, parser, _env)
          rest = skip_options(words.drop(1), %w[-n --interval])
          parser.parse_nested(rest.map(&:to_s).join(" ")) unless rest.empty?
          nil
        end

        def xvfb_run(words, _parser, _env)
          skip_options(words.drop(1), XVFB_VALUE)
        end

        def xargs_files(words)
          args = words.drop(1).map(&:to_s)
          found = []
          args.each_with_index do |arg, at|
            if %w[-a --arg-file].include?(arg)
              found << args[at + 1]
            elsif arg.start_with?("--arg-file=")
              found << arg.split("=", 2).last
            elsif arg.match?(/\A-a.+/)
              found << arg[2..]
            end
          end
          found.compact
        end

        def nice(words, _parser, _env)
          skip_options(words.drop(1), %w[-n -c -p -P])
        end

        def timeout(words, _parser, _env)
          skip_options(words.drop(1), %w[-s -k --signal --kill-after]).drop(1)
        end

        def stdbuf(words, _parser, _env)
          skip_options(words.drop(1), %w[-i -o -e])
        end

        def flock(words, _parser, _env)
          skip_options(words.drop(1), %w[-w -E]).drop(1)
        end

        def xargs(words, _parser, _env)
          skip_options(words.drop(1), %w[-n -I -P -L -s -a -E -d -l -i])
        end

        def skip_options(args, with_value)
          args = args.dup
          while args.first.to_s.start_with?("-") && args.first != "--"
            opt = args.shift
            args.shift if with_value.include?(opt)
          end
          args.shift if args.first == "--"
          args
        end
      end
    end
  end
end
