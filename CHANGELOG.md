# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
