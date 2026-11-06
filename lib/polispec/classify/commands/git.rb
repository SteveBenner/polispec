#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

require_relative "support"

module Polispec
  module Classify
    module Git
      extend Support::Family

      NAMES = %w[git].freeze
      READ_ONLY = %w[
        status log diff show ls-files ls-remote ls-tree rev-parse rev-list blame annotate grep cat-file describe shortlog
        show-ref name-rev remote config help version reflog for-each-ref merge-base diff-tree diff-index diff-files
        range-diff cherry count-objects fsck verify-commit verify-tag whatchanged add notes archive bundle gc prune
        repack maintenance sparse-checkout lfs difftool mergetool show-branch var check-ignore check-attr mktree
        hash-object pack-objects format-patch send-email bisect symbolic-ref commit-tree write-tree
        request-pull instaweb daemon citool gui gitk fast-export fast-import unpack-objects index-pack update-index
        column credential cat-file ls-tree
      ].freeze
      HANDLERS = {
        "commit" => :commit, "cherry-pick" => :commit, "revert" => :commit, "am" => :commit,
        "merge" => :merge, "pull" => :merge, "rebase" => :rebase, "reset" => :reset, "push" => :push,
        "tag" => :tag, "branch" => :branch, "checkout" => :checkout, "switch" => :switch,
        "restore" => :fs_path, "rm" => :fs_path, "mv" => :fs_path, "apply" => :apply, "clean" => :clean,
        "update-ref" => :update_ref, "config" => :config, "filter-branch" => :rewrite_all, "filter-repo" => :rewrite_all,
        "stash" => :stash, "read-tree" => :read_tree,
        "add" => :add, "fetch" => :fetch, "clone" => :clone, "init" => :init, "worktree" => :worktree, "submodule" => :submodule
      }.freeze
      GLOBAL_VALUE = %w[-c --namespace --super-prefix --config-env --attr-source].freeze
      PUSH_VALUE = %w[-o --push-option --repo --receive-pack --exec].freeze
      CLONE_VALUE = %w[-b --branch --depth -o --origin --reference --template -c --config -j --jobs --separate-git-dir --filter -u --upload-pack].freeze
      BRANCH_VALUE = %w[-u --set-upstream-to --contains --no-contains --merged --no-merged --sort --format --points-at].freeze
      TAG_VALUE = %w[-m -F -u --contains --no-contains --points-at --merged --no-merged --sort --format].freeze
      COMMIT_VALUE_LETTERS = "mFCctu".freeze
      CONFIG_VALUE = %w[-f --file --blob --type --default --includes-from].freeze
      CONFIG_READ = %w[--get --get-all --get-regexp --list -l].freeze
      CONFIG_UNSET = %w[--unset --unset-all --add --replace-all].freeze
      CONFIG_KEYS = /\A(?:remote\..+\.(?:push|pushurl|url)|alias\..+|core\.(?:hookspath|sshcommand|fsmonitor)|url\..+\.(?:pushinsteadof|insteadof))\z/i.freeze
      APPLY_INDEX_ONLY = %w[--cached --unidiff-zero --recount --ignore-whitespace --ignore-space-change -v --verbose].freeze
      ROOT_PATHSPECS = [".", ":/", ":/*", ":(top)", ":(top)*"].freeze

      Invocation = Struct.new(:cmd, :path, :sub, :args, :tree)
      Spec = Struct.new(:name, :tag, :force, :delete, :source)

      class << self
        def classify(cmd)
          return [] unless cmd.name == "git"

          inv = invocation(cmd)
          return [] unless inv

          handler = HANDLERS[inv.sub]
          return with_tree(inv, public_send(handler, inv)) if handler
          return [] if READ_ONLY.include?(inv.sub)

          with_tree(inv, [Support.act("fs.write", cmd.text, "path" => inv.path, "unknown" => true, "command" => "git #{inv.sub}")])
        end

        def with_tree(inv, actions)
          return actions if inv.tree.nil? || inv.tree == inv.path

          branch = Support::Repo.current_branch(inv.tree)
          copies = actions.select { |act| act.env_hint["path"] == inv.path }.flat_map do |act|
            hints = [act.env_hint.merge("path" => inv.tree)]
            hints << hints.first.merge("ref" => branch) if branch && hints.first["ref"] && hints.first["ref"] != branch
            hints.map { |hint| Action.new(class: act.action_class, env_hint: hint, raw: act.raw) }
          end
          actions + copies
        end

        def shapes(cmd)
          return [] unless cmd.name == "git"

          inv = invocation(cmd)
          return [] unless inv

          found = []
          found << "bulk_stage" if bulk_stage?(inv)
          found << "worktree_force" if worktree_force?(inv)
          found << "git_clean_dirs" if git_clean_dirs?(inv)
          found
        end

        def bulk_stage?(inv)
          case inv.sub
          when "add" then bulk_add?(inv)
          when "commit" then commit_all?(inv.args)
          else false
          end
        end

        def bulk_add?(inv)
          pos, flags = Support.split_args(inv.args, %w[--chmod --pathspec-from-file])
          return false if flags.include?("-n") || flags.include?("--dry-run")
          return true if flags.any? { |flag| %w[-A --all -u --update].include?(flag) }

          root = Support::Repo.find(inv.path)&.root
          pos.any? { |spec| ROOT_PATHSPECS.include?(spec) || (root && !Support.dynamic?(spec) && Support.expand(spec, inv.path) == root) }
        end

        def commit_all?(args)
          args.take_while { |arg| arg != "--" }.any? do |arg|
            arg == "--all" || (arg.match?(/\A-[a-zA-Z]+\z/) && short_flag_before_value?(arg, "a"))
          end
        end

        def short_flag_before_value?(arg, letter)
          arg.delete_prefix("-").each_char do |char|
            return true if char == letter
            return false if COMMIT_VALUE_LETTERS.include?(char)
          end
          false
        end

        def git_clean_dirs?(inv)
          return false unless inv.sub == "clean"

          args = inv.args.map(&:to_s)
          return false if args.any? { |arg| arg == "--dry-run" || arg.match?(/\A-[a-zA-Z]*n[a-zA-Z]*\z/) }

          args.any? { |arg| arg.match?(/\A-[a-zA-Z]*d[a-zA-Z]*\z/) }
        end

        def worktree_force?(inv)
          return false unless inv.sub == "worktree"

          verb = inv.args.first
          return true if verb == "prune"

          verb == "remove" && inv.args.drop(1).any? { |arg| arg == "--force" || arg.match?(/\A-[a-zA-Z]*f[a-zA-Z]*\z/) }
        end

        def add(inv)
          bulk_add?(inv) ? tree_writes(inv) : []
        end

        def invocation(cmd)
          path = cmd.cwd
          path = git_dir_path(cmd.env["GIT_DIR"].to_s, path) if cmd.env["GIT_DIR"]
          where = path
          tree = cmd.env["GIT_WORK_TREE"] ? cmd.env["GIT_WORK_TREE"].to_s : nil
          args = cmd.args.dup
          while (arg = args.shift)
            if arg == "-C"
              dir = args.shift
              path = Support.abs(dir, path)
              where = Support.abs(dir, where)
            elsif arg == "--git-dir" || arg.start_with?("--git-dir=")
              path = git_dir_path(arg == "--git-dir" ? args.shift : arg.split("=", 2).last, path)
            elsif arg == "--work-tree" || arg.start_with?("--work-tree=")
              tree = arg == "--work-tree" ? args.shift : arg.split("=", 2).last
            elsif GLOBAL_VALUE.include?(arg)
              args.shift
            elsif !arg.start_with?("-")
              return Invocation.new(cmd, path, arg, args, tree && Support.abs(tree, where))
            end
          end
          nil
        end

        def git_dir_path(dir, base)
          full = Support.abs(dir, base)
          File.basename(full) == ".git" ? File.dirname(full) : full
        end

        def commit(inv)
          return [] if inv.args.include?("--dry-run")

          out = [action(inv, "git.commit", ref: current(inv))]
          out << action(inv, "git.rewrite", ref: current(inv)) if inv.args.include?("--amend")
          out
        end

        def merge(inv)
          [action(inv, "git.merge", ref: current(inv))]
        end

        def rebase(inv)
          [action(inv, "git.rewrite", ref: current(inv))]
        end

        def rewrite_all(inv)
          [action(inv, "git.rewrite", ref: "*")]
        end

        def fs_path(inv)
          tree_writes(inv) + pathspec_writes(inv)
        end

        def apply(inv)
          paths = cached_patch_paths(inv)
          return fs_path(inv) unless paths

          paths.product([inv.path, inv.tree].compact.uniq).filter_map do |path, base|
            Support.write_action(Support.abs(path, base), inv.cmd.text)
          end
        end

        def cached_patch_paths(inv)
          flags, files = inv.args.partition { |arg| arg.to_s.start_with?("-") }
          names = flags.map(&:to_s)
          return nil unless names.include?("--cached") && (names - APPLY_INDEX_ONLY).empty?
          return nil unless files.length == 1 && !Support.dynamic?(files.first)

          text = Shell.read_script(Support.abs(files.first, inv.path))
          text && patch_paths(text)
        end

        def patch_paths(text)
          found = []
          text.each_line do |line|
            entry = patch_header_paths(line.chomp)
            return nil if entry == :unreadable

            found.concat(entry)
          end
          found.empty? ? nil : found.uniq
        end

        def patch_header_paths(line)
          case line
          when /\A(?:---|) (.*)\z/ then strip_patch_prefix(Regexp.last_match(1).split("\t").first.to_s)
          when /\A(?:rename|copy) (?:from|to) (.+)\z/ then Regexp.last_match(1).start_with?("\"") ? :unreadable : [Regexp.last_match(1)]
          when /\Adiff --git (.*)\z/ then diff_git_paths(Regexp.last_match(1))
          else []
          end
        end

        def diff_git_paths(rest)
          sides = rest.split(" ")
          return :unreadable unless sides.length == 2

          sides.flat_map do |side|
            stripped = strip_patch_prefix(side)
            return :unreadable if stripped == :unreadable

            stripped
          end
        end

        def strip_patch_prefix(path)
          return [] if path == "/dev/null"
          return :unreadable if path.empty? || path.start_with?("\"") || !path.include?("/")

          rest = path.split("/", 2).last
          rest.to_s.empty? ? :unreadable : [rest]
        end

        def tree_writes(inv)
          [inv.path, inv.tree].compact.uniq.map { |dir| Support.write_action(dir, inv.cmd.text) }
        end

        def pathspec_writes(inv)
          return [] unless %w[checkout restore rm mv].include?(inv.sub)

          args = inv.args.map(&:to_s)
          specs = args.include?("--") ? args.drop(args.index("--") + 1) : args.reject { |arg| arg.start_with?("-") }
          bases = [inv.path, inv.tree].compact.uniq
          specs.product(bases).filter_map do |spec, base|
            action = Support.write_action(Support.abs(spec, base), inv.cmd.text)
            action if action && action.action_class != "fs.write"
          end
        end

        def stash(inv)
          return [] if %w[list show].include?(inv.args.first)

          fs_path(inv)
        end

        def read_tree(inv)
          flags = Support.split_args(inv.args).last
          flags.any? { |flag| flag == "-m" || flag == "-u" || flag.match?(/\A-[a-zA-Z]*[mu][a-zA-Z]*\z/) || flag == "--reset" } ? fs_path(inv) : []
        end

        def clean(inv)
          return [] if inv.args.any? { |arg| arg == "--dry-run" || arg.match?(/\A-[a-zA-Z]*n[a-zA-Z]*\z/) }

          forced = inv.args.any? { |arg| arg == "--force" || arg.match?(/\A-[a-zA-Z]*f[a-zA-Z]*\z/) }
          forced ? fs_path(inv) + [Support.act("fs.delete", inv.cmd.text, "path" => inv.path, "command" => "git clean")] : fs_path(inv)
        end

        def reset(inv)
          before, after = inv.args.map(&:to_s).partition.with_index { |_, i| i < (inv.args.index("--") || inv.args.length) }
          pos, flags = Support.split_args(before)
          return [] if flags.include?("-p") || flags.include?("--patch")

          touches = flags.any? { |flag| %w[--hard --merge --keep].include?(flag) } || pospath?(inv, pos) || after.length > 1
          rev = pos.find { |arg| !File.exist?(File.join(inv.path, arg)) }
          return touches ? fs_path(inv) : [] if rev.nil? || %w[HEAD @].include?(rev)

          out = [action(inv, "git.rewrite", ref: current(inv))]
          out << action(inv, "git.rewrite", ref: ref_name(rev)) if branch_like?(rev)
          out.concat(fs_path(inv)) if touches
          out
        end

        def pospath?(inv, pos)
          pos.any? { |arg| File.exist?(File.join(inv.path, arg)) }
        end

        def branch_like?(rev)
          !rev.match?(/[~^@{}:]/) && !rev.match?(/\A[0-9a-f]{7,40}\z/) && rev != "HEAD"
        end

        def push(inv)
          pos, flags = Support.split_args(inv.args, PUSH_VALUE)
          return [] if dry_run?(flags)

          remote = pos.shift
          force = flags.any? { |f| f.start_with?("--force") || f.match?(/\A-[a-zA-Z]*f[a-zA-Z]*\z/) }
          delete = flags.include?("-d") || flags.include?("--delete")
          push_specs(inv, pos, flags).flat_map { |spec| push_actions(inv, remote, spec, force, delete) }
        end

        def dry_run?(flags)
          flags.any? { |flag| flag == "--dry-run" || flag.match?(/\A-[a-zA-Z]*n[a-zA-Z]*\z/) }
        end

        def push_specs(inv, pos, flags)
          return [Spec.new("*", false, false, false)] if flags.include?("--all") || flags.include?("--mirror")

          specs = pos.map { |text| refspec(inv, text) }
          specs << Spec.new(current(inv), false, false, false) if specs.empty? && !flags.include?("--tags")
          specs << Spec.new("*", true, false, false) if flags.include?("--tags") || flags.include?("--follow-tags")
          specs
        end

        def refspec(inv, text)
          force = text.start_with?("+")
          body = text.sub(/\A\+/, "")
          src, dst = body.include?(":") ? body.split(":", 2) : [body, body]
          target = dst == "HEAD" ? current(inv) : dst
          name = body == ":" || dst.to_s.match?(/[*?\[{]/) ? "*" : ref_name(target)
          Spec.new(name, target.to_s.start_with?("refs/tags/"), force, src.empty?, src.empty? ? nil : src)
        end

        def config(inv)
          pos, flags = Support.split_args(inv.args, CONFIG_VALUE)
          return [] if flags.any? { |flag| CONFIG_READ.include?(flag) }

          verb = %w[set unset].include?(pos.first) ? pos.shift : nil
          return [] if pos.empty?

          writing = verb || pos.length > 1 || flags.any? { |flag| CONFIG_UNSET.include?(flag) }
          return [] unless writing && CONFIG_KEYS.match?(pos.first.to_s)

          [Support.act("policy.edit", inv.cmd.text, "path" => inv.path, "command" => "git config")]
        end

        def push_actions(inv, remote, spec, force, delete)
          extra = { remote: remote }
          extra[spec.tag ? :tag : :ref] = spec.name
          extra[:source] = spec.source if spec.source && !spec.tag && spec.source != spec.name
          classes = ["git.push"]
          classes << "git.rewrite" if (force || spec.force) && !spec.tag
          classes << "git.branch" if (delete || spec.delete) && !spec.tag
          extra[:delete] = true if (delete || spec.delete) && spec.tag
          extra[:deleting] = true if (delete || spec.delete) && !spec.tag
          classes.map { |klass| Support.act(klass, inv.cmd.text, base(inv).merge(Support.hint(extra))) }
        end

        def tag(inv)
          pos, flags = Support.split_args(inv.args, TAG_VALUE)
          listing = flags.any? { |f| %w[-l --list -n -v --verify --contains --points-at --merged --no-merged].include?(f) }
          return [] if listing || pos.empty?

          ref = pos[1] && !pos[1].match?(/\A[0-9a-f]{7,40}\z/) ? ref_name(pos[1]) : current(inv)
          deleting = flags.include?("-d") || flags.include?("--delete")
          out = [action(inv, "git.tag", ref: ref, tag: pos[0], at: pos[1], delete: deleting ? true : nil)]
          out << action(inv, "git.rewrite", ref: ref, tag: pos[0]) if flags.include?("-f") || flags.include?("--force")
          out
        end

        def branch(inv)
          pos, flags = Support.split_args(inv.args, BRANCH_VALUE)
          return [] if pos.empty? || flags.any? { |f| %w[-l --list --show-current -u --set-upstream-to --unset-upstream --edit-description].include?(f) }

          names = branch_names(pos, flags)
          creating = !branch_delete?(flags) && flags.none? { |f| %w[-m -M -c -C --move --copy].include?(f) }
          out = names.map { |name| action(inv, "git.branch", ref: ref_name(name), base: creating ? (pos[1] || "HEAD") : nil) }
          out << action(inv, "git.rewrite", ref: ref_name(pos[0])) if branch_force?(flags) && !branch_delete?(flags)
          out
        end

        def branch_delete?(flags)
          flags.any? { |f| %w[-d -D --delete].include?(f) }
        end

        def branch_force?(flags)
          flags.any? { |f| %w[-f --force -M -C].include?(f) }
        end

        def branch_names(pos, flags)
          return pos if branch_delete?(flags) || flags.any? { |f| %w[-m -M -c -C --move --copy].include?(f) }

          [pos[0]]
        end

        def checkout(inv)
          created = Support.option_value(inv.args, "-b", "-B", "--orphan")
          return branch_created(inv, created, inv.args.include?("-B")) if created
          return fs_path(inv) if inv.args.include?("--") || inv.args.first == "."
          return [] if inv.args.any? { |arg| %w[-p --patch].include?(arg) }

          pos, = Support.split_args(inv.args)
          pos.empty? ? [] : fs_path(inv)
        end

        def switch(inv)
          created = Support.option_value(inv.args, "-c", "-C", "--create", "--force-create")
          return branch_created(inv, created, inv.args.include?("-C") || inv.args.include?("--force-create")) if created

          pos, = Support.split_args(inv.args)
          pos.empty? ? [] : fs_path(inv)
        end

        def branch_created(inv, name, force)
          out = [action(inv, "git.branch", ref: ref_name(name), base: start_point(inv, name))]
          out << action(inv, "git.rewrite", ref: ref_name(name)) if force
          out
        end

        def start_point(inv, name)
          args = inv.args.dup
          index = args.index { |arg| %w[-b -B -c -C --create --force-create --orphan].include?(arg) }
          args.slice!(index, 2) if index
          pos, = Support.split_args(args)
          pos.first || "HEAD"
        end

        def update_ref(inv)
          pos, flags = Support.split_args(inv.args)
          return [] if pos.empty?

          klass = flags.include?("-d") ? "git.branch" : "git.rewrite"
          [action(inv, klass, ref: ref_name(pos[0]))]
        end

        def fetch(inv)
          pos, = Support.split_args(inv.args)
          pos.drop(1).filter_map do |text|
            next unless text.include?(":")

            dst = text.sub(/\A\+/, "").split(":", 2).last.to_s
            next if dst.empty? || dst.start_with?("refs/remotes/", "refs/tags/")

            action(inv, "git.merge", ref: ref_name(dst))
          end
        end

        def clone(inv)
          pos, = Support.split_args(inv.args, CLONE_VALUE)
          return [] if pos.empty?

          dest = pos[1] || File.basename(pos[0].sub(%r{[/:]+\z}, ""), ".git")
          [Support.write_action(Support.abs(dest, inv.path), inv.cmd.text)]
        end

        def init(inv)
          pos, = Support.split_args(inv.args, %w[--template --separate-git-dir -b --initial-branch])
          [Support.write_action(Support.abs(pos.first || ".", inv.path), inv.cmd.text)]
        end

        def worktree(inv)
          verb, *rest = inv.args
          pos, = Support.split_args(rest, %w[-b -B --reason])
          out = []
          created = Support.option_value(rest, "-b", "-B")
          out << action(inv, "git.branch", ref: ref_name(created), base: pos[1] || "HEAD") if created
          out << Support.act("fs.delete", inv.cmd.text, "path" => inv.path, "command" => "git worktree prune") if verb == "prune" && !rest.include?("--dry-run") && !rest.include?("-n")
          return out if pos.empty? || %w[list prune].include?(verb)

          out << Support.write_action(Support.abs(pos.first, inv.path), inv.cmd.text) if %w[add remove move].include?(verb)
          out
        end

        def submodule(inv)
          return [] unless %w[add update init deinit sync].include?(inv.args.first)

          fs_path(inv)
        end

        def action(inv, klass, ref: nil, tag: nil, base: nil, delete: nil, at: nil)
          Support.act(klass, inv.cmd.text, base(inv).merge(Support.hint(ref: ref, tag: tag, at: at, base: base, delete: delete)))
        end

        def base(inv)
          { "path" => inv.path }
        end

        def current(inv)
          Support::Repo.current_branch(inv.path)
        end

        def ref_name(raw)
          return nil if raw.nil?

          raw.to_s.sub(/\A\+/, "").sub(%r{\Arefs/(?:heads|tags)/}, "").sub(%r{\Aheads/}, "").sub(%r{\Arefs/remotes/[^/]+/}, "").sub(%r{\A(?:origin|upstream)/}, "")
        end
      end
    end

    Registry.register("git", Git)
  end
end
