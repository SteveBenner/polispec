---
name: polispec
description: >
  Find and use polispec to inspect governing rules, explain a guard verdict,
  validate or modify specs, promote a development release to test, or preview
  harness controls. Routes spec authoring to polispec-specs and non-repository
  path registration to polispec-register. Use for polispec operations, not
  generic product specifications that do not use polispec.
---

# polispec

## When to use it

- The user asks what is allowed in a live project, which branch is production, or why a command was denied or warned.
- The user wants a policy, roster, ledger, or behavioral policy file checked.
- The user wants to create or modify a rulebook, application behavioral policy, or code-spec pack. Use [polispec-specs](../polispec-specs/SKILL.md).
- The user asks how code moves from `main` to `test` to `stable`.
- The user wants deterministic harness controls, a native installation preview, or an explanation of sealed authority and lock prerequisites.
- The user wants to see or change policy in a browser: which rulebooks govern which project, why a call was denied or warned, what a change would flip, who an exception reaches, or what a new project should register.
- The user wants to put software, a directory, or their home directory that is not a git repository under polispec. Use the `polispec-register` skill (`skills/polispec-register/SKILL.md`).

Moving `stable`, deploying production, pausing the guard, redeeming an allow-once ID, recording an exception to an ask (`polispec exceptions promote|add|remove`; the ask text names the proposal id), sealing, activating projects, and removing or loosening controls are operator actions. Give the operator the exact command. Sealed actions require authenticated privilege through the protected launcher; an interactive terminal and typed phrase alone do not establish that authority.

## Find the installed CLI first

Run `command -v polispec`, then `polispec version` and `polispec help`. Use the installed command for host operations; a repository's `bin/polispec` is a development candidate, not proof of what protects the host.

If it is not on PATH, check the known installation you actually have: `<plugin root>/bin/polispec`, `~/.rplugins/polispec/bin/polispec`, or `~/.local/bin/polispec`. Obtain the plugin root from the loaded skill's location or the harness's plugin context; do not assume a personal checkout path or that rplugin is installed. If none exists, use the plugin's README installation instructions within the user's authorized scope. Never download or install a replacement merely to get past a denial.

Read `rules/polispec.md` and `rules/polispec-stewardship.md` relative to that plugin root. Resolve `docs/`, `schemas/`, and `examples/` there too, not in the user's unrelated project. `polispec doctor` reports the runtime root and its pinned, clone, or sealed status; it can exit nonzero with useful findings, so read them before proceeding. Development of polispec uses a separate worktree and scratch `POLISPEC_*` state as stewardship specifies.

## Inspect the target before writing

Run these in the target project, not the plugin directory:

```sh
polispec resolve .
polispec resolve . --layers
polispec status
```

Use the reported project id, environment, trust ref, layer chain, and roster. `not ledgered` does not authorize unrelated host changes. A working-tree edit does not replace the trusted policy. Obey `allow`, ask for the user's explicit approval on `warn`, and stop on `deny`; do not retry a refused operation through another tool or change settings to evade it. Respect specific approvals already given for the same action.

To explain a refused call, use the read-only command `polispec explain --harness HARNESS --json < CALL.json`, where `CALL.json` contains the actual harness hook payload. Do not invent a tool name or change its arguments to obtain a different verdict. Use `polispec judgments show ID` when a judgment id is available. Report the winning rule and its legitimate next step; a rule file's presence alone is not evidence that a harness is enforcing it.

## Choose the task

| Request | Route |
| --- | --- |
| Create or edit environment rules, a roster, modules, the ledger, a behavioral policy, or code specs | [polispec-specs](../polispec-specs/SKILL.md) |
| Register or retire software or a directory outside a governed repository | [polispec-register](../polispec-register/SKILL.md) |
| Promote a release to test | Read `docs/operator.md`; use `polispec promote PROJECT --to test`, never push the test branch directly |
| Change polispec itself, its runtime, or its installation | Read `rules/polispec-stewardship.md` before acting |
| Native harness control or sealed authority | Read the harness-controls section below and `docs/harness-controls.md` |

## Validate and inspect

- `polispec validate auto <file>` checks a policy, roster, ledger, or behavioral policy file against its schema and prints every violation with a JSON pointer. Add `--json` for machine output.
- After generating or editing spec files, run `polispec lint` (project scope) and read its findings: a clean lint proves loader-safe YAML and agreement with source, not safe composition.
- `polispec behavior compile <file>` emits deterministic compiled JSON and its content digest. It does not sign, publish, or install policy. The receiving application owns authentication and enforcement.
- `polispec behavior decide <file> <event> <facts.json>` evaluates declarative deny predicates; missing facts deny. Native bindings and advisory guidance are not executed by this command.
- `polispec version` prints the installed version.
- `docs/schema.md` documents every key with an example.
- `polispec help` lists the commands installed in this version.

## The web app

`polispec web` is a local web app for the person: a map of governed projects, the pipeline, live judgments, a playground and explainer for why a call was judged, and a manager that changes a rulebook through a plan with its effect shown first. `docs/web.md` documents it.

