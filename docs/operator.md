# Operator guide

`polispec promote` moves code between branches and `polispec deploy` puts a branch or tag into an environment checkout. Both read the project from the ledger and the promotion policy from the trust ref (`PolicySource.load`), never from the working tree. Both accept `--json` and `--dry-run`.

```
polispec promote <project> --to <env> [--waive-soak] [--dry-run] [--json]
polispec deploy  <project> <env> [--tag vX.Y.Z] [--skip-drain] [--dry-run] [--json]
```

`--json` prints one object. A failure is `{"ok":false,"error":{"code":"…","message":"…","payload":{…}}}` with exit status 1; a usage error exits 2. `--dry-run` runs every check and every gate and changes nothing.

## Git discipline

Project promotion Git runs through Open3 with exact argv, never a shell. The helper refuses `--force`, `--force-with-lease`, `+refspec`, `reset`, `--hard`, `--no-ff` and `--mirror`. Test and stable only ever move by a non-forced, atomic push of a fast-forward; no merge commit is created on either. Every comparison uses the remote-tracking refs after a `git fetch origin --prune --tags` in the project's repo, so unpushed local commits are never promoted. After the push the local `test` or `stable` branch is advanced with a compare-and-swap `update-ref` (or `merge --ff-only` when it is checked out), and skipped when another worktree has it checked out.

## promote --to test

Actor: `agent` or `operator`, checked against `promotion.to_test.actor`. Unsealed development recognizes its existing terminal flow; sealed operator actions require verified privileged launcher authority.

1. Fetch. `main_tip` is `origin/<from>`.
2. Drift: `origin/<stable>` must be an ancestor of `main_tip`, or the command fails with `drift` and the exact `git merge stable` to run on main (ADR-9).
3. `origin/<test>` must be an ancestor of `main_tip` (`not_fast_forward`) and not equal to it (`nothing_to_promote`).
4. `VERSION` at `main_tip` must exceed the highest `v*` tag when `requires_version_bump` is set (`version_not_bumped`); the tag `v{VERSION}` must not exist (`tag_exists`).
5. Preflight gates, then gates, run in order and the first failure stops the run.
6. Tag `main_tip`, then one atomic push of `main_tip:refs/heads/test` and the tag. A rejected push removes the local tag again.
7. Append a `PromotionRecord` to `promotions.jsonl`, emit `polispec.promote`.
8. When `release.github_prerelease` is true, run `gh release create <tag> --prerelease --title <tag> --generate-notes --verify-tag` in the repo.
9. Run each `after` entry. `polispec deploy <project> <env> [--tag t]` entries run in-process through the same code as the CLI; any other entry runs as an argv in the repo.

A failure in steps 8 or 9 happens after the promotion landed; the error payload carries `promoted: true`, `to_sha`, `tag` and `record_id`.

## promote --to stable

Operator only. Without `--dry-run` it needs an interactive terminal (`not_tty` otherwise). The sequence:

1. Fetch. `tip` is `origin/<from>` (test). `origin/<stable>` must be an ancestor of it and different from it.
2. `v{VERSION}` must exist and point at `tip` (`tag_mismatch`).
3. Gates run. `sha_ran_on_test` and `not_frozen` always run even when the policy omits them, so a stable promotion can never skip the test-health or freeze check.
4. `Polispec::Operator::Tty.confirm!(phrase)` with the policy phrase, `{project}` interpolated, after every check has passed.
5. Atomic push of `tip:refs/heads/stable`, record, event.
6. When `release.flip_latest` is `deferred`, run `gh release edit <tag> --prerelease=false --latest=false` and record `latest: deferred`. When it is true, run `gh release edit <tag> --prerelease=false --latest`; GitHub does not allow a prerelease to be Latest, so the flip also clears the prerelease mark.
7. Run `after`; the usual entry is `polispec deploy {project} stable --tag v{VERSION}`. A deploy started by an operator-confirmed promotion does not ask for a second phrase.

## Gates

Each gate is `{id, run}` or `{id, builtin}`. A `run` command is split with Shellwords and executed without a shell (only `$HOME`, `${HOME}` and a leading `~` are expanded in each word), in the project repo, with `{sha}`, `{VERSION}`, `{project}`, `{tag}` and `{stable_tag}` interpolated and `POLISPEC_PROJECT`, `POLISPEC_SHA`, `POLISPEC_VERSION` and `POLISPEC_TAG` exported. Exit 0 passes; a gate that runs longer than 900 seconds is killed and fails.

| Builtin | Passes when |
| --- | --- |
| `clean_tree` | the project repo has no uncommitted changes to tracked files and no untracked files that are not ignored |
| `version_homes_agree` | `VERSION`, every top-level `*.rplugin.yml`, `.codex-plugin/plugin.json` and `.claude-plugin/plugin.json` at the promoted sha carry the same version |
| `sha_ran_on_test` | `deploys.jsonl` holds a `test` deploy of that project and sha with `health: ok` (a `url` or `run` health check passed) |
| `not_frozen` | `Polispec::Freeze.active(policy, "promote.to_<target>")` is empty |

Errors from gates:

| Code | Payload |
| --- | --- |
| `gate_failed` | `gate_id`, `command`, `output_tail` (the last 40 lines of combined output) |
| `frozen` | `gate_id`, `freeze_id`, `until` |
| `untested_sha` | `gate_id`, `sha` |

## deploy

Environment checkouts are separate clones at `<envs_root>/<project>/<env>` (`envs_root` from the ledger, overridden by `POLISPEC_ENVS_ROOT`). The clone source is the ledger `remote`, or the repo's `origin` when the ledger has none.

- `test` follows the branch tip: `git checkout test` (tracking `origin/test`) and `merge --ff-only origin/test`.
- `stable` is a detached checkout of a tag. The tag is `--tag`, or the highest `v*` tag on stable's tip. It must be an ancestor of `origin/<stable>` (`tag_not_promoted`), so only promoted tags run in production.
- `stable` needs an interactive terminal and the typed phrase `deploy {project} to prod`, unless the call comes from an operator-confirmed `promote --to stable`. `prod` is accepted as an alias for `stable`. `--tag` on `test` is refused.

Then the policy's `deploy.steps` run in the checkout, one argv each (no shell; `$HOME`, `${HOME}` and a leading `~` are expanded), with `{sha}`, `{VERSION}`, `{project}`, `{tag}` interpolated and `POLISPEC_PROJECT`, `POLISPEC_ENV`, `POLISPEC_SHA` and `POLISPEC_VERSION` exported. A failing step stops the deploy (`deploy_step_failed`, with `output_tail`).

Since 0.12.0 `deploy.health.run` is a command health check for a project with no server, such as a plugin: one argv run in the checkout like a deploy step (no shell, the same interpolation, expansions and `POLISPEC_*` variables), with `timeout_s` as its timeout (1800 s by default). Exit 0 is `ok`, a non-zero exit is `failed` with the output tail, and a timeout is `timeout`. A block with both `run` and `url` runs the command first and polls the URL only when it passed.

Health polling GETs `deploy.health.url` once a second until `timeout_s` (60 by default). With `expect_version` the response must report the deployed `VERSION`: any value under a key containing `version` in a JSON body, or a version string in a plain body. Statuses: `ok`; `timeout` (no 2xx before the deadline); `failed` (answered 2xx but with another version, or a step failed); `unchecked` (the policy declares no health block; deploy steps alone never make a deploy `ok`). `unchecked` never satisfies `sha_ran_on_test`, so a project must declare a test health check to be promotable to stable.

Every deploy appends a `DeployRecord` to `deploys.jsonl` and emits `polispec.deploy`. After a successful deploy `state.yml` holds `deployments.<project>.<env>` with `tag`, `sha`, `pinned_behind` and `at`. `pinned_behind` is true when the deployed stable tag is older than the highest `v*` tag, and is cleared by the next deploy of a tag that is not behind. Errors: `health_timeout`, `health_failed`, `deploy_step_failed`, `checkout_conflict`, `tag_required`, `tag_not_found`, `tag_not_promoted`.

## Hermetic runs

`hermetic.<env>: { isolate: [VAR...], protected_roots: [path...] }` isolates the commands polispec runs for a stage: every deploy step, `deploy.health.run` and command gate. Each variable in `isolate` is set to `<scratch>/<variable lowercased>`, where `<scratch>` is a fresh 0700 directory `$POLISPEC_HOME/scratch/<record id>` (`~/.polispec` when `POLISPEC_HOME` is unset). The scratch directory is removed after the run only when it holds no files; otherwise it is kept and the deploy result reports it under `hermetic`. Before and after each such command polispec fingerprints every protected root: a sha256 over the sorted list of (relative path, size, mtime in nanoseconds) of every file under it, stopping at 200000 entries (the root is then listed in `hermetic.truncated`). A root that does not exist fingerprints as `absent`. Any change records health `failed` with the detail `wrote outside its location: <root>` and the deploy (or gate) fails. `drain` and `activate` commands are not isolated, and neither is a command gate that sets `hermetic: false`: it runs with the caller's environment and no protected-root fingerprint, for a check that must read the real install (a plugin manager's `check` or `doctor`, which appends to the install's own event logs). Its entry in the promote result carries `"hermetic": false`, so every opt-out is on the record. Use it only for a gate whose command is a read-only check of the installed copy; a gate that builds, tests or runs the project's code keeps the isolation.

