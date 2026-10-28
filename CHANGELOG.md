# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.52.2] - 2026-10-28

### Fixed
- **`doctor`'s `harness_coverage` tells the user how Hermes actually grants hook consent.** It said to approve the hook with `hermes hooks`, which has only `list`, `test`, `revoke` and `doctor`; Hermes records consent at the first-use prompt of an interactive session (or with `--accept-hooks`, which approves every configured hook). The reason now says to start `hermes` at a terminal, approve the polispec-guard hooks at that prompt, and check with `hermes hooks list` (`lib/polispec/effect.rb`).

## [0.52.1] - 2026-10-28

### Fixed
- **`lint --ref` exports the target of every behavior surface.** Once 0.52.0 exported the `.tpl` templates, rEach's surfaces compiled at its trust ref and the drift check compared them with targets the export never carried (`AGENTS.md`, `agents/*.md`, `rules/*.md`, `skills/*/SKILL.md`), so `doctor` reported 18 false `behavior_surface_drift` errors with `actual missing` where 0.51.2 reported one warn. The ref reader now reads the `surfaces` of each exported document and exports each named target that exists at the ref (`lib/polispec/lint/targets.rb`). rEach at `stable` lints with no drift finding, and a surface changed at a ref is still reported with its actual digest.

## [0.52.0] - 2026-10-28

### Fixed
- **A torn journal tail no longer stops every later judgment from being recorded.** A hook killed during its `syswrite` (the launcher's `timeout -k` under an IO stall) left `judgments.jsonl` ending mid-record with no newline. `read_head` then found the tail unreadable and refused every append, so from that moment every verdict was delivered but recorded only as a `judgment_unrecorded` finding through the events port, `judgments list` showed nothing new, and `guard_failing` never cleared (no clean judgment arrives). On this host that ran from 09:25 to the re-pin. The head anchor, which the cut-off write never advanced, is now the chain head; the next append starts on a new line; `verify` reports the fragment as `torn_tail` or `torn_record` among the interrupted entries, outside findings, and reads a record appended onto a torn line from its own start, so the two 2026-10-20 lines that held a fragment and a record stop breaking the chain (`lib/polispec/judgments.rb`). Every refused append now also writes `judgments.stalled.json` (count, first and last time, error), which the next successful append removes, and `doctor` reports it as `judgments_stalled` (blocking) and the torn fragments as `judgments_interrupted` (info).
- **The judge serves requests concurrently, and the launcher stops starting cold Rubies that cannot finish.** `polispec judge serve` answered one connection at a time, so one slow request or one slow client held every other call, and the launcher gave up at 6 s and started a cold path with 2 s left that lost under the same load (307 `timeout` denials on this host from 10-20 to 10-28, in bursts). The judge now runs up to `POLISPEC_JUDGE_THREADS` workers (1 to 32, default 8), queues the connections beyond them (up to 64 open; past that it answers `busy` and the launcher takes the cold path), reloads on a content-key change only once the requests in flight are done, keeps each request's deferred events on its own thread, and reaps its detached event writers with `Process.detach` instead of waiting on any child (`lib/polispec/judge.rb`, `lib/polispec/commands/hook.rb`). The launcher's default `POLISPEC_JUDGE_WAIT` is one second below the deadline (7), and after an extended wait that still times out with under 2 s left it denies the call as `judge_timeout` at once (`bin/polispec-guard`). Root cause of the slow requests, host IO saturation, is outside polispec; expect fewer denials, not none.
- **`lint --ref` exports every file under `specs/polispec/`.** The ref reader exported only lint-eligible extensions, so a surface template (`.tpl`) was missing from the export and `doctor` reported a false `lint_behavior_surface_drift` warn for rEach at its trust ref (`lib/polispec/lint/targets.rb`).
- **`docs/harness-controls.md` states the real hook limits** (8 MiB input, 7 s hook budget inside the 8 s launcher deadline), not 64 KiB and ten seconds.

### Added
- **`doctor` reports `trust_ref_stale`** (warn) when a ledger project's local trust ref is behind `origin`'s or has diverged from it, with the operator's fast-forward command; a local ref ahead of origin (an unpushed operator hotfix) is not reported. The guard and `doctor` read the local branch, so polispec's own dev clone was judged and linted from a stale `stable` while `origin/stable` had moved (`lib/polispec/commands/doctor.rb`).
- **`doctor` reports `harness_coverage`** (warn) when a harness installed for the user sent nothing to the guard in the last 14 days, naming the Codex trust findings, the Hermes config and allowlist, or the Antigravity `hooks.json` as the reason; nothing when every installed harness is covered, and nothing under a redirected `POLISPEC_STATE_HOME`, whose stream is not the user's (`lib/polispec/effect.rb`).
- **`polispec judgments acknowledge <id> [--reason TEXT]`.** An operator command (TTY, typed phrase) that records a chain break it has examined and cannot repair, in `judgments.acknowledged.json` beside the stream. `verify` still lists the finding, marked acknowledged, and exits 0 when none is open; `doctor` lists it as `judgments_acknowledged` (info) instead of blocking. `verify` also counts a record recovered from a torn line as unanchored, so the live anchor (167169) and the stream (167171 with two recovered records) agree again instead of reading as `truncated` (`lib/polispec/judgments.rb`, `lib/polispec/commands/judgments.rb`, `lib/polispec/commands/doctor.rb`).
- **`doctor` folds info findings** into one count line per run (`description_missing x47, ...`) and lists them with `--all`; the JSON output is unchanged.
- **Catalog spec `harness/hook-files`.** Nine overridable warn rules on `fs.write` and `fs.delete` to the files Claude Code, Codex, Hermes and Antigravity load hooks, skills and agents from. Inactive until the operator runs `polispec catalog activate harness`; `catalog list` shows the new spec, which changes that command's output against 0.51.2.
- **`environment-control` 1.3.0 adds the `library` variant** for a library, plugin or tool with no running instance: test and prod carry a deploy whose only step and health check are `true`, so a deploy moves the checkout to the tag and `G-TESTED` can pass. Four projects on this host removed their deploy blocks by hand and have had `gate_unreachable` since; re-planning them with `--variant library` is a loosening the operator confirms.

## [0.51.2] - 2026-10-28

### Fixed
- **Live Codex sessions authenticate again.** Since f68b3c7 (2026-10-21), the fixture environment pointed `CODEX_HOME` at the scratch home, which has no `auth.json`. As a result, every `smoke run --live codex` session failed with `401 Unauthorized` before the model ran. Live Codex sessions now use the user's own `CODEX_HOME`, and `--ignore-user-config` still drops the user's config. Fixture steps keep the scratch home (`lib/polispec/smoke/live.rb`, `codex_env`). In a real session, Codex was then denied `git push origin main:stable` by `R-PROD-GIT` and its dev write was allowed.
- **A harness that cannot authenticate is reported as blocked, not as a model that declined.** Auth failure was detected only when the hook log was empty. Codex's SessionStart hook fires before the model is reached, so the 401 runs were recorded as inconclusive, "the model did not attempt the forbidden action". Detection now looks only at tool calls, so these sessions are `blocked: auth_unavailable`, which `--strict` fails. The three codex proof cells that 0.51.1 recorded as failing were this case.

## [0.51.1] - 2026-10-28

### Added
- **`polispec smoke run --strict`.** It exits 1 when a scenario was blocked or inconclusive, or when no scenario matched the filters. Without it, those runs still exit 0. polispec's six live `per_target` proof runs (claude-code and codex) now pass `--strict`. Before this, a live Codex session that never attempted the forbidden action was recorded as inconclusive, `smoke run` exited 0, and `proof run` signed the cell as a rung-3 pass. Because the manifest change alters those runs' argv, the three codex records signed that way are now stale. `smoke-suite.yml` asserts both strict exits and the unchanged default.

### Fixed
- **A slow host probe no longer prints a thread error.** When a command in `Smoke.command` (the runtime capture behind smoke and proof records, such as a harness `--version`) passed its 2 second timeout, the child was killed and the pipe closed under the reader thread, which died printing `IOError: stream closed in another thread`. The reader is now stopped and joined before the call returns `nil` (`lib/polispec/smoke.rb`); the result was already `nil` and is unchanged.

## [0.51.0] - 2026-10-28

### Added
- **A behavior directive can be scoped to code or document slices.** The directive `slice` enum in `schemas/behavior.v1.yml` and `schemas/behavior.v2.yml` adds `code` and `document` beside `all`, `backend`, `panel` and `verification`, so an application whose course has written-work (document) assignments beside code ones can mark which directives apply to each. polispec compiles the value through unchanged; the application filters by it. No verdict changes.

## [0.50.2] - 2026-10-27

### Fixed
- **`polispec proof run --target T` works.** Since 0.49.0, `--target` was parsed as repeatable for `proof except`, so `run` passed a list where it expected one id and every `--target` refused `target_unmatched`, which made the harness-only targets unreachable. `run` now takes one `--target` and answers a second with its usage, exit 2 (`lib/polispec/commands/proof.rb`). The `proof` scenario now runs `--target`, an unknown target and a repeated one.

### Changed
- **A release no longer stales every polispec proof.** polispec's `specs/features.yml` listed `VERSION` in `shared`, so each version bump changed every feature's digest; it now sits in `ignore`, and a release re-proves only the features whose files changed (`commands.version` and the owner of `polispec.rplugin.yml` still change with each bump). The operator confirms this weakening change at `promote --to stable`.

## [0.50.1] - 2026-10-27

### Added
- **Every polispec feature proves itself with its own scenario.** Seventeen features ran another feature's scenario as their smoke command; each now has one whose unit is its own `specs/app.yml` node: `smoke/scenarios/replay.yml`, `shadow.yml`, `pin.yml`, `install-uninstall.yml`, `uninstall-all-restore.yml`, `deployments.yml`, `ledger-init.yml`, `settings.yml`, `code-code-hook-specs.yml`, `explain.yml`, `exceptions.yml`, `plane.yml`, `authorizations.yml`, `judge.yml`, `delegate.yml`, `changes.yml` and `sessions.yml`. They run the commands against scratch fixtures: read verbs and `--json`, dry runs, writes that stay in the fixture, and the refusals (`not_tty`, `phrase_mismatch`, `plane_unavailable`, `operator_required`, `unknown_exception`, `unknown_proposal`, usage exits). The suite has 68 scenarios.
- **polispec's manifest names five targets.** `specs/features.yml` adds `linux-x86-64-ruby4.0` (ruby 4.0), `macos-arm64`, `claude-code` and `codex` beside `linux-x86-64-ruby3.3`. Every feature runs on the three platform targets; `commands.hook-pretool-session`, `code-specs.commands.code-hook-pre-post-stop-session` and `harness-controls`, the features with live scenarios, also run on the two harness targets, where `smoke.per_target` runs `smoke run --live <harness>` at rung 3. The harness targets carry only the `harness` fact and are chosen with `proof run --target`.

### Changed
- **The seventeen features' manifest entries point at their own scenario and unit.** Their old borrowed scenario path left their `paths`, which `promote --to stable` lists as a weakening change for the operator to accept.

## [0.50.0] - 2026-10-27

### Added
- **A code-spec enforcer can declare the rplugin plugins it needs.** `execution.enforcer.requires` is an optional list of `{plugin, version}` entries (`schemas/spec.v1.yml`, `$defs.enforcer`; `plugin` matches `^[a-z][a-z0-9-]*$`, `version` is a RubyGems requirement). Before a `script` enforcer runs, the runner resolves each plugin under `RPLUGINS_HOME` (else `~/.rplugins`) and passes its real path as `POLISPEC_PLUGIN_<ID>_ROOT`; an uninstalled plugin is an enforcer error that never blocks. `polispec doctor` reads the pack the hooks read and reports `code_enforcer_unresolved` and `code_enforcer_version_skew`, both blocking, one per policy and plugin. Before, an enforcer that located its tool by a hard-coded path failed non-blocking with no finding anyone saw.

### Changed
- **One plugin-store helper.** `Polispec::PluginStore` (`lib/polispec/plugin_store.rb`) resolves the store, a plugin root and its `VERSION`; `Stewardship.plugins_home`, the runner and doctor all use it.

## [0.49.0] - 2026-10-27

### Added
- **A release can be held at stable until every feature it changed has a passing smoke record on every target the product supports.** Nothing stopped a release from reaching stable when a feature it changed was never smoke-tested, or was tested on only one of the platforms the product claims; polispec's own smoke ledger proved spec nodes of polispec, recorded no target, and no gate read it. A project now declares its targets (named fact tuples such as os, arch, ruby, harness) and its features (paths, shared paths, an optional spec anchor, a smoke command per target, `min_rung`, default 2) in `specs/features.yml` (`polispec.features/v1`, `schemas/features.v1.yml`). The digest of a feature on a target covers its files at the commit, its manifest entry, its target and its spec node, so a record stays valid while the feature is untouched and a feature the delta changed needs a new pass. `polispec proof run` runs the smoke command through the new `proof_runner` port (standalone adapter `local`; setting `polispec.proof.runner`; kill switch `POLISPEC_PROOF_RUNNER=off`), signs the record with an SSH key (`ssh-keygen -Y`, namespace `polispec-proof`) and appends it to `proofs/<feature>.jsonl` (`polispec.proof/v1`), hash-chained and committed, so every tag carries its evidence; `proof import` takes records a peer or CI job produced with `proof run --out`, after checking signature, producer and digest; `proof status`, `proof verify`, `proof except` (an exception per feature and target, at most 90 days) and `proof keygen` (operator, typed phrase `create proof key`) complete the verb (`lib/polispec/proof/`, `lib/polispec/commands/proof.rb`). Each record is emitted as `polispec.proof`.
- **Gate builtin `features_proven` (`G-PROVEN`), mode `report`, `enforce` or `off`.** At the candidate commit every feature and target cell needs a passing record at the current digest, at or above `min_rung`, signed by a `trusted_producers` key with an intact chain, or an unexpired exception; and every file changed since the stable tag must be owned by a feature or ignored, so new code cannot skip the rule by being left out of the manifest. `report` passes and lists the findings in the promote output, the promotion record and the `polispec.promote` event; `enforce` fails `gate_failed`; the lock edition treats `report` as `enforce` (editions row `proof.report_mode`). `doctor` and `status` report `proof_gap` (warn) for a live project whose stable no longer has full proof (`lib/polispec/proof/gate.rb`, `operator/gates.rb`, `commands/doctor.rb`, `commands/status.rb`).
- **The operator confirms every manifest change that weakens proof.** An agent writes main, and the gate reads the candidate, so an exception, a new trusted producer, a new ignore glob, a dropped target or feature, a narrowed path, a changed smoke command or a lowered `min_rung` would otherwise reach stable unreviewed. `promote --to stable` lists each such change against the stable tag's manifest (an empty one when the tag has none, so a first manifest's exceptions, producers and ignore globs are listed) and, after the stable phrase, asks for `accept proof changes for <project>`; `plan project:<id>` classifies the same changes as loosening (`lib/polispec/proof/weakening.rb`, `operator/promote.rb`, `plan.rb`).
- **environment-control 1.2.0 carries the rule as an opt-in.** Param `proof` (`off` by default, `report`, `enforce`) and the project module `proof` (`packages/environment-control/modules/proof.yml`), which every variant policy includes: rule `R-PROOF-WRITE` denies the new action class `proof.write` (a Write, Edit or shell redirect into `proofs/*.jsonl` of a repository with a manifest) in every environment, and gate `G-PROVEN` joins `to_stable` when the mode is not off. A runtime older than 0.49.0 rejects the module with `policy_invalid` even with `proof` off, so upgrade a project to 1.2.0 only after 0.49.0 is pinned on every host that judges it; the smoke parity run against the pinned 0.48.1 shows every package-built fixture failing that way on the old runtime (51 of 51 scenarios pass on 0.49.0, 124 step differences, all from that, the runtime kind, ids, sizes, the version or the new `proof` scenario).

### Changed
- **`POLISPEC-CONTROL-PROTECTION` also denies a classified read under `<state home>/proof`, where the host producer key lives.** Control protection covered writes only, so a governed `cat` of the key was allowed in dev and an agent could sign a record itself. A program the classifier cannot read still can, and the key is readable by every process of the user, so a host signature proves a process on that host under that user; peer and CI producers keep their keys elsewhere (`lib/polispec/harness_controls/evaluate.rb`).
- **polispec's own `smoke.yml` is frozen.** A repository with `specs/features.yml` makes `smoke record` refuse `ledger_frozen`, `smoke run` record nothing, and `smoke coverage` print the proof cells. polispec's 67 coverage units and the new `proof` unit are features in its `specs/features.yml` on target `linux-x86-64-ruby3.3`; its own policy is unchanged until `plan project:polispec` adds the gate in report mode after this release is pinned. `seal` leaves `proofs/` out of the runtime manifest, as it does `smoke.yml`.

## [0.48.1] - 2026-10-26

### Fixed
- **Replay compared nothing for a release that changed an active catalog module.** 0.48.0's replay decided whether a project's rulebook had moved since a row was recorded with the candidate's own digest, and compared the candidate's verdict with the recorded one. 0.48.0 added descriptions to the catalog modules this host has active (`tools/*`, `delete-guard/*`), so the candidate's catalog layer digest, and with it every project's, differed from every recorded digest: on this host's 14-day corpus of 349,447 rows, replay of 0.48.0 compared 0 and passed, which would have let any verdict change through the gate. Replay now also judges the rows with a baseline tree, `--baseline TREE`, by default the installed runtime (`POLISPEC_BIN`, then `PATH`, links resolved, else the running tree). The baseline's digest decides whether the rulebook moved, and a change is a candidate verdict or rule that differs from the baseline's, so a rule that matches on text a row does not keep no longer shows as a change (`lib/polispec/replay.rb`, `commands/replay.rb`). On the same corpus against the pinned 0.47.5, an export of v0.48.0 compares 5,746 rows with 0 changes (exit 0). A copy that turns every `R-DEV` allow into a warn reports 5,601 unexplained changes across six projects (exit 1), and the pinned tree replayed against itself reports none. Comparing with recorded verdicts instead had shown 10 rule-only differences in teach (`R-DESK-ISSUE-*` and `TOOL-SUBAGENTHANDBACK`) that the 0.47.5 engine reproduces as well. Replaying a working clone as the candidate still shows its own repository's writes as `R-POLISPEC-RUNTIME` changes, because a clone is a runtime root, so the docs and the stewardship rule now say to replay a release export or pinned tree.

## [0.48.0] - 2026-10-26

### Added
- **`polispec explain TOOL INPUT [--cwd DIR] [--json]` shows every rule that matched and the lever that would change it.** The only explain form took a full hook payload and printed one verdict, so finding why a call was denied meant reading rulebooks by hand. The new form takes the shell command for Bash, a JSON object for any other tool and a bare path for Read, Write and Edit, and judges it through the same read-only path as the `--harness` form. For each governing project and environment it prints the classified actions, every rule that matched in every layer with its verdict, layer, file, line, module instance and parameters and, for a repo-layer rule, the package and version, whether it is in effect, overridden or the winner and why, and the levers (`plan project:<id>`, `plan global`, `catalog deactivate`, `exceptions add` for a warn). Code: `lib/polispec/explain/rule_trace.rb`, `lib/polispec/commands/explain.rb`; RuleLocator moved to `lib/polispec/explain/rule_locator.rb`, shared with the web explainer. On this host `explain Bash 'git push origin stable' --cwd <polispec checkout>` names `R-PROD-GIT` at `specs/polispec/policy.yml:6` with `polispec plan project:polispec`, and writes nothing to the state home; the `--harness` form gives byte-identical output to 0.47.5.
- **A pin is gated on verdict replay, and a candidate runtime can run in shadow beside the live guard.** Since 0.25.0 the judgment stream was the corpus, but only `plan` replayed it, so a new runtime could change a verdict unnoticed. `polispec replay --runtime TREE [--days N]` has the candidate's own engine judge the recorded rows of the last 14 days and lists each change as rule and verdict before and after, with a count and an example call digest; a change is explained only when the candidate's CHANGELOG section names the rule (`lib/polispec/replay.rb`, `replay_child.rb`, `commands/replay.rb`). `polispec pin` runs it on the extracted release before swapping `current` and refuses with `pin_unexplained_verdicts` or `pin_replay_failed`; `--dry-run` shows it; only an operator on a terminal can override, with the phrase `pin with unexplained verdicts` (`commands/pin.rb`, `native_pin.rb`). On an rplugin host the stewardship rule asks for `polispec replay --runtime <candidate>` before `rplugin install --ref`. `polispec shadow start|status|report|stop` (`shadow.rb`, `commands/shadow.rb`, one hand-off in `commands/hook.rb`) has the candidate judge each judged call in a detached, niced process through `explain` and logs only disagreements to `shadow.jsonl`. Evidence in scratch: a copy that flips `R-PROD-GIT` to warn replays as 3 unexplained changes (exit 1), explained once its changelog names the rule; a pin of it is refused with `current` unmoved; a shadow run recorded 1 disagreement in 9 calls with the live verdict unchanged and no state file touched by the candidate. Hook cost on a warm judge: about 1 ms with no shadow, about 5 ms with one.
- **`polispec lint --ref REF` lints a project at a ref instead of its working tree.** `lint` read only the checkout, so a clean run said nothing about what `stable` holds. `--ref` materializes the ref's yml, yaml and json files with one `git cat-file --batch` and lints them, naming findings `<repo>@REF:<path>` (`lib/polispec/lint/targets.rb`, `sweep.rb`, `commands/lint.rb`); a missing ref is an error. On a scratch project `lint --ref stable` reported nothing while plain `lint` reported the defect on `main`.

