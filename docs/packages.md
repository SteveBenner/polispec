# Packages, plan and apply

Every change to a rulebook goes through two commands. `polispec plan` shows what a change would do and classifies it. `polispec apply` carries it out, and asks for a confirmation when the change loosens anything. Since 0.21.0 they replace `polispec onboard`, which was removed with no alias.

## Contents

- [What can be planned](#what-can-be-planned)
- [Reading a plan](#reading-a-plan)
- [Classification and confirmation](#classification-and-confirmation)
- [Packages](#packages)
- [The environment-control package](#the-environment-control-package)
- [Upgrades](#upgrades)
- [Verdict replay](#verdict-replay)
- [Stewardship: polispec steward and apply --with-stewardship](#stewardship-polispec-steward-and-apply---with-stewardship)

## What can be planned

| Target | Proposed | Compared with | Apply does |
|---|---|---|---|
| `<package> --repo <repo>` | The package rendered for that repository | The repository and ledger as they are | Runs the package's steps |
| `project:<id> [--from REF\|worktree]` | The project's `specs/polispec/` at REF (default: the `main` worktree) | Its trust ref | Copies the files onto `main` and commits `Apply polispec plan <plan-id>`; refuses when `HEAD` is not `main`. The change takes effect when the operator promotes it. |
| `global [--from REF\|worktree]` | The global source's polispec directory at REF or in its worktree | The configured global ref | Commits the changed files on the configured ref branch of the global repository; refuses `not_on_ref` when another branch is checked out, and `global_not_repo` for a plain-directory global |
| `ledger --from FILE` | FILE | The live ledger | Validates FILE, backs the ledger up beside itself and replaces it atomically |

```sh
polispec plan project:shop
polispec apply project:shop
polispec apply project:shop --confirm plan_3f9c0d2e1a7b4c58e6d09a12
```

`apply --dry-run` is the same as `plan`. When the sealed plane is active, the sealed source owns the global layer and the ledger: `plan global` and `plan ledger` still work, and `apply` of either refuses with `sealed_authority`.

## Reading a plan

A plan lists:

- every file it would add, replace or leave alone, with a diff, and every conflict;
- the ledger entry before and after;
- the composed policy difference for every affected project: rules, gates, freezes and modules added, removed or changed, and the effective digest before and after;
- probe verdicts before and after (see [verdict replay](#verdict-replay)), each marked `tighten`, `loosen` or `same`;
- the classification, whether it needs a confirmation, and why;
- the plan id.

`--json` prints the same as `polispec.plan/v1` ([schema](schema.md#plan-polispecplanv1)).

## Classification and confirmation

Verdict severity runs allow, warn, deny. A plan is:

- **tightening** when something becomes stricter and nothing looser: a probe moves up, or a rule, gate, freeze, module, protected root or hermetic entry is added;
- **loosening** when something becomes looser and nothing stricter: a probe moves down, or one of those is removed;
- **mixed** when both happen;
- **neutral** when no verdict or structure changes.

A changed rule, gate, freeze, module or hermetic entry counts as loosening unless a probe or a replayed journal entry shows the change is stricter; a rule's `reason` text is not compared.

A ledger plan is judged by structure; probes are shown but not counted. Adding a project with status `onboarding` tightens. Changes to `packages`, `onboarded`, `remote` or `related` are neutral. Everything else loosens: a change to an existing entry's status, profile, trust ref, repository, policy, roster or worktree globs, a retirement, a dropped project, a project added in any other status, and a change to `defaults` or `envs_root`. Flipping a project to `live` is reported as loosening because it needs the same confirmation, even though enforcement starts.

A tightening or neutral plan applies directly, except for the global target. Every other plan needs a confirmation: `apply` refuses with `confirm_required` and prints the plan id and reasons, and runs only with `--confirm <plan-id>`. Apply recomputes the plan each time; when the proposal changed since the id was printed it refuses with `plan_changed`.

The guard treats `polispec apply … --confirm` as a policy edit, so on a live policy the agent's harness asks the user first. An agent following `rules/polispec-stewardship.md` asks the user before it confirms any plan. `polispec.enforce` is a setting, not a plan target; changing it stays with `rplugin settings` and the user.

## Packages

A package is a named, versioned setup: template files, modules, parameters and an ordered list of built-in steps. polispec finds a package by name in two places:

- `packages/<name>/` shipped with polispec;
- `packages/<name>/` on the host's global shelf, read the same way as global modules.

A name found in both places is an error and nothing is applied.

```yaml
schema: polispec.package/v1
name: environment-control
version: 1.0.0
summary: Environments, policy and roster for a project that serves real users
params:
  serves:   { type: string, default: real_users, allowed: [real_users, internal, none] }
  trust_ref: { type: string, default: stable }
variants:
  service:     { summary: Hosted service, files: { specs/polispec/environments.yml: variants/service/environments.yml } }
  distributed: { summary: Software users install, files: { specs/polispec/environments.yml: variants/distributed/environments.yml } }
default_variant: service
files: { specs/polispec/roster.yml: roster.yml }
modules: []
steps:
  - { kind: files, when: { param: serves, equals: real_users } }
  - { kind: manifest }
```

The step vocabulary is fixed: `files`, `manifest`, `ledger`, `render`, `commit`, `branches`, `push`, `checkouts`. A package composes them; it cannot run arbitrary commands. The full format is in the [schema](schema.md#package-packagesnamepackageyml-polispecpackagev1).

## The environment-control package

`environment-control` is the former `onboard`, step for step, with variants `service` and `distributed` and parameters `serves`, `id`, `trust_ref` and `envs_root`:

```sh
polispec plan  environment-control --repo ~/src/shop --variant service
polispec apply environment-control --repo ~/src/shop --variant service --commit --push
```

The steps, their former names and the `--commit`, `--push` and `--checkouts` flags are described in [environments](environments.md#applying-environment-control).

## Upgrades

The ledger records every package applied to a project with its version and the digest of each file it wrote. `polispec status <id>` lists them, and `polispec doctor` reports `package_upgrade_available` when a newer version exists and `package_file_drift` when a written file has since been edited.

Planning a newer version of a recorded package is an upgrade. Files still identical to what the package wrote are replaced. Edited files are listed as conflicts with a diff of the new rendering, and apply leaves them untouched. Applying the same version again is refused with `already_applied`, and an older version with `downgrade_refused`. A project ledgered before 0.21.0, which records no packages, is refused with `already_onboarded`.

## Verdict replay

A plan judges a set of actions twice, once against the current composed rulebook and once against the proposed one, through the same engine the guard uses and without emitting events.

- **Probes** are generated from each affected project's environments: git operations on every environment branch, writes and deletes in every checkout, secret reads, data writes, service control, deploy and promote per environment, data copies between every pair of environments, an edit of the policy file, and a write into the polispec runtime.
- **Journal** rows are replayed too: every call the guard judges leaves a judgment record (`docs/operator.md`, judgment records), and a plan replays the per-action rows of the last 14 days (project, environment, action class, tool, ref, home-relative path, verdict and rule id) as actions against the current and the proposed rulebook. The rows never hold command text, file contents or environment values, and no setting is needed.

## Stewardship: polispec steward and apply --with-stewardship

`polispec steward` protects the host on its own; `polispec steward --check` only reports, changes nothing, and exits 1 when a step is not satisfied. `apply --with-stewardship` runs the same steps before an apply and stops before changing anything on any failure. Each step is skipped when already satisfied:

1. **Rule.** The running polispec and the tree the plugin store links to both ship `rules/polispec-stewardship.md` in the manifest's rules; if not, `rplugin install <runtime root>`. With rplugin 1.15.0 or later and a Claude Code home present, the rule must also be linked at `<claude home>/rules/rplugin/polispec/polispec-stewardship.md`; if not, `rplugin install polispec`. Antigravity CLI loads rules natively too; Codex, Hermes, Pi and the DeepSeek TUI have no rules directory and read the same guidance through the polispec skill.
2. **Protection.** The runtime is a clone or a pinned release, so the built-in `R-POLISPEC-RUNTIME` protection applies.
3. **Pin.** A clone runtime is pinned to the tag of the version it is running with `rplugin install <clone> --ref v<VERSION>`, so running `polispec steward` from a clone at a newer released version re-pins the host to that version. A missing tag fails the step.

Each prints `stewardship_<n>: ok|installed|missing|failed <detail>` (`missing` only under `--check`, naming what would run); `--json` prints the runtime, the steps and `ok`. See [operator](operator.md#the-runtime-and-stewardship) for the runtime kinds.
