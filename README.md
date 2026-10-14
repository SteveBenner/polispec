# polispec

> **AI agents:** read [`AGENTS.md`](AGENTS.md) first.

Spec-based policy guardrails for agents working on software that serves real users. Each governed project declares its dev, test and prod environments, what an agent may do in each (allow, warn, deny), how code is promoted from one to the next, which data and secrets each environment may hold, when promotion is frozen, and which harness, model and effort each agent role gets. polispec judges every agent tool call against that policy and prints a verdict with a reason and a way forward.

The environment policy is read from the project's committed trust ref, normally `stable`. Unsealed development retains user-controlled settings and overrides. A sealed installation adds root-owned authority, a pinned runtime, and authenticated operator actions; see [harness controls](docs/harness-controls.md) and [operator setup](docs/operator.md). An enforcing guard refuses non-read actions when a live project's trusted policy cannot be loaded. Promotion bootstrap still reads the committed candidate branch policy and reports its exact source; it does not relax the guard.

Behavioral policy adds a separate contract for application directives, parameters and enforcement bindings. Applications consume compiled data through their own adapters; they do not need a running polispec service. See [the behavioral contract](docs/behavior.md).

## Install

With the rplugin SDK: `rplugin install polispec`, then `rplugin doctor polispec`.

Without it, run `bin/polispec` from a clone. It needs Ruby and no gems beyond the standard library.

## Quick start

```
polispec onboard <repo> --serves real_users --dry-run
polispec onboard <repo> --serves real_users
polispec doctor
polispec resolve .
```

`onboard` scaffolds `specs/polispec/environments.yml`, `policy.yml` and `roster.yml` from a template (`--archetype service` or `distributed`), points the component manifest at them, adds a ledger entry with status `onboarding`, and renders the `[ENVS]` row. `doctor` reports what is missing or invalid. `resolve` names the environment a directory is in and the policy that governs it.

Other commands:

```
polispec validate auto examples/policy.shop.yml
polispec validate roster examples/roster.shop.yml --json
polispec validate behavior path/to/behavior.yml --json
polispec behavior compile path/to/behavior.yml
polispec agents render <project-id|repo>
polispec promote <project> --to test
polispec hook git install <project-id> <dev|test|prod|all>
```

Environment facts live in `specs/polispec/environments.yml`, read from the trust ref like the policy. `docs/environments.md` covers the file, onboarding, the `[ENVS]` directive and the git hooks.

## Code specs

When an agent writes a file, polispec detects its language and applies the code specs from the code specs repository (`~/.polispec/specs`, read from its `stable` branch). The spec chain is injected before the first write, MUST violations on changed lines are refused, SHOULD violations are reported, and agent-judged policies are reviewed at task end. `docs/code-specs.md` covers the commands and `schemas/spec.v1.yml` the policy schema.

```
polispec code chain app.rb
polispec code check app.rb --json
polispec code controls
polispec specs promote
```

## Harness controls

Version 0.18.0 publishes the implementation with `harness_controls` and `sealed_plane` disabled. Grammar, validation, planning, and read-only inspection are available. New installations, removals, and sealing remain gated; upgrading does not activate the new host defaults. Enabling them is a separate operator decision. Existing explicitly installed controls and active or broken seals retain their protections.

Translate a request into the published grammar or a `polispec.control/v1` document, preview the native artifacts, and install only a verified tightening change.

```sh
polispec harness grammar --json
polispec validate control examples/controls.minimal.yml --json
polispec harness plan examples/controls.minimal.yml --harness codex --scope project --project /absolute/project --json
polispec plane status --json
```

Backends cover Claude Code, Codex, Hermes, Antigravity CLI, and OS sandbox planning. Capability reports distinguish generated artifacts, parser acceptance, native enforcement, and lock certification. Missing evidence keeps lock inactive. The `polispec-lock` branch shares the code on `main` and differs only in `EDITION`. [The harness guide](docs/harness-controls.md) records the current native and privileged verification limits.

rplugin's Antigravity integration installs skills only. polispec's separate `harness install --harness antigravity` path generates agy CLI artifacts; native operation remains unverified, and the GUI receives directives only.