### Changed
- **`doctor` lints each project's trust ref.** doctor read the trust ref for its policy checks and the checkout for its `lint_<code>` findings, so a defect only on the development branch made it exit 1. `check_lint` now reads each trust ref through the reader of `lint --ref`; the agents and manifest drift checks skip ref roots (`lint/drift.rb`). The `gate-unreachable` smoke scenario passes, including "doctor no longer reports gate_unreachable", and the `lint` scenario now shows a checkout-only duplicate key as a `lint --host` error and no doctor finding, and as a doctor finding once it is committed to the trust ref.
- **The lock edition forces `mcp/undeclared` and `tools/unknown` on.** Since 0.45.0 both catalog gates were off until the operator activated them, in every edition, so a lock host that activated nothing did not deny undeclared MCP calls or unknown tools, and an operator could deactivate them with a typed phrase. The editions row `catalog.gate_optional` (excluded from lock) makes `Catalog.active?` true for every gated subspec under lock, and `catalog deactivate` refuses them with `gate_forced` (`lib/polispec/catalog.rb`, `commands/catalog.rb`, `specs/editions.yml`). Under lock in scratch, 0.47.5 allowed `mcp__nowhere__do_thing` and `FrobnicateTool`; 0.48.0 denies them with `POLISPEC-MCP-UNDECLARED` and `POLISPEC-TOOL-UNKNOWN`. The standard edition is unchanged.
- **The fast path is refreshed on every judged call.** It was written only when the harness-control gate was on. The pretool judge now refreshes `fastpath.txt`, `fastpath.watch` and `fastpath.tools` on the no-controls branch too, with a null control digest in the key (`commands/hook.rb`). Shipped releases keep `harness_controls: true`, so a default host sees no change; with it set false in scratch, 0.47.5 wrote no fast path and judged a Glob call, and 0.48.0 wrote the files, skipped the Glob as `no_match` and still judged a Write.
- **`deployments` is a schema kind.** The `deployments.json` write gate checked hygiene only and `lint --host` ran a direct validator on it. `deployments` is now in `Schema::KINDS` (`lib/polispec/schema/core.rb`) and both validate through `Schema.validate`, reporting the same `schema_invalid` finding.
- **plan global and apply global remove the files a draft deletes.** apply global wrote what a draft added or changed but never removed a file it deleted, and plan global did not list the deletion, so a shelf module could not be retired without a hand edit. `plan.rb` lists each such file as `remove PATH`, and `apply.rb` deletes it and stages the deletion in the commit. In a scratch shelf, a draft that deleted a module and its include planned as loosening with `remove polispec/modules/extra.yml` and applied as one commit of two files.
- **`--verbose` traces the remaining operations, and trace fields can be lazy.** The contract runner and its process-group timeout, the Code baseline and controls record writes, the specs link relink, `Environments.git` and the judge-side git helpers of `git_hook.rb` emitted no steps, and eager `Trace.path` arguments were computed with the trace off. They now emit steps, and `Trace.compact` calls a lambda field only when the trace is on (`trace.rb`, `contract.rb`, `code/*.rb`, `environments.rb`, `git_hook.rb`). `contract check` output without the flag is byte-identical to 0.47.5.
- **The shipped catalog modules and the environment-control package carry a description.** `lint --shipped` warned `description_missing` on seven catalog modules and `packages/environment-control/package.yml`; it now reports none. The catalog module texts change, so the catalog layer digest changes on a host that has those subspecs active.
- **Smoke `composition` step "promote refuses with policy_invalid" does not reproduce.** It passed on this tree, on the pinned 0.47.5, on an export of 2950ab7 (the commit TODO 13 named) and in the full suite, and neither `load_project` in `operator/gates.rb` nor the scenario changed since; the 2026-10-18 failure most likely came from host state the scenario inherited, one input of which (the settings path) the scratch `POLISPEC_SETTINGS` below now removes. No change.
- **`smoke run` prunes old runs and reports its run directory and size.** A run without `--out` wrote under `<tmpdir>/polispec-smoke/<stamp>-<id>` and never removed anything; 43 old runs exhausted a tmpfs's inodes. Such a run now first removes the run directories there that match the run naming pattern and are more than 24 hours old (never the current run, a symlink or a path outside that directory), and every run ends with `run directory: PATH (SIZE)`; `--json` carries `out_bytes` and `pruned` (`lib/polispec/smoke/prune.rb`, `run.rb`). With a scratch `TMPDIR` holding an old run, a fresh run, a future-dated run, a symlink and a non-run name, only the old run was removed; a run with `--out` pruned nothing.
- **Every smoke scenario gets a scratch `POLISPEC_SETTINGS`.** The runner cleared `POLISPEC_SETTINGS` from every step, so a step running `settings set` or `unset` wrote the real settings file. Each step now has `POLISPEC_SETTINGS=<scenario scratch>/settings.yml` unless the scenario sets it (`lib/polispec/smoke/fixture.rb`); a scratch scenario's `settings set` wrote there and the host settings file stayed absent.
- **`smoke live --verbose` traces the live session and the hook wrapper's child runs.** The wrapper's `Open3.capture3` ran in a generated child script and showed nothing; each harness run is now a `live session` step and its hook-log entries are listed under `hook wrapper runs` (`lib/polispec/smoke/live.rb`). Shown with a scratch harness that executes the generated wrapper, not a paid session.
- **`lint --ref`, `explain` and `shadow status|report` count as diagnostic reads** in the guard's benign table (`classify/benign.rb`), so they stay available while the guard is failing.

### Fixed
- **A failing guard now says so, and every fail-closed denial names the next step.** Since 0.25.0 a fail-closed denial left a `POLISPEC-INTERNAL` judgment record, but nothing read it back, and the shim's denial said only `guard unavailable; call denied.` `lib/polispec/guard_health.rb` reads bounded tails (256 KiB each) of the last two judgment files and `launcher.jsonl`: the guard is failing while the newest event is a `POLISPEC-INTERNAL` denial, a judgment that recorded an error, or a launcher denial, since the first failure after the last clean judgment. `doctor` reports `guard_failing` (blocking), `status` prints `guard failing since T: <error>`, and the SessionStart and SubagentStart context carries the line, its error cut at 160 characters, and a read error there leaves the rest of the context intact. The shim's denials in `bin/polispec-guard`, the hook's `FIXED_DENIALS` and `HookCommand#internal` end with `Run polispec doctor`. In scratch, a copy with a fault injected into the classifier denied a Write with that text, still allowed a Read, and doctor, status and the session context (735 of 1200 characters) reported `guard failing since <T>: ArgumentError`; one clean call later all three were quiet. The first build counted the allowed Read, which records `error` beside its allow, as a clean judgment and went quiet during the outage; a judgment with an error now counts as a failure. The error recorded is the class, not the message, and a crash while the library loads leaves only the launcher's `exit_<status>`.
- **A supervised `polispec web` kept serving the release it started in.** It loads its Ruby and `web/public` once, so the host's server served 0.38.0 for four days through every pin up to 0.47.4. Every 30 s the server now re-resolves its launcher and compares the release root and `VERSION` it names with the ones it started in; on a change it prints `the installed release changed from X to Y`, emits `polispec.web` `release_changed`, shuts down and exits 75, so a supervisor that restarts on failure starts the new release. `server.json` records `version` and `root`, and doctor reports `web_stale` (warn) when the recorded running server is older than the installed release or recorded none (`web/server.rb`, `commands/web.rb`, `commands/doctor.rb`). A scratch server started through a symlink exited 75 three seconds after the link moved to a 0.99.0 tree; one whose link did not move ran for 15 minutes without exiting.
- **`exceptions add --verbose` nested its plan and apply inside the file write.** One rescue covered the write, `plan global` and `apply global`, so the trace showed both inside "write exceptions.yml" and "apply global" twice. The write and the apply now have their own rescues sharing a `roll_back` helper (`commands/exceptions.rb`); the three steps are depth-0 siblings, each labelled once, with failure handling unchanged.

## [0.47.5] - 2026-10-26