## Release directories

`deploy.strategy: release_dirs` (default `in_place`) deploys tag `vX` like this:

1. Build `<envs_root>/<project>/releases/vX` as a fresh clone (`git clone --reference <current checkout> --dissociate` when the env checkout exists), detached at the tag. A test deploy has no tag choice; it names the release after the tag at the branch tip, or `sha-<12 hex>`.
2. Run `deploy.steps` there. A failing step stops the deploy with the live release untouched.
3. Run `deploy.drain` (pause, then wait).
4. Swap `<envs_root>/<project>/<env>` to a symlink to `releases/vX`: create a temporary symlink, then rename it over the old one. On the first run, when `<env>` is a real directory it is first renamed to `releases/<tag it has checked out>`, or `releases/pre-release-dirs-<stamp>` when that tag cannot be read or the name is taken.
5. Run `deploy.activate` (the restarts) with the symlink as the working directory.
6. Run the health check. When it is not `ok` and a previous release exists, the symlink is swapped back, `activate` runs again, health is polled again, and the record carries health `rolled_back` with the `failed` and `restored` results. The deploy fails with code `rolled_back`.
7. Run `drain.resume`, always, even after a failure in steps 3 to 6.

Since 0.37.4 a failing `resume` is retried up to three more times, 2, 4 and 8 s apart. The deploy record (`deploys.jsonl`) keeps the drain log: each pause, wait, check and resume attempt with its command, exit, and for a failed resume its directory and output tail. When the last attempt still fails, the queues are still paused: the record's `detail`, the result's `queues_paused`, the text output (`WARNING: queues still paused: …`), the promote line for the deploy and a failed deploy's error payload all name the exact resume command and the directory to run it in. A deploy whose health passed still exits 0. `polispec doctor` reports `drain_resume_failed` (warn) for each project and env whose latest recorded resume failed; a later deploy whose resume succeeds clears it, and running the command by hand does not, because polispec cannot see it.

`deploy.drain` is `{ pause, wait, checks, resume, timeout_s, run_in, env_from }`. `pause` and `resume` run once; `wait` runs until it exits 0 or `timeout_s` (default 300) passes, polling every 5 s. `checks` is a list of commands that run after pause and wait and before the swap (`release_dirs`) or the first step (`in_place`); the first failing check fails the deploy with `drain_check_failed`. A wait timeout fails with `drain_timeout`, a failing `pause` with `drain_failed`. Each of these runs `resume` and leaves the live release untouched. Both strategies drain: `in_place` drains before it checks out the new tag, so no candidate code runs.

Drain commands run in the env's active checkout (`run_in: active`, the default: `<envs_root>/<project>/<env>` resolved) with the env's `env_files` loaded (`env_from`, default the env being deployed); `run_in: repo` runs them in the project repo instead. When no active checkout exists yet, they run in the new release.

`polispec deploy <project> stable --skip-drain` skips the whole drain block for a first rollout, when the active release predates the drain commands. It needs an interactive terminal and the typed phrase `skip drain for <project>`; the deploy record carries `drain: skipped`. It is refused for `test`.

Retention keeps the 3 newest releases (ordered by the tag version they hold, `Gem::Version` of `vX.Y.Z`; names like `sha-*` and `pre-release-dirs-*` sort oldest) plus every release an env symlink points at, plus the release just replaced. An older release is removed only when `git status --porcelain --ignored` lists nothing but ignored paths under `vendor/` and `.bundle/`, which a tag reproduces; anything else is moved to `releases/.held/`. The result lists `kept`, `removed` and `held` under `retention`. `pinned_behind`, tag rules and phrases are unchanged.

## Where a gate runs

A command gate takes two optional fields. `run_in: repo|active` (default `repo`) chooses the working directory: the project repo, or the active checkout or release of the stage the gate belongs to (`test` for `promote --to test`, `stable` for `promote --to stable`; `<envs_root>/<project>/<env>`). `env_from: <env>` loads that environment's `env_files` (`KEY=VALUE` lines; blanks, `#` lines and a leading `export` are skipped, one pair of quotes around a value is stripped) into the command's environment; values are never logged or printed.

Constraint: a gate that touches a live database must use `run_in: active`. Some services migrate their database whenever any process boots, so main or candidate code must never run against the live database from a gate or a drain command. `active` runs the code that is already live.

## Soak, health-required and preflight

- `soaked` (gate option `hours`) passes when `deploys.jsonl` holds a `test` deploy of the sha with health `ok` recorded at least `hours` ago and no later `test` deploy of the same sha with another health. Failure code `not_soaked`.
- `health_required` re-runs, on the policy at the candidate sha, the check that an environment declaring `deploy.steps` or `deploy.activate` also declares `deploy.health` (`env <name> deploys without a health check; G-TESTED can never pass`). The same check (`Gates.health_required_errors(policy)`) runs whenever the operator loads a project, so promote and deploy refuse such a policy with `policy_invalid`. A related check, `Gates.unreachable_errors(policy)`, finds a promotion gate (`sha_ran_on`, `sha_ran_on_test`, `soaked`, and the implicit G-TESTED on the stable hop) or an `after` step (`polispec deploy <project> <env>`) that needs a deploy in an environment which declares no `deploy` block, so the gate can never pass. It is report-only: `polispec doctor` and `polispec status` report it as a `gate_unreachable` finding (blocking in doctor), `polispec validate policy` reports it at `/promotion`, and `polispec plan project:<id>` prints it under `notes`; promote and deploy behave as before.
- `polispec promote <project> --to <env> --waive-soak` skips every `soaked` gate of that promotion and reports it as `waived`; every other gate still runs. It needs an interactive terminal and the typed phrase `waive soak for <project>`, asked before any gate runs and ahead of the promotion phrase. It is refused for `--to test` (`waive_soak_unsupported`) and when the promotion has no `soaked` gate (`nothing_to_waive`); with `--dry-run` it previews `waived` without asking. The promotion record and its `polispec.promote` event carry `waived: [soak]`.
- `promotion.to_stable.preflight` gates run first, ahead of the other gates and the phrase prompt.

## Environment names and promotion hops

Environment names come from the policy. `dev`, `test` and `prod` always exist; a policy may declare more under `environments` (for example `canary`), each with a `tier` of `dev`, `test` or `prod` that keeps its meaning for rules, data classes and `hermetic.<tier>`. The name `stable` is the operator-facing alias of `prod`: `promote --to stable`, `deploy <project> stable`, deploy records and `promotion.to_stable` all use it.

A hop is `promotion.to_<env>` for any declared env, each with `from:`, so `main -> test -> canary -> stable` is `to_test` (from `main`), `to_canary` (from `test`) and `to_stable` (from `canary`). `to_test` keeps its tag-and-push flow. Every other hop behaves like `to_stable`: the `from` branch's tip must carry the `v{VERSION}` tag, the target branch must be an ancestor of it, then the gates run and one atomic push moves the target branch. For a hop other than `to_stable`, the actor list is checked against the caller (an agent on a dry run is always allowed), and a declared `phrase` needs an interactive terminal and the typed phrase. `to_stable` is unchanged: operator only, terminal, phrase, and the implicit `G-TESTED` and `G-FREEZE` gates. The implicit `G-TESTED` (`sha_ran_on`, env `test`) is skipped when the hop lists its own `sha_ran_on` or `sha_ran_on_test` gate.

`polispec deploy <project> <env>` deploys any declared non-dev env. An env other than `test` checks out a promoted tag on its branch, unless it sets `runs: branch`; one other than `test` asks for the `deploy <project> to <env>` phrase unless a promotion confirmed it. A deploy to an env of tier `prod` records `pinned_behind`. Deploy records carry `env` as the name (`stable` for `prod`).

- `sha_ran_on` (gate option `env`, default `test`) passes when `deploys.jsonl` holds a deploy of the sha in that env with health `ok`. `sha_ran_on_test` is its alias with `env: test`. Failure code `untested_sha`.
- `soaked` takes the same `env` option (default `test`).
- `promotion.to_<env>` keys and gate `env` options that name an env the policy does not declare are a `policy_invalid` error.

## logs_quiet

`logs_quiet` compares log volume after a deploy with the same-length window before it. Options: `services: [name...]` (required), `window_minutes` (default 120) and `max_over_baseline` (default 0). It measures from the newest healthy deploy of the candidate sha in the env the hop promotes from (the env whose name or branch equals `from`; `test` when none matches). For each service it runs the argv template in the setting `polispec.logs.count_command` without a shell, once for `[deploy, deploy + window)` and once for `[deploy - window, deploy)`. `{service}`, `{since}` and `{until}` are replaced in each word (UTC ISO 8601 times), a leading `~` and `$HOME` are expanded, and the command must print one integer. The gate fails when `after` exceeds `before + max_over_baseline` (`logs_not_quiet`, listing each service) and when less than `window_minutes` have passed since the deploy (`logs_in_window`). An unset setting, or a command that fails, times out (60 s) or prints a non-integer, fails the gate closed (`gate_failed`, with the reason). `RPLUGIN_POLISPEC_POLISPEC_LOGS_COUNT_COMMAND` sets it for a scratch run.

