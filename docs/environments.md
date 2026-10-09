# Environments manifest, onboarding, `[ENVS]` and git hooks

A live project declares its environments in `specs/polispec/environments.yml`, next to `policy.yml`. The file is read from the project's trust ref (`stable`) exactly like the policy, so an agent cannot widen its own environment by editing `main`: an edit takes effect only after the operator promotes it.

The ledger stays the per-host registry of which projects are live. The component manifest carries a short pointer and a `serves:` flag, never a copy of the facts.

## How the file is read

- Schema: `schemas/environments.v1.yml` (`polispec.environments/v1`). Check a file with `polispec validate environments <file>`.
- At the trust ref, `PolicySource` reads `policy.yml` and the sibling `environments.yml`, validates the environments document, projects each environment down to the keys the policy schema knows, merges them into the policy and validates the merged policy. The engine, `polispec resolve`, `polispec status`, `promote` and `deploy` all see the merged policy.
- The rich fields (`host`, `audience`, `exposure`, `operators`, `rollback`, `pii_spec`, `freezes`, `notes`) are dropped by the projection and are used only to render the `[ENVS]` directive.
- The policy digest covers both files: sha256 of the policy text, a NUL byte and the environments text. With no environments file it is the sha256 of the policy text alone, so a project that keeps `environments` inline keeps its digest.
- A project with an invalid `environments.yml` at its trust ref falls back to the ledger defaults and `polispec doctor` reports `policy_invalid` naming `environments.yml`.
- If both files declare `environments`, the file wins and `doctor` reports `environments_duplicate`. This is a finding, not a fallback.
- `polispec validate policy <file>` merges a sibling `environments.yml` when the policy has no `environments` key and prints `ok (polispec.policy/v1 + environments.yml)`.

## Field reference

Top level of `environments.yml`:

- `schema`: `polispec.environments/v1`.
- `project`: the ledger id; must equal the policy's `project`.
- `recorded`: date the file was written, `YYYY-MM-DD`.
- `summary`: one sentence on how the environments map to branches.
- `related`: ids of related projects.
- `environments`: exactly `dev`, `test` and `prod`.

Each environment:

- `branch`: the branch the environment runs.
- `checkout`: the working directory, or `repo` for the project's own repository.
- `tier`: `dev`, `test` or `prod`.
- `runs`: `branch` or `tag`; prod usually runs a tag.
- `worktrees`: globs of agent worktrees that count as this environment.
- `services`: systemd units the environment owns.
- `unit_files`: unit file globs the environment owns.
- `env_files`: environment file globs the environment owns.
- `url`: where the environment is served.
- `ports`: ports the environment listens on.
- `data.dirs`: data directories.
- `data.databases`: database names.
- `data_classes`: data classes the environment holds; each is defined in `policy.yml`.
- `secrets`: secret globs and secret-store references (for example `vault:`).
- `deploy.steps`: commands `polispec deploy` runs.
- `deploy.health`: a `url` or a `run` command, plus `expect_version` and `timeout_s`.
- `host`: the machine the environment runs on.
- `audience`: who uses it (`customers`, `staff`, `operator`, `none` and so on); at least one entry.
- `exposure`: `none`, `loopback`, `tailnet`, `funnel` or `public`.
- `operators`: who may promote or deploy into it.
- `rollback`: the operator command that rolls it back.
- `pii_spec`: repository-relative path of the personal-data spec.
- `freezes`: ids of freezes in `policy.yml` that apply here.
- `notes`: free text.

## The manifest pointer and `serves:`

A component manifest (`*.rstack_component.yml`, else `*.rplugin.yml`) gains, at the top level:

```
serves: real_users
polispec:
  project: <id>
  environments: specs/polispec/environments.yml
```

`serves:` is `real_users`, `internal` or `none`. Only `real_users` components are scaffolded and ledgered. For `internal` and `none`, `polispec onboard` writes the `serves:` line and nothing else.

## Onboarding

```
polispec onboard <repo-path> --serves <real_users|internal|none> [--archetype service|distributed] [--id <id>] [--trust-ref stable] [--push] [--checkouts] [--dry-run] [--json]
```

`--archetype service` (the default) scaffolds a tailnet-exposed test and a public prod. `distributed` scaffolds test and prod with `exposure: none`. The deploy steps in the service templates are the placeholder `true`; replace them with the real commands before the first `polispec deploy`.

Steps, in order, one output line each (`done`, `kept`, `skipped`, `next`, or `would` under `--dry-run`):

