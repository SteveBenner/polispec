# polispec

> **AI agents:** read [`AGENTS.md`](AGENTS.md) first.

Spec-based policy guardrails for agents working on software that serves real users. Each governed project declares its dev, test and prod environments, what an agent may do in each (allow, warn, deny), how code is promoted from one to the next, which data and secrets each environment may hold, when promotion is frozen, and which harness, model and effort each agent role gets. polispec judges every agent tool call against that policy and prints a verdict with a reason and a way forward.

The policy is committed on the project's `stable` ref and the guard reads it from there, never from the working tree, so an agent cannot loosen the rules it runs under. The operator alone moves code into production, with one typed command. Until a project's stable ref carries a policy, `promote` and `deploy test` read the committed policy of the branch being promoted (`origin/main` for test, `origin/test` for stable) and report it as `bootstrap:<ref>:<sha>`; the guard keeps the ledger defaults.

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

## Settings

Change them with `rplugin settings`, or set the matching environment variable named below.

- `polispec.enforce`: `advise` (log verdicts, never block) or `enforce`; default `advise`. It governs the environment guard. `polispec.code.enforce` (`advise` or `tiered`), `polispec.code.check_at` (`pre_write` or `post_write`) and `polispec.code.inject` (`once` or `every_write`) govern code specs.
- `polispec.ledger`: path of the ledger of governed projects; default `~/.config/polispec/ledger.yml`. `POLISPEC_LEDGER` overrides it.
- `polispec.operator`: how messages name the person who promotes to stable; default `the operator`.
- `polispec.code.specs_repo`: path of the code specs repository; default `~/polispec-specs`. `POLISPEC_SPECS_REPO` overrides it.
- `polispec.global.repo`, `polispec.global.ref` (default `main`) and `polispec.global.path` (default `polispec`): where the optional global layer of shared rules, modules and profiles is read from. Unset means no global layer. `POLISPEC_GLOBAL` points at a plain directory for scratch runs. See `docs/schema.md`.

## Optional integrations

None is required. Policy `observability.events` may name an `rlogs` sink, and `polispec onboard` recognises a `*.rstack_component.yml` manifest as well as `*.rplugin.yml`.

## Documentation

- `docs/schema.md`: every key of the policy, roster and ledger, with examples.
- `docs/operator.md`: promote, deploy, allow-once, pause, settings and host wiring.
- `docs/environments.md`: the environment manifest, onboarding, `[ENVS]` and git hooks.
- `docs/roster.md`: the roster resolver.
- `docs/behavior.md`: behavioral policy.
- `docs/code-specs.md`: code specs.
- `examples/`: the `shop` (web service) and `widget` (distributed plugin) projects and an example ledger.

## License

MIT. See `LICENSE`.
