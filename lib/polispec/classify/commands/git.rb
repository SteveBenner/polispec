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
        range-diff cherry count-objects fsck verify-commit verify-tag whatchanged stash add notes archive bundle gc prune
        repack maintenance sparse-checkout lfs difftool mergetool show-branch var check-ignore check-attr mktree
        hash-object pack-objects format-patch send-email bisect symbolic-ref commit-tree write-tree read-tree
        request-pull instaweb daemon citool gui gitk fast-export fast-import unpack-objects index-pack update-index
        column credential cat-file ls-tree
      ].freeze
      HANDLERS = {
        "commit" => :commit, "cherry-pick" => :commit, "revert" => :commit, "am" => :commit,
        "merge" => :merge, "pull" => :merge, "rebase" => :rebase, "reset" => :reset, "push" => :push,
        "tag" => :tag, "branch" => :branch, "checkout" => :checkout, "switch" => :switch,
        "restore" => :fs_path, "rm" => :fs_path, "mv" => :fs_path, "apply" => :fs_path, "clean" => :clean,
        "update-ref" => :update_ref, "filter-branch" => :rewrite_all, "filter-repo" => :rewrite_all,
        "add" => :add, "fetch" => :fetch, "clone" => :clone, "init" => :init, "worktree" => :worktree, "submodule" => :submodule
      }.freeze
      GLOBAL_VALUE = %w[-c --namespace --super-prefix --config-env].freeze
      PUSH_VALUE = %w[-o --push-option --repo --receive-pack --exec].freeze
      CLONE_VALUE = %w[-b --branch --depth -o --origin --reference --template -c --config -j --jobs --separate-git-dir --filter -u --upload-pack].freeze
      BRANCH_VALUE = %w[-u --set-upstream-to --contains --no-contains --merged --no-merged --sort --format --points-at].freeze
      TAG_VALUE = %w[-m -F -u --contains --no-contains --points-at --merged --no-merged --sort --format].freeze
      COMMIT_VALUE_LETTERS = "mFCctu".freeze
      ROOT_PATHSPECS = [".", ":/", ":/*", ":(top)", ":(top)*"].freeze

      Invocation = Struct.new(:cmd, :path, :sub, :args)
      Spec = Struct.new(:name, :tag, :force, :delete)

      class << self
        def classify(cmd)
          return [] unless cmd.name == "git"

          inv = invocation(cmd)
          return [] unless inv

          handler = HANDLERS[inv.sub]
          return public_send(handler, inv) if handler
          return [] if READ_ONLY.include?(inv.sub)

          [Support.act("fs.write", cmd.text, "path" => inv.path, "unknown" => true, "command" => "git #{inv.sub}")]
        end

        def shapes(cmd)
          return [] unless cmd.name == "git"

          inv = invocation(cmd)
          return [] unless inv

          found = []
          found << "bulk_stage" if bulk_stage?(inv)
          found << "worktree_force" if worktree_force?(inv)
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
          pos.any? { |spec| ROOT_PATHSPECS.include?(spec) || (root && !Support.dynamic?(spec) && File.expand_path(spec, inv.path) == root) }
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

        def worktree_force?(inv)
          return false unless inv.sub == "worktree"

          verb = inv.args.first
          return true if verb == "prune"

          verb == "remove" && inv.args.drop(1).any? { |arg| arg == "--force" || arg.match?(/\A-[a-zA-Z]*f[a-zA-Z]*\z/) }
        end

        def add(inv)
          bulk_add?(inv) ? [Support.write_action(inv.path, inv.cmd.text)] : []
        end

        def invocation(cmd)
          path = cmd.cwd
          args = cmd.args.dup
          while (arg = args.shift)
            if arg == "-C"
              path = Support.abs(args.shift, path)
            elsif arg == "--git-dir" || arg.start_with?("--git-dir=")
              path = git_dir_path(arg == "--git-dir" ? args.shift : arg.split("=", 2).last, path)
            elsif arg == "--work-tree" || arg.start_with?("--work-tree=")
              path = Support.abs(arg == "--work-tree" ? args.shift : arg.split("=", 2).last, path)
            elsif GLOBAL_VALUE.include?(arg)
              args.shift
            elsif !arg.start_with?("-")
              return Invocation.new(cmd, path, arg, args)
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
          [Support.write_action(inv.path, inv.cmd.text)]
        end

        def clean(inv)
          return [] if inv.args.any? { |arg| arg == "--dry-run" || arg.match?(/\A-[a-zA-Z]*n[a-zA-Z]*\z/) }

          forced = inv.args.any? { |arg| arg == "--force" || arg.match?(/\A-[a-zA-Z]*f[a-zA-Z]*\z/) }
          forced ? fs_path(inv) + [Support.act("fs.delete", inv.cmd.text, "path" => inv.path, "command" => "git clean")] : fs_path(inv)
        end

        def reset(inv)
          pos, flags = Support.split_args(inv.args)
          return [] if flags.include?("-p") || flags.include?("--patch") || inv.args.include?("--")

          mode = flags.any? { |flag| %w[--hard --soft --mixed --merge --keep].include?(flag) }
          rev = pos.find { |arg| !File.exist?(File.join(inv.path, arg)) }
          return mode ? fs_path(inv) : [] if rev.nil? || %w[HEAD @].include?(rev)

          out = [action(inv, "git.rewrite", ref: current(inv))]
          out << action(inv, "git.rewrite", ref: ref_name(rev)) if branch_like?(rev)
          out
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
          Spec.new(ref_name(target), target.to_s.start_with?("refs/tags/"), force, src.empty?)
        end

        def push_actions(inv, remote, spec, force, delete)
          extra = { remote: remote }
          extra[spec.tag ? :tag : :ref] = spec.name
          classes = ["git.push"]
          classes << "git.rewrite" if (force || spec.force) && !spec.tag
          classes << "git.branch" if (delete || spec.delete) && !spec.tag
          extra[:delete] = true if (delete || spec.delete) && spec.tag
          classes.map { |klass| Support.act(klass, inv.cmd.text, base(inv).merge(Support.hint(extra))) }
        end

        def tag(inv)
          pos, flags = Support.split_args(inv.args, TAG_VALUE)
          listing = flags.any? { |f| %w[-l --list -n -v --verify --contains --points-at --merged --no-merged].include?(f) }
          return [] if listing || pos.empty?

          ref = pos[1] && !pos[1].match?(/\A[0-9a-f]{7,40}\z/) ? ref_name(pos[1]) : current(inv)
          deleting = flags.include?("-d") || flags.include?("--delete")
          out = [action(inv, "git.tag", ref: ref, tag: pos[0], delete: deleting ? true : nil)]
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

          []
        end

        def switch(inv)
          created = Support.option_value(inv.args, "-c", "-C", "--create", "--force-create")
          return [] unless created

          branch_created(inv, created, inv.args.include?("-C") || inv.args.include?("--force-create"))
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

        def action(inv, klass, ref: nil, tag: nil, base: nil, delete: nil)
          Support.act(klass, inv.cmd.text, base(inv).merge(Support.hint(ref: ref, tag: tag, base: base, delete: delete)))
        end

        def base(inv)
          { "path" => inv.path }
        end

        def current(inv)
          Support::Repo.current_branch(inv.path)
        end

        def ref_name(raw)
          return nil if raw.nil?

          raw.to_s.sub(/\A\+/, "").sub(%r{\Arefs/(?:heads|tags)/}, "").sub(%r{\Arefs/remotes/[^/]+/}, "").sub(%r{\A(?:origin|upstream)/}, "")
        end
      end
    end

    Registry.register("git", Git)
  end
end
