# Polispec schemas

Three YAML documents carry every polispec decision. Each has a machine-checkable schema (JSON Schema 2020-12, authored as YAML) under `schemas/`, and `polispec validate` checks a file against it and reports every violation with a JSON pointer.

```
polispec validate <policy|roster|ledger|auto> <file> [--json]
```

`auto` reads the file's `schema:` key. Exit status is 0 when the file is valid, 1 when it is not, and 2 on a usage error. With `--json` the result is `{"ok":bool,"schema":"polispec.policy/v1","errors":[{"pointer":"/rules/3/verdict","message":"must be one of allow, warn, deny"}]}`.

Every object rejects unknown keys, except the free text under `agents.instructions` and the parameters of a freeze (`freezes[]` accepts source-specific keys beside the ones listed here).

## Vocabulary

- Environments: `dev`, `test`, `prod`. `dev` is the `main` branch, `test` the `test` branch, `prod` the `stable` branch.
- Action classes (a closed set): `git.commit`, `git.push`, `git.tag`, `git.merge`, `git.rewrite`, `git.branch`, `release.publish`, `service.control`, `service.config`, `fs.write`, `fs.delete`, `data.write`, `data.copy`, `secrets.read`, `policy.edit`, `promote`, `deploy`, `control.edit`, `mcp.call`, `web.fetch`, `agent.spawn`, `shell.exec`.
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
| `includes[]` | list | Modules the policy pulls in: a module name, or `{ module: <name>, with: { <param>: <value> } }`. Names resolve to the project shelf (`modules/` beside the policy) or the global shelf. See [Layers](#layers-polispecglobalv1-polispecmodulev1-polispecprofilesv1). |
| `hermetic.<env>` | object | Isolation of the commands that run for a stage. See below. |

### `environments.<env>`

`dev`, `test` and `prod` are required; any other key is an additional environment of the same shape (for example `canary`), whose `tier` is still `dev`, `test` or `prod`.

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
| `match.server`, `match.operation` | string | Exact MCP server and operation. A trusted declaration must match each action; one declaration does not cover another call. |
| `match.domain`, `match.tool`, `match.role` | string | Exact domain, native tool name, and agent role respectively; supplied values all have to match. |
| `match.path` | string | Path glob using the same slash-aware and dotfile-aware matching as harness controls. |
| `match.crosses` | `data_classes` or `location` | `data_classes`, for `data.copy`: matches when the data class is not allowed in the destination. `location`, for `fs.write`, `fs.delete`, `data.write` and `data.copy`: matches when the target is another project or another environment of the same project than the caller's location, and is prod or sits under a protected root (the engine evaluates it). |
| `match.destructive` | `true` | Matches only a `data.write` the shell classifier marked destructive: SQL with TRUNCATE, DROP, ALTER ... DROP, DELETE without WHERE, or UPDATE without WHERE (the classifier sets the mark). |
| `match.ref` | string | Restrict to a git ref. |
| `match.shape` | list of shape names | Matches when the action carries any listed shape. The classifier tags shapes from the parsed script (pipeline, redirects, heredoc and `-c` bodies), never from raw text. Names: `bulk_stage` (`git add -A`, `--all`, `-u`, `--update`, `.`, `:/`, the repo root; `git commit -a`), `chained_release` (a `git.tag`, `git.push`, `release.publish` or `promote` action in a script of more than one command), `latest_flip` (`gh release create` or `edit` with `--latest`, `gh api` with `make_latest` true), `lockfile_edit` (an Edit or Write tool call, `sed -i`, `perl -i` or a redirect writing `Cargo.lock`, `Gemfile.lock`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `uv.lock` or `poetry.lock`), `pattern_kill` (`pkill -f`, `killall`, `kill` or `pkill` fed by `$(pgrep ...)`), `cargo_clean`, `worktree_force` (`git worktree remove --force`, `git worktree prune`). An unknown name is a validation error. |
| `match.lock_held` | boolean | Matches when the action's target path is listed in `TMP_AGENT_FILE_LOCKS.yml` at the target's git toplevel by a live entry that is not an ancestor of the hook process. An entry with `owner_pid`, `owner_start` and `owner_boot` is live when that process exists with the same start time and boot id; an entry without owner fields is live for 10 minutes from `acquired_at`. |
| `match.live_binary` | boolean | Matches when an `fs.delete` target, or the target directory of a `cargo clean`, contains the resolved `/proc/<pid>/exe` of a running process of the current user. |
| `match.supervised` | boolean | Matches when a `service.control` target (a unit name, or a pid from `kill`) belongs to a component reported by the command in setting `polispec.supervisor.status_command` (argv, no shell, prints `{"units": [...], "pids": [...]}`, 1 s timeout, cached 60 s under `$POLISPEC_HOME/cache`). Unset or failing, the predicate is true for a `pattern_kill` and false for a named unit, with a finding either way. |
| `match.pin_regress` | boolean | Matches a `git.commit` whose index changes a submodule pin to a commit that is not a descendant of the old pin (`git commit -a` also counts the working tree). An object missing from the local clone matches, and the reason says to fetch the submodule. |
| `match.tag_claimed` | boolean | Matches a `git.tag` or tag push of `vX` when `refs/tags/vX` already exists at a different commit, when `X` is lower than the `VERSION` file at `refs/remotes/origin/main`, or when `X` equals it and the tagged commit is not an ancestor of `refs/remotes/origin/main` whose own `VERSION` reads `X`. The tagged commit is the commit-ish `git tag` names, exactly as written (a SHA, `origin/main`), or `HEAD`; for a push it is the local tag. The reason for a lower `X` says it is not greater than origin/main's version; for an equal `X` it says the tag is not on origin/main's release commit for that version. No network is used; the reason says to fetch when the last fetch is older than an hour. |
| `match.base_unpushed` | boolean | Matches a branch creation (`worktree add -b`, `checkout -b`, `switch -c`, `branch X [start]`) whose start point resolves to a local branch with commits not on its upstream. |
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

`promotion` also accepts `to_<env>` for any other declared environment (for example `to_canary`), each with `from`, `actor`, `gates[]` and optionally `phrase`, `preflight[]`, `fast_forward_only`, `release.flip_latest` and `after[]`. `to_test` and `to_stable` stay required. See `docs/operator.md`.

A gate is `{ id: G-…, run: <command>, pass: exit_zero }` or `{ id: G-…, builtin: clean_tree | version_homes_agree | sha_ran_on_test | sha_ran_on | not_frozen | soaked | health_required | logs_quiet | requires_live }`. `soaked` takes `hours` (integer, at least 1) and `env` (default `test`); `sha_ran_on` takes `env` (default `test`; `sha_ran_on_test` is its alias). `logs_quiet` takes `services[]`, `window_minutes` (default 120) and `max_over_baseline` (default 0). `requires_live` takes `project` and `min_version`, or `min_version_from` with `min_version_key`. A command gate also takes `run_in` (`repo` default, or `active`) and `env_from` (an environment name whose `env_files` are loaded); a gate that touches a live database must use `run_in: active`. Any gate may set `dir`, a subdirectory of the run location (no `..`, no leading `/`) in which its command runs; a missing directory fails the gate. polispec sets `dir` on gates a nested child project contributes. A command gate may set `hermetic: false` to run outside `hermetic.<env>` (see `docs/operator.md`). Commands and phrases may use `{project}`, `{sha}`, `{VERSION}`, `{tag}` and `{stable_tag}` (the highest `v*` tag on the stable branch tip, empty when none). Commands run without a shell; `$HOME`, `${HOME}` and a leading `~` are the only expansions.

```yaml
promotion:
  to_stable: { from: test, actor: [operator], fast_forward_only: true, phrase: "promote {project} to stable", gates: [{ id: G-TESTED, builtin: sha_ran_on_test }] }
```

### `freezes[]`

`id` (`F-…`), `applies_to` (`promote.to_<env>` for a declared environment, such as `promote.to_stable`, or `desk.dispatch`), `source`, `project`, `kind`, `command`, `lead_minutes`, `lead_hours`, and a manual window (`rrule`, `from`, `until`, each nullable). `kind` is a free label; `project` names the ledger project whose prod checkout runs the command (default the policy's own project).

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

A slot is `{ default: <assignment>, bounds: <bounds> }`. An assignment holds `harness`, `model` (required), `effort` (string or null), `agent`, `run` (exactly one of `merge`, `script`, `model`; a worker profile checked against the slot uses `merge` or `own` for diagnose and spec and `script` or `model` for ship), `on_failure` (`stop`, `model`) and `budget_usd`. Bounds hold `harnesses`, `models`, `effort` and `budget_usd`, the last two as `{ min, max }`.

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
| `projects[]` | list | `id`, `status` (`live`, `onboarding`, `retired`), `repo`, `remote`, `worktree_globs`, `trust_ref`, `policy`, `roster`, `related`, `onboarded`, `profile` (`personal`, `service` or `live`; default `personal`), `packages` (see below). |
| `projects[].packages[]` | list | One record per applied package: `name`, `variant`, `version`, `applied_at` (date) and `files` (repository path to `sha256:<hex>` of the bytes apply wrote). Upgrades compare against these digests. |
| `pauses_log`, `allow_once_log` | path | Append-only JSONL logs. |

```yaml
projects:
  - { id: shop, status: live, repo: ~/src/shop, trust_ref: stable, policy: specs/polispec/policy.yml, roster: specs/polispec/roster.yml }
```

## Package: `packages/<name>/package.yml`, `polispec.package/v1`

A package is a named, versioned setup that `polispec plan` and `polispec apply` carry out against a repository. See [packages](packages.md).

| Key | Type | Meaning |
| --- | --- | --- |
| `schema`, `name`, `version` | | `polispec.package/v1`; the name matches `^[a-z0-9][a-z0-9-]{0,40}$` and equals the directory; the version is semver. |
| `summary` | string | One line shown by plan. |
| `params` | map | Same shape as module parameters: `type`, `default`, `summary`, plus `allowed` (a list of values, string parameters only). Given with `--param name=value`. |
| `variants` | map | `<variant>: { summary, files: { <repo target>: <source in the package> } }`. |
| `default_variant` | string | Used when `--variant` is not given. |
| `files` | map | Files written for every variant; a variant's file wins on the same target. Sources are templates rendered with `{{project}}`, `{{date}}`, `{{envs_root}}`, `{{repo_name}}` and every parameter. |
| `modules` | list | Names of files in the package's `modules/` copied to `specs/polispec/modules/<name>.yml`. |
| `steps` | list | Ordered built-in steps, each `{ kind, when }` or a bare kind: `files`, `manifest`, `ledger`, `render`, `commit`, `branches`, `push`, `checkouts`. `when: { param, equals }` is optional and names a declared parameter. Unknown keys and step kinds, and file paths that are absolute or contain `..`, are errors. |

## Plan: `polispec.plan/v1`

`polispec plan --json` prints `schema`, `target`, `plan_id`, `files[]` (`path`, `action` `add|replace|conflict|unchanged`, `diff`), `ledger` (`before`, `after`) or null, `policy_diff` (per affected project: added, removed and changed rules, gates, freezes and modules, with effective digests before and after), `probes[]` and `journal[]` (`probe`, `before`, `after`, `change` `tighten|loosen|same`), `classification` (`tightening`, `loosening`, `mixed` or `neutral`), `needs_confirm` and `reasons[]`. The `plan_id` is `plan_` plus the first 24 hex digits of the SHA-256 of the target, the proposed and current digests, and the classification, so any change to the proposal changes the id.

## Smoke ledger: `polispec.smoke/v1`

Records smoke tests that proved a spec or sub-spec in reality (`docs/smoke.md`). The file is `smoke.yml` at the git toplevel of the working directory; `POLISPEC_SMOKE`, then the `polispec.smoke.path` setting, override it. Written only by `polispec smoke record`.

| Key | Type | Meaning |
| --- | --- | --- |
| `schema` | `polispec.smoke/v1` | Document type. |
| `entries[]` | list | Append-only, oldest first. |
| `entries[].id` | `smk_` + 12 hex | sha256 prefix of the entry without `id` and `digest`. |
| `entries[].recorded_at`, `started_at`, `finished_at` | ISO 8601 | `recorded_at` is set by `record`; the others are optional. |
| `entries[].proves` | object | `spec` (path relative to the toplevel of a YAML file), `at` (slash path: mapping key or list item `name`/`id`; `~1` is `/`, `~0` is `~`; empty for the whole file), `spec_digest` (sha256 of the file), `at_digest` (sha256 of the canonical JSON of the node). |
| `entries[].verdict` | `pass`, `fail`, `partial`, `blocked` | |
| `entries[].summary` | string | What was shown. |
| `entries[].steps[]` | list | `run`, `exit` (integer or null), `expect`, `observed`. |
| `entries[].evidence[]` | list | `path` (relative to the toplevel, else a basename), `sha256`, `bytes`, `kind`. |
| `entries[].runner` | object | `kind` (`human`, `agent`), `harness`, `harness_version`, `model`, `effort`. |
| `entries[].runtime` | object | Captured OS, kernel, architecture, container and WSL flags, time zone, locale, Ruby, polispec version, edition, commit, dirty flag, install kind, rplugin version, enforce mode. No host or user identity. |
| `entries[].target` | object | Captured `commit`, `branch`, `dirty` (ignoring the ledger file), and `project`, `env`, `policy_digest` when the toplevel is governed. |
| (anchor) | | Not in the file: `record` keeps the head `{digest, count, recorded_at}` per ledger real path in `smoke-heads.json` under the polispec state home; `verify` reports `truncated` against it. |
| `entries[].prev`, `digest` | sha256 or null | `prev` is the previous entry's `digest` (null first); `digest` covers the canonical JSON of the entry without `digest`. |

```yaml
schema: polispec.smoke/v1
entries:
  - { id: smk_4980154c744d, proves: { spec: specs/app.yml, at: "commands/promote, deploy", spec_digest: "…", at_digest: "…" }, verdict: pass, summary: "promote --to test moved test and deploy recorded a verified receipt", steps: [], evidence: [], runner: { kind: agent, harness: claude-code, harness_version: 2.1.296, model: claude-haiku-5-5, effort: null }, runtime: {}, target: {}, recorded_at: "2026-10-13T23:59:00Z", prev: null, digest: "…" }
```

## Judgment record: `polispec.judgment/v1`

One record per call the guard judged (`docs/operator.md`, judgment records). The stream is `judgments.jsonl` under the polispec state home, one JSON record per line, rotated at 16 MiB to `judgments.<utc timestamp>.jsonl`; `judgments.head.json` beside it anchors the head. Written by the pretool hook and the git hooks; read by `polispec judgments`, `digest`, `plan` and `doctor`. `polispec validate judgment FILE` checks one record.

| Key | Type | Meaning |
| --- | --- | --- |
| `schema` | `polispec.judgment/v1` | Document type. |
| `id` | `jdg_` + 12 hex | sha256 prefix of the record without `id` and `digest`. |
| `ts` | ISO 8601 | When the record was sealed. |
| `action` | object | `tool`, `harness`, `event`, `session_id`, `agent_type`, home-relative `cwd`, `call_digest` (sha256 of the canonical JSON of `tool`, `arguments` and `cwd`), and `raw` only while `polispec.records.raw` is on (at most 2048 bytes). |
| `targets[]` | list | One per governed project or global baseline the call touched: `project`, `env`, `policy_source`, `policy_digest`, `verdict`, `rule_id`, and `rows[]` with `action_class`, `env`, `ref`, home-relative `path`, `crosses`, `destructive`, `shape`, `verdict`, `rule_id`. Empty for an ungoverned call. |
| `control` | object or null | `control_digest`, `edition`, `verdict`, `ask_ids` when the control ceiling ran. |
| `engine` | object | `version`, `runtime` (`pinned`, `sealed`, `clone`, `unknown`), `commit`, `tree_digest` (pinned only), `edition`, `enforce`, `plane` (`status`, `generation`), `fastpath_key`. |
| `outcome` | object | `verdict`, `rule_id`, `enforced`, `allow_once_id`, `rendered` (`allow`, `ask`, `deny`, `context`, `none`), `governed`, `error` (the exception class of a fail-closed denial), `duration_ms`. |
| `prev`, `digest` | sha256 or null | `prev` is the previous record's `digest` across rotations (null first); `digest` covers the canonical JSON of the record without `digest`. |
| (anchor) | | Not in the stream: `judgments.head.json` holds `{digest, count, file}` and `verify` reports `truncated` against it, expecting a count that leaves out the records it lists as `interrupted_append`. |
| (skips) | | Not in the stream: `skips.jsonl` holds one `{ts, tool, session, key, skip}` line per call `bin/polispec-guard` skipped; counted, never chained. |

## Layers: `polispec.global/v1`, `polispec.module/v1`, `polispec.profiles/v1`

A policy is composed from layers: the global layer, the repo policy, then every ledgered child project nested under the repo that contains the path, nearest last, to any depth. The outermost ledgered repo or worktree root containing a path owns it, whatever the ledger order. The global layer is `global.yml`, `profiles.yml` and `modules/<name>.yml` read from the `polispec.global.*` settings (see `docs/operator.md`). With no global source configured and no includes, verdicts are exactly those of the repo policy alone.

- `global.yml` (`polispec.global/v1`): `includes`, `rules`, `fallback_rules`, `gates` (`to_test`, `to_stable`), `preflight`, `freezes`, `hermetic`, `protected_roots` (`path`, `writers`).
- `modules/<name>.yml` (`polispec.module/v1`): `name` (equal to the file name), `params`, `includes`, `rules`, `gates`, `preflight`, `freezes`, `hermetic`.

### Module shelves

A module name resolves on one of two shelves:

- **Global shelf:** `modules/<name>.yml` under the `polispec.global.*` source, shared by every project on the host.
- **Project shelf:** `modules/<name>.yml` in the directory of the project's policy (normally `specs/polispec/modules/`), read from the same source as the policy: the trust ref, the bootstrap ref during promotion bootstrap, or the sibling directory of a policy file passed to `validate policy` or `POLISPEC_POLICY`.

A project module may include project and global modules; a global module sees only the global shelf. A name present on both shelves is an error (`module <name> is ambiguous`) and that include is not applied. Edits under `specs/polispec/` classify as `policy.edit`.

### Module parameters

```yaml
schema: polispec.module/v1
name: soak
params:
  hours: { type: integer, default: 24, summary: "minimum hours on test" }
gates:
  to_stable:
    - { id: G-SOAK, builtin: soaked, hours: "{{hours}}" }
```

- `params.<name>` (lowercase, digits, `_`): `type` (`string`, `integer`, `number`, `boolean`, `list`; required), `default`, `summary`.
- An include is a module name or `{ module: <name>, with: { <param>: <value> } }`. A parameter without a default must be given.
- A string that is exactly `"{{name}}"` becomes the typed value. `{{name}}` inside longer text is replaced by the value as text; a `list` cannot be used inside text. Keys are never substituted.
- A module's own `includes` are substituted too, so `with: { hours: "{{soak_hours}}" }` passes a parameter down.
- Each instance is validated against `polispec.module/v1` after substitution. An unknown, missing or mistyped parameter, an unresolved placeholder, or an invalid instance is an error and the instance is not applied.
- One module with different parameters gives separate instances, each expanded once per layer. Two instances in one layer that produce the same rule, gate or freeze id is an error.
- A layer digest covers each instance's text and resolved parameters.

### Nested projects

A child layer is built like the repo layer: the child's includes (from its own project shelf and the global shelf) come before its own rules. When the owning project is promoted, every nested project contributes its `promotion.to_test.gates`, `promotion.to_stable.gates` and `preflight`, its `freezes` and `hermetic`, and those of its modules. A gate a child contributes carries `dir` set to the child's path relative to the owner, so it runs in the child's directory. A contributed gate or freeze whose id is already defined by the owner or the global layer is an `id_collision` error and the child copy is not applied.

### Merging
- `profiles.yml` (`polispec.profiles/v1`): `profiles.personal`, `profiles.service`, `profiles.live`, each a list of module names. A ledger project gets its `profile` (default `personal`); a path outside the ledger gets only the global layer without profile modules. A policy may set `profile` only to a stricter one than its ledger entry.
- Within a layer rules stay first-match. A layer's included modules (depth-first, each once; a cycle or a missing module is an error) come before the layer's own rules. Across layers the strictest verdict wins (`deny`, then `warn`, then `allow`); on equal severity the lowest layer's rule is reported.
- A lower layer loosens an upper rule only when that rule has `overridable: true` and the lower layer's rule names it in `overrides`. Overriding a rule that is not overridable, or that no upper layer defines, is a validation error naming both rules, and the override is not applied.
- Layers merge `rules`, `gates`, `freezes` and `hermetic`, never `environments`. Inside the owner, the repo policy's own gate or freeze replaces a module's one with the same id.
- Every composition error (cycle, missing or ambiguous module, parameter error, duplicate instance id, id collision, invalid override) is reported by `validate`, `doctor` (`layers_invalid`) and `resolve --layers`, and makes `promote` refuse with `policy_invalid`.
- `fallback_rules` in `global.yml` replace the ledger `defaults.rules` as the repo layer of a project whose policy is missing at its trust ref. They never join the composed global layer. The pretool hook evaluates a live project in that state under them (or under `defaults.rules` when no global layer is configured), never with an internal denial. When `polispec.global.repo` is set and `global.yml` is absent or invalid, doctor and validate report it and the global layer contributes no rules; the repo layer still applies.

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

## Harness controls

`polispec.control/v1` is a separate deterministic control document, validated with `polispec validate control FILE`. It composes as a severity ceiling over environment policy in enforce mode. See [the grammar and lifecycle guide](harness-controls.md).

Policy, module, global, and ledger rule match objects accept the six exact-control selector keys above as nonempty strings bounded to 4096 characters. Only `path` is a glob; the others compare exact strings. Unknown selectors are invalid. A mutable overlay cannot remove the undeclared MCP default; a trusted committed policy or protected core must declare the actual matching server and operation. Every declared environment and selector must still match.