## requires_live

`requires_live` passes when the newest prod deploy record (`env` `stable`) of another project in `deploys.jsonl` has health `ok` and a tag whose version is at least the minimum. Options: `project` (required) and the minimum as `min_version` (for example `0.80.4`), or as `min_version_from` (a path in the candidate tree) with `min_version_key` (a dotted key in that YAML or JSON file). Failure code `not_live`, or `gate_failed` when the minimum cannot be read.

## Profile checks

`Polispec::ValidateProfiles.errors(policy, entry)` runs wherever the operator loads a project (`policy_invalid`) and in `polispec doctor` (finding `profile_check`). The profile is the `profile` field of the ledger entry, default `personal`.

- `personal_no_warn` (every project): a rule with verdict `warn` in a module the global layer's `personal` profile selects is an error.
- `version_reported` (profile `service` or `live`): an env with `deploy.health.url` and `expect_version` false or absent is an error, `env <name> health does not prove the deployed version`.
- `protected_writers` (profile `service` or `live`): a deploy step or `activate` command that the classifier says writes or deletes under a protected root of the global layer, whose `writers` do not include the command's `argv[0]` basename, is an error. Writes inside the project's own env directory and commands the classifier cannot place (it marks them unknown) are not reported.

The global layer is read from `POLISPEC_GLOBAL`, a plain directory holding `global.yml` (with `protected_roots: [{ path, writers }]`), `profiles.yml` and `modules/<name>.yml`. With no global layer, the roots are `[]` and `personal_no_warn` finds nothing.

## Freeze source `command`