Standard polispec runs independently without a lock checkout or protected service. The lock branch is a separately selected edition of the same code, with stricter prerequisites; it does not require a standard installation or a local `main` branch. Its immutable parent records release lineage. One edition is selected per installation; simultaneous independent authority planes in one host namespace are not provided.

## Smoke tests

polispec records smoke tests; it does not ship them. Run your own against a real installation and record each result in `smoke.yml` at the root of the repository whose spec it proves. Each entry names the spec node it proves, carries the verdict, steps and evidence digests, and captures the runtime (OS, kernel, Ruby, polispec version and commit, harness and model) without host or user identity. Entries are chained, `verify` detects edits, and `coverage` shows which units have a current pass. `docs/smoke.md` covers the format and how to write good smoke tests.

```sh
polispec smoke record --spec specs/app.yml --at commands/resolve --verdict pass --summary "resolve named the stable checkout prod"
polispec smoke verify
polispec smoke coverage
```

## Settings

For unsealed development, change settings with `rplugin settings`, or use the matching environment variable below. A sealed installation resolves protected settings first and ignores authority redirects from the calling process.

- `polispec.enforce`: `advise` (log verdicts, never block) or `enforce`; default `advise`. It governs environment and enabled harness-control verdicts. `polispec.code.enforce` (`advise` or `tiered`), `polispec.code.check_at` (`pre_write` or `post_write`) and `polispec.code.inject` (`once` or `every_write`) govern code specs.
- `polispec.ledger`: path of the ledger of governed projects; default `~/.config/polispec/ledger.yml`. `POLISPEC_LEDGER` overrides it.
- `polispec.edition`: `standard` or `lock`, default `standard`; the lock branch requests lock regardless of a mutable downgrade. A request alone does not certify enforcement.
- `polispec.root_guard`: initially `false`; recorded exposure can arm it, and lock fallback forces it on.
- `polispec.operator`: how messages name the person who promotes to stable; default `the operator`.
- `polispec.code.specs_repo`: path of the code specs repository; default `~/polispec-specs`. `POLISPEC_SPECS_REPO` overrides it.
- `polispec.smoke.path`: path of the smoke ledger; empty means `smoke.yml` at the git toplevel of the working directory. `POLISPEC_SMOKE` overrides it.
- `polispec.global.repo`, `polispec.global.ref` (default `main`) and `polispec.global.path` (default `polispec`): where the optional global layer of shared rules, modules and profiles is read from. Unset means no global layer. `POLISPEC_GLOBAL` points at a plain directory for scratch runs. See `docs/schema.md`.

## Optional integrations

None is required. Policy `observability.events` may name an `rlogs` sink, and `polispec onboard` recognises a `*.rstack_component.yml` manifest as well as `*.rplugin.yml`.

## Documentation

- `docs/schema.md`: every key of the policy, roster and ledger, with examples.
- `docs/operator.md`: sealed authority, protected allow-once, promote, deploy, pause, and host wiring.
- `docs/harness-controls.md`: grammar, native installation, authority ceilings, editions, and verification limits.
- `docs/environments.md`: the environment manifest, onboarding, `[ENVS]` and git hooks.
- `docs/roster.md`: the roster resolver.
- `docs/behavior.md`: behavioral policy.
- `docs/code-specs.md`: code specs.
- `docs/smoke.md`: the smoke ledger.
- `examples/`: the `shop` (web service) and `widget` (distributed plugin) projects and an example ledger.

## License

MIT. See `LICENSE`.

`polispec status <project> --json` includes `projects[].deployments` (contract
`polispec.status.deployments/v1`). Each environment carries `receipt`, `latest_attempt`, and `verified`.
The receipt identifies the last successful deployment by record id, SHA, tag, health, pin status, and time.
Verification requires the receipt to match the latest attempted deployment, with health `ok` and no pin.
An in-progress or newer failed attempt, unchecked health, or a legacy receipt without record identity fails closed.
Consumers must also match the current remote environment ref and tag; branch promotion alone does not prove deployment.
No state paths, health output, or secrets are exposed by this field. It is deployment-time evidence, not continuous health.