- Point the user to it; do not run it. Tell them to run `polispec web` in their own terminal (add `--read-only` to look without changing anything). It prints a link that works once, for two minutes, on `127.0.0.1:7421`. `polispec web url` prints a new link for a server already running.
- The agent never drives the web API. A `curl`, `wget`, HTTP client, or `WebFetch` call that changes anything at `/api/v1`, or that reaches its exceptions, author, state, register, session, or plan-apply routes, classifies as `policy.edit` and warns with `G-WEB-AGENT`. Do not retry it in another shape, and do not read or write `launch.secret` or `delegate.token` under the polispec state home.
- A change made there is a plan the person applies: a tightening plan on one click, a loosening, global, move, or status plan only after they type its plan id, and promotion to `stable`, deploy, pause, allow-once, seal, and plane only as commands for the operator to run. Say which view to open (Map, Pipeline, Explainer, Manager, Exceptions, Register, Manifest) and what to look for; the plan id is theirs to type.
- Under the lock edition there is no web app, no author, and no exceptions delegate; give the command-line route instead.

## Smoke tests

- After showing that a spec or sub-spec works for real, record it: `polispec smoke record --spec FILE --at PATH --verdict pass|fail|partial|blocked|inconclusive --summary TEXT` with `--step-file` and `--evidence`. Judge the verdict from evidence outside yourself (hook logs, git state, exit codes), never from your own account.
- `polispec smoke verify` checks the chain; `polispec smoke coverage` lists units without a current pass. Never edit `smoke.yml` by hand. `docs/smoke.md` documents it.
- Every call the guard judges leaves a chained record: `polispec judgments list [--since 24h] [--session ID] [--project ID]` shows them, `show <id>` prints one, and `verify` exits 1 on a digest mismatch, a broken chain or truncation. The record names the rulebook digest, the rule, the polispec that judged and the reply the harness received, with no command text unless `polispec.records.raw` is on. Never edit `judgments.jsonl` by hand.

## Environments

- A live repository's environment facts (branches, checkouts, audience, exposure, operators, rollback) are in `specs/polispec/environments.yml`, read from the stable ref like the policy; `docs/environments.md` documents it.
- `polispec resolve .` names the environment the current directory is in; run it before writing in a live repository and obey the verdict.
- The `[ENVS]` row in a repository's `AGENTS.md` and `.agents/directives/envs.md` are generated by `polispec agents render`; edit `environments.yml` or `policy.yml`, never the output.
- Putting a new user-serving project under polispec is `polispec plan environment-control --repo <repo> --variant service|distributed`, then `polispec apply` with the same arguments; add `--commit` (with `--push`) to commit the scaffold on main and publish main, test and stable. `onboard` was removed in 0.21.0.
- Any change to polispec itself, its installation, a package, a project's specs, the global shelf or the ledger follows `rules/polispec-stewardship.md` in the polispec plugin directory (`polispec doctor` prints it as the runtime root): plan first, apply tightening plans directly, and get the user's yes before `apply --confirm <plan-id>` for anything else.

## What it needs

- Ruby; no gems beyond the standard library.
- The ledger of governed projects. Unsealed resolution uses `POLISPEC_LEDGER`, then `polispec.ledger`, then `~/.config/polispec/ledger.yml`; sealed resolution uses the verified fixed authority plane and ignores those redirects.
- An install. Without rplugin: `polispec pin` (a read-only release under `~/.local/share/polispec`, with `~/.local/bin/polispec`), then `polispec install --harness claude|codex`. As a Claude Code or Codex plugin, the hooks and this skill come from the plugin cache; when asked to "set up polispec stewardship" there, run `<plugin root>/bin/polispec steward`, which pins a release and links the rules. With rplugin (1.17.0 or later for this release): install a tagged release with `rplugin install REPO --ref TAG`; never replace a pinned guard with an unpinned development clone. `polispec doctor` reports what is missing.
- Settings, changed with `polispec settings set <key> <value>` (or `rplugin settings` on an rplugin host): `polispec.enforce` (`advise` or `enforce`, default `advise`), `polispec.ledger`, `polispec.operator` (how messages name the person who promotes to stable) and `polispec.code.specs_repo`.

## Harness controls

Since 0.23.0, `harness_controls` ships enabled; `sealed_plane` remains disabled by default. Inspect the installed release and existing authority before acting. Installation is not activation, and neither a flag nor generated artifacts prove native enforcement. Never enable a feature, seal a plane, or activate a project just to make a command succeed; those require the operator's authorization and prerequisites.

1. Read `polispec harness grammar --json`. Translate the user's intent using only its published vocabulary; the guard never invokes a model to decide a control.
2. Validate the YAML with `polispec validate control FILE --json`, then run `polispec harness plan FILE --harness HARNESS --scope project --project /absolute/project --json`. User scope omits `--project`.
3. Inspect every disposition and finding. Agents may install provably tightening user/project controls; managed scope, removal, uncertain comparisons, and loosening require the operator. Preview with `harness install ... --dry-run --json` before installation.
4. Verify the installation ID. Report artifact integrity separately from observed native enforcement. Missing runtime evidence, unsealed authority, or unsupported control axes prevent lock certification.

A control deny, protected-path refusal, root guard, broken authority, or lock default remains binding even when environment policy is paused or a legacy warning has been authorized. Standard asks without native consent block pending an exact protected one-use authorization. Never substitute a synthetic session, redeem your own request, or change its arguments to reuse a grant.

`harness scan` reports container exposure and records distinct scan transitions; a read-only scan does not arm anything. Rootless and root-equivalent access are separate observations. No scan alone certifies containment.

Read `docs/harness-controls.md` for native boundaries and `docs/operator.md` for the explicit sealed setup, service, and recovery procedures. New projects serving real users stay onboarding until an authenticated operator activates them against a verified plane.