### Fixed
- **An exception chip on the web map opened a missing module.** Every chip linked to `#/detail/module/<id>`, so an exception chip asked for the detail of a module named `aex_…` and showed not found; the host's web log recorded it on 2026-10-26. Exception chips on the map and in list mode now open that exception in the exceptions view (`chipHref` in `web/public/js/map/layout.js`).
- **The command palette's "Open project" went nowhere.** It opened `#/detail/<id>`, which the detail view reads as kind and id both, so the request was `/rulebooks/teach/teach/composition` and the view said "No teach named teach". It now opens `#/detail/<kind>/<id>` for every map entry and names a path entry as one. A detail route with no kind shows "Pick an entry" instead of requesting `/rulebooks///composition`.
- **The explainer found no rule for a judgment whose target was `global` or a path entry.** It searched only the judgment's project chain, which is none for those targets, then `global.yml` and the catalog files, so a rule that lives in a shelf module (such as `G-SCRATCH-CAP-PAD` from `scratch-cap`) gave "No rule or judgment found", and the feed's Explain link was dead for every such call. The locator now also searches the shelf chain (the global layer's modules and the path layers) and answers with the module, its file and line.
- **The timeline took about 9 s to load.** `GET /changes` built every change's session list by re-reading `changes.jsonl` and recomputing the epoch for each change and session; a 30-day window on this host took 8.7 s. Each session's badges are now computed once per request: 1.0 s, with a byte-identical response.
- **"Open timeline" after an apply did not show the change.** The plan sheet links to `#/timeline?change=<id>`, and the timeline ignored the parameter; it now opens that change's drawer.
- **The sessions view never counted the global target as in step.** Calls judged against the shelf alone record the `global` target with `Layers.fingerprint` as their digest, and the view compared it with nothing, so every session showed one project out of step. The global and path targets now compare with the current fingerprint.
- **The author offered no shelf modules to the drafting model.** `polispec author draft` and the web author route listed the release's `modules/`, empty since 0.45.0; both now list the configured shelf's modules (`Author.shelf_modules`).

## [0.47.4] - 2026-10-26

### Fixed
- **A smoke run no longer leaves a resident judge behind.** A launcher step finds no judge in the scenario's scratch state home and starts one detached, and nothing stopped it, so every run left a `polispec judge serve` process per launcher scenario and pass, idle for up to 30 minutes; four were running on this host after one day of test promotions, each health check adding two. `Smoke::Run#execute` now stops, after a scenario's steps and on the `--against` pass too, the judge recorded in that scenario's state home or its scratch `xdg-state/polispec`, sending TERM only to a pid whose `/proc/<pid>/cmdline` reads `judge serve` (`lib/polispec/smoke/run.rb`). The launcher scenarios (`guard-shim`, `guard-failclosed`, `fastpath`, `fastpath-reads`, `judgments` and the rest of their units) left one judge before the change and none after, on both passes.
- **The resident judge answered `error` to every request in a process where nothing had loaded `Predicates`.** Since 0.47.1 `Judge::Server#judge` sets `Thread.current[Predicates::CALLER]` before calling the hook, and `lib/polispec/judge.rb` never required `predicates`, so the first reference raised `NameError` and so did the `ensure` that clears it. In every smoke fixture each judged call logged `error:NameError` and took the cold path; this host's judge answered normally because something earlier in its start had loaded the constant. Verdicts never changed, since the launcher falls back to the cold path. `judge.rb` now requires `predicates`; in the fixture the judge serves `guard-shim` and `fastpath` calls with status 0, and its replies match the 0.47.3 cold path byte for byte (no `--against` difference in `guard-shim`).

## [0.47.3] - 2026-10-26

### Fixed
- **A re-pin now reaches the resident judge, and launchers that find one release through different links share it.** The launcher told the judge its runtime as the directory of the `polispec` it found, without following a file symlink, so with rplugin's `~/.local/bin/polispec` link the runtime was always `~/.local/bin`. After the re-pin to 0.47.2 the 0.47.1 judge kept answering every call with 0.47.1 code (`polispec judge status` reported 0.47.1 on the pinned 0.47.2) until it was stopped by hand; it would otherwise have run until 30 idle minutes, which a busy host never reaches. On this host `/usr/local/bin/polispec` is a second link to the same release, and a session that found it first made the judge answer `stale` for everyone else: 49 `judge_stale` rows in `launcher.jsonl` on 2026-10-26, each followed by cold starts. `bin/polispec-guard` now resolves the binary with `readlink -f` (falling back to the path as found) before taking its directory, for the header and for `POLISPEC_JUDGE_RUNTIME`. Measured with real launchers against scratch state homes through rplugin's two-link layout: re-pinning 0.47.1 to 0.47.2 left the 0.47.1 judge serving; re-pinning into the candidate made it answer `stale`, exit and be replaced by a 0.47.3 judge, and so did a re-pin from one candidate copy to another; calls between re-pins stayed on the judge. Alternating two links into one release gave 7 `judge_stale` in 8 calls with the 0.47.2 launcher and 0 with the candidate, which served 7 of 8 from the judge. A judge started by an older launcher records the unresolved directory, so the first 0.47.3 call after this upgrade retires it.

## [0.47.2] - 2026-10-26

### Fixed
- **The app spec agrees with the code again.** `specs/app.yml` had drifted across many releases. It was missing 8 of the 31 settings the manifest declares (`polispec.code.enforce`, `check_at` and `inject`, `polispec.global.repo`, `ref` and `path`, `polispec.supervisor.status_command` and `polispec.logs.count_command`). It was also missing 7 shipped schemas (global, profiles, module, package, smoke-scenario, delegate_grants and editions) and listed `author` only as declared, though the manifest also lists it as optional. Every command usage was checked against the command's own usage string. Fixed: validate takes 27 kinds and `--semantic`; `sessions` has no `show`; `manifest` has `badge` and no `--yaml`; `behavior` has `export-package` and `compile --out json`; `web` has `url`, `token set` and `unit`; `plan` and `apply` take different flags; `deploy`, `unregister`, `resolve`, `classify`, `plane`, `pause`, `allow-once`, `roster`, `smoke`, `status`, `digest` and `doctor` show their full options. Other corrections: the Hermes, Pi, DeepSeek, Antigravity, Cowork and OS rows now sit under `harnesses`. Grantable delegate flags include `--verbose`. A divergent judgment head is refused, not forked. A zip with no resolvable output yields no write. The lint shipped table has 27 `{glob, kind, regexp}` rows, and only `unknown_call.ask` decides ask or deny. Host-specific names and paths were replaced with neutral wording.
- **`docs/VISION.md` rows that had gone stale.** The Codex hook no longer needs a host bridge (since 0.27.0). The sealed plane has been enabled since 0.45.1, not "flags off". The rendered composition map has been built since 0.35.0 (`polispec web`), and the practice-module catalogue is partial since the 0.45.0 catalog.
- **`specs/editions.yml` said `mcp_default.ask` decides the undeclared MCP default.** The code reads that row only into the fast-path key (`lib/polispec/commands/hook.rb`, `lib/polispec/fastpath.rb`); the verdict comes from `unknown_call.ask`. Only the note changed; no verdict changes.
- **An independent review of the first draft corrected the new wiring and model text.** A pause covers one target project, not the whole call. Actions outside every live project get an environment judgment only when a global baseline exists. MultiEdit splits per edit entry. Under advise, injected control context and the epoch notice still render. The launcher's ordinary allow is exit 0 with no output. `polispec.authorization` is listed, and two harness-control emits are named as having no `events.jsonl` fallback. code-hook accepts every harness name. The counts that restated code constants were dropped, so the spec names each constant and says the constant wins.
- **A policy or control file could not name the `web_local` shape.** The classifier has tagged `web_local` since 0.35.0 and the catalog subspec `tools/web-agent` matches it, but the `match.shape` enums of `schemas/policy.v1.yml` and `schemas/control.v1.yml` left it out, so `polispec validate policy` rejected `shape: [web_local]` with "must be one of" and a control naming it matched no allowed form. Both enums now list every `Shapes::NAMES` entry plus `opaque_shell`, and `docs/schema.md` describes the shape. Module and global files were never affected (their `shape` is a free string list).
- **`docs/operator.md` said rplugin renders the guard hook for Pi, the DeepSeek TUI and the Antigravity CLI.** rplugin 1.19.0 renders hooks for Claude Code (`hooks/hooks.json`), Codex (`hooks/codex.json`) and Hermes (its extension) only, so those three get skills only unless a host wires the guard; the page now says so and names Codex, which it had left out.
- **`docs/CURRENT-STATE.md` still described 0.25.1.** It now states 0.47.2: 50 smoke scenarios, the last live-harness runs (16 October 2026), the fail-closed launcher since 0.33.2, the sealed plane shipped enabled since 0.45.1 with no host sealed, and where each review finding (F-01 to F-05) and the P0 work stand. The status line per finding was checked against the code and the smoke ledger.
- **`ROADMAP.md` still planned standing exemptions as if nothing were built.** The section now says what 0.29.0's persistent exceptions cover and lists what remains: a grant at the prompt, a lapse when the rule's digest moves, a path-glob target for file tools, and listing open exceptions in the promote preview, `status` and `doctor`.

### Added
- `specs/app.yml` sections `vision`, `features`, `model` and `wiring`. `vision` holds the arc, the principles, the planned work, the ideas and how far enforcement reaches. `features` indexes 41 built capabilities, each with its first release, surfaces, spec section and limits. `model` holds the engine vocabulary as the code defines it: 23 action classes, the classifier families, 13 shapes, 26 match keys, 9 predicates, composition, the per-action judgment order, built-in rule ids, 9 gate kinds and freezes. `wiring` covers how each harness reaches polispec, the pretool path hop by hop, the session path, the state and sealed paths, events, and which rplugin ports the code actually calls. `smoke.coverage_units` gains `catalog`, `fs_walk` and `verbose`, which scenarios already prove.
- README sections **Imagine**, three hypothetical scenarios with images in `assets/imagine/`, and **Alignment tactics**, with two mermaid diagrams of the alignment loop and of how directives reach an agent and how hooks hold them.

### Deprecated
- The freeze sources `teach.calendar` and `teach.activity` (`lib/polispec/freeze.rb`) name one application's commands inside polispec. They keep working in 0.47.2. Their two users, the Teach and rEach policies, moved on their `main` on 2026-10-26 to `source: command` with the same argv, which a scratch-fixture comparison showed gives the same freeze windows at every instant checked; only the freeze message gains the window's detail and course. A later release removes the two names once both projects' stable branches carry that change.

## [0.47.1] - 2026-10-26

### Fixed
- **An agent is no longer denied `G-LOCK-HELD` on a file it locked itself when the resident judge answers.** A Claude Code session (pid 2130520) took `reaper lock acquire` on `~/.ai/.rproject/WIP.md`, and its own Edit of that file was denied "locked by agent checkin-589b14c2 (pid 2130520)", served `via: judge`. `Predicates#live_holder` compared an owned entry's `owner_pid` with `ancestors(Process.pid)`, and under the judge that pid is the detached `polispec judge serve`, whose parents never include the harness; the cold path, a child of the launcher, was right. The launcher now sends `caller=<its pid>` in the `POLISPEC/1` header, the judge keeps it only when `/proc/<pid>` exists and belongs to its own uid, and `lock_held` walks that pid's parents (`bin/polispec-guard`, `lib/polispec/judge.rb`, `lib/polispec/predicates.rb`). A missing or rejected caller keeps the judge's parents, so an owned lock stays held, and a judge older than 0.47.1 reads the field as part of the runtime directory, answers `stale` and exits. Measured with the real launchers against scratch state homes: through the 0.47.0 judge the holder's own Edit is denied and through the 0.47.1 judge it is allowed; a lock owned by another live process is denied by both, cold and judged; a 0.47.0 launcher is still served by the new judge with the old result; a 0.47.1 launcher against a 0.47.0 judge logs `judge_stale`, the old judge exits, and its replacement allows the call.

### Changed
- `specs/app.yml` (`resident_judge`) and `docs/operator.md` ("The resident judge") describe the `caller=` field.

## [0.47.0] - 2026-10-26

### Added
- **`polispec-advise`, a read-only skill that suggests specs and directives from history, a project or named files.** It matches what it finds against `skills/polispec-advise/patterns.md` (repeated asks, denies that point to a sanctioned tool, first policies, hygiene domains, spec lifecycle, reading history, classification, minimum versions per key) and answers with a spec draft for `polispec-specs` to validate, lint and plan, advisory directive text aimed at the canonical behavior directive, or both. Each suggestion names its evidence, its lever, its classification and its confirmer. Levers against repeated asks are keyed on the source of the ask (`POLISPEC-TOOL-UNKNOWN`, `POLISPEC-MCP-UNDECLARED`, an environment rule warn, a deny) in the order declare, narrow, exception, allow-once, and drop what the edition, the sealed plane or a kill switch removes. It writes nothing, applies nothing, records no proposal, never coaches evasion and never suggests overriding the delete-guard, web-agent, runtime or control-protection rules. It adds no verb and no library code.
- **`docs/cli.md` and `docs/agent-guide.md`.** The first lists every verb by family with who may run it (agent, agent with the user's yes, operator, sealed operator, internal) and the document that explains it. The second holds positioning, reach, layers from posture to match, the anatomy of an ask, the lever order, evidence sources, edition differences and the never-override list.
- **A trigger table for creating, modifying, deleting, moving and registering a spec** in the `polispec` skill and the stewardship rule, and a short "Fewer asks" digest in `rules/polispec.md`.

### Changed
- **`skills/polispec/SKILL.md` is a lean router.** Positioning and reach, the rules that always hold, CLI discovery, a routing table, the trigger table and one table of every verb by authority replace the long reference prose, which moved to the two new docs. The never list, warn handling and operator boundaries stay in the router because only a native Claude Code install links the rule files; Codex, Hermes, Pi, DeepSeek TUI and Antigravity reach the content through the skills.
- `specs/app.yml`: the `agent_skills` block describes the router, the advise skill, the awareness digest, the reference docs and the uninstall skill; seven commands (web, manifest, register, changes, sessions, editions, author) no longer read `status: planned`, though they shipped in 0.35.0; `G-WEB-AGENT` is described as the catalog subspec `tools/web-agent`, not a rule of the removed shipped module.
- `rules/polispec-stewardship.md` lists `rules/` and `skills/` among the shipped directories that carry no personal policy, as the `personal_defaults` check already enforced.
- `.claude-plugin/plugin.json` lists the new skill; it was regenerated with `rplugin package` from `contents.skills`.

### Notes
- The verb table in the router and in `docs/cli.md` is maintained by hand and can drift from `polispec help`; check it at each release. `lint --shipped` and `personal_defaults` do not read `docs/`, so the two new docs were checked by hand for host paths, project ids and names.
- Existing installs link the new skill only when `polispec install --harness claude|codex` is run again, and a new skill appears in a new session. `rules/` links follow the `current` pin and update on `polispec pin`.
- No verb, library, schema or verdict changes. The evidence for the lever order came from 256 recorded asks on one host since 2026-10-22, 216 of them control asks, mostly shell lines starting with a directory change or running `eval`, `source` or `.`, and about a dozen undeclared MCP calls.

## [0.46.0] - 2026-10-25

### Added
- **Recursive filesystem walks are visible to rules as the `fs.walk` action class.** On 2026-10-25 subagent calls such as `find / -name X 2>/dev/null | head` ran for 45 to 65 minutes over a 4.5 TB exFAT disk and a FUSE mount and held host IO at 65% full pressure, and a read-only walk produced no action, so no rule could match it. The classifier now emits one `fs.walk` action per dangerous start path of `find`, `bfs`, `du`, `fd`, `fdfind`, `rg`, recursive `grep`, `egrep` and `fgrep`, `ls -R` and `tree`, tagged `root_walk` (start path `/`, not confined by `-xdev`, `-mount`, `-x` or `--one-file-system`) or `slow_mount_walk` (start path on a FUSE or network filesystem or under `/run/media`, `/media` or `/mnt`, or such a mount beneath a walk that does not stay on one filesystem, read from `/proc/self/mountinfo` or the file named by `POLISPEC_MOUNTINFO`). Both shapes are valid in `match.shape` of policy, module, global and control files. Walks inside a project emit nothing and every other read keeps the fast path. No shipped rule matches `fs.walk`, so verdicts are unchanged until a shelf module denies them.

## [0.45.2] - 2026-10-25

### Fixed
- **Calls were denied with `guard unavailable` while the resident judge reloaded.** The judge answers one request at a time. The launcher gave up on it after 0.5 seconds and each waiting caller started its own cold Ruby, so while the judge was slow the herd of cold starts missed the 8 second deadline and the shim failed closed. The launcher log held 263 `timeout` rows since 2026-10-20, 244 of them denials, in bursts (the latest at 21:25 and 21:34 UTC on 2026-10-25). The judge log showed accepted requests finishing 2.8 to 6.2 seconds later and repeated `Timeout::Error` replies at 7.0 seconds, none of them on a request that changed the freshness key (`key_changed` is false on every slow row). Why the judge is slow at those moments is not established; the host was heavily loaded (load average between 7.6 and 31 on 32 cores while this was investigated). `bin/polispec-guard` now keeps waiting on the same connection for a judge that accepted the request, up to `POLISPEC_JUDGE_WAIT` seconds (integer 0 to 8, default 6, held below the launcher deadline; 0 restores the earlier behaviour), logs a served late reply as `judge_slow`, and gives the cold path the deadline less the seconds already waited, rounded up to whole seconds and never below 1 second. That arithmetic runs before the caller's locale is restored, because bash writes `EPOCHREALTIME` with the locale's decimal mark. Measured with the real launcher against a stand-in judge: a reply after 2 seconds is served by the judge in 2.0 seconds and not by a cold start; with `POLISPEC_JUDGE_WAIT=0` the same case falls to the cold path at 0.5 seconds as before; a judge that errors at 3.95 seconds ends the call at 8.0 seconds, a judge that never answers at 7.0 seconds, and under `LANG=en_DK.utf8` a judge that errors at 1.3 seconds at 7.3 seconds, all inside the 8 second deadline. A cold hook for a call outside any governed project took 0.13 to 0.14 seconds at load 11, so the 1 to 2 seconds left to the cold path after a full wait is ample for such a call; a governed call was not timed. The cause of the judge's slow requests is neither changed nor reproduced here.

Validation: existing smoke suite 49/49 from the candidate against the installed 0.45.1, with all 63 output differences reviewed: clone-versus-pinned runtime evidence and its runtime-write verdicts, scratch fixture paths, generated ids and timestamps, and version output. No launcher scenario differs and none exercises the new wait, which was measured only with the stand-in judge above. No new tests were written.

## [0.45.1] - 2026-10-25

### Fixed
- **Protected-plane provisioning stopped before operator authentication.** The implemented capability still shipped disabled: the installed 0.45.0 refused 1 of 1 measured non-root attempts with `feature_disabled`; this candidate reaches the existing `operator_required` refusal in 1 of 1 equivalent attempts. Enable `sealed_plane` by operator direction (SEALED-ACT-001), retaining root identity, typed confirmation, protected runtime provenance, and fail-closed activation checks. Installation creates no plane generation, starts no service, and grants no authorization; privileged verification remains pending.
- **Catalog decisions were not bound to protected authority.** The 0.45.0 catalog selected user-writable state independently of the sealed generation. Require an explicit `catalog/active.yml` snapshot, validate its known subspecs and provisioned files through existing schemas, digests, and provisioning rules, and bind sealed catalog lookup to that generation (SEALED-ACT-005). In real sealing previews the old catalog-less bundle is now rejected (`preparation_ready: false`, `catalog_missing`), while a committed snapshot preserving five active host subspecs is accepted for preparation. Old catalog-less operator bundles must add the reviewed snapshot before sealing. Missing or broken protected bindings never fall back to user state.

- **Composition validation could lose its original errors during garbage collection.** Weak-valued maps discarded error arrays while their policy keys were alive; validation then recomposed without the original local source and could report missing modules instead of the missing parameter. A measured actual composition on 0.45.0 lost its one recorded error after `GC.start`; the candidate retains that same error and unchanged serialized policy fields. A Hash-compatible composed-policy value now owns its raw digest and error evidence through readers (SEALED-ACT-006), and the weak side maps are removed.

Validation: final existing smoke suite 49/49 against the installed 0.45.0, with all 64 output differences reviewed: the new catalog requirement, clone-versus-pinned runtime evidence and its runtime-write verdicts, fixture/runtime paths, generated IDs and timestamps, and version output. The failed composition run and earlier storage/layout failures are preserved beside the final report. `rplugin check` reports zero findings; native package projections have zero stale files. Shipped lint retains eight existing missing-description warnings and the existing oversized-smoke-ledger skip. No new tests were written, and no privileged sealing, protected authorization-service operation, production promotion, or enforcement certification is claimed.

## [0.45.0] - 2026-10-24

### Added
- The catalog: polispec ships a set of optional specs under `catalog/`, and none is active by default. A catalog spec is `catalog/<spec>/catalog.yml` (`polispec.catalog/v1`) with one `polispec.module/v1` file per subspec beside it. Three specs ship:
  - `tools`: subspecs `declared` (the `TOOL-*` allow rules for the harness's own tools and reads, and `TOOL-OPAQUE-DEVELOPMENT`), `unknown` (the `POLISPEC-TOOL-UNKNOWN` default for a call polispec cannot positively classify) and `web-agent` (`G-WEB-AGENT`).
  - `delete-guard`: subspecs `protected` (the `delete_protected` list, `G-DELETE-PROTECTED` and `G-DELETE-PROTECTED-FILE`) and `xargs` (`G-DELETE-XARGS`).
  - `mcp`: subspecs `undeclared` (the `POLISPEC-MCP-UNDECLARED` default, ask under standard and deny under lock) and `declared` (the host's own MCP declarations, provisioned by the operator from a file; the release ships it empty).
- `polispec catalog list|show|activate|deactivate|provision`. `list` and `show` are read-only. `activate`, `deactivate` and `provision` are the operator's: each needs a TTY and a typed phrase (`activate catalog SPEC`, `deactivate catalog SPEC`, `provision catalog SPEC/SUBSPEC`), refuses while the sealed plane is active, and emits a `polispec.catalog` event. A bare `SPEC` names every subspec; `SPEC/SUBSPEC` names one.
- Host-local catalog state, `<state home>/catalog/active.yml` (`polispec.catalog-state/v1`), with provisioned files under `<state home>/catalog/provisioned/`. Activation is per host and never lives on the global shelf or in the ledger, which a host may share with other hosts. The state directory is a protected path for the harness-control ceiling. A state file that does not parse or validate fails closed: every gate counts as on.
- Schemas `schemas/catalog.v1.yml` and `schemas/catalog-state.v1.yml`; `validate catalog` and `validate catalog-state`.
- Doctor findings `catalog_none_active` (info), `catalog_state_invalid` (blocking) and `catalog_provision_missing` (warn).
- Smoke scenario `smoke/scenarios/catalog.yml`, and a smoke fixture key `catalog:` (with `catalog_provisioned:`) that activates catalog subspecs in the scenario's state home.

### Changed
- There is no always-on shipped layer. The first layer of every chain is the catalog layer, built from the active subspecs in catalog order (tools, delete-guard, mcp), and it is absent when nothing is active. `resolve --layers` prints it as `catalog`. Its digest covers each active subspec's module text, so activating, deactivating or provisioning changes every effective digest and the fast-path key.
- The undeclared-MCP gate runs only while `mcp/undeclared` is active, and the unknown-tool gate only while `tools/unknown` is active. With neither, an MCP call or an unknown call gets only the verdicts of the rules that match it. The `unknown_call.ask` and `mcp_default.ask` edition rows decide ask or deny only while their gate is on.
- `fastpath.tools` takes its names from the release's `tools/declared` module when that subspec is active or the unknown-tool gate is off, and is empty otherwise.
- `modules/tool-declared.yml` and `modules/delete-guard.yml` moved into `catalog/tools/` and `catalog/delete-guard/`, rule for rule, and `modules/` is gone. The personal-defaults scan and `lint --shipped` sweep `catalog/`.

### Upgrade
- A host upgrading from 0.44.x gets none of the previous shipped rules until the operator activates them. To keep the 0.44.1 behavior, run `polispec catalog activate tools` and `polispec catalog activate delete-guard`, and `polispec catalog activate mcp` for the undeclared-MCP gate. A host that declared its MCP servers in a global shelf module can provision that module into `mcp/declared` (`polispec catalog provision mcp/declared --from FILE`) or remove it from the shelf. Pin 0.45.0 before removing the module: an older runtime keeps its undeclared-MCP gate on, so a shelf without declarations makes every MCP call ask there.

### Notes
- The resident judge's freshness key and the fast-path watch list include the catalog state, so an activation is judged on the next call without restarting the judge, and the launcher stops skipping until the fast path is re-stamped.
- `polispec catalog list` and `show` are benign reads for the guard. `polispec.catalog` is a registered event.
- The web map's shipped band and the explain view read the catalog layer; the API keys are unchanged. The author adapter reads `catalog/` where it read `modules/`.
- Parity against the installed 0.44.1: 49 of 49 scenarios pass, 76 changed steps, recorded in `smoke.yml`. Every hook verdict is the same once a scenario activates the catalog specs it relies on (`catalog:` fixture key). The changes are the absent catalog layer where 0.44.1 printed its shipped layer (12: `resolve --layers`, `manifest`, and the onboarding plan that no longer lists the 36 shipped rules as added), the clone runtime both working trees are against the pinned 0.44.1 (18: `R-POLISPEC-RUNTIME` ask against deny, the doctor runtime line and exit), `edition_provenance_invalid` while the branch is ahead of local main (doctor exits), the version string, the `against/` scratch-path prefix and the truncation it shifts, generated ids, commit ids and timestamps, the seal tree listing, and `lint --shipped` warning `description_missing` on the seven catalog modules where 0.44.1 warned on its two shipped modules.

## [0.44.1] - 2026-10-24

### Fixed
- `plan global` (and so `exceptions add`, which plans and applies the global shelf) no longer takes tens of minutes and hundreds of megabytes on a host with a large judgment log. The journal replay in `lib/polispec/plan.rb` re-read and re-parsed the whole 14 day window once for each ledger project, then judged each distinct replayed action on both sides with a `git rev-parse` of the roster and uncached lookups for every one. The plan now reads the window once per plan (`journal_rows_for` indexes it by project), `lib/polispec/journal.rb` and `lib/polispec/judgments.rb` stream it a record at a time instead of holding every record and every row at once (`Judgments.each_recent`), and `lib/polispec/probes.rb` resolves the project roster once per side and runs the side's batch inside `PolicySource.memoize`. The rows, their order, the verdicts and the plan output are unchanged; no replayed action is dropped or capped, so a loosening in the replay is still found.

## [0.44.0] - 2026-10-24

### Added
- `--verbose[=text|json]`, `-v` and `POLISPEC_VERBOSE=1|text|json`: stream what an operation does while it does it, on stderr. Each step is a nested, timestamped line (`>` opens, `+` closes with its duration, `!` closes failed with the reason, `-` is a fact with `key=value` fields); each git call and child process is a `$` line, its output arrives line by line as the child writes it (`|` stdout, `2|` stderr) and its exit status and duration are an `=` line. A test deploy that runs the full smoke suite now shows its progress instead of waiting. `--verbose=json` writes the same events as NDJSON, one object per line (`{v: 1, ts, t, depth, event, ...}` with `begin`, `step`, `info`, `command`, `exit`, `output`, `end`). Stdout, `--json` documents and exit statuses are the same with and without the flag, and without it nothing is traced.
- Coverage. Promote and deploy: project and policy load, git calls, every gate and its result, the plan, the typed-phrase wait, tag, atomic push and branch advance, the release call, each after step, and for a deploy the checkout, drain phases, steps, activation, each health poll, a swap and a rollback. Rulebook changes: `exceptions add|promote|remove`, `plan` and `apply` for every target (each file written with its bytes and sha, the commit, the change record), `register`, `unregister`, `ledger init`, `settings`, `manifest --write`, `agents render`, `behavior`, `specs`, `roster`, `pause`, `allow-once`, `delegate`, `code`. Install lifecycle: `pin`, `install`, `uninstall`, `uninstall --all`, `restore`, `steward`, `deployments --scan`, `harness`, `seal`, `plane`, `hook git install|uninstall`. Diagnostics: each `doctor` check, each `lint` target, `status`, `digest`, and `smoke run` (a step per scenario step; a passing step is counted, a failing step shows its failed checks and the first 40 lines of its output).
- `Polispec::Trace`, the one facility behind it (`lib/polispec/trace.rb`, `trace/stream.rb`, `trace/logfile.rb`): `step`, `info`, `command`, `exit_line`, `output`, `drain`, and `capture3|capture2|capture2e` as drop-in replacements for the `Open3` methods that stream when the trace is on and call `Open3` unchanged when it is off. The `hook` and `code-hook` verbs ignore the flag and the variable, so the guard never writes to stderr because of either.
- Trace file. While a run is verbose and `polispec.verbose.trace` is on (the default), the trace is also written to `<state home>/trace/<UTC stamp>-<verb>-<pid>.log` (`.ndjson` in JSON mode), directory 0700, file 0600, capped at 8 MiB, with files older than 14 days and all but the newest 63 removed at the start of a verbose run. It is written only when the state home exists. `polispec.verbose.trace off` writes no file.
- `--verbose` is a grantable delegation flag: `polispec delegate grant ... --flags --dry-run,--json,--tag,--verbose` lets an application pass `--verbose` or `--verbose=json` (also `--verbose=text`) to `promote`, `deploy` and the exceptions verbs; the default grant flags are unchanged, and the stream reaches the application through the run log it already reads. `schemas/delegate_grants.v1.yml` admits `--verbose` in `flags`.
- Smoke scenario `smoke/scenarios/verbose.yml` (unit `verbose`): flag off, `lint --verbose`, `--verbose=json` parsed line by line, a promote to test with the gates and the push, `exceptions add` through the typed phrase, the hook silent with `POLISPEC_VERBOSE=1`, the variable on a normal verb, and an unknown format as a usage error.

### Changed
- `Classify::Benign` ignores `--verbose`, `--verbose=text|json` and `-v` before it reads a verb's flags, so `polispec doctor --verbose` and `polispec --verbose status` stay benign reads; `polispec --verbose promote P --to stable` is still classified as a promotion to prod.
- `polispec help` gains one line for the flag. `polispec settings list` shows `polispec.verbose.trace`.
- `Operator::Gates.exec` reads the child's output through `Trace.drain` when the trace is on, and `Operator::Git`, `Git.clone`, `Deploy.clone_release`, `NativePin`, `UninstallAll`, `Stewardship`, `Deployments`, the lint target collector and the smoke host copy call `Trace.capture*` instead of `Open3`; with the trace off each is the same call as before.

### Notes
- A bare `-v` or `--verbose` that is the value of another flag is read as the flag; pass such a value as `--note=-v`, or name `--verbose` in a grant as part of a comma list. A runtime older than 0.44.0 rejects `--verbose` as an unknown flag (exit 2), so an application must not pass it to a delegate runner on an older host.
- Not yet traced: `contract` (its runner and process-group timeout), `smoke live`, the baseline and controls writes of `code`, the relink wait of `specs link`, and the git calls of `agents render` and `manifest` that go through `Environments.git` (see TODO.md).

## [0.43.0] - 2026-10-24

### Added
- The behavior contract, `polispec.contract/v1`: a versioned document per agent behavior that binds an intent, an optional directive, the guards that enforce it and where they run, the exact user-facing messages with a truth condition per clause, the constraints it protects, positive and negative probes, an owner, and a rollback target. `polispec.contract-vocabulary/v1` is the project-owned vocabulary for locations, annotations, facts, and approval roles. Both are schema kinds (`validate contract`, `validate contract-vocabulary`, `validate auto`).
- `polispec contract check|render|digest|diff|approve|export` ([contract](docs/contract.md)). `check` resolves behavior refs and an optional whole-file sha256 pin, evaluates probes (declarative rules built in, native guards through `--runner`, which may answer `unrun`), composes clauses from facts, reports conflicts, approval state, and surface drift; `diff --from REF` classifies tightening, loosening, mixed, or neutral; `approve` appends a hash-chained approval bound to the contract digest and records a `contract_approval` change; `export` writes `polispec.contract.compiled/v1`.
- Behavior v2 surface kinds `policy_json` and `locale`, and an optional `locale` key on a surface. Both are wholly generated, need no `template`, and are drift-checked like every surface.
- `plan project:<id>` classifies contract changes, `lint` and `doctor` report contract surface drift, and `doctor` reports `contract_ahead_of_runtime` when a project holds contract files and the installed release is older than 0.43.0.
- Smoke scenario `smoke/scenarios/contract.yml` (unit `contract`).

### Changed
- `polispec contract approve` classifies `policy.edit`; `check`, `digest`, `diff`, `export` to stdout, and `render` without `--write` are read verbs for the guard, and `check` stops being one when `--runner` is given. No verdict of any existing command changes.
- Parity against the installed 0.41.1 (46 of 46 scenarios pass, 124 changed steps, recorded in `smoke.yml`) and against v0.42.0 (46 of 46, 99 changed steps). Against v0.42.0 the changes are the new `contract` scenario (42 steps) and run artifacts: the version string and `shipped:` layer source, the `against/` scratch-path prefix and the message truncation it shifts, generated ids, commit ids, and timestamps, the larger CHANGELOG in the seal tree listing, and the steward step that looks for the not yet created v0.43.0 tag. The other 25 steps print what 0.42.0 prints: its `lint` verb (11) and the clone runtime both working trees are, against the pinned 0.41.1 (`R-POLISPEC-RUNTIME` ask against deny, the doctor runtime line and exit). No existing verb's output changes because of contracts.

## [0.42.0] - 2026-10-23

### Added
- `polispec lint [PATH...] [--host] [--shipped] [--only RULE[,RULE]...] [--strict] [--json]`, a read-only sweep of the files polispec generates or ships. It reads what the YAML loader accepts silently and reports it: a repeated mapping key (the loader keeps the last), a second document (the loader reads only the first), an anchor or alias (the loader refuses them), a tab after a colon or dash, trailing spaces, CRLF, a BOM, a missing final newline, and a plain `yes`, `no`, `on` or `off` that reads as a boolean. Five rules: `schema` (every polispec document against its schema, with the same semantic checks as `validate`), `hygiene`, `drift` (a rendered `envs.md` or `AGENTS.md`, a behavior surface, a manifest or badge, and a harness artifact's file integrity, each against its source), `refs` (version homes that disagree, a missing schema file or `$ref`, a package source that does not exist, a ledger repo or path that is gone) and `description`. A PATH is a project root or one file; `--host` adds the ledger, the global shelf, the deployments manifest, delegate grants, settings, the published index and every ledger project; `--shipped` sweeps the release tree through a table of globs and kinds. Exit 0 when there is no error (no warning either under `--strict`), 1 otherwise, 2 for a usage error.
- Write gate. With `polispec.lint.on_write` on (the default) every generator that writes a structured file lints its output first and refuses an error finding with `lint_failed`, writing nothing: `apply project`, `apply global` and `apply ledger`, the starter ledger, a registration proposal, the manifest and the published index, `agents render`, `behavior render --write`, the exceptions file, the deployments manifest, delegate grants, `code generate rubocop`, and the rendered files of a package. `off` restores the 0.41.1 behavior.
- Doctor findings. With `polispec.lint.doctor` on (the default) `polispec doctor` files a `lint_<code>` finding, with the ledger project when one is known, for the host-scope sweep; warnings and info stay non-blocking. Lint reads each project's checkout while the other doctor checks read the trust ref, so a defect only on the dev branch now makes `doctor` exit 1 where 0.41.1 exited 0; a schema error already filed as `layers_invalid` or `gate_unreachable` is not repeated. `polispec.lint.strict` (default off) makes warnings fail `lint`.
- `Polispec::Schema::Check`, the check `validate` ran inline, now shared by `validate` and `lint`. The output of `validate` is byte for byte what 0.41.1 printed for every tracked YAML and JSON file, in all of its flag forms, except the three files repaired below.
- Smoke scenario `smoke/scenarios/lint.yml` (unit `commands/lint`): clean, a repeated key, an alias, a tab under `--strict`, drift and its repair, a usage error, the write gate and its off switch, doctor and its off switch, `--shipped`, and agreement with `validate`.

### Changed
- `docs/effect.md` no longer names the release host's own paths: the AI home is written `<ai home>`, the user home `<home>`, and the host's plugin list, other hook groups, a recorded trust hash and the launcher's fixed checkout path are described generically. The findings are unchanged.
- A generator that wrote a file with a repeated key, an alias or a second document used to succeed; with the gate on it now fails with `lint_failed` and leaves the file as it was. `polispec.lint.on_write off` (or `POLISPEC_LINT_ON_WRITE=off`) restores the old behavior.
- `lint` is a read verb for the guard (`Classify::Benign::POLISPEC_READ`).

### Fixed
- `specs/provenance.impl.yml`, `specs/smoke.impl.yml` and `specs/webapp.impl.yml` did not load as the loader reads them: the first two held plain scalars containing `: ` (a value that is not valid YAML), and the third repeated the `events` key, so the loader silently dropped the first. The values are quoted and the key is renamed.
- The `status-digest-doctor` smoke step `doctor reports package_file_drift as info and not_live` expected `(4 blocking, 7 info)`. The fourth blocking finding was `edition_provenance_invalid`, which exists only when HEAD differs from local `main`, so the step passed on a feature branch and failed on `main` itself. It now expects `7 info)`.
- `web/public/openapi.yml` carried 24 Psych anchors and aliases from a Ruby dump of shared objects, which polispec's loader refuses. They are expanded in place; the document is unchanged.

## [0.41.1] - 2026-10-23

### Fixed
- `personal_default` matched the ledger host as a substring, so a host named after an ordinary word reported every shipped sentence containing it: the smoke fixture's host `smoke` flagged `polispec smoke run` in the stewardship rule and the polispec skill, which changed the `status-digest-doctor` counts and failed the 0.41.0 test deploy's health check. The host is now matched only as an exact YAML scalar, like project ids, and path tokens need a boundary before them as well as after.

## [0.41.0] - 2026-10-23

### Added
- Deployments manifest. `<state home>/deployments.json` (`polispec.deployments/v1`, `schemas/deployments.v1.yml`) records every place polispec is deployed: harness hooks, harness-control overlays, git hook shims, the native pin, the rplugin install, marketplace plugins, the ledger, the settings file and the state home. `install`, `uninstall`, `harness install` and `uninstall`, `hook git install` and `uninstall`, `pin`, `ledger init`, `steward` and `apply --with-stewardship` record or retire their entry; recording never fails an installer, and the guard hook never writes it.
- `polispec deployments [--scan] [--json]` lists every entry with a live status (present, drifted, gone, removed); `--scan` backfills the manifest from the receipts, links, shims and files that already exist. A receipt whose target no longer exists is listed as gone, never hidden.
- `polispec uninstall --all [--keep wiring,pins,rplugin,data] [--dry-run] [--json]` backs up the manifest and every file it will change to `<data home>/backups/<bkp_ id>/` (`polispec.backup/v1`, `schemas/backup.v1.yml`), then removes every deployment through its own uninstaller: hooks and links, own harness-control overlays (an overlay that needs the operator is skipped and reported), git hook shims, `rplugin uninstall polispec`, the current and bin links (release directories are kept), and moves the ledger, settings file and state home into the backup. A ledger or settings file inside the global shelf or any git working tree is kept, not moved. Gone receipts are retired. Marketplace plugins are reported with their harness command. The real run needs a TTY and the typed phrase `uninstall polispec`; it prints the restore command with the path of a release that survives the uninstall.
- `polispec restore <bkp_id> [--mode rewire|bytes] [--dry-run] [--json]` and `restore --list`. Data is copied back to absent paths only; `rewire` (default) runs each installer again at its recorded target, `bytes` copies the backed-up files back and refuses any file edited since the uninstall. Harness-control overlays are reported manual. Needs the typed phrase `restore polispec`.
- `uninstall.sh`, beside `install.sh`, and the `polispec-uninstall` skill.
- Personal defaults. `Polispec::PersonalDefaults` reports a shipped default (modules, packages, config, rules, skills) that names a token taken from this host: a ledger project id, a ledger repo path or host, the global shelf's directory or git toplevel, or a non-default operator name. `doctor` reports each as `personal_default` (warn); `steward --check` reports step 4 and exits 1 on a hit; `steward` reports it and continues. The stewardship rule says personal policy belongs on the shelf or in the ledger.
- Change kinds `uninstall` and `restore` (`schemas/change.v1.yml`).

### Changed
- `modules/delete-guard.yml` no longer ships `~/.ai` as a protected tree: it is one host's AI home, not a path every polispec user has. A host that wants it lists it in its global shelf's `delete_protected` (the release host does). Every other entry is unchanged.
- `steward` counts a step that only warns as passing for its exit status.
- `GitHook::Installer` takes `resolve_policy:` so a scan can locate a checkout without composing its policy.

## [0.40.0] - 2026-10-23

### Added
- Text rules. A `match.text_matches` key, valid in policy, module and global documents: a Ruby regular expression tested against an action's new `text` hint. polispec ships no rule; a host adds them with `plan global` and `apply global`. A runtime older than 0.40.0 rejects the key, so apply such a rule only after the host is pinned at 0.40.0 or later.
- Action hint `text`: on every action of a shell command, the command's text followed by the body of each of its heredocs; on a write tool's `fs.write`, its content strings (per `edits` entry for a MultiEdit-style input), and for `apply_patch` each file's added lines or an Add File's whole body. Cut to 262,144 bytes on a character boundary, with `text_truncated` true.
- `polispec validate` reports a `text_matches` source that does not compile as an error naming the rule. At runtime, an uncompilable source, a match over its 0.25 s timeout (Ruby 3.2 and later) or a bad encoding does not hold and records a `text_matches` finding.
- `specs/text-match.impl.yml`, the blueprint, and the `text_match` section of `specs/app.yml`.

### Changed
- `apply_patch` write actions now carry `bytes` (and `text`), so `bytes_over` rules see Codex patches; before, the live path dropped the patch text.
- The fast path adds the tool needles whenever a composed shelf rule uses `text_matches`, so a call outside every ledger project still reaches the judge.
- The protected-authorization material leaves `text` and `text_truncated` out of each action. The tool input they come from is already bound, and keeping them would double a write's share of the 256 KiB material limit. Judgment records never carried hints beyond path and shape, so no written content reaches a log.
- No other verdict changes. Smoke against the pinned 0.39.0: 43 of 44 scenarios pass, as 0.39.0 did against 0.38.0; the one failure, `status-digest-doctor`, and the diffs are runtime kind (clone against pinned), ids and timestamps. Hook latency with one `text_matches` rule on a 200 KiB Write is within run-to-run noise over 200 calls.

## [0.39.0] - 2026-10-22

### Added
- Scratch size caps. Four `match` keys, valid in policy, module and global documents: `bytes_over` (an integer; an `fs.write` whose `bytes` hint is above it), `fsize_unset` (a shell `fs.write` with no hard file-size limit in force), `fsize_above` (a shell `fs.write` whose limit, in bytes, is above the value) and `tree_over` (`{marker, bytes}`; the scratch tree, found as the path itself or its nearest ancestor named `marker`, is above `bytes` by `du -sb`, cached 60 s under the state home). polispec ships no rule: the caps are the rules of a shelf module, `scratch-cap`, that a host adds with `plan global` and `apply global`. A runtime older than 0.39.0 rejects the new keys, so apply that module only after the host is pinned at 0.39.0 or later.
- Shape `bulk_write`, on the `fs.write` actions of tar in create mode, zip, 7z, 7za, 7zr, 7zz, pg_dump, pg_dumpall, mysqldump, ffmpeg, curl, wget, cp, rsync, dd, git archive and git bundle, and of any command with one of those upstream in its pipeline. The unknown write at the working directory kept for a command whose output could not be resolved does not carry it.
- Action hints: `bytes` on a write tool's `fs.write` (the byte size of its content strings, per `edits` entry for a MultiEdit-style input) and `fsize_blocks` on a shell command's `fs.write` (the hard `ulimit -f` in force when the command runs, or `unlimited`; the weakest limit when several commands of a script share a text).
- `specs/scratch-cap.impl.yml`, the blueprint, and the `scratch_cap` section of `specs/app.yml`.

### Changed
- Tightening for every project, found by the work: `tar` in create mode now yields an `fs.write` for the archive when the name sits in a bundled option cluster (`tar czf X`, `tar -czf X`, `tar cf X`), after other options (`tar -C src -czf X .`) or in `--file=X`; before, only a separate `-f X` was seen and the usual forms wrote nothing polispec saw. `zip`, `7z`, `ffmpeg`, `mysqldump`, `pg_dump -f`, `git archive -o` and `git bundle create` also yield an `fs.write` for their output. Rules that judge `fs.write` (prod-write, location, protected roots) now see these outputs. `7z`, `ffmpeg` and `mysqldump` keep the 0.38.0 unknown write at the working directory when no output can be resolved.
- A write tool call whose input exceeds 8 MiB is already denied by the hook input cap (`INPUT_LIMIT`), so a `bytes_over` cap helps only below that.
- No other verdict changes. Smoke against the pinned 0.38.0: 43 of 44 scenarios pass; the one failure, `status-digest-doctor`, fails the same way on an unmodified copy of 0.38.0 (its expected finding count depends on the checkout's HEAD being local main), and the 37 differences are runtime kind (clone against pinned), ids and timestamps.

## [0.38.0] - 2026-10-22

### Added
- Resident judge. `polispec judge serve|status|stop` runs one Ruby process on `127.0.0.1` that answers pretool and session calls from memory through `HookCommand#judge_request`, the code the cold path runs, with the same flocked, hash-chained journal record. It records its port and a per-start token in `judge.json` (mode 0600), reloads the ledger, the global shelf and each live project's policy only when a content key changes (ledger bytes, both settings files, `/etc/polispec/active.json`, the shelf's files or ref commit, each live project's trust-ref commit, the runtime version), and exits after `POLISPEC_JUDGE_IDLE` seconds idle (default 1800) or after answering a request from another runtime directory (`lib/polispec/judge.rb`, `lib/polispec/commands/judge.rb`).
- `bin/polispec-guard` asks the judge through bash's `/dev/tcp` after the fast-path skip test and binary resolution, within `POLISPEC_JUDGE_BUDGET` seconds (default 0.5, so that budget, the 8 second deadline and the margin stay below the hook's 10 second timeout), and falls back to the unchanged cold path with a `launcher.jsonl` row (`judge_<reason>`, decision `pass`) on any other outcome; a detached judge is started at most once per 30 seconds. `POLISPEC_JUDGE=off` skips it.

### Changed
- No verdict changes. `HookCommand` splits `pretool` and `session` into `pretool_result` and `session_result`, which return the reply instead of writing it; the cold path writes it exactly as before.
- A request that overruns the launcher's budget after the judge started judging can be journaled twice, once by the judge and once by the cold path.

## [0.37.4] - 2026-10-22

### Changed
- Reads of release code in a prod checkout are allowed (loosening, approved by Sven). A read candidate (`secrets.read` with hint `candidate`, from Read and the shell read classifiers) that resolves to a prod tier is allowed by the new `POLISPEC-RELEASE-READ` row before policy rules when its path lies under an environment's declared `checkout`, matches none of the policy's `data.dirs`, `unit_files`, `env_files` or `secrets`, is tracked by git there and `git status --porcelain --ignored` reports it unmodified (`Engine::Envs.release_read?`, `Engine.judge`, `lib/polispec/engine.rb`). Before, every such read took the env of the checkout and `R-PROD-SECRET` denied it, so an agent could not read the code it was asked to diagnose. Modified, untracked, ignored and missing paths, directories holding any of them, prod data dirs (student records), env and unit files, declared secrets, and a command that also reads one of those stay denied.

### Fixed
- A failing `drain.resume` is no longer silent. It is retried up to three more times (2, 4 and 8 s apart); the deploy record keeps the drain log (each pause, wait, check and resume attempt with its exit, and for a failed resume its directory and output tail); when the resume still fails, the record detail, the result's `queues_paused`, the deploy and promote text output and a failed deploy's error payload say the queues are still paused and name the exact resume command and directory; and `polispec doctor` reports `drain_resume_failed` (warn) for each project and env whose latest recorded resume failed until a later deploy's resume succeeds (`lib/polispec/operator/deploy.rb`, `lib/polispec/commands/deploy.rb`, `lib/polispec/commands/promote.rb`, `lib/polispec/commands/doctor.rb`). On 2026-10-20 a Teach stable deploy failed a drain check while the disk was full; its resume left no trace and grading stayed paused for seven hours.

## [0.37.3] - 2026-10-22

### Fixed
- The fast path re-stamps when a watched file is newer. `Fastpath.stale?` now treats any watched file (the ledger, a global shelf ref or packed-refs, the rplugin settings, the native settings file, `/etc/polispec/active.json`) with a modification time later than `fastpath.txt` as stale, so `refresh` re-stamps even when the content key is unchanged and read tools skip the launcher again after a shelf commit or a ledger write (`lib/polispec/fastpath.rb`).

## [0.37.2] - 2026-10-21

### Fixed
- The web UI session gates for no session, a used or expired link, and an ended session now name `polispec web url`, which mints a fresh one-time link for the server already running. They previously named `polispec web --open`, which a supervised server refuses with `already_running`. The not-running gate keeps `polispec web --open` (`web/public/js/components/ps-session-gate.js`, `web/public/js/app.js`, `specs/web-frontend.impl.yml`).

## [0.37.1] - 2026-10-21

### Fixed
- Recognize static noninteractive shell noexec checks without classifying the checked script as executed. Retain caller redirects, substitutions, privilege, and surrounding commands, and classify the script operand as a read. Unsupported option combinations stay conservative.
- Treat stdin supplied to an interpreter with a literal existing script operand as data, rather than extracting shell commands from its JSON input.
- Detect Codex guard bridges launched through known interpreters instead of inspecting only the interpreter binary. Wiring discovery still makes no trust or enforcement claim.
- Keep smoke runs on their own Codex home with an empty configuration, so doctor findings and hook discovery do not depend on the operator's running harness configuration.
- Refuse judgment appends on an unreadable tail or divergent head and detect short writes before advancing the anchor. Verification takes the append lock in shared mode and names malformed archive records without altering historical evidence.

## [0.37.0] - 2026-10-20

### Added
- Optional `polispec.web.public_origin` for serving the existing web UI through an external HTTPS proxy while retaining a loopback backend. Initial and fresh links use the origin recorded by the running server, cookies carry Secure, and Host and Origin checks admit only the configured public authority.
- Agent web API classification recognizes the configured and running HTTPS origins as well as existing loopback endpoints. Routing and supervision remain external; the standalone plugin requires neither rStack nor Tailscale.

## [0.36.0] - 2026-10-20

### Added

- Optional guided-learner catalog package with six canonical public presentation policies and bounded explicit-violation detector data. Applying it writes only its behavior source, without changing environments, the ledger, or host enforcement.
- Read-only `polispec behavior export-package NAME` for consumers that ship compiled policy through their own adapters without a runtime Polispec dependency. Unsupported external body references are refused.


## [0.35.1] - 2026-10-20

### Added

- The packaged `polispec-specs` agent skill: how to identify, draft, validate, plan, and safely apply environment policies, modules, rosters, ledger proposals, behavioral policies, and code-spec packs; it explains candidate refs, generated surfaces, exact-plan approvals, runtime compatibility, and operator promotion boundaries.

### Changed

- The main agent skill now locates the installed CLI and plugin-relative documentation, resolves the target environment, explains actual hook calls, and routes spec authoring and registration to dedicated skills. Corrected the obsolete claim that harness controls ship disabled.
- Registration guidance reuses supplied context and authorization, and routes shelf and ledger modifications through the spec-authoring workflow.

### Fixed

- Standalone installation and removal cover every shipped skill directory for Claude Code user/project scope and Codex user scope, preserving foreign links and receipt ownership. Previously only the main skill was installed.
- Description-lint documentation names the supported strict setting rather than a nonexistent `validate --strict` flag.

## [0.35.0] - 2026-10-20

### Fixed

- The edition registry's epoch notice entry points to `lib/polispec/effect.rb`, so `polispec editions --check` can verify its implementation.

### Upgrade and rollback

- 0.35.0 adds keys that every earlier release rejects as unknown: `description` on every rulebook and ledger entry, and `paths`, `owner` and `registered_by` in the ledger. A ledger or trust ref that uses them is invalid to 0.34.0 and older, and a guard running such a release judges the affected projects by their fallback rules. Pin 0.35.0 on every host that reads a ledger or trust ref before writing these keys into it. Writers check the installed release first (`Description::RUNTIME_FLOOR`, read from the native pin, the rplugin store or the pinned runtime) and refuse with `runtime_behind`.
- To roll back after 0.35.0 has written the ledger, restore the ledger backup that `apply ledger` left beside it (or remove `paths`, `owner`, `registered_by` and `description` by hand through `polispec plan ledger --from FILE` on 0.35.0) before reinstalling 0.34.0.

### Added

- `polispec web`, a local web app over the files polispec already keeps: the map of projects and governed paths with their layers, project detail, the rulebook manager with a CodeMirror editor, live lint and blast radius, plans and applies through the same plan and apply path as the CLI, pipeline, sessions, timeline, feed and heatmap views, the playground and explainer, history, the gallery, exceptions, manifest and register views, six themes through one switcher, and a command palette. Loopback by default, one-time exchange links (`polispec web url`), session cookie plus CSRF for every mutating route, `--read-only`, and `G-WEB-AGENT` classifying an agent's call to it as `policy.edit`. Routes are glob-loaded from `lib/polispec/web/routes/*.rb`; the contract is `web/public/openapi.yml`. No database: browser storage caches views and `web/state/*.yml` keeps layout, pins and saved playground calls.
- The `author` port: `polispec author draft <kind> --intent TEXT` drafts a rulebook or description, validated and planned before anyone sees it, and writes nothing. The standalone adapter runs a read-only harness CLI session (Read, Grep and Glob only, one Read rule per root, scratch `POLISPEC_*` variables stripped); rplugin extensions add adapters through the declared port (`polispec.rplugin.yml` `ports.declared: [author]`, rplugin 1.17.0 or later).
- `description` on every rulebook and ledger entry, with a deterministic lint (`missing`, `too_short`, `too_long`, `restates_summary`, `names_nothing`, `states_no_effect`), warnings in `polispec validate`, `POLISPEC_DESCRIPTION_STRICT=on` to fail on them, `--semantic` to judge a description against the rules (`matches`, `partial`, `contradicts`), and the doctor finding `description_ahead_of_runtime`.
- Governed path entries: `polispec register <path> --kind software|directory|system` and `polispec unregister <id>` plan and apply a `paths` entry in the ledger with owner stamping, so software, a directory or the system scope that is not a git repository with branches can be governed; judgments on a path entry are labelled with it.
- Effect tracking: the policy epoch, chained change records, session records, `polispec changes list|show|await|verify`, `polispec sessions list|show`, and a once-per-epoch notice line on the next pretool call after a change.
- `polispec manifest` and `manifest index`: a per-project `polispec.manifest.json` and badge, committed on main with `--write`, and a publishable index (`POLISPEC_INDEX_DIR`).
- The edition registry `specs/editions.yml` and `polispec editions [--check]`, which list every feature that differs between the standard and lock editions; lock comparisons now go through it.
- Delegate grants may name `exceptions-add`, `exceptions-promote` and `exceptions-remove`; refused under lock.

### Changed

- The shell parser follows `source` and `.` files as it follows scripts, bounded in commands and time, and treats a same-line rewrite of a followed file as opaque, so a sourced file's commands are judged instead of asking `POLISPEC-TOOL-UNKNOWN`.
- Hook latency: plane, ledger, settings and shelf reads, ownership, location and canonical-path resolution are memoized within one hook or explain process, and classifier modules are preloaded.
- `polispec smoke run` gives every scenario a scratch `RPLUGINS_HOME` and `POLISPEC_DATA_HOME`, so a scenario no longer reads the host's rplugin store or native pin.

## [0.34.0] - 2026-10-20

### Added

- `polispec.behavior/v2` (`schemas/behavior.v2.yml`), a superset of v1 selected by its schema id. Directives gain `scope`, `duplicate_of` and `body_ref: {path, sha256}`; a referenced body is checked against its hash at compile time and the compiled form carries `body_sha256`, never the text. New maps `surfaces`, `frames`, `antifeatures`, `controls`, `messages` and `overlays.cutout`. v1 files validate and compile byte for byte as before.
- `polispec behavior render`, `drift` and `lint`. `render` writes a surface from its template; `drift` exits 1 when a generated target differs from its rendering; `lint` exits 1 when a sentence of 8 or more tokens restates a directive (0.8 token overlap) without naming it. `duplicate_of` exempts only the linked pair from each other.
- `polispec behavior compile --root DIR`; the v2 compiled form `polispec.behavior.compiled/v2` adds a `surfaces` map with the sha256 of each generated surface, so a consumer without polispec can detect a hand-edited projection. Compile fails, naming the surface, when a surface cannot render.
- `Polispec::Surfaces` (resolve, render, drift, lint, `when_matches?`) and `AgentsRender.directive_row`/`directive_rows`, which render any directive set in the `[OPCODE] rule d/x ⚙ enforce ⚡ [when]` row format.

## [0.33.2] - 2026-10-20

### Fixed

- The guard launcher fails closed. `bin/polispec-guard` denies every non-read call when polispec is missing, exits with an unexpected status, or runs past the launcher deadline. Each harness gets the reply the hook's own internal failure gives: Claude Code, Codex, Antigravity, Pi and DeepSeek exit 0 with their deny or block JSON, Hermes exits 2 with its block, and an unknown harness name gets the reason on stderr and exit 2. Read tools (`polispec-guard --read-tools` lists them) and session start still pass, and an exit 0 with no output is still an allow. The 0.33.1 fallback denied only shell calls that matched a prod-shaped pattern and let every other call through. Each failure appends one line to `launcher.jsonl` in the state directory: ts, tool, session, harness, mode, cause (`no_binary`, `timeout` or `exit_<status>`) and decision.
- The launcher runs the hook under an 8 s deadline (`POLISPEC_GUARD_DEADLINE`, an integer from 1 to 9), through `timeout -k 1` or, where `timeout(1)` is missing, a bash watchdog. The hook's own budget drops from 9.5 s to 7 s, so polispec answers before the harnesses' 10 s hook timeout cuts it off.
- A hook call composes each project's policy once. For every path in a command the engine recomposed each live project's policy: `Atlas#lookup` cached per locator and `Envs.spec_owner` not at all. On this host one ordinary Bash call composed policies 2,101 times, ran out the 9.5 s budget and was denied as an internal failure, and a five-word command composed 1,570 times. `PolicySource.memoize` keeps each composed policy for the length of one hook call and gives every caller its own copy. The same two commands now take about 0.7 s with nine compositions.
- Hook input up to 8 MiB is judged. The cap was 64 KiB, so a Write or Edit of a larger file was denied as "guard unavailable". Input over 8 MiB is denied with "[POLISPEC internal] hook input exceeds 8 MiB; call denied. Split the change into smaller calls." The launcher reads at most one byte past the cap.
- The launcher maps the harness name `deepseek-tui` to `deepseek`, as it maps `claude-code` to `claude`.
- `polispec smoke run` runs each scenario file once when the tree is reached through a symlink. It deduplicated files by `File.expand_path`, so with `--live` a scenario found both through `--scenarios <symlinked tree>/smoke/live` and through the tree's real path ran twice. The second fixture build then failed `git commit` with nothing to commit. Every rplugin store reaches its release through such a link (`~/.rplugins/polispec`). It now deduplicates by `File.realpath`.

### Added

- Finding `gate_unreachable`. Some promotion setups can never pass: a gate that needs a passing deploy of an environment with no `deploy:` (`G-TESTED`, or any `sha_ran_on`, `sha_ran_on_test` or `soaked` gate), or an `after:` step that deploys such an environment. `polispec doctor` reports each one as blocking, and `polispec status` shows it as the project's finding. `polispec validate policy` reports it at `/promotion`, and `polispec plan project:<id>` lists it under notes without changing the classification or the plan id. `promote` and `deploy` are unchanged.
- environment-control 1.1.0. The distributed variant declares placeholder deploy blocks for test and prod, as the service variant does, so a project applied from it no longer starts with unreachable gates.
- Smoke scenarios `guard-failclosed`, `gate-unreachable` and `policy-memo`. `examples/environments.widget.yml` declares deploy blocks for test and prod.

## [0.33.1] - 2026-10-20

### Fixed

- `bin/polispec-guard` passes a Hermes block through. The Hermes adapter answers a deny with exit status 2 and `{"action":"block",...}` on stdout, and so does its fail-closed internal denial. The shim treated every nonzero exit as a runtime failure, dropped the reply, applied the inline fallback and exited 0. On every Hermes host wired through the shim (the rplugin hook manifest wires every harness that way), a deny was an allow unless the command matched the fallback pattern for prod-shaped git, `systemctl` or `gh release`. A pretool reply with exit status 2 and a JSON object on stdout now reaches the harness unchanged with status 2; any other nonzero exit still takes the fallback. Claude Code, Codex and Antigravity replies exit 0 and are unchanged.

### Added

- Smoke scenario `guard-shim` (unit `commands/hook pretool|session`) drives the shim for Hermes (a deny, an allow and a malformed call) and for Claude Code and Codex (a deny each) in a live fixture project.

## [0.33.0] - 2026-10-19

### Added

- A shipped delete guard. `modules/delete-guard.yml` composes in the shipped layer beside `modules/tool-declared.yml` on every host, with three overridable rules. `G-DELETE-PROTECTED` denies a delete that reaches a protected path. `G-DELETE-PROTECTED-FILE` asks before a single, non-recursive file delete under a protected folder. `G-DELETE-XARGS` asks before a deleter fed through `xargs`, whose targets polispec cannot see.
- The data key `delete_protected` holds `exact` entries (the path itself) and `tree` entries (the path and everything below it). The shipped list is exact `/`, `~`, `/home`, the system folders and `/usr/bin`, `/usr/sbin`, `/usr/lib` and `/usr/lib64`, and tree `~/.ssh`, `~/.ai`, `~/.claude`, `~/.config`, `~/.rplugins` and `~/.polispec`. The global doc and every shelf module may add entries; nothing removes one, and a global plan classifies an added entry tightening and a removed one loosening (`delete:exact:<path>`, `delete:tree:<path>`).
- Match predicates `delete_protected` and `delete_protected_file`. A delete of a directory's contents (`*`, `.*`, `.[!.]*`, `..?*`, `.??*`) is judged as a delete of that directory. A recursive delete is denied at or under a tree entry or at an ancestor of any entry. Paths are compared lexically and with symlinks resolved, so a tree entry that is a symlink also protects the folder it points to, and every ancestor of it. Beneath a tree entry the resolved form counts only when the entry is a real folder: `~/.ssh` is covered through any alias, while a path inside a symlinked entry's target written by its real path (a build directory in the git repo `~/.rplugins` points into) is not judged.
- `fs.delete` actions carry the `recursive` hint for `rm -r`/`-R`/`--recursive`, `rmdir`, find deletes and `cargo clean`. A deleter whose words come through `xargs` carries the shape `xargs_delete`.

## [0.32.2] - 2026-10-19

### Fixed

- `Engine::Envs.under?` holds every path under the root `/`. It tested the prefix `//`, so a root of `/` contained nothing and `match.live_binary` missed `rm -rf /`: the shelf's `G-LIVE-BINARIES` denied `rm -rf /usr/lib` and `rm -rf ~` but allowed `rm -rf /`. The same helper decides protected roots, hermetic protected roots, policy checkouts, spec data dirs and the runtime guard, which now also contain everything when their root is `/`.

## [0.32.1] - 2026-10-18

### Fixed

- A command placed in a shell script file no longer escapes classification. `bash run.sh`, `sh -e run.sh`, `sudo bash run.sh` and `./run.sh` (an executable with a shell shebang, or no shebang and `.sh`) used to parse as fully classified lines whose script was never read, so every deny rule could be walked past by writing the command to a file, while `source run.sh` asked. The parser (`Shell::Parser#follow_script`) now classifies the script's commands as if written in the line, taking the content a `cat > FILE` or `tee FILE` heredoc earlier in the same line wrote, else the file on disk up to 1 MB (`Shell::MAX_SCRIPT_FILE`), to `MAX_DEPTH`. A dynamic operand, a missing, unreadable or oversized file, exhausted depth, or a path the same line wrote with unknown content marks the line opaque, judged as `eval` and `source` are (`opaque_shell`). A followed script's host is not counted for `chained_release`, as a `-c` host is not.

### Added

- Shape `tmux_kill` (`Classify::Shapes.tmux_kill?`): `tmux kill-server` or `tmux kill-session` with no `-L` or `-S` before the subcommand, which also adds a `service.control` action. On 2026-10-17 an agent's scratch script ran `tmux kill-server` with an inherited `TMUX` and killed the live rterm agent server. `schemas/policy.v1.yml` and `schemas/control.v1.yml` accept the name; no shipped rule uses it.

## [0.32.0] - 2026-10-18

### Added

- `modules/tool-declared.yml`, a module polispec ships and composes first in every chain as the `shipped` layer, on every host, before the global shelf. It declares the harness-internal tools (`TOOL-<NAME>`, `match.tool` with class `tool.internal`), the read tools called without a path (`TOOL-READ-<NAME>`, class `tool.read`) and the development relaxation of `eval`, `source` and `.` lines (`TOOL-OPAQUE-DEVELOPMENT`, shape `opaque_shell` with the new `in_development` predicate). Every rule is overridable: the shelf declares another tool or tightens a shipped one with a plain rule, narrows the relaxation with a rule on `opaque_shell`, and loosens a shipped rule only through `overrides`, all through `polispec plan global` and `apply global`. `polispec resolve <path> --layers` prints the layer; `Layers.shipped_rules` exposes its rules.
- Action classes `tool.internal` and `tool.read`, shape `opaque_shell` and the `in_development` predicate in the policy, module, global, control and ledger schemas. `in_development` applies `Ledger#development` to the line's directory and to every command directory as 0.30.2 did, and is false under the lock edition and under `polispec.relax.dev off`, which is now the predicate's kill switch.
- An unknown-tool action is declared the way an MCP operation is: a trusted rule whose `match.tool` names the exact tool (case-insensitive) or whose `match.shape` includes `opaque_shell`, matching the action in full, lifts the unknown mark; the declared action is then judged by environment policy, so a stricter shelf rule on the same tool wins. With no trusted policy at all only the shipped rules declare.

### Changed

- The library keeps detection and the edition default only: `Classify::Benign::INTERNAL_TOOLS` and `HookCommand#dev_projects` are gone. A non-shell tool with no classified action yields a `tool.internal` action, a read tool with no path a `tool.read` action, an opaque shell line a `shell.exec` action with shape `opaque_shell`, each marked unknown until a rule declares it. An undeclared tool asks exactly as before. `match.tool` compares case-insensitively.
- `fastpath.tools` derives from the shipped layer (the declared `tool.internal` and `tool.read` names, minus the read tools when the shelf governs reads, minus every tool a shelf rule names) instead of the two library lists.
- `Layers.fingerprint` and every effective digest include the shipped layer digest, so the baseline target digest, the fast-path key and `resolve --layers` output change with this release while every verdict stays: the 0.30.2 development matrix, the recorded non-Bash judgments since 0.30.2 and the smoke suite against the pinned 0.31.0 give the same verdicts as an unmodified 0.31.0 tree.

## [0.31.0] - 2026-10-17

### Added

- `polispec delegate` lets an application run `polispec promote` and `polispec deploy` for the operator through a local runner (`lib/polispec/delegate.rb`, `lib/polispec/delegate/`, `lib/polispec/commands/delegate.rb`, `schemas/delegate_grants.v1.yml`). `grant APP` at a terminal, with a typed phrase, stores a scope of verbs, ledger projects, targets and flags and prints a one-time app token. Only the token's sha256 is kept, in `<state home>/delegate/grants.yml`. `revoke`, `list`, `status` and `unit` manage it. `serve` is the runner: a Unix socket private to the user, with a peer-uid check, per-app token authentication, a rate limit of 60 a minute, and runs forked into their own session with output kept by byte offset. Each run has an hour's timeout and at most 8 MiB of readable output. It refuses on a sealed plane and while `<state home>/delegate/delegate.disabled` exists.
- `Operator::Tty.confirm!` and `Gates.interactive?` honor an in-process delegated confirmer that only the runner's child sets. It relays the phrase an application's user typed to the same exact-match check, once per prompt, waits at most 10 minutes, and never logs the typed text. Without a confirmer nothing changes: `deploy <project> stable` from a non-terminal still fails `not_tty` with the same message.
- Promotion and deploy records and the `polispec.promote` and `polispec.deploy` events carry `via: delegate:<app>:<by>` for delegated runs. The new event `polispec.delegate` reports each run's result.

### Changed

- The guard classifies a Write, Edit or shell redirect into the grants file as `policy.edit`, and also `polispec delegate grant`, `revoke` and `serve`. The host defaults and the environment-control packages warn on that class, so an agent cannot quietly grant itself a scope or start its own runner. `delegate list`, `status` and `unit` stay benign.

## [0.30.2] - 2026-10-17

### Fixed

- The 0.30.0 relaxation kept the `POLISPEC-TOOL-UNKNOWN` ask on lines that change into a directory outside development before they source an env file. Real calls showed it: since 0.30.0 went live on this host it relaxed 84 calls and still asked 27, and 25 of those 27 touched the session scratchpad under `/tmp`, where agents write and source an env file (24 in rdemo, 1 in rEach, 1 in rllm). `dev_projects` (`lib/polispec/commands/hook.rb`) now accepts a command directory that is in development or that no non-retired ledger project contains (`Ledger#locate` returns nil). A line that changes into a live project or a checkout, a session that itself starts in an unowned path, the lock edition and `polispec.relax.dev off` keep the ask, and the visible commands of the line are judged as before. The `relaxed` field lists the development projects only.

## [0.30.1] - 2026-10-17

### Fixed

- A hook process killed after it appended a judgment record and before it moved `judgments.head.json` no longer forks the chain. `Judgments.read_head` (`lib/polispec/judgments.rb`) compares the anchor with the last record of the stream; when the records after the anchored digest chain unbroken from it within the last 256 KiB, the next append chains to the last record and counts the ones the anchor missed. An anchor the stream does not chain from is still not adopted, so a truncated stream or a foreign head forks and is reported as before. Before the fix the next append chained to the stale digest, and the anchored count stayed short for good: this host had three such forks (01:53, 05:48 and 07:40 UTC on 2026-10-17, two of them with a zero-byte `judgments.head.json.<pid>.tmp` left behind) and `doctor` reported `judgments_chain_broken` and `judgments_truncated` for them.
- `polispec judgments verify` recognises that signature, a record whose `prev` equals the `prev` of the record before it, as an `interrupted_append`. It lists those in a new `interrupted` array beside `findings` (also in `--json`), prints `chain ok; N interrupted appends`, exits 0, and expects the anchor's count to leave them out. `doctor` reports nothing for them.
- Append latency on a stream of this host's size rose from 0.37 ms to 0.55 ms.

## [0.30.0] - 2026-10-17

### Changed

- A governed line that runs `eval`, `source` or `.` no longer asks `POLISPEC-TOOL-UNKNOWN` in a project in development. `Ledger#development(path)` (`lib/polispec/ledger.rb`) returns the project ids when at least one non-retired ledger project contains the directory, every such project has status `onboarding`, and the directory is not inside an env checkout; `HookCommand#judge` (`lib/polispec/commands/hook.rb`) then skips the opaque unknown in both of its branches. Agents source env files they wrote themselves on nearly every task, and 82 of the 86 asks left in `rllm`, `teach`, `reach` and `rdemo` since 0.28.3 were such lines, in projects the guard lists as not enforced. The directory of every command in the line must be in development too, so `cd <live project> && source env.sh` still asks. A live project, a live project containing an onboarding one, a test or stable checkout, an unowned path and the lock edition keep the ask, and so does everything that is not an opaque line: an unrecognised tool, a line the parser extracts no command from, an undeclared MCP operation, every deny and every rule warn. The visible commands of a relaxed line are judged as before, so `source env.sh; git push origin main:stable` is still denied; what the relaxation gives up is sight of the commands inside the sourced file.
- Each relaxed call carries an optional `relaxed` field in its judgment record (rule, reason `development`, project ids; `schemas/judgment.v1.yml`). Records without it are unchanged.
- The new setting `polispec.relax.dev` (`on` by default, `POLISPEC_RELAX_DEV=off`) restores the 0.29.0 ask in every project without a release.

## [0.29.0] - 2026-10-17

### Added

- Persistent exceptions to guard asks: an always-allow list for `POLISPEC-TOOL-UNKNOWN`, `POLISPEC-MCP-UNDECLARED` and environment rule warns. Claude Code's own prompt for a hook ask offers only Yes or No, so a line the guard cannot classify (an `eval`, `source` or `.` line, an unrecognised tool, an undeclared MCP operation) asked again in every session. The operator now records an exception once, in `exceptions.yml` (schema `polispec.exceptions/v1`, `schemas/exceptions.v1.yml`) at the root of the global shelf. It lifts exactly the ask it names, for the commands it matches, in the project or on the host it is scoped to.
- `polispec exceptions list|add|promote|remove`. When a call asks, the hook records a proposal (`apr_` id, `exception_proposals.jsonl` in the state home, kept seven days) and ends the ask text with `To stop asking for [<command>], the operator can run in a separate terminal: polispec exceptions promote <id>`. `promote`, `add` and `remove` need a TTY and a typed phrase, refuse while the sealed plane is active, and write nothing but `exceptions.yml`: they require the shelf to be a git repository on its ref with no other uncommitted change under the shelf path, then plan and apply the global target with the plan's own id as the confirmation, which commits the file as `Apply polispec plan <id>`. A failed apply restores the previous bytes, or moves a new file to `<state home>/exceptions.yml.failed-<UTC>`. An agent shell cannot run them (`not_tty`).
- An entry has a kind (`control` for the unknown-tool and undeclared-MCP asks, `rule` for a Bash rule warn), the exact tool, a glob over the whitespace-normalised, unexpanded command text (`*` crosses slashes; the first word may not contain a glob character), and a scope of one project (the git toplevel of the working directory, of the proposal's directory for `promote`) or the whole host. `promote` escapes the glob characters of the proposed text, so a promoted entry matches that command exactly. A shell line with several `eval`, `source` or `.` commands is lifted only when every one is covered, and the rest of the line is judged as before.
- Every call an exception lifted carries the `aex_` ids in an optional `exceptions` field of its judgment record (`schemas/judgment.v1.yml`); records without one are unchanged. `polispec doctor` reports `exceptions_invalid`. The setting `polispec.exceptions` (`on` by default, `POLISPEC_EXCEPTIONS=off`) honors no entry, records no proposal and adds no hint, which restores the 0.28.3 output.

### Security

- Exceptions never lift a deny, `POLISPEC-CONTROL-PROTECTION`, the container root guard, a broken seal or any lock-edition verdict, and `plan`, `apply`, probes and the journal replay never apply them. The file is a protected path like the ledger: a Write, Edit or shell redirect into it classifies as `policy.edit` and is denied.
- An exception matches the text of a command, not what it expands to or runs. An entry for `. $B/env.sh` stays in force whatever `$B/env.sh` contains, so scope it as narrowly as the work allows. The `sealed_authority` refusal was exercised only against a stubbed `Plane.resolve`, because no plane is active on this host.

## [0.28.3] - 2026-10-17

### Fixed

- `SubagentHandback`, `StructuredOutput` and `ScheduleWakeup` asked `POLISPEC-TOOL-UNKNOWN` on every call. They are harness-internal tools like `TaskStop` and `SendMessage` (a subagent returning its result, a headless run emitting its structured answer, a loop resuming itself), so they are now in `Classify::Benign::INTERNAL_TOOLS` (`lib/polispec/classify/benign.rb`) and are not unknown. Over the two days of host judgments before this change they made 177 of the 381 `POLISPEC-TOOL-UNKNOWN` asks. `CronCreate` and the other scheduling tools, `Artifact` and every unrecognised tool keep asking.

## [0.28.2] - 2026-10-17

### Fixed

- Every Claude Code `Monitor` call asked `POLISPEC-TOOL-UNKNOWN`, whatever its command was, because `Monitor` was not a recognised shell tool: its command was never parsed, so a loop of read-only commands such as `until grep -q … ; do sleep 5; done; echo finished` was judged as an unknown tool. `Monitor` now joins the shell tools, so its command is classified and judged by policy like the same Bash line, and a line the parser fully parses and policy allows no longer asks (`Harness::Base::SHELL_TOOLS` in `lib/polispec/harness/base.rb`). The container root guard covers it as well, so a privileged `docker run` in a `Monitor` is caught as in Bash (`HarnessControls::RootGuard::SHELL_TOOLS`); without that, the call would have stopped asking and stopped being guarded at once. A `Monitor` line that runs `eval`, `source` or `.` still asks, and a push to `stable` in one is now denied by `R-PROD-GIT` as in Bash rather than only asked. Over the last two days of host judgments, 59 of the 381 `POLISPEC-TOOL-UNKNOWN` asks were `Monitor` calls.

## [0.28.1] - 2026-10-16

### Fixed

- Reading compressed files counted as writing them. `zcat`, `zgrep`, `zegrep`, `zfgrep`, `zless`, `zmore`, `bzcat`, `xzcat` and `zstdcat` were unrecognised programs, so each got the fallback write on its working directory, and a protected-root rule such as a location bound denied a plain read. They now classify as reads of their file operands, like `cat` and `grep` (`lib/polispec/classify/commands/secrets.rb`).
- `gzip`, `gunzip`, `bzip2` and `xz` always counted as writing their first operand. With `-c`, `-t` or `-l` (alone or in a short-option cluster such as `-dc`), `--stdout`, `--to-stdout`, `--test` or `--list` they write nothing and now read their operands. Compressing or decompressing in place still writes, and a redirect such as `gzip -c a > b.gz` still writes `b.gz` (`lib/polispec/classify/commands/fs.rb`).
- `mkdir -p "$DIR"` with an operand the parser cannot resolve counted as a write of the working directory. From the home directory, that write is an ancestor of polispec's protected roots, so POLISPEC-CONTROL-PROTECTION denied creating a scratch directory. Such an operand is now the fallback write with `unknown`, which the ancestor match skips (as for unrecognised programs since 0.23.1). A static `mkdir` target, and an unresolved operand of any other command (`chmod -R "$X"`, `rm -r "$X"`), keep the ancestor match (`lib/polispec/classify/commands/fs.rb`).
- Pre-release smoke against the pinned 0.28.0: 31/31. The 29 diffs are the same set an unmodified tree at 0.28.0 produces against it: the clone-versus-pinned runtime kind of the candidate tree, installation and operation ids, backup timestamps, scratch paths and commit ids.

## [0.28.0] - 2026-10-16

### Added

- Code specs gain two classification axes on `polispec.spec/v1`: `type` (`directive`, `lint`, `review`, `contextual`) says how a policy binds, and `domain` (`design`, `accessibility`, `performance`, `code-quality`, `code-meta`, `security`, `operations`) says what it governs. Both may be declared at spec level, as a default for the spec and its child specs, and on any composite or rule, overriding for its subtree. An undeclared type is derived from `execution.class` (`lib/polispec/code/pack.rb`, `schemas/spec.v1.yml`).
- `polispec code list [--type T] [--domain D] [--spec PATH] [--json]` prints every active policy with its type and domain and the count (`lib/polispec/commands/code.rb`).
- `--type` and `--domain` filter `polispec code show`, and the output of `show` and `chain` carries each rule's type and domain. The guard classifies `code list` and the new flags as read-only (`lib/polispec/classify/benign.rb`).

### Changed

- The `code-commands` smoke scenario expects the new `show` line format, `<level> <severity> <class> <type> <domain> <lifecycle>`. Pre-release smoke against the pinned 0.27.1: 31/31, with diffs limited to the new type and domain columns, the version, commit ids, and the clone-versus-pinned runtime kind of the candidate tree.
- `polispec code validate` rule 9: an active rule whose declared or spec-level type disagrees with its `execution.class` is a problem. Packs that declare no types are unaffected (`lib/polispec/code/validator.rb`).

## [0.27.1] - 2026-10-16

### Fixed

- A fresh install could not follow the quick start. `polispec apply environment-control --repo <repo>` failed with `ledger_missing: … create it before onboarding`, and nothing created a ledger. polispec now creates a starter ledger from one template, `config/ledger.starter.yml` (the schema, the short hostname, `envs_root ~/.polispec/envs`, the example default rules, `projects: []`):
  - `polispec install` creates it at user scope, and so does `install.sh` through it. The receipt records `ledger_created`, and `uninstall` leaves the ledger in place.
  - A package `plan` on a host without a ledger shows `before: none` and the tighten change "creates the starter ledger … with no projects". `apply` creates it (no `.bak-` file, since there was none) and adds the project as `onboarding` without `--confirm`.
  - `doctor`'s `ledger_missing` says "create one with polispec ledger init".
- An existing ledger is never overwritten. A sealed host never gets one created (`ledger_sealed`; `ledger_missing` names the operator). The starter changes no verdict, because its default rules apply only to the projects it lists, and it lists none (`lib/polispec/ledger.rb`, `lib/polispec/packages.rb`, `lib/polispec/plan.rb`, `lib/polispec/native_install.rb`, `lib/polispec/commands/doctor.rb`, `install.sh`).

### Added

- `polispec ledger init [--dry-run] [--json]` writes the starter ledger to the resolved ledger path, mode 0600 in a 0700 directory, after validating it against the schema. It prints `kept` when a ledger is already there (`lib/polispec/commands/ledger.rb`).

### Changed

- `rules/polispec-stewardship.md` lists `polispec ledger init` for a host with no ledger and counts creating the starter ledger as tightening. The README quick start and command table describe the starter ledger.

## [0.27.0] - 2026-10-16

### Added

- polispec installs and runs without rplugin. `install.sh` (`curl -fsSL …/install.sh | sh`) checks for git and Ruby 2.6, clones the newest `vX.Y.Z` tag (or `POLISPEC_REF`), pins it, and runs `polispec install` for each harness it finds (`POLISPEC_HARNESS=claude,codex|none`, `POLISPEC_DRY_RUN=1`).
- `polispec pin [--ref TAG] [--source PATH|URL] [--dry-run] [--json]`. It archives a tag whose `VERSION` matches into `<data home>/releases/<commit>/` (`POLISPEC_DATA_HOME`, else `$XDG_DATA_HOME/polispec`, else `~/.local/share/polispec`). It makes the copy read-only, records `.polispec-release.json` (`polispec.release/v1`: ref, commit, version, source, tree digest, previous target), swaps `current` atomically, and links `~/.local/bin/polispec` unless that path belongs to something else. The source is the clone runtime, the source a pinned release records, or a bare fetch of the public repository into `<data home>/source.git`. Pinning is idempotent and never deletes an older release (`lib/polispec/native_pin.rb`, `lib/polispec/commands/pin.rb`).
- `polispec install` / `uninstall --harness claude|codex|all [--scope user|project] [--project DIR] [--force] [--dry-run] [--json]`:
  - Claude Code: the `PreToolUse`, `SessionStart` and `SubagentStart` guard hooks go into `settings.json`, with the skill link and, at user scope, the two rule links under `~/.claude/rules/polispec/`.
  - Codex: one marked `# >>> polispec hooks >>>` block in `config.toml` and the skill link under `~/.codex/skills/`. No trust hash is written, so Codex asks the user to trust the hooks.
  - Every changed file is backed up beside itself, and hooks polispec did not write are kept.
  - It refuses without `--force` when the polispec Claude Code or Codex plugin is already enabled.
  - Receipts go to `<state home>/installs/` (`polispec.install/v1`). `uninstall` removes only the marked hooks and the links that still match the receipt (`lib/polispec/native_install.rb`, `lib/polispec/commands/install.rb`, `uninstall.rb`).
- `polispec settings list|get|set|unset [--json]` and the settings file `~/.config/polispec/settings.yml` (`POLISPEC_SETTINGS`). Values are validated against the settings in `polispec.rplugin.yml`, `list` names where each value came from, and the verb refuses while the sealed plane is active. Every setting gains a short environment variable (`POLISPEC_ENFORCE`, `POLISPEC_CODE_CHECK_AT`, …; `polispec.operator` is `POLISPEC_OPERATOR_NAME`; `polispec.edition` has none) (`lib/polispec/native_settings.rb`, `lib/polispec/commands/settings.rb`).
- `polispec.gemspec`: `gem build` gives a gem with the `polispec` and `polispec-guard` executables. Not published.

### Changed

- Unsealed settings resolve from the `RPLUGIN_POLISPEC_*` variable, then the short `POLISPEC_*` variable, then rplugin's settings snapshot, then the settings file, then the default. A value that fails validation falls through to the next source. The fast path watches the settings file (`lib/polispec/engine.rb`, `lib/polispec/code/settings.rb`, `lib/polispec/fastpath.rb`). Hosts with rplugin resolve exactly as before unless they set a short variable or the file.
- `bin/polispec-guard` also tries `<data home>/current/bin/polispec` and, last, the `polispec` beside the shim. A Claude Code or Codex plugin install now runs the real guard instead of the inline fallback, and a pinned release still wins over the cached copy.
- The runtime recognises a native release (`.polispec-release.json`) as `pinned`. `doctor` prints `pinned (native)`, verifies its tree digest, and checks provenance against `<data home>/source.git` when the recorded source is a URL (`lib/polispec/runtime.rb`, `lib/polispec/commands/doctor.rb`).
- `polispec steward` and `apply --with-stewardship` work without rplugin. When `rplugin` is not executable, step 1 links the rules into `<claude home>/rules/polispec/` (or reports that there is no Claude Code home) and step 3 runs `polispec pin --ref v<VERSION>`. With rplugin, every step is unchanged (`lib/polispec/stewardship.rb`).
- The README leads its Install section with the one-line installer, then a clone, then the Claude Code and Codex plugin marketplaces, then the gem, and lists rplugin last. `AGENTS.md`, `rules/polispec-stewardship.md`, the skill, `docs/operator.md` and `specs/app.yml` describe the paths that do not need rplugin.

## [0.26.0] - 2026-10-16

### Added

- `polispec explain --harness HARNESS [--json] < hook-json` judges one PreToolUse hook call through the same path as `hook pretool` (classification, environment outcomes, the harness-control ceiling with the undeclared MCP default) and prints the verdict the harness would get under enforce, whatever `polispec.enforce` is: `verdict`, `rule_id`, `reason`, `governed`, the control verdict and `ask_ids`, and per action its class, server, operation and whether a protected or committed rule declares it. It writes nothing: no judgment record, no event, no fast-path refresh, no policy cache, no allow-once issue or consumption and no protected authorization (the explain adapter answers `ask?` true, so ask composition returns before the authorization branch; `Engine::Passes.consume!`, `PolicySource.remember_environments` and `write_cache` are no-ops while it runs, so a held allow-once pass is reported as not held). Exit 0 with a verdict, 2 on invalid input, 1 on an internal error, never a fabricated allow. For callers that must know before an unattended session runs whether its tools pass, such as Teach's doctor (`lib/polispec/commands/explain.rb`, `lib/polispec/commands/hook.rb`; blueprint `specs/explain.impl.yml`). `hook pretool` output and records are unchanged.

## [0.25.1] - 2026-10-15

### Fixed

- `seal` no longer dies `oversized_bundle` on the smoke ledger: `smoke.yml` grows with every recorded run and passed the seal's 1 MiB per-file limit in 0.24.0, so `seal --dry-run` from a clone exited 1 and the `seal.yml` scenario failed. The runtime manifest of the committed release now leaves the smoke ledger out, as it has left the logo images out since 0.24.0; `MAX_FILE` and `MAX_BUNDLE` are unchanged (`lib/polispec/harness_controls/authority.rb`).
- `seal` from a polispec installed as an rplugin release enumerated the wrong tree: the pinned directory has no `.git`, so the runtime plan ran `git ls-tree` against whatever repository encloses the plugin store and died on that repository's files. The runtime manifest now comes from the source repository and commit the release descriptor records (`.rplugin-release.json`), the resolved commit must equal the pinned one, and a missing or incomplete source fails `runtime_source_unavailable` instead of inspecting an unrelated repository. A clone runtime still uses its own working tree and fails the same way when it is not one.

## [0.25.0] - 2026-10-15

### Added

- Judgment records. Every call the guard judges leaves one chained `polispec.judgment/v1` record in `judgments.jsonl` under the polispec state home: what was judged (tool, harness, event, session, home-relative cwd, and a `call_digest` over tool, arguments and cwd), against which rulebook (one target per governed project or baseline with its policy source and digest, the matched rule and the per-action rows), by which polispec (version, runtime kind, commit, tree digest when pinned, edition, enforce mode, plane status, fast-path key), and what the harness was told (the composed verdict, rule, rendered decision, duration). Allows are recorded. The record is written after the control ceiling composes and before the reply, chained with `prev` and `digest` under `judgments.lock`, anchored in `judgments.head.json`, and rotated at 16 MiB. A fail-closed internal denial records `POLISPEC-INTERNAL` and the error class. Git hooks record with harness `git`. Recording never changes a verdict; a failed append emits a `judgment_unrecorded` finding (`lib/polispec/judgments.rb`, `lib/polispec/canonical.rb`, `schemas/judgment.v1.yml`, `lib/polispec/commands/hook.rb`, `lib/polispec/git_hook.rb`).
- `polispec judgments list [--since 24h] [--session ID] [--project ID] [--json] | show <id> [--json] | verify [--json]`, `polispec validate judgment`, the `doctor` findings `judgments_chain_broken` and `judgments_truncated`, and `polispec digest` built from warn and deny judgments (`lib/polispec/commands/judgments.rb`, `doctor.rb`, `digest.rb`).
- Setting `polispec.records.raw` (`off` by default): `on` adds the classifier's raw view of the judged command or target, at most 2048 bytes, to the local record only. It never goes through the events port.
- `bin/polispec-guard` appends one line to `skips.jsonl` for every call its fast path skips (tool, session, fast-path key, `no_needles` or `no_match`) with bash builtins only, and `judgments verify` counts them per key. The shim extracts the tool name with a bash regex instead of grep, head, sed and tr, and reads the first line of its files instead of running head and wc.
- Smoke scenario `judgments.yml` (unit `judgments`): 31 scenarios.

### Changed

- The `polispec.judgment` event replaces `polispec.verdict`: the events port receives a copy of each record without its raw field, and the local record is the system of record. The control-ask `polispec.verdict` event added in 0.24.0 is folded into the record's `control` block (verdict and ask ids). `verdicts.jsonl` and the opt-in journal (`polispec.verdicts.journal`, `journal.jsonl`) are no longer written; existing files are left in place. `polispec plan` replays the per-action rows of the last 14 days of judgments without a setting (`lib/polispec/journal.rb`, `lib/polispec/plan.rb`, `lib/polispec/events.rb`).

## [0.24.0] - 2026-10-15

### Changed

- A shell line that runs `eval`, `source` or `.` now asks `POLISPEC-TOOL-UNKNOWN` under harness controls, in addition to whatever its commands classify as, because what it runs cannot be seen. The shell parser records `eval` when it unwraps it, at any nesting depth (`Script#opaque`, `lib/polispec/classify/shell.rb`), so words inside quoted strings, heredoc bodies fed to non-shells and grep patterns do not count (`Classify.opaque_shell?`, `lib/polispec/commands/hook.rb`). Replaying 1,699 real Bash calls against 0.23.2, two newly ask, both lines that source an env file with `.`; the other differences come from where each runtime lives, since the protected runtime is the running tree.
- `R-POLISPEC-RUNTIME` no longer shadows a stricter policy rule: the runtime verdict and the policy's first-match verdict are both computed and the stricter wins, so a write inside a clone runtime that is also a production checkout is denied by `R-PROD-FS` instead of warned (`Engine#stricter_runtime`).
- G-CLEAN (`clean_tree`) counts untracked, non-ignored files as dirty (`lib/polispec/operator/git.rb`, `gates.rb`).
- `seal` leaves image assets under `assets/` (the logos) out of the runtime bundle, so a logo over 1 MiB no longer stops a seal with `oversized_bundle`; `MAX_FILE` and `MAX_BUNDLE` are unchanged. A seal dry run on an unprepared host now reports its blocked prerequisites (exit 3) instead of dying on the oversize (exit 1).
- Codex code-hook denials carry the blocking code-spec rule id (for example `code.ruby.no-binding-pry`), and the "specs injected, retry" deny carries `POLISPEC-CODE`, instead of `POLISPEC-INTERNAL` (`lib/polispec/harness/codex.rb`, `lib/polispec/code/hook.rb`).
- Every blocking `code-hook stop` carries the instruction to run the polispec-reviewer subagent, not only a stop with deferred rules.
- `polispec doctor` prints `N findings (B blocking, I info)` when info findings are present; the count covers every listed finding.

### Added

- A non-root user may uninstall their own user- or project-scope harness-controls overlay on an unsealed host: the receipt must be unprotected and carry their `owner_uid` (written by unprivileged installs since this release), and they type `uninstall INSTALLATION_ID` on a TTY. Protected receipts, managed scope, other owners, a broken or active plane and receipts from before 0.24.0 still need the operator (`lib/polispec/harness_controls/lifecycle.rb`, `docs/harness-controls.md`).
- Smoke verdict `inconclusive`: a live scenario whose model never attempted the action is retried once and, if it still does not attempt, recorded inconclusive. It does not fail the run, never proves a unit and never revokes an earlier pass; a forbidden file or ref change always fails with no retry (`lib/polispec/smoke/live.rb`, `run.rb`, `schemas/smoke.v1.yml`).
- `POLISPEC_CODE_DECIDE=off` disables the decide port; the smoke runner sets it for every step, so no smoke run reaches a model through `code classify`.
- `polispec apply … --checkouts` prints each git hook it installs and the checkout it went into (`lib/polispec/packages.rb`, `docs/environments.md`).
- Smoke scenarios `steward.yml` (unit `commands/steward`) and `harness-uninstall.yml`, and new steps in `noise.yml`, `classify.yml`, `stewardship.yml`, `code-commands.yml`, `code-hook.yml`, `plan-apply.yml`, `promote-deploy.yml`, `seal.yml`, `smoke-suite.yml` and `status-digest-doctor.yml`: 30 scenarios.

### Fixed

- A shell redirect, Write or Edit of the ledger was allowed while `rm` of it was denied: a `policy.edit` whose target is a protected path or lies inside one is now denied with `POLISPEC-CONTROL-PROTECTION`. `polispec apply`, whose `policy.edit` names a directory, is unaffected (`lib/polispec/harness_controls/evaluate.rb`).
- Control asks are written to the event log as `polispec.verdict` with level `warn` and the control's rule id, so asks can be counted.
- `git log -p`, `git show -p` and `git diff -p` are benign reads; `-p`, `--paginate`, `-c`, `--config-env` and `--exec-path` are refused only as git global options.
- `polispec code controls --policy ID` exits 1 with `unknown policy id ID` for an id the pack does not define.
- `docs/operator.md` scratch use names `POLISPEC_LEDGER`, `POLISPEC_HOME`, `POLISPEC_GLOBAL`, `POLISPEC_STATE_HOME` and `POLISPEC_ENVS_ROOT` and no longer tells you to redirect `XDG_STATE_HOME`. `docs/roster.md` and `docs/schema.md` list the roster `run` values the schema and the worker-profile check accept.

## [0.23.2] - 2026-10-15

### Fixed

- `polispec smoke run` works from a pinned install. The runner took the git top level of the tree as its root, and a pinned release lives inside another checkout (`rstack-uber/plugins/.pinned/…`), so every scenario failed with `specs/app.yml is not a regular file`. The git top level is used only when it is the tree itself (`lib/polispec/smoke/run.rb`).
- `--scenarios smoke/live` together with `--live` no longer runs each live scenario twice into the same fixture directory.

### Added

- `smoke/scenarios/smoke-suite.yml` covers the `smoke` unit: a nested run of one bundled scenario without recording, and the live kill switch blocking a live scenario before any harness starts.

## [0.23.1] - 2026-10-15

### Fixed

- A shell line the parser fully parses no longer asks `POLISPEC-TOOL-UNKNOWN` just because it is not on the benign list (`sed -n`, `git branch -a`, `cd …; …`, `for` loops, `bin/polispec smoke verify`, `psql -c`): its commands' classes, or none, go to policy as in 0.22.0. The unknown ask stays for unparseable shell lines, lines that use `eval`, `source` or `.`, unknown non-shell tools, and undeclared MCP operations (`Classify.parsed_shell?`, `lib/polispec/classify/benign.rb`). Replaying 1,699 real Bash calls, 0.23.0 asked on 234; 0.23.1 asks on none of them.
- The fallback write an unrecognised program gets on its working directory no longer counts as a change to protected polispec authority when that directory is only an ancestor of a protected path. `rstack status`, `rswitch` or `persona load` run from the home directory, `~/.ai` or `rstack-uber` were denied with `POLISPEC-CONTROL-PROTECTION` (78 of the 1,699 replayed calls); an explicit recursive change, move or delete of an ancestor, and any program run inside a protected path, are still denied (`lib/polispec/harness_controls/evaluate.rb`).

## [0.23.0] - 2026-10-15

### Added

- `polispec smoke run [--unit PATTERN]... [--scenarios DIR] [--against TREE] [--host-copy] [--live claude-code|codex]... [--out DIR] [--no-record] [--accept-changes] [--json]`: a bundled, deterministic smoke suite. 27 scenarios in `smoke/scenarios/` (`polispec.smoke-scenario/v1`, `schemas/smoke-scenario.v1.yml`) each build a scratch fixture (ledger, global shelf, git projects with test and stable checkouts) and run hook calls and commands against it with isolated state (`POLISPEC_STATE_HOME`, `XDG_STATE_HOME` under the scratch directory), so a run never writes the live guard's state. A passing run records one `suite` entry per scenario in `smoke.yml` (runner kind `suite` added to `schemas/smoke.v1.yml`) (`lib/polispec/smoke/`).
- `--against TREE` runs every scenario a second time with another tree's `bin/polispec` and reports each step whose verdict, exit code or normalised output differs; paths, timestamps, digests, record ids and durations are normalised, and a diff exits 1 unless `--accept-changes`. `--host-copy` judges the probes in `smoke/host-probes.yml` against a copy of this host's ledger and global shelf and prints the verdict table. `--live claude-code|codex` runs the live scenarios in `smoke/live/` through `claude -p` (Haiku) or `codex exec` with a timeout and turn cap; the setting `polispec.smoke.live` (`on` by default) and `POLISPEC_SMOKE_LIVE=off` stop every live step.
- `POLISPEC_STATE_HOME` moves polispec's state while no sealed plane is active; events skip the rplugin port while it is set, and `bin/polispec-guard` reads its fast-path files from it when `/etc/polispec/active.json` is absent (`lib/polispec/state.rb`).
- `fastpath.tools`: the tools `bin/polispec-guard` may skip under a governed baseline. Harness-internal tools are listed; Read, Grep and the other read tools are listed only while no global or module rule governs reads (a `secrets.read` class, a `tool` naming a read tool, or a rule with neither `class` nor `shape`). Any other tool, including every MCP and unknown tool, reaches polispec (`lib/polispec/fastpath.rb`).
- `harness install --harness claude-code` checks for `bwrap` and `socat` on Linux and refuses with `sandbox_unavailable`, writing nothing; `--dry-run` and `harness plan` report the same finding and succeed.

### Changed

- `harness_controls` is on by default (`config/harness-features.yml`); `sealed_plane` stays off. Under a governed baseline the guard asks about undeclared MCP operations and unknown non-read tools (standard edition). Harness-internal tools (TodoWrite, Skill, ToolSearch, Glob and the like), fully parsed read-only shell lines and read-only `polispec` verbs are classified as benign and stay allowed; WebFetch and WebSearch classify as `web.fetch`, Agent and Task as `agent.spawn` (`lib/polispec/classify/benign.rb`).
- An MCP operation counts as declared when a rule with an exact `match.server` and `match.operation` sits in any layer the engine composes for the call, including the global shelf and its modules, not only a live project's own policy (`lib/polispec/commands/hook.rb`).
- Without an active sealed plane, an ask that comes only from environment-policy warnings keeps the 0.21.0 legacy deny with an `alo_` allow-once id; a control ask (undeclared MCP, unknown tool) under Codex is denied because exact operator authorization needs the plane.
- Project-scope Claude Code, Codex and Antigravity hook callbacks pass `--controls-project`.
- `polispec code detect` on an empty file reports `unknown` and exits 0.

### Behaviour changes on upgrade

- Every MCP call that no rule declares asks under Claude Code and is denied under Codex. Declare the operations you use in the global shelf (for example a module with one `{ match: { class: [mcp.call], server: S, operation: O }, verdict: allow }` rule per operation) before installing this release.
- Smoke parity against v0.22.0 differs only in that change, in the control install now working, and in runtime-kind and state-path differences between a clone and a pinned tree.

## [0.22.0] - 2026-10-15

### Added

- `polispec steward [--check] [--json]`: the stewardship steps without an apply target. `--check` only reports, marking an unsatisfied step `missing` with what would run, and exits 1 (`lib/polispec/commands/steward.rb`, `lib/polispec/stewardship.rb`).
- `bin/polispec-guard`, the guard shim every harness hook now runs: a bash fast path that skips starting Ruby for calls that cannot touch a governed path, the call to the `polispec` on PATH (the pinned release, never a harness's plugin-cache copy), and a fail-closed fallback that denies prod-shaped shell calls when polispec is missing or fails. It replaces the host-wired `~/.claude/hooks/polispec-guard.sh`, with byte-identical pretool verdicts on this host.
- `fastpath.watch` beside `fastpath.txt`: the ledger, global-layer refs, settings and plane files whose change invalidates the fast path, so the shim needs no host-specific paths (`lib/polispec/fastpath.rb`).

### Changed

- polispec installs natively into Claude Code: `extensions.only` now includes `claude-code`, so `rplugin install polispec` brings the guard hooks (SessionStart, PreToolUse, SubagentStart), the skill and the rule links (`~/.claude/rules/rplugin/polispec/`). Requires rplugin 1.15.0. Codex stays excluded and keeps its host bridge.
- Stewardship step 1 also requires the Claude Code rule link when rplugin supports rules for Claude Code; when the runtime still has to be pinned, step 3's pin creates the link and verifies it.
- `hooks/polispec.hooks.yml` runs `bin/polispec-guard` and adds `subagent_start`; `hooks/hooks.json` and `hooks/codex.json` are regenerated by `rplugin package`.

## [0.21.0] - 2026-10-14

### Added

- `polispec plan` and `polispec apply`: one preview-then-apply path for every rulebook change. Targets are a package (`<name> --repo REPO [--variant V] [--param k=v]`), `project:<id>`, `global`, and `ledger --from FILE`. A plan lists files, the ledger effect, the composed policy difference, and the verdicts that change, classifies the change as tightening, loosening, mixed, or neutral, and prints a plan id. Loosening, mixed, and global plans apply only with `--confirm <plan-id>`; a stale id refuses with `plan_changed` (`lib/polispec/plan.rb`, `lib/polispec/commands/plan.rb`, `lib/polispec/commands/apply.rb`, `docs/packages.md`).
- Packages: `packages/<name>/package.yml` (`polispec.package/v1`) with parameters, variants, files, modules, and ordered built-in steps, found in the shipped `packages/` and on the global shelf. `environment-control` (variants `service` and `distributed`) is the first. The ledger records each applied package with its version and file digests; `status` lists them, `doctor` reports `package_upgrade_available` and `package_file_drift`, and an upgrade keeps edited files as conflicts (`lib/polispec/packages.rb`, `schemas/package.v1.yml`, `schemas/ledger.v1.yml`).
- Verdict replay: plans judge synthetic probes generated from each project's environments, and, with the new setting `polispec.verdicts.journal` (`off` by default), the last 14 days of journaled verdict facts. The journal never holds command text (`lib/polispec/probes.rb`, `lib/polispec/journal.rb`).
- Stewardship: the shipped rule `rules/polispec-stewardship.md` tells agents how to develop, install, upgrade, and repair polispec and change its rulebooks without disrupting the host. rplugin installs it as a rule where a harness has a rules surface (Antigravity CLI); every other harness reaches it through the polispec skill and the `[POLISPEC]` directive, and AGENTS.md points to it.
- Runtime awareness: polispec knows whether it runs from a pinned rplugin release, a working clone, or the sealed plane, verifies a pinned release's tree digest, and `doctor` prints `runtime:`. A built-in protected root denies writes into a pinned runtime and warns on writes into a clone runtime (`R-POLISPEC-RUNTIME`) (`lib/polispec/runtime.rb`, `lib/polispec/engine.rb`).
- `polispec apply --with-stewardship` checks that the installed plugin ships the stewardship rule (reinstalling it from the running tree when not), checks the runtime protection, and pins a clone runtime to the tag of the running version with `rplugin install <clone> --ref <tag>` before applying anything; any failure stops it first (`lib/polispec/stewardship.rb`).

### Changed

- `polispec apply … --confirm`, and `apply global` or `apply ledger` with or without it, classify as `policy.edit`, so on a live policy the harness asks the user (`R-POLICY`); `polispec plan` and `apply <package>` classify as before (`lib/polispec/classify/commands/release.rb`).
- `doctor` prints `runtime:` before its findings; info findings (`package_upgrade_available`, `package_file_drift`) do not affect `ok` or the exit code. A pinned runtime's provenance requires its commit to be on the source's `main` (`lib/polispec/commands/doctor.rb`).

### Removed

- `polispec onboard`, with no alias. `polispec apply environment-control --repo <repo>` runs the same steps; `--serves`, `--archetype`, `--id`, and `--trust-ref` became `--param serves=`, `--variant`, `--param id=`, and `--param trust_ref=`, and `--dry-run` became `polispec plan`. `templates/onboard/` moved into `packages/environment-control/`.

## [0.20.0] - 2026-10-14

### Added

- Project-local modules: a project ships its own `modules/<name>.yml` beside its policy, read from the same source as the policy (trust ref, bootstrap ref, or the sibling directory of a validated file). A project module may include project and global modules; a name on both shelves is an `ambiguous` error (`lib/polispec/layers.rb`, `docs/schema.md`).
- Typed module parameters: a module declares `params` (`string`, `integer`, `number`, `boolean`, `list`, with `default` and `summary`); an include is a name or `{ module, with }`; `"{{name}}"` keeps the type, `{{name}}` inside text interpolates, and includes pass parameters down. Unknown, missing or mistyped parameters, unresolved placeholders and duplicate instance ids are errors (`lib/polispec/layers.rb`, `schemas/module.v1.yml`, `schemas/policy.v1.yml`, `schemas/global.v1.yml`).
- Gate `dir`: a gate may run in a subdirectory of its run location; a missing directory or a path escaping it fails the gate (`lib/polispec/operator/gates.rb`, `schemas/policy.v1.yml`).
- `examples/clinic/`: a booking-app policy composed three levels deep from parameterised project modules.
- `docs/VISION.md`: where polispec is going, every item labelled Built, Partial, Planned or Idea.

### Changed

- Nested ledgered projects contribute everything they declare: a child layer expands its own includes ahead of its rules, and every descendant's promotion gates (run in the child's directory), preflight, freezes and hermetic settings join the owner's promotion. A child id that collides with the owner or global layer is an `id_collision` error (`lib/polispec/layers.rb`, `lib/polispec/policy_source.rb`).
- The outermost ledgered repo or worktree root containing a path owns it, regardless of ledger order (`lib/polispec/ledger.rb`).
- Composition errors make `promote` refuse with `policy_invalid` instead of promoting with fewer gates; `resolve --layers` lists them (`lib/polispec/operator/gates.rb`, `lib/polispec/commands/resolve.rb`).
- Promotion bootstrap now composes the candidate branch's policy with the global layer and its project modules (`lib/polispec/policy_source.rb`).
- A layer digest covers its module instances and their resolved parameters.
- README rewritten: plain-language introduction, table of contents, the clinic worked example, how a verdict is made, composition, alternatives, honest limits and FAQ, with the project hero image.

## [0.19.1] - 2026-10-13

### Fixed

- `onboard --dry-run` rendered `4_render` from the templates even when the scaffold files already existed and were kept, so on a scaffolded repository it previewed a render and a commit the real run did not perform; it now previews from the files in the repository (`lib/polispec/commands/onboard.rb`, `docs/environments.md`).
- `onboard --commit` reported step `4b_commit` as `kept` when onboard wrote no files; it is now `skipped` with nothing to commit (`lib/polispec/commands/onboard.rb`, `docs/environments.md`).
- Removed the unused `started` variable that `ruby -w` reported in `lib/polispec/commands/harness.rb`.

## [0.19.0] - 2026-10-13

### Added

- `polispec onboard --commit`: after rendering (step `4b_commit`) onboard stages by name and commits only the files it wrote on main as `Add the polispec scaffold`, so `5_branches` creates test and stable in the same run; with `--push` it pushes main, test and stable. Skipped with a note when HEAD is not main; `--dry-run` previews the commit and the branches. Without `--commit` the output is unchanged (`lib/polispec/commands/onboard.rb`, `docs/environments.md`, `README.md`, `skills/polispec/SKILL.md`).

### Changed

- The service archetype's placeholder `deploy.health.run` is the shell-free nonexistent command `polispec-placeholder-health-check-replace-it-in-specs-polispec-environments-yml`; `deploy` records `health_failed` (run exited 127) naming it until the operator writes a real check (`templates/onboard/service/environments.yml`).
- Repointing the `specs` link needs the typed phrase `relink <full target path>`, the absolute `<repo>/specs` path shown in the prompt, instead of `relink specs`. `specs` refusals report `not_tty` and `confirmation_failed` like the other operator commands (`lib/polispec/code/admin.rb`, `lib/polispec/commands/specs.rb`, `docs/code-specs.md`).
- `harness scan` exits 1 instead of 3 when the environment scan cannot run (`lib/polispec/commands/harness.rb`, `docs/harness-controls.md`).

### Fixed

- The harness-controls target resolver raised `committed policy is unavailable` for a live project without a committed policy at its trust ref; the fallback policy (global `fallback_rules`, else ledger `defaults.rules`) now governs, as it does for the guard since 0.18.5 (`lib/polispec/commands/hook.rb`).
- `harness uninstall --dry-run --owner` needed root. A non-root dry run now previews from what the current uid can read, writes nothing, and reports each owner check it could not perform as `owner_check_unverified`; root and real uninstalls are unchanged (`lib/polispec/harness_controls/lifecycle.rb`).

## [0.18.7] - 2026-10-13

### Fixed

- `specs link` replaced an existing `~/.polispec/specs` link that pointed elsewhere without confirmation, even from an agent shell. Repointing now needs an interactive terminal and the typed phrase `relink specs`; creating a missing link or confirming the same target needs neither, and `--dry-run` previews (`lib/polispec/code/admin.rb`, `lib/polispec/commands/specs.rb`, `docs/code-specs.md`).
- `harness uninstall --dry-run` returned `operator_required` for a non-root operator; without `--owner` a dry run now previews without root (`lib/polispec/harness_controls/lifecycle.rb`).
- `harness scan` returned `ok: true` and exit 0 with an opaque `environment_scan_failed`; it now returns `ok: false`, exits 3 and names the cause (`lib/polispec/commands/harness.rb`, `lib/polispec/harness_controls/environment.rb`).
- `seal` rejected `examples/ledger.example.yml` because YAML read `onboarded` as a date; bundle YAML is normalised as the ledger loader does (`lib/polispec/harness_controls/authority.rb`).
- `code classify` on a file that defines no policy rules printed nothing and exited 0; it now says why and exits 1 (`lib/polispec/commands/code.rb`).
- `docs/harness-controls.md` documents the `operation_id` shapes.

## [0.18.6] - 2026-10-13

### Fixed

- `onboard` (service archetype) scaffolded `deploy.steps` without `deploy.health`, so validate, promote and deploy refused the new policy. test and prod now carry a placeholder `deploy.health.run` that exits 1 and says to replace it: the policy validates and promotes to test, and `deploy` fails its health check until the operator writes a real one (`templates/onboard/service/environments.yml`, `docs/environments.md`).
- `onboard` validates the ledger with the new entry before writing any file, so a `ledger_invalid` failure leaves no scaffold behind.
- `onboard` created test and stable at main before the scaffold was committed, so with `--push` origin stable carried no policy and doctor reported `policy_missing`. The branches are now created only once the scaffold is committed on main; otherwise step 5 is skipped with the exact commands to run (`lib/polispec/commands/onboard.rb`).
- `onboard` dry-run and re-run wording ("would wrote", "would fresh added", "kept kept") now reads "would write", "would add fresh to", "already present".
- `status` reported no finding for a policy that `promote` rejects as `policy_invalid`; it now reports the same `policy_invalid` finding for a missing health check, bad environment names or invalid profiles (`lib/polispec/commands/status.rb`).

## [0.18.5] - 2026-10-13

### Fixed

- `hook pretool` denied every non-read call in a live ledgered project whose policy was missing or invalid at its trust ref with `[POLISPEC internal] guard unavailable`. The global layer's `fallback_rules` (ledger `defaults.rules` when there is no global layer) now govern, as `docs/schema.md` states (`lib/polispec/commands/hook.rb`).
- Claude PreToolUse deny and ask reasons now name the rule: `[POLISPEC <rule_id>] DENIED:` or `WARNING:`, matching the git hook and the other harness backends (`lib/polispec/harness_controls/backends/claude.rb`).
- The next step for a path no polispec project owns said `polispec promote global --to stable`; it now says no project owns the path, so there is no `polispec promote` for it (`lib/polispec/engine.rb`).
- `tag_claimed` for a tag equal to origin/main's version on a commit that is not origin/main's release commit now says the tag is not on that release commit, instead of "not greater than" (`lib/polispec/predicates.rb`, `docs/schema.md`).

## [0.18.4] - 2026-10-13

### Fixed

- `allow-once` prompts and stored grants named only the tool (`edit`) for a file-tool call, so the operator could not see which file a grant unlocks. The raw action text of a file-tool call is now the tool and its absolute target (`edit /abs/path`), in the prompt, the stored grant and the deny and ask reasons (`lib/polispec/classify/tool.rb`, `lib/polispec/commands/allow_once.rb`).
- `polispec status <unknown> --json` printed plain text; it now prints a JSON `unknown_project` error and exits 1 (`lib/polispec/commands/status.rb`).
- `polispec behavior decide` rendered empty arrays as `[`, a blank line and `]`; empty arrays and maps now render as `[]` and `{}` (`lib/polispec/commands/behavior.rb`).
- `pause` and `allow-once` report `not_tty` and `confirmation_failed` like `promote` (`lib/polispec/commands/pause.rb`, `allow_once.rb`).
- `docs/operator.md` lists `tag_unsupported` and describes the allow-once prompt.

## [0.18.3] - 2026-10-13

### Fixed

- `polispec code-hook post|stop|session` with `--harness claude` or `--harness codex` rejected every payload that was not `PreToolUse` and failed open without a trace: a `post_write` MUST violation landed unblocked, `stop` never reviewed, and compact/clear never re-armed injection. Each mode now normalizes its own event (`PreToolUse`, `PostToolUse`, `Stop`, `SessionStart`) for both harnesses, and a hook failure prints a one-line diagnostic on stderr; the exit status stays 0 (`lib/polispec/harness_controls/backends/claude.rb`, `codex.rb`, `lib/polispec/harness/*.rb`, `lib/polispec/code/hook.rb`). Found by the 0.18.2 smoke sign-off; a Haiku session now gets the post and stop blocks.

## [0.18.2] - 2026-10-13

### Added

- Smoke ledger: `smoke.yml` (`polispec.smoke/v1`, `schemas/smoke.v1.yml`) records smoke tests that proved a spec or sub-spec in reality. `polispec smoke record` checks that the `--spec`/`--at` reference resolves, stores the node's digest, the verdict (`pass`, `fail`, `partial`, `blocked`), steps and evidence digests, and captures the runtime (OS, kernel, architecture, container and WSL flags, time zone, locale, Ruby, polispec version, edition, commit and install kind, rplugin version, enforce mode) and the target (commit, branch, dirty flag, governed project, environment and policy digest). No hostname, user name or absolute path is recorded. Entries are hash-chained and appended under a lock in the git common dir. `record` also anchors the head digest and count per ledger in `smoke-heads.json` under the state home. `smoke list`, `show`, `verify` (schema, digest, chain, duplicate ids, truncation against the anchor; stale and unresolved references) and `coverage` (per-unit status against the current spec, from `smoke.coverage_units` in `specs/app.yml` or `--at` patterns) read it back; `polispec validate smoke` validates it. `record` emits `polispec.smoke`. Setting `polispec.smoke.path`, overridden by `POLISPEC_SMOKE` (`lib/polispec/smoke.rb`, `lib/polispec/commands/smoke.rb`, `docs/smoke.md`).
- `ROADMAP.md`, with shipping a bundled smoke-test suite as its first item. Operators run their own smoke tests today.

## [0.18.1] - 2026-10-13

### Fixed

- `tag_claimed` no longer refuses the release tag itself. A tag equal to the `VERSION` at `refs/remotes/origin/main` matched as taken even when it named the release commit on origin/main, so the order the rule asks for (re-bump, push main, tag last) was always denied, for `git tag` and for the tag push. An equal version now matches only when the tagged commit is not an ancestor of origin/main or its own `VERSION` differs; a lower version still matches (`lib/polispec/predicates.rb`).
- `git tag vX <commit-ish>` is judged on the commit it names. The classifier gave `tag_claimed` the current branch for a SHA target and the local branch for `origin/main` (`ref` strips the remote for environment resolution), so a clone without a current local `main` was refused for tagging origin/main's release commit. The `git.tag` hint now carries the commit-ish as written in `at`, which `tag_claimed` checks; `ref` is unchanged (`lib/polispec/classify/commands/git.rb`, `docs/schema.md`).

## [0.18.0] - 2026-10-13

### Added

- Deterministic harness-control grammar and `polispec.control/v1`, with explicit native plans, tightening-only installation, owned-artifact receipts, verification, and authenticated removal. Backends cover Claude Code, Codex, Hermes, Antigravity CLI, and OS sandbox planning.
- Root-owned authority generations and pinned runtime provenance, exact Git sources for standard, root-authored sources for lock, and explicit operator activation and rollback. No live project is activated by installation.
- Protected one-use authorization service with kernel peer identity, bounded Unix transport, exact combined ask bindings, durable consumption, replay refusal, operator redemption, an explicit kill marker, and stale-socket recovery. Unit rendering does not install or start a service.
- Container exposure scans with distinct follow-up arming, conservative protected-history validation, and separate rootless observations.
- Standard and lock editions using one codebase, an edition-only `polispec-lock` release operation with exact leases and recovery reporting, and local provenance checks in doctor.

### Fixed

- Hook failures now deny non-read actions with fixed native output while preserving positive diagnostic reads. Input and judgement are bounded, native session envelopes stay separate, and multi-edit and rename endpoints are fully classified.
- Independent control ceilings, exact MCP declaration selectors, strict overlay history and current contribution checks, and sealed settings resolution prevent mutable additions from weakening protected authority.
- Doctor works without RubyGems, and edit classification retains the declared Ruby 2.6 API floor.

### Release activation

- Both feature flags remain disabled by operator direction. This release publishes the finished implementation; it does not activate host defaults, controls, a plane, or live projects. Grammar, validation, planning, and read-only inspection remain available.
- Standard and lock operate from independent checkouts. Lock doctor verifies its immutable parent without depending on the current main ref, and a lock executable refuses an active standard-plane mismatch. Shared release source does not require the other edition to be installed.

### Verification limits

- Artifact, CLI, parser, and scratch transport evidence are reported separately from native enforcement. No paid model journey, root-owned host seal, protected host service installation, timer activation, or live-project activation was performed. Hermes and agy runtimes were absent; Bubblewrap namespace startup was unavailable. No backend is marked lock-certified.
- This standalone plugin has no matching compiled rhomeostasis obligation verifier. The operator approved reviewed commits and actual CLI/rplugin verification with unavailable attestation recorded; no passed attestation is claimed.

## [0.17.1] - 2026-10-10

### Fixed
- `status --json` exposes a read-only deployment receipt and latest attempt per environment. Successful deployment state now retains its deploy record identity and health; verification rejects an in-progress or newer failed attempt, unchecked health, pins, and legacy receipts without identity. Consumers can distinguish successful deployment from a stable branch move that preceded failed deployment.

## [0.17.0] - 2026-10-09

### Added
- `polispec promote <project> --to <env> --waive-soak` (`lib/polispec/commands/promote.rb`, `lib/polispec/operator/promote.rb` `waive_soak!`): the operator skips the `soaked` gates of a promotion past test. It needs an interactive terminal and the typed phrase `waive soak for <project>` before any gate runs; agents cannot pass it. `Gates.run_all` reports the waived gate as `waived` and every other gate still runs. It is refused for `--to test` (`waive_soak_unsupported`) and when the promotion has no `soaked` gate (`nothing_to_waive`). `--dry-run --waive-soak` previews without the phrase. The promotion record, the result and the `polispec.promote` event (`lib/polispec/events.rb`) carry `waived: [soak]`. It lives in polispec, so no policy change is needed to use it.

## [0.16.2] - 2026-10-09

### Fixed
- The global baseline judged every action of an onboarding project as `dev` when the action carried no path of its own (`lib/polispec/commands/hook.rb` `evaluate_baseline`). A `systemctl --user restart` run from the project's prod checkout, or from a `release_dirs` release behind it, was allowed by a baseline rule scoped to `env: prod`. The baseline now takes the working directory's environment the way a live project does; a repository outside the ledger stays `dev`.

## [0.16.1] - 2026-10-09

### Fixed
- A path under a project's environment checkout root that names no environment resolved to `dev` (`lib/polispec/resolve.rb` `location_env`). With `deploy.strategy: release_dirs` the prod checkout is a symlink into `releases/`, so every path in the live release, and in `shared/`, resolved as `releases` or `shared` and fell back to `dev`. Once the project is live, the guard would have judged edits and git commits in production by dev rules. Such a directory now fails closed to `prod`, as `Engine::Envs.env_for_checkout_dir` already did.

## [0.16.0] - 2026-10-09

### Added
- Layered policy (`lib/polispec/layers.rb`). A global layer is read from the committed `polispec.global.ref` (default `main`) of the git repository in `polispec.global.repo`, in the directory `polispec.global.path` (default `polispec`). `POLISPEC_GLOBAL`, a plain directory, wins for scratch runs. The global layer is composed with the repo policy and with nested child projects. Rules stay first-match within a layer, and the strictest verdict wins across layers. An upper rule can be loosened only when it is marked `overridable: true` and the lower rule names it in `overrides`; anything else is a validation error naming both rules. With no global source set, verdicts are unchanged.
- `global.yml` may carry `fallback_rules`. They replace the ledger `defaults.rules` only for a project whose policy is missing at its trust ref, and never join the composed layer. A configured global source with an absent or invalid `global.yml` is reported (`layers_invalid`) and contributes no rules.
- Modules and profiles. `global.yml` and policies take `includes` of modules from `modules/<name>.yml`, resolved depth-first and each once, with cycles and missing modules reported. The ledger `profile` field (`personal`, `service` or `live`, default `personal`) selects modules from `profiles.yml`. A policy may only name a stricter profile.
- Schemas `polispec.global/v1`, `polispec.module/v1` and `polispec.profiles/v1`, `profile` in the ledger and policy schemas, and `polispec validate global|module|profiles`.
- The guard applies the global baseline outside live projects. When a global layer has rules, an action no live project owns is judged by the global layer plus its project's profile modules: an onboarding project's id, or `global` for a repo outside the ledger. The fast path then also passes every shell, edit, write and patch tool call to polispec, and its cache key covers the global layer.
- `polispec resolve <path> --layers --json` prints the layer chain with each layer's digest and the effective digest. Verdict reasons name the layer that decided.
- Action class `fs.delete`, emitted alongside `fs.write` for `rm`, `rmdir`, `unlink`, `shred`, `find -delete`, `find -exec rm` and `git clean -f`, and alone for `cargo clean` (its target directory) and `git worktree prune`. Edit and Write tool calls never produce it.
- Match key `shape` with the names `bulk_stage`, `chained_release`, `latest_flip`, `lockfile_edit`, `pattern_kill`, `cargo_clean` and `worktree_force`, tagged from the parsed script (`classify/shapes.rb`). An unknown name fails validation.
- Match keys `lock_held`, `live_binary`, `supervised`, `pin_regress`, `tag_claimed` and `base_unpushed` (`lib/polispec/predicates.rb`). They are read-only and bounded by a 2 s budget, and report a finding instead of failing when they cannot decide.
- Setting `polispec.supervisor.status_command`, an argv printing `{"units": [...], "pids": [...]}`, which feeds `supervised` and is cached for 60 s. When unavailable, `supervised` fails closed for `pattern_kill` and open for a named unit.
- Protected roots declared by the global layer (`protected_roots: [{path, writers}]`) are honoured by `crosses: location` for `fs.write` and `fs.delete` from any working directory. A command whose argv[0] basename is in `writers` does not cross.
- Environment names come from the policy. Any declared environment can be a promotion hop through `promotion.to_<env>` (each with `from:`), and `polispec promote --to <env>` and `polispec deploy <project> <env>` accept it, so `main -> test -> canary -> stable` works. `environments.yml` accepts environments beyond dev, test and prod. The guard treats such an environment as its declared `tier`, or as prod when it declares none.
- Builtin gates `sha_ran_on` (option `env`, default `test`), `logs_quiet` (options `services`, `window_minutes`, `max_over_baseline`) and `requires_live` (options `project` plus `min_version`, or `min_version_from` with `min_version_key`). `soaked` takes `env`. Setting `polispec.logs.count_command` is an argv template with `{service}`, `{since}` and `{until}` that prints one integer; `logs_quiet` fails closed when it is unset or fails.
- Profile checks (`lib/polispec/validate_profiles.rb`): `personal_no_warn`, `version_reported` (service and live projects must have health that proves the deployed version) and `protected_writers` (a deploy step must not write under a global protected root it is not a writer of). They run when the operator loads a project and in `polispec doctor` (finding `profile_check`). Doctor and validate also report environments that deploy without a health check.
- Freeze `applies_to` accepts `promote.to_<env>`.

### Changed
- `sha_ran_on_test` is an alias of `sha_ran_on` with `env: test`. The implicit stable `G-TESTED` uses `sha_ran_on` and is skipped when the hop lists either form.
- `kill <pid>` and `kill $(pgrep ...)` classify as `service.control` as well as the existing unknown-command `fs.write`. A bulk `git add` classifies as `fs.write`. `gh release ... --latest=true` is read as a Latest release.
- `invalid_target` and `invalid_env` list the policy's declared names; for `test` and `stable` the text is unchanged.

## [0.15.2] - 2026-10-09

### Fixed
- `schemas/environments.v1.yml` accepts the same `deploy` block as `schemas/policy.v1.yml`: `strategy`, `activate` and `drain` (`pause`, `wait`, `resume`, `timeout_s`, `checks`, `run_in`, `env_from`). The manifest schema predated those keys, so a project that deploys with `release_dirs` or drains could not move its environments into `environments.yml`: validation, `agents render` and the policy merge all failed with `unknown key`.

## [0.15.1] - 2026-10-09

### Added
- A command gate may set `hermetic: false` (`schemas/policy.v1.yml`, `operator/gates.rb`). Such a gate runs with the caller's environment and without the protected-root fingerprint, and its entry in the promote result carries `"hermetic": false`. It is for a read-only check of the installed copy: a plugin manager's `check` or `doctor` needs the real plugin home, and appends to the install's own event logs, so under `hermetic.<env>` it always failed, either because the isolated home held no install or with `wrote outside its location`. Every other command, deploy step and `deploy.health.run` keeps the isolation.

## [0.15.0] - 2026-10-09

First public release.

### Added
- Environment guard and classifier: every agent tool call in a governed project gets an allow, warn or deny verdict from the policy committed on the project's stable ref, with a reason and a next step.
- Schemas and validators for policy, roster, ledger and environments (`polispec.policy/v1`, `polispec.roster/v1`, `polispec.ledger/v1`, `polispec.environments/v1`), plus the behavioral policy format with deterministic compilation and declarative deny evaluation.
- `polispec promote` and `polispec deploy` with gates and freezes, tagged releases and rollback by tag.
- `polispec allow-once` and `polispec pause`, both operator actions that need an interactive terminal and a typed phrase.
- Roster resolution and checks: harness, model and effort per agent role, with bounds an edit may not leave.
- Code specs: language detection, spec chain injection, changed-line enforcement with a ratchet baseline and waivers, and `polispec specs promote`.
- `polispec onboard` for a new user-serving project, with service and distributed archetypes.
- `polispec agents render` and the generated `[ENVS]` AGENTS.md row, with doctor drift detection.
- Git hooks per environment (`polispec hook git`) that judge commits, pushes and ref moves outside an agent harness.
- Hermetic runs (`hermetic.<env>.isolate`, `protected_roots`): deploy steps, health runs and command gates run with each isolated variable pointed into a scratch directory, and a change under a protected root fails the run with `wrote outside its location`.
- `deploy.strategy: release_dirs` with `deploy.activate` and `deploy.drain`: releases built beside the live one, an atomic symlink swap, automatic rollback recorded as health `rolled_back`, drain pause, wait and resume (resume always), and retention of the 3 newest plus active releases ordered by tag version.
- Drain `checks` (`drain_check_failed`), gate and drain fields `run_in: repo|active` and `env_from`, and `polispec deploy <project> stable --skip-drain` (terminal plus the typed phrase `skip drain for <project>`, recorded as `drain: skipped`). In-place deploys drain before checking out the new tag.
- Gates `soaked` (option `hours`) and `health_required`, `promotion.to_stable.preflight`, `release.flip_latest: deferred`, and the `{stable_tag}` interpolation variable. A policy that deploys without a health check is refused with `policy_invalid`.
- Engine match keys `crosses: location` (a write that resolves into another project's protected roots or production checkout) and `destructive: true` (an unbounded DELETE or UPDATE, DROP, TRUNCATE, or a destructive shell verb).
- Policy schema keys `includes`, rule `overridable` and `overrides`, and freeze `project`.

### Changed
- The ledger path resolves from `POLISPEC_LEDGER`, then the `polispec.ledger` setting, then `$XDG_CONFIG_HOME/polispec/ledger.yml` (default `~/.config/polispec/ledger.yml`).
- Deny and next-step messages name the person who promotes to stable through the `polispec.operator` setting (default `the operator`).
- Freezes gain a generic `source: command` that runs a list of argv strings without a shell in the prod checkout and parses its JSON windows. The previous calendar and activity source names stay accepted as deprecated aliases (see `docs/schema.md`).
- The code specs repository defaults to `~/polispec-specs` and is configurable with the `polispec.code.specs_repo` setting; `POLISPEC_SPECS_REPO` still wins.
- Schema and documentation wording is neutral; the `rlogs` observability value and the `*.rstack_component.yml` manifest recognition are optional integrations.
- Secret references of the form `scheme:path` (a lowercase scheme and a colon, not starting with `~` or `/`) are treated as store references rather than file paths.
