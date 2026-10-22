# Environments manifest, applying environment control, `[ENVS]` and git hooks

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

Since 0.37.4 an agent may read release code in a prod checkout: a read of a path under a prod `checkout` that matches none of the environment's `data.dirs`, `unit_files`, `env_files` or `secrets`, is tracked by git there and is unmodified (git status, ignored files included) is allowed by `POLISPEC-RELEASE-READ` before the policy's rules. Any other read in prod stays `secrets.read`: data dirs, unit and env files, declared secrets, and untracked, ignored, modified or missing files in the checkout.
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

`serves:` is `real_users`, `internal` or `none`. Only `real_users` components are scaffolded and ledgered. For `internal` and `none`, `polispec apply environment-control` writes the `serves:` line and nothing else.

## Applying environment control

A project comes under polispec by applying the shipped `environment-control` package ([packages](packages.md)). Plan first, then apply the same arguments:

```
polispec plan  environment-control --repo <repo-path> [--variant service|distributed] [--param serves=real_users|internal|none] [--param id=<id>] [--param trust_ref=stable] [--param envs_root=<dir>] [--json]
polispec apply environment-control --repo <repo-path> [same arguments] [--commit] [--push] [--checkouts] [--with-stewardship] [--json]
```

`polispec onboard` was removed in 0.21.0 with no alias. Its flags map one to one: `--serves X` is `--param serves=X`, `--archetype V` is `--variant V`, `--id` and `--trust-ref` are `--param id=` and `--param trust_ref=`, and `--dry-run` is `polispec plan` (or `apply --dry-run`). Putting a new project in `onboarding` status is a tightening change, so an agent may apply it without a confirmation.

`--variant service` (the default) scaffolds a tailnet-exposed test and a public prod. `distributed` scaffolds test and prod with `exposure: none`. The deploy steps in the service templates are the placeholder `true`, and each service environment's `deploy.health.run` is the placeholder command `polispec-placeholder-health-check-replace-it-in-specs-polispec-environments-yml`, which does not exist, so the scaffolded policy validates and `polispec promote <id> --to test` passes its gates, but `polispec deploy` records a failed health check (`run exited 127:` naming the placeholder command) until you replace both with the real commands. A `health.run` command is split into arguments and run without a shell, and a command that cannot be started is a failed health check that names it, never a crash.

The package's steps run in order, one output line each (`done`, `kept`, `skipped`, `next`, or `would` in a plan). The plan prints the mapping from the former onboard step names:

| Step | Former name | What it does |
|---|---|---|
| `files` | `1_scaffold` | Render `environments.yml`, `policy.yml` and `roster.yml` into `specs/polispec/` from the package's variant. Existing files are kept. The merged policy, the environments document, the roster and the ledger with the new entry are all validated before anything is written, so a failure leaves no scaffold behind. |
| `manifest` | `2_manifest` | Append the pointer block to the component manifest. |
| `ledger` | `3_ledger` | Insert the project into the ledger with status `onboarding` and a `packages` record (name, variant, version, date, and the digest of every file written). The new text is validated, a `ledger.yml.bak-<UTC timestamp>` copy is written beside the ledger, and the replacement is atomic. Existing entries are untouched. |
| `render` | `4_render` | Render `AGENTS.md` and `.agents/directives/envs.md` (see below). A plan previews from the scaffold files already in the repository where they exist, and from the templates otherwise. |
| `commit` | `4b_commit` | With `--commit`: stage by name exactly the files the earlier steps wrote or changed and commit only those paths on `main` as `Add the polispec scaffold`, through the operator git, with an explicit pathspec so other staged changes stay staged and uncommitted. When `HEAD` is not `main` the commit is skipped with a note and the commit command is printed; when nothing was written the step is `skipped`. Without `--commit`, apply never commits. |
| `branches` | `5_branches` | When the three `specs/polispec` files are committed on `main`, create local `test` and the trust ref at `main` when absent. Without `--commit` on a fresh scaffold this step is `skipped` and prints the commit, branch and push commands to run; the branches must be created after the commit so the trust ref carries the policy. |
| `push` | (part of `5_branches`) | With `--push`: push `test` and the trust ref to `origin` without force, and `main` too when `--commit` was given. Without it the exact push command is printed. |
| `checkouts` | `6_checkouts` | With `--checkouts` and both branches on `origin`: clone the test and stable checkouts under `envs_root` and install the git hooks for test and prod. For each of the test and prod checkouts the step prints a `checkouts: hook` note, one per environment, naming the installed hooks (`pre-commit`, `pre-push` and `reference-transaction`) and the checkout directory they went into, because it sets `core.hooksPath` there. Otherwise the next step is `polispec deploy <id> test`. |

For `serves` `internal` or `none` only the `manifest` step runs.

Applying the same package version to a project that already records it is refused; nothing is overwritten. A higher version is an upgrade: files whose bytes still match the recorded digest are replaced, edited files are reported as conflicts with a diff and left untouched, and the record is updated. `polispec status <id>` lists the project's packages, and `polispec doctor` reports `package_upgrade_available` and `package_file_drift`.

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
