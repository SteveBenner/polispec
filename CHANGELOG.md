# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
