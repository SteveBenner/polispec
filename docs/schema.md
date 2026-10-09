# Polispec schemas

Three YAML documents carry every polispec decision. Each has a machine-checkable schema (JSON Schema 2020-12, authored as YAML) under `schemas/`, and `polispec validate` checks a file against it and reports every violation with a JSON pointer.

```
polispec validate <policy|roster|ledger|auto> <file> [--json]
```

`auto` reads the file's `schema:` key. Exit status is 0 when the file is valid, 1 when it is not, and 2 on a usage error. With `--json` the result is `{"ok":bool,"schema":"polispec.policy/v1","errors":[{"pointer":"/rules/3/verdict","message":"must be one of allow, warn, deny"}]}`.

Every object rejects unknown keys, except the free text under `agents.instructions` and the parameters of a freeze (`freezes[]` accepts source-specific keys beside the ones listed here).

## Vocabulary

- Environments: `dev`, `test`, `prod`. `dev` is the `main` branch, `test` the `test` branch, `prod` the `stable` branch.
- Action classes (a closed set): `git.commit`, `git.push`, `git.tag`, `git.merge`, `git.rewrite`, `git.branch`, `release.publish`, `service.control`, `service.config`, `fs.write`, `data.write`, `data.copy`, `secrets.read`, `policy.edit`, `promote`, `deploy`.
- Verdicts: `allow`, `warn` (a stern warning plus explicit user confirmation), `deny`.
- Actors: `agent` (any tool call through a harness hook) and `operator` (an interactive terminal with a typed phrase).

## Policy: `specs/polispec/policy.yml` of the project, `polispec.policy/v1`

The guard reads it from the project's trust ref (the committed blob on `stable`), never from the working tree. Examples: `examples/policy.shop.yml` with `examples/environments.shop.yml` (a web service), and `examples/policy.widget.yml` with `examples/environments.widget.yml` (a distributed plugin).

| Key | Type | Meaning |
| --- | --- | --- |
| `schema` | const `polispec.policy/v1` | Document type. |
| `project` | id | Must equal the ledger id of the project. |
| `recorded` | date | When the policy was recorded. |
| `summary` | string | One sentence on the project's stages. |
| `environments.<dev|test|prod>` | object | Required. See below. |
| `rules[]` | list | First match wins, evaluated per (action class, environment). |
| `promotion.to_test`, `promotion.to_stable` | object | How code moves. Required. |
| `freezes[]` | list | Windows during which promotion or desk dispatch stops. |
| `data_classes.<name>` | object | Where a kind of data may live. |
| `observability` | object | Where events go and the digest cadence. |
| `agents` | object | Instructions injected at session start and the roster path. |
| `includes[]` | list of module names | Safe-operation modules the policy pulls in. The name is validated now; resolution arrives with layers. |
| `hermetic.<env>` | object | Isolation of the commands that run for a stage. See below. |

### `environments.<env>`

| Key | Type | Meaning |
| --- | --- | --- |
| `branch` | string | Git branch bound to the stage. Required. |
| `checkout` | string | `repo` for the working repository, otherwise the directory services run from. Required. |
| `tier` | `dev`, `test` or `prod` | Required. |
| `runs` | `branch` or `tag` | Whether the stage runs the branch tip or a promoted tag (`prod`). |
| `worktrees` | list of globs | Worktree directories counted as this stage. |
| `services` | list | Service unit names. |
| `unit_files`, `env_files` | list of globs | Files that configure the services. |
| `url` | string | Where the stage is served. |
| `ports` | list of integers | Ports the stage owns. |
| `data.dirs`, `data.databases` | lists | Data stores the stage owns. |
| `data_classes` | list | Data classes the stage may hold. |
| `secrets` | list of globs | Secret scopes of the stage. |
| `deploy.steps` | list of commands | Run in order by `polispec deploy`. |
| `deploy.health.url`, `.expect_version`, `.timeout_s` | string, bool, integer | Health check that must report the deployed version. |
| `deploy.strategy` | `in_place` or `release_dirs` | Default `in_place`: the stage checkout is updated where it stands. `release_dirs` builds each release in `<envs_root>/<project>/releases/<tag>` and points `<envs_root>/<project>/<env>` at it by an atomic symlink swap, with automatic rollback. |
| `deploy.activate` | list of commands | `release_dirs` only: the restarts, run after the symlink swap and again after a rollback. Default none. |
| `deploy.drain.pause`, `.wait`, `.resume` | string | Quiesce hooks around the swap. `pause` and `resume` run once; `wait` repeats until exit 0. All optional. |
| `deploy.drain.timeout_s` | integer | How long `wait` may run (default 300; polled every 5 s). |
| `deploy.drain.checks` | list of commands | Run after pause and wait, before the swap or first step; a failure aborts with `drain_check_failed`. |
| `deploy.drain.run_in`, `.env_from` | `repo` or `active`; env name | Where drain commands run (default `active`) and whose `env_files` they load (default the env being deployed). |
| `deploy.health.run` | string | Command health check, run in the checkout like a deploy step; exit 0 is `ok`. A block may declare `url`, `run` or both; with both, each must pass. |

