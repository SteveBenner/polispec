#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require "strscan"

module Polispec
  module Classify
    module Shell
      MAX_DEPTH = 6
      SHELLS = %w[bash sh zsh dash ksh ash].freeze
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

      class Word < String
        attr_accessor :dynamic

        def dynamic?
          dynamic ? true : false
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

      Command = Struct.new(:argv, :cwd, :redirects, :env, :pipeline, :index, :text, :sudo, :host, :xargs, keyword_init: true) do
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

      Script = Struct.new(:commands, :text, :opaque, :followed)

      module_function

      def parse(text, cwd, depth = 0, vars = nil)
        vars ||= default_vars(cwd)
        parser = Parser.new(text.to_s, cwd, vars, depth)
        commands = parser.run
        nested = embedded_scripts(commands, depth)
        Script.new(commands + nested.flat_map(&:commands), text.to_s, parser.opaque || nested.any?(&:opaque), (parser.followed + nested.flat_map(&:followed)).uniq)
      end

      def default_vars(cwd)
        { "HOME" => Dir.home, "PWD" => cwd.to_s }
      end

      def embedded_scripts(commands, depth)
        return [] if depth >= MAX_DEPTH

        commands.flat_map do |cmd|
          embedded_sources(cmd).map { |source| parse(source, cmd.cwd, depth + 1) }
        end
      end

      def embedded_sources(cmd)
        bodies = cmd.redirects.select(&:here?).map { |redirect| redirect.op == "<<<" ? redirect.target : redirect.body }.compact
        return bodies if SHELLS.include?(cmd.name)
        return [] unless INTERPRETERS.include?(cmd.name)

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
        File.file?(path) && File.size(path) <= MAX_SQL_FILE ? File.read(path) : nil
      rescue SystemCallError
        nil
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
        File.file?(path) && File.readable?(path) && File.size(path) <= MAX_SCRIPT_FILE ? File.read(path) : nil
      rescue SystemCallError
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

        attr_reader :commands, :opaque, :followed
        attr_accessor :vars, :cwd, :written, :unknown_writes

        def initialize(text, cwd, vars, depth, budget = nil, following = false)
          @budget = budget || FollowBudget.new(0, nil, false)
          @following = following
          @s = text
          @ss = StringScanner.new(text)
          @cwd = cwd.to_s.empty? ? Dir.pwd : cwd.to_s
          @vars = vars
          @depth = depth
          @commands = []
          @pipe = nil
          @heredocs = []
          @tok_start = 0
          @quoted = false
          @opaque = false
          @written = {}
          @unknown_writes = false
          @followed = []
        end

        def run
          parse_list(false)
          commands
        end

        def parse_nested(source, following = @following)
          return if @depth >= MAX_DEPTH

          child = Parser.new(source.to_s, @cwd, @vars.dup, @depth + 1, @budget, following)
          @commands.concat(child.run)
          @opaque ||= child.opaque
          @followed.concat(child.followed)
        end

        def parse_sourced(source)
          child = Parser.new(source.to_s, @cwd, @vars.dup, @depth + 1, @budget, true)
          child.written = @written.dup
          child.unknown_writes = @unknown_writes
          @commands.concat(child.run)
          @opaque ||= child.opaque
          @followed.concat(child.followed)
          @vars = child.vars
          @cwd = child.cwd
          @written = child.written
          @unknown_writes = child.unknown_writes
        end

        def mark_opaque!
          @opaque = true
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
          File.expand_path(file.to_s, @cwd)
        rescue ArgumentError
          nil
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
          saved = [@cwd, @vars.dup, @pipe]
          @pipe = nil
          parse_list(true)
          @cwd, @vars, @pipe = saved
        end

        def nested_list
          saved = [@cwd, @vars.dup, @pipe, @heredocs]
          @pipe = nil
          @heredocs = []
          parse_list(true)
          @cwd, @vars, @pipe, @heredocs = saved
        end

        def add_word(seg, word)
          seg.start ||= @tok_start
          return seg.words << word unless seg.pending

          redirect = Redirect.new(seg.pending[1], seg.pending[2], word, nil)
          seg.redirects << redirect
          @heredocs << [redirect, word.to_s, seg.pending[1] == "<<-"] if %w[<< <<-].include?(seg.pending[1])
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
          return [:eof] if @ss.eos?

          if @ss.peek(1) == "\n"
            @ss.getch
            return [:nl]
          end
          return [:word, process_substitution] if @ss.check(/[<>]\(/)

          operator_token || word_token
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
          word = read_word
          return [:word, word] if @quoted || !word.empty?

          @ss.getch
          scan_token
        end

        def process_substitution
          start = @ss.pos
          @ss.pos += 2
          nested_list
          word = Word.new(@s[start...@ss.pos])
          word.dynamic = true
          word
        end

        def read_word
          word = Word.new("")
          @quoted = false
          loop do
            char = @ss.peek(1)
            break if char.empty? || WORD_STOP.include?(char)

            consume(word, char)
          end
          word
        end

        def consume(word, char)
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
          @ss.getch
        end

        def double_quoted(word)
          @quoted = true
          @ss.getch
          until @ss.eos?
            char = @ss.peek(1)
            break @ss.getch if char == '"'

            dq_char(word, char)
          end
        end

        def dq_char(word, char)
          case char
          when "\\" then dq_escape(word)
          when "$" then dollar(word)
          when "`" then backtick(word)
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
          boundary = @ss.eos? || WORD_STOP.include?(@ss.peek(1)) || @ss.peek(1) == "/"
          word << (at_start && boundary ? @vars.fetch("HOME", Dir.home) : "~")
        end

        def dollar(word)
          @ss.getch
          if @ss.check(/\(\(/)
            arithmetic(word)
          elsif @ss.check(/\(/)
            command_substitution(word)
          elsif @ss.check(/\{/)
            braced(word)
          else
            plain_variable(word)
          end
        end

        def arithmetic(word)
          depth = 0
          until @ss.eos?
            char = @ss.getch
            depth += 1 if char == "("
            depth -= 1 if char == ")"
            break if depth.zero?
          end
          word << "0"
          word.dynamic = true
        end

        def command_substitution(word)
          start = @ss.pos - 1
          @ss.getch
          nested_list
          word << @s[start...@ss.pos]
          word.dynamic = true
        end

        def braced(word)
          @ss.getch
          body = @ss.scan(/[^}]*/) || ""
          @ss.getch
          name = body.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) ? body : nil
          append_variable(word, name, "${#{body}}")
        end

        def plain_variable(word)
          name = @ss.scan(/[A-Za-z_][A-Za-z0-9_]*/)
          return append_variable(word, name, "$#{name}") if name

          special = @ss.scan(/[?$!@*#\-0-9]/)
          return word << "$" unless special

          word << "$#{special}"
          word.dynamic = true
        end

        def append_variable(word, name, literal)
          if name && @vars.key?(name)
            word << @vars[name].to_s
          else
            word << literal
            word.dynamic = true
          end
        end

        def backtick(word)
          start = @ss.pos
          @ss.getch
          inner = +""
          until @ss.eos?
            char = @ss.getch
            break if char == "`"

            char = @ss.getch if char == "\\" && @ss.peek(1) == "`"
            inner << char
          end
          parse_nested(inner)
          word << @s[start...@ss.pos]
          word.dynamic = true
        end

        def read_heredocs
          @heredocs.each do |redirect, delim, strip|
            lines = []
            until @ss.eos?
              line = @ss.scan(/[^\n]*\n?/)
              check = line.chomp
              check = check.sub(/\A\t+/, "") if strip
              break if check == delim

              lines << line
            end
            redirect.body = lines.join
          end
          @heredocs.clear
        end

        def emit(seg, piped)
          finish_segment(seg)
          @pipe = nil unless piped
        end

        def finish_segment(seg)
          return if seg.words.empty? && seg.redirects.empty?

          text = @s[(seg.start || @tok_start)...@tok_start].to_s.strip
          words = seg.words.dup
          env = take_assignments(words)
          words.shift while KEYWORDS.include?(words.first.to_s)
          return set_variables(env) if words.empty? && seg.redirects.empty?
          return add_command([], seg.redirects, env, text, false) if words.empty?
          return if CLAUSES.include?(words.first.to_s)

          dispatch(words, seg.redirects, env, text)
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
          env.each { |name, value| @vars[name] = value.to_s unless value.dynamic? }
        end

        def dispatch(words, redirects, env, text)
          sudo = false
          xargs = false
          loop do
            return if words.empty?

            handler = Wrappers.handler_for(words)
            break unless handler

            sudo ||= %w[sudo doas].include?(File.basename(words.first))
            xargs ||= File.basename(words.first) == "xargs"
            words = Wrappers.public_send(handler, words, self, env)
            return if words.nil?
          end
          finalize(words, redirects, env, text, sudo, xargs)
        end

        def finalize(words, redirects, env, text, sudo, xargs = false)
          name = File.basename(words.first)
          return change_directory(words) if %w[cd pushd].include?(name)
          return export_variables(words) if %w[export declare local readonly typeset].include?(name)

          return if follow_source(words, redirects, env, sudo, xargs)

          host = follow_script(words) == :followed
          added = add_command(words, redirects, env, text, sudo, xargs)
          added.host = true if host && added
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

        def change_directory(words)
          target = words.drop(1).reject { |arg| arg.start_with?("-") }.first
          target ||= @vars.fetch("HOME", Dir.home)
          return if target.respond_to?(:dynamic?) && target.dynamic?
          return if target == "-"

          @cwd = resolve(target) || @cwd
        end

        def export_variables(words)
          words.drop(1).each do |word|
            next unless word.match?(ASSIGNMENT) && !(word.respond_to?(:dynamic?) && word.dynamic?)

            name, value = word.split("=", 2)
            @vars[name] = value.to_s
          end
        end

        def add_command(words, redirects, env, text, sudo, xargs = false)
          @pipe ||= []
          cmd = Command.new(argv: words, cwd: @cwd, redirects: redirects, env: env, pipeline: @pipe, index: @pipe.length, text: text, sudo: sudo, xargs: xargs)
          return halt_following unless !@following || @budget.spend

          @pipe << cmd
          @commands << cmd
          record_writes(cmd)
          cmd
        end
      end

      module Wrappers
        TABLE = {
          "sudo" => :sudo, "doas" => :sudo, "env" => :env, "nohup" => :plain, "time" => :plain,
          "command" => :command, "builtin" => :plain, "exec" => :plain, "nice" => :nice, "ionice" => :nice,
          "timeout" => :timeout, "stdbuf" => :stdbuf, "setsid" => :plain, "unbuffer" => :plain,
          "xargs" => :xargs, "flock" => :flock, "eval" => :eval_command
        }.freeze
        SUDO_ARGS = %w[-u -g -h -p -C -U -T -r -t -D -R].freeze

        module_function

        def handler_for(words)
          name = File.basename(words.first.to_s)
          return :shell if SHELLS.include?(name) && words.drop(1).any? { |arg| arg.match?(CODE_FLAG) }

          TABLE[name]
        end

        def shell(words, parser, _env)
          args = words.drop(1)
          idx = args.index { |arg| arg.match?(CODE_FLAG) }
          parser.parse_nested(args[idx + 1]) if idx && args[idx + 1]
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

        def sudo(words, _parser, env)
          rest = skip_options(words.drop(1), SUDO_ARGS)
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
            if %w[-C --chdir].include?(first)
              parser.set_cwd(rest[1])
              rest = rest.drop(2)
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
