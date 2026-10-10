# Operator commands: promote and deploy

`polispec promote` moves code between branches and `polispec deploy` puts a branch or tag into an environment checkout. Both read the project from the ledger and the promotion policy from the trust ref (`PolicySource.load`), never from the working tree. Both accept `--json` and `--dry-run`.

```
polispec promote <project> --to <env> [--waive-soak] [--dry-run] [--json]
polispec deploy  <project> <env> [--tag vX.Y.Z] [--skip-drain] [--dry-run] [--json]
```

`--json` prints one object. A failure is `{"ok":false,"error":{"code":"…","message":"…","payload":{…}}}` with exit status 1; a usage error exits 2. `--dry-run` runs every check and every gate and changes nothing.

## Git discipline

Git runs through Open3 with exact argv, never a shell. The helper refuses `--force`, `--force-with-lease`, `+refspec`, `reset`, `--hard`, `--no-ff` and `--mirror`. Test and stable only ever move by a non-forced, atomic push of a fast-forward; no merge commit is created on either. Every comparison uses the remote-tracking refs after a `git fetch origin --prune --tags` in the project's repo, so unpushed local commits are never promoted. After the push the local `test` or `stable` branch is advanced with a compare-and-swap `update-ref` (or `merge --ff-only` when it is checked out), and skipped when another worktree has it checked out.

## promote --to test

Actor: `agent` or `operator` (operator means an interactive terminal), checked against `promotion.to_test.actor`.

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
| `clean_tree` | the project repo has no uncommitted changes to tracked files |
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

`deploy.drain` is `{ pause, wait, checks, resume, timeout_s, run_in, env_from }`. `pause` and `resume` run once; `wait` runs until it exits 0 or `timeout_s` (default 300) passes, polling every 5 s. `checks` is a list of commands that run after pause and wait and before the swap (`release_dirs`) or the first step (`in_place`); the first failing check fails the deploy with `drain_check_failed`. A wait timeout fails with `drain_timeout`, a failing `pause` with `drain_failed`. Each of these runs `resume` and leaves the live release untouched. Both strategies drain: `in_place` drains before it checks out the new tag, so no candidate code runs.

Drain commands run in the env's active checkout (`run_in: active`, the default: `<envs_root>/<project>/<env>` resolved) with the env's `env_files` loaded (`env_from`, default the env being deployed); `run_in: repo` runs them in the project repo instead. When no active checkout exists yet, they run in the new release.

`polispec deploy <project> stable --skip-drain` skips the whole drain block for a first rollout, when the active release predates the drain commands. It needs an interactive terminal and the typed phrase `skip drain for <project>`; the deploy record carries `drain: skipped`. It is refused for `test`.

Retention keeps the 3 newest releases (ordered by the tag version they hold, `Gem::Version` of `vX.Y.Z`; names like `sha-*` and `pre-release-dirs-*` sort oldest) plus every release an env symlink points at, plus the release just replaced. An older release is removed only when `git status --porcelain --ignored` lists nothing but ignored paths under `vendor/` and `.bundle/`, which a tag reproduces; anything else is moved to `releases/.held/`. The result lists `kept`, `removed` and `held` under `retention`. `pinned_behind`, tag rules and phrases are unchanged.

## Where a gate runs

A command gate takes two optional fields. `run_in: repo|active` (default `repo`) chooses the working directory: the project repo, or the active checkout or release of the stage the gate belongs to (`test` for `promote --to test`, `stable` for `promote --to stable`; `<envs_root>/<project>/<env>`). `env_from: <env>` loads that environment's `env_files` (`KEY=VALUE` lines; blanks, `#` lines and a leading `export` are skipped, one pair of quotes around a value is stripped) into the command's environment; values are never logged or printed.

Constraint: a gate that touches a live database must use `run_in: active`. Some services migrate their database whenever any process boots, so main or candidate code must never run against the live database from a gate or a drain command. `active` runs the code that is already live.

## Soak, health-required and preflight

- `soaked` (gate option `hours`) passes when `deploys.jsonl` holds a `test` deploy of the sha with health `ok` recorded at least `hours` ago and no later `test` deploy of the same sha with another health. Failure code `not_soaked`.
- `health_required` re-runs, on the policy at the candidate sha, the check that an environment declaring `deploy.steps` or `deploy.activate` also declares `deploy.health` (`env <name> deploys without a health check; G-TESTED can never pass`). The same check (`Gates.health_required_errors(policy)`) runs whenever the operator loads a project, so promote and deploy refuse such a policy with `policy_invalid`.
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

`policy_invalid`, `not_soaked`, `drain_timeout`, `drain_failed`, `drain_check_failed`, `skip_drain_unsupported`, `waive_soak_unsupported`, `nothing_to_waive`, `env_file_unreadable`, `unknown_env`, `rolled_back`, `release_conflict`, `clone_failed`, `not_tty`, `confirmation_failed`, `actor_denied`, `drift`, `not_fast_forward`, `nothing_to_promote`, `version_not_bumped`, `tag_exists`, `tag_mismatch`, `missing_ref`, `push_rejected`, `release_failed`, `after_failed`, `locked` (another promote or deploy of the same project holds its lock), `policy_unavailable`, `unknown_project`, `retired_project`, `repo_missing`, `invalid_target`, `invalid_env`, `logs_not_quiet`, `logs_in_window`, `not_live`, `untested_sha`, `invalid_tag`, `no_deploy`, `no_remote`.

## Events and records

`polispec.promote` carries `project, to, from_sha, to_sha, tag, actor, gates, waived, result, duration_ms` (`waived` only when `--waive-soak` was used); a failure emits it with `result` set to the error code. `from_sha` in a record is the target branch's previous tip, or forty zeros when the branch is created. `polispec.deploy` carries `project, env, sha, tag, steps, health, pinned_behind, actor, result`.

## Scratch use

Point `POLISPEC_LEDGER`, `XDG_STATE_HOME` and `POLISPEC_ENVS_ROOT` at scratch directories and a bare remote; nothing else is read or written.

## Settings and host wiring

polispec reads these machine settings, each from an environment variable, then the rplugin settings snapshot, then the default:

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

The guard is a hook the host wires into each agent harness: it runs `polispec hook pretool --harness <name>` on every tool call and prints the harness's own allow, ask or deny reply. The plugin ships `hooks/polispec.hooks.yml` for harnesses rplugin can render; any other harness calls the same command from its pre-tool event. Two integrations are optional and never required: events may be emitted to an `rlogs` sink (`observability.events: rlogs`, otherwise `local` or `none`), and `polispec onboard` recognises a `*.rstack_component.yml` manifest as well as `*.rplugin.yml` when it adds a `serves:` pointer.