```yaml
environments:
  prod: { branch: stable, checkout: "~/.polispec/envs/shop/stable", tier: prod, runs: tag, services: [shop-web], data: { dirs: ["~/.shop"], databases: [shop] }, data_classes: [customer_pii], secrets: ["~/.shop/keys/**"] }
```

### `rules[]`

| Key | Type | Meaning |
| --- | --- | --- |
| `id` | `R-…` | Rule id shown in every message. |
| `match.env` | environment | Restrict to a stage. |
| `match.class` | list of action classes | Restrict to these classes. |
| `match.crosses` | `data_classes` or `location` | `data_classes`, for `data.copy`: matches when the data class is not allowed in the destination. `location`, for `fs.write`, `data.write` and `data.copy`: matches when the target is another project or another environment of the same project than the caller's location, and is prod or sits under a protected root (the engine evaluates it). |
| `match.destructive` | `true` | Matches only a `data.write` the shell classifier marked destructive: SQL with TRUNCATE, DROP, ALTER ... DROP, DELETE without WHERE, or UPDATE without WHERE (the classifier sets the mark). |
| `match.ref` | string | Restrict to a git ref. |
| `verdict` | `allow`, `warn`, `deny` | Required. |
| `reason` | string | Why, shown to the agent. |
| `requires` | `gates.to_test` or `gates.to_stable` | Gates that must pass for the rule to allow. |
| `overridable` | boolean | Marks a rule a lower layer may loosen. Default false. |
| `overrides` | `R-…` | Declares that this rule loosens the named rule of an upper layer. Valid only against a rule marked `overridable`. |

```yaml
- { id: R-PROD-GIT, match: { env: prod, class: [git.push] }, verdict: deny, reason: "stable is production" }
```

### `promotion`

`to_test` keys: `from`, `actor`, `fast_forward_only`, `requires_version_bump`, `tag`, `release.github_prerelease`, `drift`, `gates[]`, `after[]`. `to_stable` keys: `from`, `actor`, `fast_forward_only`, `phrase`, `preflight[]`, `gates[]`, `release.flip_latest`, `after[]`.

`preflight[]` takes gates of the same shape and runs before the other gates and the phrase prompt, so an operator is not asked to type a phrase for a promotion that would fail. `release.flip_latest` is `true`, `false` or `deferred`: `deferred` publishes the release as a full (not pre-) release without `--latest` and records `latest: deferred` in `promotions.jsonl`, leaving the flip to the project's own soak job.

A gate is `{ id: G-…, run: <command>, pass: exit_zero }` or `{ id: G-…, builtin: clean_tree | version_homes_agree | sha_ran_on_test | not_frozen | soaked | health_required }`. `soaked` takes `hours` (integer, at least 1). A command gate also takes `run_in` (`repo` default, or `active`) and `env_from` (an environment name whose `env_files` are loaded); a gate that touches a live database must use `run_in: active`. A command gate may set `hermetic: false` to run outside `hermetic.<env>` (see `docs/operator.md`). Commands and phrases may use `{project}`, `{sha}`, `{VERSION}`, `{tag}` and `{stable_tag}` (the highest `v*` tag on the stable branch tip, empty when none). Commands run without a shell; `$HOME`, `${HOME}` and a leading `~` are the only expansions.

