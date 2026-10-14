# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