A freeze with `source: command` runs its `command` argv in the prod checkout of its `project` (default the policy's own project), with a 5 s timeout, a 300 s cache and the findings described in `docs/schema.md`. The output is `{ "windows": [{ "kind", "from", "until", "detail" }] }`; a window covers now from `from` (less any lead) until `until`, and the window's `detail` shows in the freeze label. When the freeze sets `kind`, only windows of that kind apply. `source: teach.activity` is a deprecated alias for `command: [bin/teach, activity, --json]` without the kind filter; `source: teach.calendar` is a deprecated alias for `command: [bin/teach, calendar, freezes, --json]` with it.

## Other error codes

`policy_invalid`, `not_soaked`, `drain_timeout`, `drain_failed`, `drain_check_failed`, `skip_drain_unsupported`, `waive_soak_unsupported`, `nothing_to_waive`, `env_file_unreadable`, `unknown_env`, `rolled_back`, `release_conflict`, `clone_failed`, `not_tty`, `confirmation_failed`, `actor_denied`, `drift`, `not_fast_forward`, `nothing_to_promote`, `version_not_bumped`, `tag_exists`, `tag_mismatch`, `missing_ref`, `push_rejected`, `release_failed`, `after_failed`, `locked` (another promote or deploy of the same project holds its lock), `policy_unavailable`, `unknown_project`, `retired_project`, `repo_missing`, `invalid_target`, `invalid_env`, `logs_not_quiet`, `logs_in_window`, `not_live`, `untested_sha`, `invalid_tag`, `tag_unsupported` (`deploy <project> test --tag` is refused because test deploys follow the branch tip; `--tag` applies to stable only), `no_deploy`, `no_remote`.

## Events and records

`polispec.promote` carries `project, to, from_sha, to_sha, tag, actor, gates, waived, result, duration_ms` (`waived` only when `--waive-soak` was used); a failure emits it with `result` set to the error code. `from_sha` in a record is the target branch's previous tip, or forty zeros when the branch is created. `polispec.deploy` carries `project, env, sha, tag, steps, health, pinned_behind, actor, result`.

## Scratch use

Point `POLISPEC_LEDGER`, `POLISPEC_HOME`, `POLISPEC_GLOBAL`, `POLISPEC_STATE_HOME` and `POLISPEC_ENVS_ROOT` at scratch directories and a bare remote; nothing else is read or written. Do not redirect `XDG_STATE_HOME`: it hides the rplugin settings and, without `POLISPEC_STATE_HOME`, scratch runs write the live guard's state.

## Settings and host wiring

polispec reads these machine settings. Unsealed, each comes from the first of: its `RPLUGIN_POLISPEC_*` environment variable, its short `POLISPEC_*` variable (`polispec.enforce` is `POLISPEC_ENFORCE`; `polispec.operator` is `POLISPEC_OPERATOR_NAME`, because `POLISPEC_OPERATOR=1` already marks operator git; `polispec.edition` has none), the rplugin settings snapshot, the polispec settings file (`POLISPEC_SETTINGS`, else `$XDG_CONFIG_HOME/polispec/settings.yml`, written by `polispec settings set`), then the default. Sealed, only the plane's settings count. A change to the settings file invalidates the guard's fast path like a change to rplugin's.

| Setting | Default | Meaning |
| --- | --- | --- |
| `polispec.enforce` | `advise` | `advise` logs every verdict and never blocks; `enforce` applies allow, warn and deny. |
| `polispec.ledger` | `~/.config/polispec/ledger.yml` | Path of the ledger of governed projects. `POLISPEC_LEDGER` overrides it. When the setting is absent, `$XDG_CONFIG_HOME/polispec/ledger.yml` is used. |
| `polispec.operator` | `the operator` | How deny and next-step messages name the person who promotes to stable and redeems allow-once, for example `Only the operator moves production: ask the operator to run ...`. |
| `polispec.code.specs_repo` | `~/polispec-specs` | Path of the code specs repository. `POLISPEC_SPECS_REPO` overrides it. |
| `polispec.global.repo` | unset | Path of the git repository that holds the global layer. Unset means no global layer. `POLISPEC_GLOBAL`, a plain directory, overrides it and the two settings below, for scratch runs. |
| `polispec.global.ref` | `main` | Ref of that repository the layer is read from with `git show`; the working tree is never read. |
| `polispec.global.path` | `polispec` | Directory inside the repository that holds `global.yml`, `profiles.yml` and `modules/`. |
| `polispec.logs.count_command` | unset | Argv template (no shell) for the `logs_quiet` gate; takes `{service}`, `{since}` and `{until}` and prints one integer. Unset fails the gate closed. `RPLUGIN_POLISPEC_POLISPEC_LOGS_COUNT_COMMAND` overrides it. |
| `polispec.notice` | `on` | `off` stops the in-band epoch notice (see [When a change lands](#when-a-change-lands-the-epoch-notice)). |
| `polispec.description.strict` | `off` | `on` turns the description lint warnings of `polispec validate` into errors (exit 1). |
| `polispec.lint.on_write` | `on` | `off` stops the write gate: a generator's output is no longer linted before it is written. `POLISPEC_LINT_ON_WRITE=off` does the same for one run while unsealed. |
| `polispec.lint.doctor` | `on` | `off` stops `polispec doctor` from filing the host-scope lint findings (`lint_<code>`). |
| `polispec.lint.strict` | `off` | `on` makes a warning finding fail `polispec lint` (exit 1), as `--strict` does. |
| `polispec.records.raw` | `off` | `on` adds the classifier's raw view of the judged command or target, at most 2048 bytes, to each judgment record in local state; `off` keeps only the call digest. Raw text never goes through the events port. |

The guard is a hook in each agent harness. The plugin ships `hooks/polispec.hooks.yml`, which rplugin renders for Claude Code (installed natively since 0.22.0; needs rplugin 1.15.0 for `SubagentStart`), Hermes, Pi, the DeepSeek TUI and Antigravity CLI. Every hook runs `bin/polispec-guard <pretool|session> --harness <name>`, a bash shim that:

- skips starting Ruby when the fast path (`fastpath.txt` and its `fastpath.watch` list in the polispec state directory) shows the call cannot touch a governed path and none of the watched files (ledger, global layer refs, settings, `/etc/polispec/active.json`) changed since, and appends one line for the skipped call to `skips.jsonl` in that directory (tool, session, fast-path key, `no_needles` or `no_match`) with bash builtins only;
- otherwise runs `polispec hook <mode> --harness <name>` and prints the harness's own allow, ask or deny reply, with the exit status the harness reads it by (since 0.33.1 a Hermes block keeps its exit status 2; before, the shim read it as a failure and let the call through);
- runs the first `polispec` it finds in this order: `POLISPEC_BIN`, `PATH`, `~/.local/bin`, the rplugin store, the native pin (`<data home>/current/bin/polispec`), and only then the copy beside the shim in a harness's plugin cache, so a pinned release always wins over a cached copy and a plain plugin install still runs the real guard;
- fails closed since 0.33.2: when polispec is missing, exits with anything but a well-formed reply, or does not answer within 8 seconds (`POLISPEC_GUARD_DEADLINE`, an integer from 1 to 9, overrides it), it denies every tool call except the read tools (`Read`, `NotebookRead`, `read_file`, `view`, `grep`, `search_file_content`, `read_many_files`, `view_image`) with the same reply and exit status the hook uses for its own internal denial on that harness, and lets reads through. A harness name polispec does not know gets exit 2 and a stderr reason. In session mode a failure never blocks. Each such event is appended to `launcher.jsonl` in the polispec state directory with its cause (`no_binary`, `timeout` or `exit_<status>`) and whether the call was denied or passed. There is no setting that turns this off; recovering a broken guard is the user's own prompt.
- bounds the hook's input: the shim reads at most 8 MiB plus one byte, and the hook denies a call whose input passes 8 MiB with a reason that names the size (`hook input exceeds 8 MiB; call denied. Split the change into smaller calls.`). The hook's own time budget is 7 seconds, so it answers inside the shim's deadline.

### The resident judge

Since 0.38.0 the launcher asks a resident judge before it starts Ruby. `polispec judge serve` keeps one process on `127.0.0.1` (an ephemeral port) and records the port, a token generated for that start, its pid, its runtime directory, its version and its start time in `judge.json` in the polispec state directory (mode 0600). The launcher reads that file, opens the port with bash's `/dev/tcp`, sends the hook input behind a one-line `POLISPEC/1` header carrying the token, and prints the reply when the status is 0, or 2 with a JSON object in pretool mode. The reply is what the cold path would have printed, and the judge appends the same chained journal record.

- the judge answers only a request that carries its token, refuses a header over 512 bytes and a payload over 8 MiB, and answers a request from another runtime directory with `stale` and exits, so an upgrade is picked up on the next call.
- it keeps the ledger, the global shelf and each live project's policy in memory and reloads them only when a content key changes: the ledger bytes, the rplugin and native settings files, `/etc/polispec/active.json`, the runtime version, the shelf (its files, or the commit its ref points to) and each live project's trust-ref commit. A ledger edit, a shelf commit or a trust-ref move therefore changes the next verdict with no restart; `judge.log` records `key_changed` for the request that saw the change.
- on any other outcome (no `judge.json`, connection refused, no reply within `POLISPEC_JUDGE_BUDGET` seconds, default 0.5, a wrong token, a stale or busy judge, a malformed reply) the launcher appends a `launcher.jsonl` row with the cause `judge_<reason>` and the decision `pass`, then takes the cold path exactly as before. A missing or dead judge is started detached, at most once per 30 seconds (`judge.spawn`).
- since 0.45.2 a judge that accepted the request but has not answered inside the budget is waited for on the same connection, up to `POLISPEC_JUDGE_WAIT` seconds after the request (an integer from 0 to 8, default 6, always below the launcher deadline, `POLISPEC_GUARD_DEADLINE`, default 8; `0` restores the earlier behaviour). The judge answers one request at a time, and callers that gave up after 0.5 seconds each started a cold Ruby, so while the judge was slow (requests of 3 to 14 seconds were logged under heavy host load) the herd of cold starts could pass the 8 second deadline and deny calls with `guard unavailable`. A reply inside the window is served as usual and logged with the cause `judge_slow` and the decision `pass`. When the wait ends without a usable reply the cold path runs under the deadline less the seconds already waited, rounded up to whole seconds and never below 1 second, so the launcher still answers within the harness's 10 second limit.
- `POLISPEC_JUDGE=off` skips the judge. `POLISPEC_JUDGE_IDLE` (seconds, default 1800) ends a judge that has seen no request, which removes `judge.json`. `polispec judge status` prints the recorded fields and whether the port answers; `polispec judge stop` ends it. The budget default is 0.5 so that the budget, the 8 second deadline and one second of margin stay below the 10 second harness timeout of the hook.
- each request appends a row to `judge.log` (rotated at 1 MiB): `ts`, `mode`, `harness`, `tool`, `status`, `duration_ms`, `key_changed`, `via`.

Without rplugin, `polispec install --harness claude|codex [--scope user|project]` writes the same three hooks into `~/.claude/settings.json` (or `<project>/.claude/settings.json`) or as one marked block in `~/.codex/config.toml` (or `<project>/.codex/config.toml`), pointing at `<data home>/current/bin/polispec-guard` when a native pin exists. It links the skill and, at user scope, the rules (`~/.claude/rules/polispec/`). It backs each changed file up beside itself as `<file>.polispec-backup-<timestamp>` and keeps every hook it did not write. Its receipt goes to `installs/` under the polispec state directory. It refuses, unless `--force`, when the polispec Claude Code or Codex plugin is already enabled, because the guard would then run twice. `polispec uninstall` removes only the marked hooks and the links it made. Since 0.41.0 every installer also records its target in `deployments.json` under the state directory (`polispec deployments [--scan]` lists them with a live status), and `polispec uninstall --all [--keep wiring,pins,rplugin,data] [--dry-run]` removes every deployment in the order controls, hooks, git hooks, rplugin, pin, data, after copying each file it will change into `<data home>/backups/<id>/` and moving the ledger, settings file and state home into it; the real run needs a terminal and the typed phrase `uninstall polispec`. `polispec restore <id> [--mode rewire|bytes] [--dry-run]` and `restore --list` put it back (phrase `restore polispec`); `uninstall.sh` runs the dry run and then the real uninstall. It writes no Codex trust hash, so Codex asks the user to trust the new hooks. The Claude Code and Codex plugin marketplaces (`SteveBenner/polispec`) are the other path; they bring the hooks and the skill but no rules and no `PATH` entry. A host with the `~/.ai` Codex bridge calls the same shim through the bridge, which also parses `apply_patch` targets and adapts the reply. Any other harness can call the shim from its pre-tool event. Two integrations are optional and never required: events may be emitted to an `rlogs` sink (`observability.events: rlogs`, otherwise `local` or `none`), and `polispec apply environment-control` recognises a `*.rstack_component.yml` manifest as well as `*.rplugin.yml` when it adds a `serves:` pointer.

## Linting generated files

`polispec lint [PATH...] [--host] [--shipped] [--only RULE[,RULE]...] [--strict] [--json]` is read-only. It judges every file with the loader the guard uses (`YAML.safe_load`, aliases refused), so it reports what that loader refuses and what it accepts silently. `validate` stays the single-file schema check.

- Project scope (the default; the git toplevel of the working directory, or each directory operand): files found by their `polispec.` schema id, the fixed `specs/polispec` files with the kind their name demands, the `[ENVS]` row of `AGENTS.md`, `.agents/directives/envs.md`, behavior v2 surfaces and `polispec.manifest.json`.
- `--host` adds the ledger, the global shelf as the guard reads it, `deployments.json`, `delegate/grants.yml`, the settings file (hygiene only), the published index, the harness-control installations the current user owns (file integrity only), and the working tree of every non-retired ledger project.
- `--shipped` judges the running release tree against the ordered table in `lib/polispec/lint/shipped.rb`. Expected on a clean tree: three `description_missing` warnings (`catalog/delete-guard/protected.yml`, `catalog/tools/declared.yml`, `packages/environment-control/package.yml`) and one `file_too_large` info for `smoke.yml`, which is over the 5 MiB cap on purpose.

Rules and codes. Schema: `schema_invalid`, `schema_kind_mismatch` (errors), `schema_unrecognized` (warn). Hygiene errors: `yaml_syntax`, `json_syntax`, `yaml_duplicate_key`, `json_duplicate_key`, `yaml_alias`, `yaml_multiple_documents`, `text_invalid`. Hygiene warnings: `text_final_newline`, `yaml_tab`, `yaml_bom`, `yaml_crlf`, `yaml_trailing_space`, `yaml_no_final_newline`, `yaml_bool_word`, `yaml_non_string_key`, `target_unreadable`. Hygiene info: `file_too_large`. Drift errors: `agents_drift`, `behavior_surface_drift`, `harness_artifact_drift`; drift warning: `manifest_drift`. Refs errors: `version_disagree`, `schema_ref_missing`, `schema_file_missing`, `package_source_missing`; refs warnings: `ledger_repo_missing`, `ledger_path_missing`, `shipped_unclaimed`, `shipped_row_unmatched`; refs info: `too_many_files`. Description: `description_<code>` (warn, error while `polispec.description.strict` is on). `--only` takes `schema`, `hygiene`, `drift`, `refs`, and `description`.

Exit codes: 0 when no error finding results (and no warning with `--strict` or `polispec.lint.strict` on), 1 otherwise, 2 on usage. `--json` prints `{ ok, targets, counts, findings }`.

The write gate. With `polispec.lint.on_write` on (the default) the hygiene and schema rules run on a generator's output before it is written. An error finding raises `lint_failed`, lists the problems, and writes nothing. Gated: `apply` on the project, global, and ledger targets, the starter ledger, registration proposal files, `polispec.manifest.json` and the host index, `exceptions.yml`, the deployments manifest, the delegate grants file, the rubocop base of `code generate`, and the hygiene pass over rendered package templates; `agents render` and `behavior render --write` are checked as text: invalid UTF-8 or a NUL byte refuses the write, and a missing final newline is only a warning, because the generators may write such a file. `polispec.lint.on_write off` restores 0.41.1.

Doctor. With `polispec.lint.doctor` on, `doctor` runs the host scope without the description rule and files each finding as `lint_<code>` against the ledger project that owns the path: an error blocks, a warning and an info do not. It skips the ledger and exceptions schema checks, the agents drift check, and `manifest_drift`, because doctor already reports those or composing a manifest runs doctor. Lint reads each project's checkout, while the other doctor checks read the trust ref, so a defect that exists only on the dev branch is filed as `lint_<code>` and blocks until it is fixed; a schema error that doctor already reports as `layers_invalid` or `gate_unreachable` for the same project is not filed a second time. A failure of the step files `lint_unavailable` (info).

Limits. A clean sweep proves schema acceptance, loader-safe YAML, and agreement between a generated file and its source; it does not prove that policies compose safely or that a harness enforces anything. Harness integrity is file integrity only; no native probe runs. Markdown generators are checked for text validity only. `manifest_drift` compares identity, status, mode, and digests, not findings, promotions, or timestamps. Lint reads the working tree, so an uncommitted edit is judged and the trust ref is not; `doctor` remains the check of what the guard reads.

## Watching an operation: --verbose

An operation prints one summary when it ends. `--verbose` (also `--verbose=text`, `--verbose=json`, `-v`) streams what it does while it does it, so a promotion, a deploy, `exceptions add` or `uninstall --all` can be watched instead of waited for. `POLISPEC_VERBOSE=1|text|json` does the same for one process (the flag wins; `0`, `false`, `off` or empty is off). Any verb takes the flag except `hook` and `code-hook`, which ignore both the flag and the variable so the guard never writes to stderr because of them. The exception is `hook git install` and `hook git uninstall`, which are installers and do take it; `hook git pre-commit` and the other git hooks stay silent.

The trace goes to stderr and nowhere else. What an operation prints on stdout, its `--json` document and its exit status are the same with and without the flag, and without the flag nothing is traced. A line looks like this:

```
[   12.3s]   > gate G-CLEAN
[   12.4s]     $ git status --porcelain
[   12.4s]     = exit 0 in 98 ms
[   12.4s]   + gate G-CLEAN (112 ms)
```

`>` opens a step and `+` closes it with its duration, `!` closes it failed with the reason, `-` is an information line with `key=value` fields, `$` is a command, `=` its exit status, `|` is a line of the child's stdout and `2|` of its stderr, and `#` marks the start and the end of the run. Indent is nesting. A child's output appears line by line as the child writes it, so the test deploy of a promotion shows the smoke suite's progress; a read-only git call shows its command and a one-line summary instead of its output.

What it covers, by group:

- Promote and deploy: project and policy load, every git call, each gate with its result, the plan (shas, version, tag), the typed-phrase wait, the tag, the atomic push, the release call, each after step, and for a deploy the checkout, the drain phases, each step, the activation, every health poll, a swap and a rollback.
- Rulebook changes: `exceptions add|promote|remove` (preflight, the new entry, validation, the wait, the write, the plan and apply of the global shelf, the commit, the change record), `plan` and `apply` for every target, `register`, `unregister`, `settings`, `manifest --write`, `agents render`, `behavior render`, `specs`, `roster`, `pause`, `allow-once`, `delegate grant|revoke`, `code`.
- Install lifecycle: `pin`, `install`, `uninstall`, `uninstall --all`, `restore`, `steward`, `deployments --scan`, `harness`, `seal`, `plane`, `hook git install|uninstall`.
- Diagnostics: each `doctor` check, each `lint` target, `status`, `digest`, and `smoke run` scenario and step (a passing step's output is counted, a failing step's output is shown).

`--verbose=json` writes the same events as NDJSON, one object per stderr line: `{v: 1, ts, t, depth, event, ...}` with the events `begin`, `step` (`phase` start or end), `info`, `command`, `exit`, `output` and `end`. Keys are added, never renamed or removed, within `v` 1. A reader can follow a run with `polispec promote shop --to test --verbose=json 2>&1 >/dev/null | jq -c .`.

The trace file. While a run is verbose and `polispec.verbose.trace` is on (the default), the same trace is written to `<state home>/trace/<UTC stamp>-<verb>-<pid>.log` (`.ndjson` in JSON mode), directory 0700, file 0600, and the end line names it. A file stops at 8 MiB with one closing line. At the start of a verbose run, files older than 14 days are removed and the oldest beyond 64 are removed. The file is written only when the state home already exists, so a verbose run never creates it (this keeps `restore` after `uninstall --all` from finding a state directory it would have to treat as a conflict). An unwritable or missing state home never fails the run.

What it never prints. Environment values and env-file contents, delegate app tokens, the web launch secret and the answer typed at a confirmation prompt; the phrase to type is printed, since it is already on screen. A command is printed as the operator ran it, and child output is printed as the child wrote it, so a step that prints a secret on its own would show it, and the trace file would keep it. That is why the file is 0600 and why `polispec.verbose.trace off` exists.

Delegation. `--verbose` is a grantable flag: `polispec delegate grant ... --flags --dry-run,--json,--tag,--verbose` lets an application pass `--verbose` or `--verbose=json` to `promote` or `deploy`. The default grant flags are unchanged, so an existing grant does not stream. The runner already keeps both streams in the run log that the application reads by offset (`output {run_id, offset}`), so the stream reaches the application with no new protocol.

The guard. `polispec doctor --verbose` and `polispec --verbose status` stay benign reads, and `polispec --verbose promote shop --to stable` or `polispec promote shop --to stable -v` is still the promotion to prod it was: the flag changes neither what is classified nor what is asked.

Limits. A trace is a record for the person at the terminal, not an audit log: it is not chained, not sent to the events port and not read by the guard, `doctor` or any consumer. A bare `-v` that is the value of another flag is read as the flag; write `--note=-v` to pass such a value, and name `--verbose` in a grant as part of a comma list (`--flags --dry-run,--verbose`). A runtime older than 0.44.0 rejects `--verbose` as an unknown flag (exit 2), so an application must not pass it to a delegate runner on an older host. A run that is killed leaves a trace file without its end line.

## Judgment records

Every call that reaches the guard leaves one record in `judgments.jsonl` under the polispec state directory (`polispec.judgment/v1`, `docs/schema.md`): what was judged (tool, harness, event, session, home-relative working directory, and a `call_digest` over the tool, its arguments and the working directory), against which rulebook (one target per governed project or global baseline the call touched, with the policy source and digest, the matched rule and one row per classified action), by which polispec (version, runtime kind, commit, tree digest when pinned, edition, enforce mode, plane status, fast-path key), and what the harness was told (the composed verdict, rule, rendered decision and duration). Allows are recorded as well as warns and denies. A guard that fails closed records `POLISPEC-INTERNAL` and the error class. Git hooks record with harness `git`; the session hook records nothing.

Records are chained (`prev`, `digest`), appended under `judgments.lock`, anchored in `judgments.head.json`, and rotated at 16 MiB to `judgments.<timestamp>.jsonl`. `polispec judgments list [--since 24h] [--session ID] [--project ID]` shows them, `show <id>` prints one, and `verify` walks every file against the anchor and exits 1 on a digest mismatch, a broken chain or truncation; `doctor` reports the same as `judgments_chain_broken` and `judgments_truncated`. A hook process killed after it wrote a record and before it moved the anchor leaves the anchor one record behind; since 0.30.1 the next append notices, chains to the record that is there and counts it, so nothing forks. Streams written before 0.30.1 can hold such forks (a record with the same `prev` as the record before it): `verify` lists them as `interrupted_append` beside the findings, prints `chain ok; N interrupted appends`, and exits 0, and `doctor` stays silent about them. Until the next append re-anchors it, an anchor that is one append behind still reads as `truncated`. `polispec digest` and `polispec plan` read the stream. A copy of each record without raw text goes through the events port as `polispec.judgment`; the local file is the system of record.

A default record holds no command text, file contents or environment values. `polispec.records.raw` on adds the classifier's raw view, bounded to 2048 bytes, to the local record only. Recording never changes a verdict: a failed append emits a `judgment_unrecorded` finding. The shim's skipped calls are counted in `skips.jsonl` beside the stream and reported by `judgments verify`; they are not chained. A record proves what polispec judged and replied, not that the harness obeyed the reply, and it carries no harness version.

## The runtime and stewardship

The polispec that runs the guard is the polispec judging every agent call on the host, so it is protected from the agents it judges. `polispec doctor` prints which runtime is running (`runtime: <kind> <commit> <root>`):

| Kind | What it is | Writes into it |
|---|---|---|
| `pinned` | A read-only release made by `rplugin install <repo> --ref <tag>` under the plugins home's `.pinned/polispec/<commit>/` with `.rplugin-release.json`, or by `polispec pin --ref <tag>` under `<data home>/releases/<commit>/` with `.polispec-release.json` (`doctor` prints `pinned (native)`); either file records the commit, the source and a tree digest. The data home is `POLISPEC_DATA_HOME`, else `$XDG_DATA_HOME/polispec`, else `~/.local/share/polispec`. | Denied (`R-POLISPEC-RUNTIME`); only the pinning tool writes there. |
| `clone` | A working git clone linked as the plugin. | Warned (`R-POLISPEC-RUNTIME`): the clone is the live guard. |
| `sealed` | The sealed plane's `/usr/local/lib/polispec/releases/<commit>`, described below. | Protected by the sealed plane. |
| `unknown` | None of the above. | No built-in protection. |

`polispec steward` (or `polispec apply --with-stewardship` before an apply) arms this for a host, and `polispec steward --check` reports whether it is armed: it makes sure the installed plugin ships the stewardship rule (reinstalling from the running tree with `rplugin install <runtime root>` when not), checks the runtime protection, and pins a clone runtime to the tag of the version it is running (`rplugin install <clone> --ref v<VERSION>`), skipping each step that is already in place and stopping before the apply on any failure. On a host without rplugin the same steps run natively: step 1 links `polispec.md` and `polispec-stewardship.md` into `<claude home>/rules/polispec/` (or reports that there is no Claude Code home), and step 3 runs `polispec pin --ref v<VERSION>`. `polispec pin` archives the tag from the running clone, the source a pinned release records, or, from a plugin cache or a gem, a bare fetch of the public repository kept at `<data home>/source.git`. It makes the copy read-only, swaps `<data home>/current` atomically, and links `~/.local/bin/polispec` unless that path already belongs to something else. A pinned host upgrades by releasing and pinning or reinstalling with a newer `--ref`; the earlier release stays under `.pinned/` or `releases/` as the rollback. The rule agents follow for all of this is `rules/polispec-stewardship.md`.

The 0.18.0 construction release kept both feature flags disabled. Since 0.23.0 harness controls are enabled; since 0.45.1 the sealed-plane capability is enabled by operator direction. The setup procedures below still require authenticated operator execution and their own activation decision; publishing or installing a release performs none of them.

## Sealed authority and harness controls

Unsealed development retains environment and XDG overrides and its existing terminal confirmations. Those conveniences are not operator authentication. A sealed plane resolves the fixed `/etc/polispec/active.json` authority first, verifies its generation and digests, and ignores user-controlled redirects for authority, settings, ledger, layers, runtime, and code specs. Reports name ignored variables without exposing their values. An invalid existing seal remains broken and cannot fall back to unsealed settings.

Protected actions require effective root identity and verified ancestry through the pinned launcher, interpreter, plugin release, and separately protected rplugin SDK. A TTY, an environment variable, or a user-owned executable cannot supply that authority. Sealed policy remains an independent ceiling even when the legacy environment guard is paused.

The source layout contains `ledger.yml`, one or more `controls/HARNESS.json` documents, the required `catalog/active.yml` snapshot with any referenced provisioned files beneath `catalog/`, optional `settings.json` as a flat machine-setting map, and optional global and code-spec trees. Since 0.45.1 the catalog snapshot is schema-validated, known active subspecs are checked, and provisioned files are required to match their recorded digests and existing provisioning rules. An active plane resolves catalog decisions only from this protected generation; a missing protected catalog binding fails closed. Standard seals an exact committed Git source; dirty worktree bytes do not enter the generation. Lock uses the root-authored `/etc/polispec/source` tree and records that provenance honestly.

```sh
polispec seal --from /absolute/source-repo@FULL_COMMIT --dry-run --json
polispec seal --source /etc/polispec/source --dry-run --json
polispec plane status --json
polispec plane verify --json
```

Preparation and switching are explicit operator actions. Use the prerequisite findings to establish the protected SDK/runtime and native evidence before requesting a seal. The implementation can prepare a generation while reporting activation blocked; neither a prepared generation nor a dry run means the plane is active. Sealing and lock certification are Linux-first, and unsupported platforms refuse the guarantee.

Pinned releases live under `/usr/local/lib/polispec/releases/COMMIT`, with launchers under `/usr/local/lib/polispec/launchers/COMMIT/polispec`. Generation files remain readable to guards and writable only by the operator. The SDK is an independently protected dependency, not a copy bundled into polispec.

New projects that serve real users remain `onboarding` until a verified plane and its authenticated operator activate them:

```sh
/absolute/pinned/launcher plane activate PROJECT_ID --dry-run --json
/absolute/pinned/launcher plane activate PROJECT_ID --json
/absolute/pinned/launcher plane rollback OPERATION_ID --dry-run --json
```

Run protected commands through the actual active launcher with the required privilege and terminal confirmation. The example path is a placeholder, not an alternative authority source. Activation and rollback record authenticated transactions. This release does not activate any existing live-user project.

## Exceptions: an always-allow list for guard asks

Claude Code's prompt for a hook ask offers only Yes or No, so a command the guard cannot classify (an `eval`, `source` or `.` line, an unrecognised tool, an undeclared MCP operation) asks again in every session. `polispec exceptions` records a persistent exception instead.

An exception lifts exactly the ask it names, for the commands it matches, and nothing else. The rest of a line is still judged by policy, a deny is never excepted, and neither are `POLISPEC-CONTROL-PROTECTION`, the container root guard, a broken seal or any lock-edition verdict. Every call an exception lifted carries the exception's `aex_` id in its judgment record, and `polispec judgments show` prints it.

**Making one.** When a call asks, the ask text ends with a hint such as `polispec exceptions promote apr_0123456789ab`. The `apr_` id names a proposal the hook recorded; a proposal grants nothing. In a separate terminal (an agent shell cannot do this, and `!` in the agent prompt has no keyboard), run the command. It shows the pattern, the scope and the rule, asks you to type a phrase, and then writes `exceptions.yml` into the global shelf and commits it through `plan global` and `apply global` (the commit message is `Apply polispec plan <id>`).

```
polispec exceptions list
polispec exceptions promote apr_0123456789ab
polispec exceptions promote apr_0123456789ab --command '. */env.sh' --global
polispec exceptions add --command 'source .venv/bin/activate' --note 'project venv'
polispec exceptions add --kind rule --rule G-STAGE-EXPLICIT --command 'git add -A docs'
polispec exceptions remove aex_0123456789ab
```

The proposed pattern is the exact, unexpanded text of the triggering command, with its glob characters escaped, so `. $B/env.sh` matches the next `. $B/env.sh` whatever `$B` holds. Widen it with `--command`, which takes a pattern as written; `*` matches across slashes, and the first word must not contain a glob character. An exception matches the text of a command, not what it expands to or runs: the entry for `. $B/env.sh` stays in force whatever `$B/env.sh` contains, so scope it as narrowly as the work allows. A new entry is scoped to the project root (the git toplevel of the directory, of the proposal's directory for `promote`); `--global` widens it to the host. Entries never expire; `remove` revokes.

**Refusals.** Mutations need a TTY, a typed phrase, an unsealed plane (`sealed_authority` otherwise), a shelf that is a git repository on its ref (`global_not_repo`, `not_on_ref`), and no other uncommitted change under the shelf path (`dirty_shelf`), because `apply global` commits everything under it. A failed apply restores the previous file.

**Where it applies.** `exceptions.yml` sits at the root of the global shelf and is read from the committed ref, so editing the working copy changes nothing until it is committed. The file is a protected path: an agent's Write, Edit or redirect into it is denied like an edit of the ledger. A program the classifier cannot read, such as an interpreter running inline code, is still an unknown write, as for every protected path. `polispec.exceptions off` (or `POLISPEC_EXCEPTIONS=off`) honors no entry, records no proposal and adds no hint. `polispec doctor` reports `exceptions_invalid` for a file that fails its schema; an invalid file honors nothing.

**Delegating the typed phrase (standard edition only).** Since 0.35.0 an application such as the web app can relay the phrase of `exceptions add`, `promote` and `remove` through the delegate runner. The operator grants it at a terminal with the verbs `exceptions-add`, `exceptions-promote` and `exceptions-remove` beside `promote` and `deploy` (see [Delegation](#delegation-letting-an-application-run-promote-and-deploy)). The runner accepts for each verb only the flags `exceptions` itself takes (`add`: `--command`, `--tool`, `--kind`, `--rule`, `--note`, `--global`; `promote`: `--command`, `--note`, `--global` and `apr_` proposal ids; `remove`: an `aex_` id), and every other flag or argument is refused with the reason `flag not granted` or similar. The relayed run stays a terminal confirmation made reachable from the application: the phrase is still typed by a person. Under the lock edition the feature does not exist (`exceptions.delegate_promote` is excluded): `delegate grant` refuses the verbs with `edition_excluded` and a runner refuses a request for them with `verb not available in this edition`. Exceptions themselves are also off under lock.

## Projects in development

Agents working in a project write an env file and `source` it on nearly every task. The commands of a sourced file are invisible to the classifier, so since 0.24.0 a governed line that runs `eval`, `source` or `.` asks `POLISPEC-TOOL-UNKNOWN`. A ledger project with `status: onboarding` is listed but not enforced, which is the guard's word for a project in development, so since 0.30.0 that one ask is not raised there.

A directory is in development when at least one non-retired ledger project contains it (its repo root or a `worktree_globs` match), every project that contains it has status `onboarding`, and it is not inside an env checkout under `envs_root`. The line must start in such a directory, and since 0.30.2 the directory of every command in it must be one too or lie in no non-retired ledger project at all, such as the scratch directory under `/tmp` that an agent changes into to source an env file it wrote; 0.30.0 and 0.30.1 asked again as soon as a command ran outside development, which kept the ask on exactly those lines. A line that changes into a live project or a checkout before it sources keeps the ask. A live project, a live project that contains an onboarding one, a test or stable checkout, a session that starts in a path no project owns and the lock edition keep the ask. To put a project in development, list it in the ledger as `onboarding` with `polispec plan ledger --from FILE` and `polispec apply ledger --from FILE` (adding an onboarding project tightens, so it applies without a confirm); moving it to `live` ends the relaxation.

Only the opaque trigger is relaxed. An unrecognised tool, a line the parser extracts no command from, an undeclared MCP operation and every deny or rule warn behave as before, and the visible commands of the line are judged as they always were, so `source env.sh; git push origin main:stable` is still denied. What the relaxation gives up is sight of the sourced file's own commands: a rule that would deny something inside `env.sh` cannot see it. Each relaxed call carries `relaxed` in its judgment record (`polispec judgments show <id>`), so the calls it let through can be audited. `polispec.relax.dev off` (or `POLISPEC_RELAX_DEV=off`) restores the ask everywhere without a release.

Since 0.32.0 that relaxation is a rule polispec ships: `TOOL-OPAQUE-DEVELOPMENT` in the catalog spec `tools/declared`, composed as the `catalog` layer above the global shelf on a host where the operator activated it (`polispec resolve <path> --layers` prints it first). It allows a line with shape `opaque_shell` when the `in_development` predicate holds, under the rules above; `polispec.relax.dev off` makes the predicate false everywhere, so the rule declares nothing. The same subspec declares the harness-internal tools (`TOOL-<NAME>`, class `tool.internal`: TodoWrite, Skill, AskUserQuestion and the rest) and the read tools (`TOOL-READ-<NAME>`, class `tool.read`: Read, Grep and the rest, when called without a path); an undeclared tool such as `CronCreate` asks `POLISPEC-TOOL-UNKNOWN` while `tools/unknown` is active. Every catalog rule is overridable, and the shelf changes them with ordinary rules through `polispec plan global` and `polispec apply global`:

- declare another tool: `{ id: TOOL-CRONCREATE, match: { tool: CronCreate, class: [tool.internal] }, verdict: allow }`;
- tighten one: the same match with `verdict: deny` (the strictest layer wins, and the tool leaves the fast-path skip list);
- narrow the relaxation: `{ match: { shape: [opaque_shell], in_development: true, path: "/srv/**" }, verdict: warn }`, which asks with that rule's id instead of the control ask;
- loosen a shipped rule only by naming it in `overrides`.

## Allow-once prompt

`polispec allow-once <id>` prints the grant before it asks for the typed phrase: the project, environment, action class and rule, then the call itself. For a file tool the call is the tool name and the absolute target path, for example `edit /srv/shop/specs/polispec/policy.yml`, so the operator sees what the grant unlocks. The same text is stored as `raw` in the allow-once log and appears in the verdict reason. Refusals use the promote vocabulary: `not_tty` without a terminal and `confirmation_failed` on a wrong phrase.

## Rolling out 0.35.0

An installed polispec older than 0.35.0 rejects a ledger that carries `paths`, `owner` or `registered_by`, and any rulebook or ledger entry that carries `description`: every object rejects unknown keys, so the older guard cannot load them. Install 0.35.0 first, then use the new keys.

1. Pin and install 0.35.0 (`polispec pin --ref <tag>`, or `rplugin install polispec --ref <tag>`), then run `polispec doctor` and check that the runtime is the new release.
2. Only then register paths, add `description` to a policy, roster, environments file, global layer or module, or apply the environment-control package to a new project (it now stamps `owner` and `registered_by` on the entry it adds).
3. Run `polispec doctor` again. It guards the order from both sides:
   - `ledger_ahead_of_runtime` (warn) names the keys the ledger uses while the installed release is older than 0.35.0.
   - `description_ahead_of_runtime` (warn) says a trust ref, the shelf or the ledger uses `description` while the installed release is older, and that the older runtime would judge by `fallback_rules`.
   - `launcher_stale` (warn) names a session that still runs an older launcher than the installed release; run `/reload-plugins` in that session or start a new one.
   - `codex_hook_untrusted` (warn) and `codex_hook_unverified` (info) report a Codex hook that reaches polispec but is not trusted, or whose trust cannot be checked offline; open `/hooks` in Codex, review and trust it, and start a new Codex session.
   - `description_missing` (info) and `description_invalid` (warn) report the rulebooks that lack a description or whose description fails the lint.
   - `editions_drift` (warn) repeats `polispec editions --check`.

The writers refuse while the installed release is older than 0.35.0. `polispec register`, `polispec unregister` and the package apply that adds a project entry (`polispec apply environment-control`) fail with code `runtime_behind`, which names the installed release and says to install 0.35.0 first; with `--dry-run` (or `plan`) they still print the preview and add a note that the apply will be refused. A host with no installed release, or one at 0.35.0 or later, is unchanged. The release is read the same way `polispec doctor` reads it: the native pin (`<data home>/current/VERSION`), then a pinned runtime's own `VERSION`.

## Catalog

Since 0.45.0 polispec ships a catalog of optional specs under `catalog/`, and none is active by default. A spec takes effect on a host only when the operator activates it there (and, for a provisioned subspec, provisions it first). Activation is recorded in `catalog/active.yml` inside the polispec state directory, which the guard protects like the rest of its state. With nothing active, polispec gives no special verdict to MCP calls, unknown tools, protected deletes or calls to the local web app; every other rule, gate, control, root guard and protected root is unchanged.

| Spec | Subspec | Effect while active |
| --- | --- | --- |
| `tools` | `declared` | Classifies the harness's own tools and read tools as known, and relaxes `eval`, `source` and `.` lines in development. |
| `tools` | `unknown` | Gates every call polispec cannot positively classify (`POLISPEC-TOOL-UNKNOWN`: ask under standard, deny under lock). |
| `tools` | `web-agent` | Warns on an agent call to the local web app (`G-WEB-AGENT`). |
| `delete-guard` | `protected` | Denies deletes that reach the protected system and configuration folders, and warns on single-file deletes beneath them. |
| `delete-guard` | `xargs` | Warns on an xargs-fed delete. |
| `mcp` | `undeclared` | Gates MCP operations that no protected control or committed policy declares (`POLISPEC-MCP-UNDECLARED`: ask under standard, deny under lock). |
| `mcp` | `declared` | Declares the operations of the MCP servers the host configures; needs a provisioned file. |

Commands:

- `polispec catalog list [--json]` prints every spec and subspec with its gate, whether it needs provisioning, and its state on this host: `active`, `inactive`, `provisioned` or `not_provisioned`. It changes nothing.
- `polispec catalog show SPEC [--json]` prints the subspecs of one spec with the rules of each module. It changes nothing.
- `polispec catalog activate SPEC[/SUBSPEC] [--dry-run]` activates one subspec, or every subspec of the spec when no subspec is named. A provisioned subspec that is not provisioned is skipped, and listed, when the spec is named whole, and refused with `not_provisioned` when named alone.
- `polispec catalog deactivate SPEC[/SUBSPEC] [--dry-run]` reverses it.
- `polispec catalog provision SPEC/SUBSPEC --from FILE [--dry-run]` stores the host's own module for a provisioned subspec. For `mcp/declared` the file is a `polispec.module/v1` document whose every rule has the shape `{ id, reason, verdict: allow, match: { class: [mcp.call], server: S, operation: O } }`; nothing else is accepted. polispec records the file's sha256, and a file that later changes stops counting until it is provisioned again.

The three changes are operator-only. Each types a phrase on a terminal: `activate catalog SPEC`, `deactivate catalog SPEC` or `provision catalog SPEC/SUBSPEC`, with the argument exactly as given. Without a terminal the command exits 1 with `not_tty` and writes nothing; a wrong phrase exits 1 with `confirmation_failed`; while the sealed plane is active the command exits 1 with `catalog_sealed`; `not_provisioned` and `provision_invalid` also exit 1; a usage error exits 2. `--dry-run` prints what would change and writes nothing. Each change emits a `polispec.catalog` event with the action, the spec, the subspecs and the actor.

`polispec doctor` reports `catalog_none_active` (info) while nothing is active, `catalog_provision_missing` (warn) for an active provisioned subspec whose file is missing or changed, and `catalog_state_invalid` (blocking) when the state file cannot be read; in that last case every gate counts as on until the file is fixed.

Upgrading from 0.44.x: the release no longer applies the tool declarations, the unknown-tool gate, the delete guard or the undeclared-MCP gate on its own. Activate `tools` and `delete-guard` to keep the previous behavior, and `mcp/undeclared` if the host relied on the undeclared-MCP gate. A host that kept its MCP declarations in a shelf module can provision them into `mcp/declared` or leave the module where it is.

## Registering software, directories and the system scope

A path entry brings something that is not a git repository under polispec. `polispec register <path>` writes the proposed ledger to `<state home>/register/<id>.ledger.yml`, runs `plan` on it, prints the plan and applies it when the plan is a tightening (an onboarding add); `--dry-run` stops after the plan, and `--confirm PLAN_ID` applies a plan that needs confirmation. `unregister <id>` sets the entry to `retired`, which is a loosening and needs `--confirm`.

- `--kind software|directory|system` (default `directory`). `system` registers only the home directory.
- `--id` defaults to the path's base name, lowercased with other characters replaced by hyphens, at most 41 characters; it must be unique across projects and paths.
- `--description` is optional, 1 to 4000 characters, and passes the same lint as any rulebook description.
- It refuses a missing path (`path_missing`), a path inside a ledgered project's repository or worktree (`inside_project`), an id collision (`id_collision`), an already registered path (`path_registered`), and, under the lock edition, every governed path (`edition_restricted`): the protected ledger the sealed plane names is the only way to add one there.
- The entry's `owner` is the uid and login name of the process that registered it and `registered_by` is `POLISPEC_ACTOR` or `cli`. The entry starts `onboarding` and changes nothing; its module `paths/<id>.yml` on the global shelf is written separately with `plan global` and `apply global`, and the entry becomes `live` through a plan the operator confirms.
- The skill `polispec-register` walks an agent through this.

## Publishing the index

`polispec manifest index` prints the local index of every non-retired project and path entry (`docs/schema.md#manifest-polispecmanifestv1-and-the-index-polispecindexv1`). `polispec manifest index --publish` is an operator action and needs an interactive terminal, the directory `/var/lib/polispec/index` to exist and be writable by you (polispec does not create it), and the phrase `publish polispec index for <user>`. It writes `/var/lib/polispec/index/<user>.json` with mode 0644, so every local user can read the owners and governed paths in it. `--unpublish` removes only your file after the phrase `unpublish polispec index for <user>`. Publishing is opt-in, never automatic, and does not exist under the lock edition (`manifest.index_publish`; `edition_excluded`). `POLISPEC_INDEX_DIR` redirects the directory on an unsealed host, for scratch runs.

## When a change lands: the epoch notice

polispec derives an epoch from everything that decides a verdict: the runtime, the edition, the ledger, the layers and the global shelf, every live project's trust-ref commit, the control plane, and the enforce, relax and exceptions settings. Every change polispec itself applies (a plan, a register, a manifest publish, an exception) is recorded with the epoch before and after. In both editions, the first tool call a session makes after the epoch changed gets one line of context, at most 300 characters, once per session per epoch: `polispec: <kind> <subject> landed <age> (epoch <8 hex>); it applies from this call.`, with `Hooks changed: run /reload-plugins.` appended when the change touched hooks. A session sees no notice for its first call, and none when the epoch changed without a recorded change. `polispec.notice off` disables it. `polispec changes` lists the recorded changes. See [When a change takes effect](effect.md) for which changes need a restart.

## Delegation: letting an application run promote and deploy

Since 0.31.0 an application can run `polispec promote` and `polispec deploy` for you, for example from a button in its console, without a terminal of its own. You stay in charge of the scope, the confirmation phrase and the kill switch.

1. Grant the application a scope at your terminal. It asks for the phrase `grant delegation to teach`, then prints a token once:

   ```
   polispec delegate grant teach --projects teach,reach --verbs promote,deploy --targets test,stable
   ```

   Flags default to `--dry-run`, `--json` and `--tag`; add `--flags --dry-run,--json,--tag,--waive-soak` to allow more (`--skip-drain` and, since 0.44.0, `--verbose` are the other flags a grant may name; see [watching an operation](#watching-an-operation---verbose)). Put the token in the application's protected secrets (for Teach, `TEACH_RELEASE_TOKEN` in its env file). Granting again replaces the token; `polispec delegate revoke teach` withdraws it.
2. Run the runner as a user service. `polispec delegate unit` prints the unit and the two commands that install and start it. It refuses to start on a sealed plane.
3. The application sends `request`, `output`, `phrase`, `cancel` and `status` over the local socket (`specs/app.yml#delegation` has the protocol). When a run reaches a confirmation, the application shows the phrase and forwards what the person typed, once; a wrong phrase stops the run with `confirmation_failed`, exactly as at a terminal.

Every delegated run is recorded in `delegate_runs.jsonl`, and promotion and deploy records name it as `via: delegate:<app>:<who>`. `touch <state home>/delegate/delegate.disabled` stops all delegation at once: the runner answers `disabled` to every request and refuses to start. An agent that runs `delegate grant`, `revoke` or `serve` meets the policy-edit warn.

Delegation is the terminal confirmation made reachable from the application, not stronger authentication: whoever holds the token and types the phrase can run what you granted. Keep the scope small and the token in the application's secret store.

## Protected allow-once service

An unprivileged hook cannot safely mark a root-owned grant spent. Sealed one-use authorizations therefore use a small operator-run Unix socket service. It accepts only bounded request, consume, and status operations; redemption remains a local authenticated operator command.

```sh
/absolute/pinned/launcher authorizations unit --json
/absolute/pinned/launcher authorizations serve
polispec authorizations status --json
/absolute/pinned/launcher allow-once alo_0123456789ab
```

`unit` renders a systemd unit using the active pinned launcher; it does not install or start it. The operator reviews and installs that unit or runs `serve` in the foreground. The socket is fixed at `/run/polispec/authorizations.sock`. The client authenticates a root peer; the server gets the caller's UID from the kernel, never the request. There is no TCP listener or remote redemption operation.

Redemption displays the requesting UID, project, rule, environment, session, and action digest, and requires the typed confirmation shown by the command. Grants expire within ten minutes. Consumption binds the exact request and appends durable spent state before replying. Concurrent consumers, replay, and a lost reply cannot create an extra grant. A lost success reply leaves the grant spent; request a new authorization after reviewing the action again.

Missing service, invalid history, rate limits, timeouts, changed authority, and malformed protocol all refuse an override. Native asks remain native. One standard grant binds the complete environment/control ask set, its trusted policy and control digests, and the actual harness/session; it resolves only those bound decisions. Explicit control denials, broken authority, protected paths, root guard, and lock defaults remain in force.

The root-owned regular marker `/etc/polispec/authorizations.disabled` disables request, redemption, and consumption. Unsafe ownership or ancestry fails closed. Removing a deliberate marker and restarting services are operator actions, not hook recovery behavior.

After a crash leaves a socket, recovery first proves that the fixed socket has no listener. It refuses a live, ambiguous, or changed endpoint, and preserves a stale socket by an exclusive in-place backup rename:

```sh
/absolute/pinned/launcher authorizations recover --dry-run --json
/absolute/pinned/launcher authorizations recover --json
```

Recovery authenticates the operator even for a dry run. Actual recovery requires confirmation. The unit's restart policy does not silently remove a stale socket.

## Removing another user's tightening overlay

Without `--owner`, uninstall selects protected operator records only, except that on a host with no active sealed plane a non-root user can remove their own user-scope or project-scope overlay (receipt `owner_uid` equal to the caller's uid) from a TTY by typing `uninstall INSTALLATION_ID`; see `docs/harness-controls.md`. To remove a mutable overlay, the operator explicitly selects its passwd owner and original scope:

```sh
/absolute/pinned/launcher harness uninstall INSTALLATION_ID --owner USER --scope user --dry-run --json
/absolute/pinned/launcher harness uninstall INSTALLATION_ID --owner USER --scope project --project /absolute/project --state-home /absolute/state --dry-run --json
```

`--state-home` is optional and must be an absolute existing owner-controlled XDG state directory. Project scope requires an absolute project path; user scope rejects one. The privileged parent verifies identity and paths, then permanently drops supplementary groups, GID, and UID before opening the selected user's SDK state, files, or schedule port. The child revalidates bounded journal transitions, document and artifact identities, current owned contributions, and digest-checked historical backups before restoring anything.

Historical runtime bytes need not equal a newer launcher, but target paths and ownership selectors must still match the canonical backend. Unrelated entries are preserved. Missing backups, interrupted transactions, malformed restoration metadata, and protected-path collisions refuse removal. Omit `--dry-run` only after reviewing the result and the requested operator confirmation.

## Maintaining the lock branch

`scripts/release-lock` is a maintainer operation in this repository, separate from project promotion. After the accepted standard release is committed and pushed on `main`, read the exact local and remote `polispec-lock` heads. Run from a clean repository root on `main` with the full accepted main SHA:

```sh
scripts/release-lock --base FULL_MAIN_SHA --expected-local FULL_LOCK_SHA --expected-remote FULL_LOCK_SHA --dry-run --json
```

For the initial creation, both explicit expected values are `absent`. Inspect the dry run, then repeat without `--dry-run`. The command requires local main, remote-tracking main, and live remote main to equal the accepted base. Fetch and push must resolve to the same single endpoint. It constructs a sole-parent commit with exactly one `EDITION` change, archives a prior local lock ref before refresh, and pushes only `refs/heads/polispec-lock` under an exact lease. It updates the local lock ref only after confirming the remote result.

A divergent remote refuses. Exit 4 means recovery is required: a push may have reached the remote or local compare-and-swap failed. Preserve the reported target and archive, inspect both refs, and reconcile explicitly before retrying; an uncertain push is never reported as an ordinary no-change refusal. `doctor` checks local edition provenance without network access. Lock validates its immutable parent and edition-only tree difference without requiring a local main ref or standard installation.