```yaml
promotion:
  to_stable: { from: test, actor: [operator], fast_forward_only: true, phrase: "promote {project} to stable", gates: [{ id: G-TESTED, builtin: sha_ran_on_test }] }
```

### `freezes[]`

`id` (`F-…`), `applies_to` (`promote.to_stable`, `desk.dispatch`), `source`, `project`, `kind`, `command`, `lead_minutes`, `lead_hours`, and a manual window (`rrule`, `from`, `until`, each nullable). `kind` is a free label; `project` names the ledger project whose prod checkout runs the command (default the policy's own project).

A freeze without `source` is a manual window. `source: command` runs `command`, a list of argv strings, without a shell: the first element is relative to the prod checkout or absolute, the working directory is the prod checkout, and stdout must be JSON of the form `{"windows": [{"kind": "...", "from": "ISO-8601", "until": "ISO-8601", "detail": "..."}]}`. When the freeze sets `kind`, only windows with that `kind` apply; otherwise every returned window applies. Results are cached for five minutes. A missing or failing program yields the finding `freeze_source_unavailable` ("<argv0> is not available in <checkout>") and no windows. Two sources are deprecated aliases with unchanged behaviour: `source: teach.calendar` is `command: [bin/teach, calendar, freezes, --json]` (kind filter always applied), and `source: teach.activity` is `command: [bin/teach, activity, --json]` (no kind filter, `project` selects the checkout).

### `hermetic.<env>`

`isolate` (list of environment variable names) and `protected_roots` (list of paths, `~` and `$HOME` expanded). Declared for `test` or `prod`; applied to the deploy steps, `deploy.health.run` and command gates of that stage. See `docs/operator.md`.

### `data_classes.<name>`

`allowed_in` (list of environments, required), `pii_spec` (path of a personal-data map such as `specs/pii.yml`), `produced_by` (the command that creates the class).

### `observability`, `agents`

`observability.events` is `rlogs`, `local` or `none`; `observability.digest` is `daily`, `weekly` or `none`. `agents.instructions` is a list of free-text lines for the session summary; `agents.roster` is the roster path.

## Roster: `specs/polispec/roster.yml` of the project, `polispec.roster/v1`

Which harness, model and effort each agent role gets, with bounds an edit may not leave. Example: `examples/roster.shop.yml`.

| Key | Type | Meaning |
| --- | --- | --- |
| `schema`, `project` | | As in the policy. |
| `harness_effort.<harness>` | list | The effort vocabulary of each harness, lowest first. |
| `roles.<role>` | slot | Interactive and workflow roles. |
| `pipelines.<name>.phases.<phase>` | slot | A pipeline phase, for example `shop.release`. |
| `workflows.<name>` | object | `build_role`, `verify_role`, `author_role`, `min_effort`. |
| `environments.<env>` | object | `roles` and `pipelines` allowed to act there; `*` matches all. Required for all three. |
| `budgets` | object | `per_run_usd_max` and `per_day_usd.<scope>`. |

A slot is `{ default: <assignment>, bounds: <bounds> }`. An assignment holds `harness`, `model` (required), `effort` (string or null), `agent`, `run` (`merge`, `script`, `model`), `on_failure` (`stop`, `model`) and `budget_usd`. Bounds hold `harnesses`, `models`, `effort` and `budget_usd`, the last two as `{ min, max }`.

```yaml
roles:
  reviewer: { default: { harness: claude, model: opus, effort: high }, bounds: { effort: { min: high } } }
```

## Ledger: `polispec.ledger/v1`

Names the live projects of the host. The file is resolved in order from the `POLISPEC_LEDGER` environment variable (when non-empty), the `polispec.ledger` rplugin setting, then `$XDG_CONFIG_HOME/polispec/ledger.yml` (`~/.config/polispec/ledger.yml` when `XDG_CONFIG_HOME` is unset). Example: `examples/ledger.example.yml`.

| Key | Type | Meaning |
| --- | --- | --- |
| `schema`, `host` | | Document type and machine name. |
| `envs_root` | path | Where `test` and `stable` checkouts live. |
| `defaults.rules[]` | list | The fail-closed policy for a ledgered project whose stable policy is missing or invalid. Each rule has `match` (`env`, `ref`, `class`), `verdict`, optional `id` and `reason`. |
| `projects[]` | list | `id`, `status` (`live`, `onboarding`, `retired`), `repo`, `remote`, `worktree_globs`, `trust_ref`, `policy`, `roster`, `related`, `onboarded`, `profile` (`personal`, `service` or `live`; default `personal`). |
| `pauses_log`, `allow_once_log` | path | Append-only JSONL logs. |

```yaml
projects:
  - { id: shop, status: live, repo: ~/src/shop, trust_ref: stable, policy: specs/polispec/policy.yml, roster: specs/polispec/roster.yml }
```

## Layers: `polispec.global/v1`, `polispec.module/v1`, `polispec.profiles/v1`

A policy is composed from layers: the global layer, the repo policy, then any ledgered child project nested under the repo that contains the path, nearest last. The global layer is `global.yml`, `profiles.yml` and `modules/<name>.yml` read from the `polispec.global.*` settings (see `docs/operator.md`). With no global source configured, verdicts are exactly those of the repo policy alone.

- `global.yml` (`polispec.global/v1`): `includes` (module names), `rules`, `fallback_rules`, `gates` (`to_test`, `to_stable`), `preflight`, `freezes`, `hermetic`, `protected_roots` (`path`, `writers`).
- `modules/<name>.yml` (`polispec.module/v1`): `name` (equal to the file name), `includes`, `rules`, `gates`, `preflight`, `freezes`, `hermetic`.
- `profiles.yml` (`polispec.profiles/v1`): `profiles.personal`, `profiles.service`, `profiles.live`, each a list of module names. A ledger project gets its `profile` (default `personal`); a path outside the ledger gets only the global layer without profile modules. A policy may set `profile` only to a stricter one than its ledger entry.
- Within a layer rules stay first-match. A layer's included modules (depth-first, each once; a cycle or a missing module is an error) come before the layer's own rules. Across layers the strictest verdict wins (`deny`, then `warn`, then `allow`); on equal severity the lowest layer's rule is reported.
- A lower layer loosens an upper rule only when that rule has `overridable: true` and the lower layer's rule names it in `overrides`. Overriding a rule that is not overridable, or that no upper layer defines, is a validation error naming both rules, and the override is not applied.
- Layers merge `rules`, `gates`, `freezes` and `hermetic`, never `environments`. Child layers contribute rules only.
- `fallback_rules` in `global.yml` replace the ledger `defaults.rules` as the repo layer of a project whose policy is missing at its trust ref. They never join the composed global layer. When `polispec.global.repo` is set and `global.yml` is absent or invalid, doctor and validate report it and the global layer contributes no rules; the repo layer still applies.

`polispec resolve <path> --layers --json` prints each layer with its source, digest, rule count and modules, then the effective digest (sha256 over the ordered layer digests). `polispec validate policy`, `validate global`, `validate module` and `polispec doctor` report override, include and profile errors, and an environment that deploys without a health check.

## Candidates for schema v2

- SUG-1 `approvals.quorum`: N named humans must confirm a prod promotion (a second owner or reviewer).
- SUG-2 `change_classes`: classify a diff (hooks, wire files, migrations, agent control) and attach stricter gates or a soak per class.
- SUG-3 `coupling`: cross-project promotion constraints, for example a plugin's stable may not advance past a wire version the service's stable does not serve.
- SUG-4 `slos`: per-environment objectives that block promotion when test missed them (error rate, p99).
- SUG-5 `incident.runbooks`: named rollback and incident runbooks the guard links in deny messages.
- SUG-6 `providers_by_data_class`: which model providers may see which data classes.
- SUG-7 `network.egress`: allowed outbound hosts per environment, enforced through harness sandboxes.
- SUG-8 `exceptions`: expiring, named policy exceptions with an owner, replacing ad-hoc pauses.
- SUG-9 `release_gate.POL-*`: a release-gate check that the target ref carries a valid policy.
- SUG-10 `retention`: per-environment data retention and automatic test-data expiry.
- SUG-11 `notify`: route warn and deny digests to Telegram or desktop notification through the notify port.
- SUG-12 `compliance_tags`: regulatory tags such as GDPR on environments and data classes, surfaced in the daily digest.