1. `1_scaffold`: render `environments.yml`, `policy.yml` and `roster.yml` into `specs/polispec/` from `templates/onboard/`. Existing files are kept. The merged policy, the environments document and the roster are validated before anything is written.
2. `2_manifest`: append the pointer block to the component manifest.
3. `3_ledger`: insert the project into the ledger with status `onboarding`. The new text is validated, a `ledger.yml.bak-<UTC timestamp>` copy is written beside the ledger, and the replacement is atomic. Existing entries are untouched.
4. `4_render`: render `AGENTS.md` and `.agents/directives/envs.md` (see below).
5. `5_branches`: create local `test` and the trust ref at `main` when absent. With `--push` it pushes both to `origin` without force; without it the exact push command is printed.
6. `6_checkouts`: with `--checkouts` and both branches on `origin`, clone the test and stable checkouts under the ledger's `envs_root` and install the git hooks for test and prod. Otherwise the next step is `polispec deploy <id> test`.

A repository already in the ledger, by id or by path, is refused with `already_onboarded`; nothing is overwritten.

## `[ENVS]` and `polispec agents render`

```
polispec agents render <project-id|repo-path> [--from worktree|<ref>] [--check] [--json]
```

Renders two things from `environments.yml` and `policy.yml`:

- a one-line `[ENVS]` row in the repository's `AGENTS.md`, replacing an existing `[ENVS]` line or inserted before the first other directive row (or under the title when there are none);
- `.agents/directives/envs.md`, a deterministic table of environments, what each one forbids, promotion, operators and rollback, and data.

Both are generated: edit `environments.yml` or `policy.yml`, never the output. `--check` writes nothing and exits 1 when a file differs. A write to `.agents/directives/envs.md`, or to the `[ENVS]` row of an `AGENTS.md`, classifies as `policy.edit`, so the guard warns before an agent changes it; other `AGENTS.md` edits remain `fs.write`.

`polispec doctor` compares the `[ENVS]` row and `envs.md` at each project's trust ref against a fresh render and reports `agents_drift` when they disagree, when either is missing, or when the trust ref has no `environments.yml`.

## Git hooks

Git hooks judge commits, pushes and ref moves made outside any agent harness, such as by a terminal, a script or a cron job.

```
polispec hook git install <project-id> <dev|test|prod|all> [--dry-run]
polispec hook git uninstall <project-id> <dev|test|prod|all>
```

Install writes three POSIX shims (`pre-commit`, `pre-push`, `reference-transaction`) under the polispec state directory, `git-hooks/<project>/<env>/`, records the checkout's previous `core.hooksPath` in `polispec.previousHooksPath`, and points `core.hooksPath` at the shims. Each shim runs polispec and then chains to the previous hook. Installing twice is a no-op. Uninstall restores the previous path and leaves the shims on disk. The dev checkout is the ledger repository; test and prod use the `checkout` paths of the merged policy.

Behavior per hook, for a checkout of a live project:

- `pre-commit` judges `git.commit` on the current branch.
- `pre-push` judges each pushed ref: a tag is `git.tag`; a branch is `git.push`, or `git.rewrite` when it deletes the branch or the remote tip is not an ancestor of the pushed commit.
- `reference-transaction` judges the `prepared` state: a tag is `git.tag`; a branch is `git.branch`, or `git.rewrite` when the old tip is not an ancestor of the new one. In the dev checkout only the test and prod branches are judged, so ordinary dev work is not slowed.

In test and prod checkouts every judged action is attributed to that checkout's environment, whatever branch is checked out. The verdict is the policy's: in `advise` mode a denial prints `polispec (advise): would deny <rule>: <reason>` and the command proceeds; in `enforce` mode a denial prints the rule and the next step and the git command fails. Warnings in enforce mode fail the command and print an allow-once id. A hook error fails open, except in enforce mode in a prod checkout, where it fails closed. Polispec's own `promote`, `deploy` and clone steps set `POLISPEC_OPERATOR=1` and are never judged by the hook.

Git hooks are a seatbelt for processes outside a harness, not a security boundary. `--no-verify`, a `core.hooksPath` override and the `POLISPEC_OPERATOR` marker all bypass them, and the PreToolUse guard still classifies any such command when an agent runs it. A `git reset --hard` that the `reference-transaction` hook refuses has already rewritten the index and working tree by then; only the ref update is aborted.

## Migrating an existing project

1. On `main`, move the `environments` block from `policy.yml` into `specs/polispec/environments.yml` (`schema: polispec.environments/v1`, same `project`) and add `audience` and `exposure` to each environment. Remove the block from `policy.yml`.
2. Run `polispec validate environments specs/polispec/environments.yml` and `polispec validate policy specs/polispec/policy.yml`.
3. Run `polispec agents render <repo>` to write the `[ENVS]` row and `envs.md`.
4. Commit all of it in one commit.
5. Promote to test and then to stable. Until stable carries the new files the guard keeps reading the inline block, and `doctor` reports `agents_drift`.
