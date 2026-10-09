# Code specs

polispec applies a tree of composable policies, kept in the code specs repository, whenever an agent writes code. This page describes the engine: `lib/polispec/code/**` and the commands `polispec code`, `polispec specs` and `polispec code-hook`.

## The pack

- The pack is the code specs repository: `specs/<spec path>/spec.yml` (schema `polispec.spec/v1`), `controls/<spec path>/<slug>.bad.<ext>` and `.good.<ext>`, `enforcers/<language>/<name>.rb`, `enforcers/rubocop/base.yml` (generated).
- Location: `POLISPEC_SPECS_REPO`, else the parent of the `~/.polispec/specs` symlink, else the `polispec.code.specs_repo` setting (default `~/polispec-specs`).
- Hooks read the `stable` ref with `git ls-tree` and `git cat-file --batch`, never the working tree. `--ref main`, `--ref worktree` or any git ref is for authoring; `POLISPEC_CODE_REF` sets the default ref for every command and the hook.
- The parsed pack is cached under the state directory, keyed by tree sha and polispec version.

## Language and chain

A file's language comes from the `detection` blocks of the specs: extension (longest suffix first), exact filename, shebang on line 1, modeline in the first 5 lines, within the first 4 KiB. No match gives `unknown`, which receives only the `*` specs.

The chain for a language is every spec whose `activation.languages` lists the language or `*`, ordered by depth then path, each followed by its ref'd subspecs depth-first. The chain digest is sha256 over the tree sha and the chain's spec paths.

## Injection

Before the first write of a language in a session, the hook injects the chain: one line per rule, `[id] LEVEL statement`, MUST and MUST_NOT first, then SHOULD, by severity, capped per spec at `defaults.inject.budget_lines` with a pointer `N more: polispec code show <spec>`. Agent-class rules append their `lens.violation` and one rationalization. The text is capped at 9500 characters, under Claude Code's 10000-character limit for hook context.

Claude Code documents `hookSpecificOutput.additionalContext` for PreToolUse, delivered next to the tool result. The hook uses it for Claude. Other harnesses, and any session with `POLISPEC_CODE_PRE_CONTEXT=deny`, get deny-once: the first write is denied with the injection as the reason and the identical retry is allowed.

`polispec.code.inject` is `once` (per session and chain digest, re-armed by SessionStart with source `compact` or `clear`) or `every_write`.

## Checking

`polispec.code.check_at` selects when the check runs.

- `pre_write`: the Write, Edit, MultiEdit or apply_patch is applied to the file in memory, the changed lines are computed with a minimal LCS diff, and the edit is denied before anything lands when a MUST or MUST_NOT finding sits on a changed line.
- `post_write`: the write lands, then PostToolUse returns a block carrying the findings.
- SHOULD findings are always reported after the write, as PostToolUse context.

`polispec.code.enforce` is `tiered` (block MUST, warn SHOULD) or `advise` (never block). NotebookEdit injects only; its cells are not simulated.

Findings on unchanged lines carry `baseline: true` and never block (the ratchet). `polispec code baseline <repo>` records `{policy, path, count}` per repository key (sha256 of the origin URL, else the real path) under the state directory `baselines/`; a count only shrinks, and a write that raises it adds a SHOULD finding. A rule with `ratchet: false` treats every finding as changed.

Waivers are read from `specs/polispec/code-waivers.yml` at the repository's HEAD. A `waive` entry suppresses the policy (or any policy under that id prefix) on the matching paths; a `tighten` entry raises its level. An entry past `review_after` is reported as expired and stops suppressing. `waivable: never` rules ignore waivers; `waiver_tty` rules need `approved`.

## Enforcers

| kind | behavior |
| --- | --- |
| ripper | a Ruby script in the pack defining `check(source, path)` returning `[[line, message], ...]`, loaded with `load` into an anonymous module |
| grep | `enforcer.pattern` as a regular expression against each line |
| rubocop | the pack's bundled RuboCop through `bundle exec` in the pack directory, `--server` when it works, `--stdin <path> --format json --only <cops>`, configured by `enforcers/rubocop/base.yml` or a config generated on the fly |
| script | `enforcer.ref` executed with the path as argv and the text on stdin, JSON lines `{"line":N,"message":"..."}` out |
| hook | recorded only; names an existing guard that polispec does not execute |

An enforcer that crashes, times out (`budget_ms`) or is missing never blocks: the check reports it and emits `polispec.code.finding`.

A hybrid rule's findings are candidates (`candidate: true`) and never block. A contextual rule asks the `decide` port whether it applies; a probability below `confidence_floor`, or a missing port, defers the rule to task-end review.

## Stop and session hooks

`code-hook stop` collects the files written this session (recorded writes, plus `git diff` against the session start sha and untracked files, minus files already dirty at the session start), runs the harness checks on them, and blocks the stop once when MUST findings remain or agent, hybrid or deferred rules apply, instructing the agent to run the `polispec-reviewer` subagent. It never blocks twice and honors `stop_hook_active`.

## Commands

```
polispec code detect <file>
polispec code chain <file|language>
polispec code show <spec>
polispec code check <file> [--before <file>] [--json]
polispec code validate [--ref main|worktree]
polispec code baseline <repo> [--force]
polispec code controls [--policy id] [--spec path]
polispec code generate rubocop|directives|skill
polispec code classify <policy-id|file>
polispec specs link | status | promote
polispec code-hook pre|post|stop|session --harness <claude|codex|hermes|...>
```

`validate` enforces the semantic rules of the contract: policy ids start with the spec path (slashes to dots), active harness and hybrid rules have an enforcer and a control, agent, hybrid and contextual rules have a lens (contextual also `applies_if`), rejected rules carry `rejected:`, refs resolve without a cycle, ids and directive opcodes are unique, and control, compliant and exemplar files exist. `controls` requires each `.bad` fixture to violate exactly its policy and each `.good` fixture to be clean; it exits 1 on any survivor.

`specs promote` needs an interactive terminal and the phrase `promote specs`, requires a clean `validate --ref main` and `controls --ref main`, moves `stable` fast-forward only to `main`, and appends to the `spec_promotions` log.

## Settings

`polispec.code.enforce` (`tiered` default, `advise`), `polispec.code.check_at` (`pre_write` default, `post_write`), `polispec.code.inject` (`once` default, `every_write`). Each reads the environment variable `RPLUGIN_POLISPEC_POLISPEC_CODE_<NAME>` first, then the machine scope of the resolved rplugin settings.
