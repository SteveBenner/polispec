#!/usr/bin/env ruby
# SPDX-License-Identifier: MIT

module Polispec
  module Code
    module Admin
      PHRASE = "promote specs".freeze
      LINK_PHRASE = "relink specs".freeze

      module_function

      def link(repo = Paths.specs_repo, dry_run: false)
        target = File.join(repo, "specs")
        raise Error, "#{target} does not exist" unless File.directory?(target)

        link = Paths.specs_link
        current = File.symlink?(link) ? File.readlink(link) : nil
        return { "link" => link, "target" => target, "changed" => false } if current == target
        raise Error, "#{link} exists and is not a symlink; refusing to replace it" if current.nil? && File.exist?(link)

        replaces = current
        return { "link" => link, "target" => target, "changed" => true, "dry_run" => true, "replaces" => replaces, "needs_terminal" => !replaces.nil? } if dry_run

        if replaces
          raise Operator::Tty::NotTty, "replacing #{link} (#{replaces}) with #{target} needs an interactive terminal; an agent shell cannot run it" unless Operator::Tty.terminal?

          Operator::Tty.confirm!(LINK_PHRASE, prompt: "Repoint #{link} from #{replaces} to #{target}.")
        end
        FileUtils.mkdir_p(File.dirname(link))
        File.delete(link) if replaces
        File.symlink(target, link)
        { "link" => link, "target" => target, "changed" => true, "replaced" => replaces }
      end

      def status(repo = Paths.specs_repo)
        stable = Code.git(repo, "rev-parse", "--verify", "--quiet", "refs/heads/stable").to_s.strip
        main = Code.git(repo, "rev-parse", "--verify", "--quiet", "refs/heads/main").to_s.strip
        ahead = stable.empty? || main.empty? ? nil : Code.git(repo, "rev-list", "--count", "#{stable}..#{main}").to_s.strip.to_i
        main_tree = Code.git(repo, "rev-parse", "--verify", "--quiet", "main^{tree}").to_s.strip
        stable_tree = Code.git(repo, "rev-parse", "--verify", "--quiet", "stable^{tree}").to_s.strip
        {
          "repo" => repo, "link" => Paths.specs_link, "linked" => File.symlink?(Paths.specs_link) && File.readlink(Paths.specs_link) == File.join(repo, "specs"),
          "stable" => stable.empty? ? nil : stable, "main" => main.empty? ? nil : main, "main_ahead" => ahead,
          "controls_main" => Controls.recorded(main_tree), "controls_stable" => Controls.recorded(stable_tree)
        }
      end

      def promote(repo = Paths.specs_repo)
        raise Operator::Tty::NotTty, "promote specs needs an interactive terminal; an agent shell cannot run it" unless Operator::Tty.terminal?

        main = Code.git(repo, "rev-parse", "--verify", "--quiet", "refs/heads/main").to_s.strip
        raise Error, "branch main does not exist in #{repo}" if main.empty?

        stable = Code.git(repo, "rev-parse", "--verify", "--quiet", "refs/heads/stable").to_s.strip
        raise Error, "stable is already at main" if stable == main
        if !stable.empty? && Code.git(repo, "merge-base", "--is-ancestor", stable, main).nil?
          raise Error, "stable is not an ancestor of main; promotion is fast-forward only"
        end

        pack = Pack.load(ref: "main", repo: repo)
        problems = Validator.new(pack).call
        raise Error, "code validate --ref main reports #{problems.length} problems; first: #{problems.first}" unless problems.empty?

        outcomes = Controls.new(pack).run
        Controls.record(pack, outcomes)
        failed = outcomes.select { |outcome| outcome.status == :fail }
        raise Error, "code controls --ref main has #{failed.length} survivors; first: #{failed.first.rule.id}: #{failed.first.message}" unless failed.empty?

        Operator::Tty.confirm!(PHRASE, prompt: "Promote polispec-specs #{stable.empty? ? '(new stable)' : stable[0, 12]} to main #{main[0, 12]}: #{outcomes.length} controls clean, 0 validation problems.")
        update = stable.empty? ? ["update-ref", "refs/heads/stable", main] : ["update-ref", "refs/heads/stable", main, stable]
        raise Error, "git update-ref refused the move" if Code.git(repo, *update).nil?

        record = { "ts" => Time.now.utc.iso8601, "repo" => repo, "from" => stable.empty? ? nil : stable, "to" => main, "controls" => outcomes.length, "actor" => ENV.fetch("USER", "operator") }
        State.append_jsonl("spec_promotions", record)
        record
      end
    end
  end
end
