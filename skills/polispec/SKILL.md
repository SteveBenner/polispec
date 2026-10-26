---
name: polispec
description: >
  Find and use polispec, the guard and rulebook tooling that judges agent tool
  calls (allow, warn, deny) in governed projects. Use it to inspect governing
  rules, explain a verdict, cut repeated asks, decide when a spec should be
  created, modified, deleted, moved or registered, validate specs, promote a
  release to test, or preview harness controls. Routes spec authoring to
  polispec-specs, path registration to polispec-register, and use-case
  suggestions to polispec-advise. Not for generic product specifications.
---

# polispec

polispec is a versioned rulebook plus a guard that gives every agent tool call in a governed project one verdict: `allow`, `warn` or `deny`, with a reason and a next step. Dev work on `main` is frictionless; `test` and `stable` (prod) are promoted by fast-forward. It works on Claude Code and Codex through hooks, on Hermes through a native backend, and as skills only on Pi, DeepSeek TUI and Antigravity. Full picture: `docs/agent-guide.md`.

## Rules that always hold

- Before writing in a project: `polispec resolve .` and obey the verdict.
- `allow` proceeds. `warn` needs the user's explicit yes through the question tool, naming what and why. `deny` stops: relay the next step.
- Never retry a refused call in another shape or tool, never edit the ledger or `specs/polispec/**` to change a verdict, never self-redeem `allow-once`, never push or tag `test` or `stable`, never touch a production checkout, its secrets or data, never edit the running polispec.
- Promote to `stable`, deploy stable, pause, `allow-once`, exceptions, catalog changes, sealing and plane activation are the operator's. Give the exact command; sealed actions also need authenticated privilege.
- A draft is not trusted policy. The trust ref in effect, and observed enforcement, decide. Generated files prove neither.
- Under the lock edition there is no web app, no author, no exceptions and no delegate: give the command-line route.

## Find the installed CLI first

`command -v polispec`, then `polispec version`, `polispec doctor`, `polispec help`. The installed command is the host runtime; a repository's `bin/polispec` is a development candidate. If it is not on PATH, try `<plugin root>/bin/polispec`, `~/.rplugins/polispec/bin/polispec`, `~/.local/bin/polispec`. Take the plugin root from this skill's location. rplugin is optional. Never download a replacement to get past a denial. `docs/`, `schemas/`, `rules/` live in the plugin root, not the user's project. `polispec doctor` reports the runtime as pinned, clone, sealed or unknown and exits nonzero with findings worth reading.

## What to do

| Request or signal | Route |
| --- | --- |
| Why was this denied or asked? | `polispec explain --harness H --json < CALL.json` with the real payload, or `judgments show ID`. Report the winning rule and its legitimate next step. |
| Too many asks, unattended runs blocked | `polispec-advise`; levers in `docs/agent-guide.md` |
| Recommend specs for a project or from history | `polispec-advise` |
| Create, modify, delete, move a rule, module, roster, behavior or code spec | `polispec-specs` |
| Put software or a directory outside a repository under polispec | `polispec-register` |
| New project serving users | `polispec plan environment-control --repo R --variant service\|distributed`, then `apply` with the same arguments |
| Check a file | `polispec validate auto FILE`, then `polispec lint` and read its findings |
| Watch an operation | add `--verbose` to promote, deploy, apply, pin, install, doctor or smoke |
| Promote to test | `polispec promote PROJECT --to test` (tags; never push `test`) |
| Change polispec itself, its install, a package, the shelf or the ledger | `rules/polispec-stewardship.md`: plan first, user's yes for anything not tightening |
| Browser view of policy | Tell the person to run `polispec web`; never run it or call its API (`G-WEB-AGENT` warns when that subspec is active) |
| Native harness controls, sealed authority | Below, and `docs/harness-controls.md` |

## Spec change triggers

| Event | Signal | Route |
| --- | --- | --- |
| create | project serves users with no `specs/polispec/`; new tool, MCP server, service, secret or data environment used repeatedly | environment-control plan, or `polispec-specs` |
| modify | the same rule warns or denies benign calls across sessions; a surprising verdict; wrong role harness or model | `polispec-specs`, project or global plan |
| delete | a rule or exception no recent judgment hit; a retired project or path | removal loosens: user's yes and `--confirm` |
| move | a rule belongs in a wider or narrower layer; a repo path or id changed | two plans; the web Manager does it as one for the person |
| register | a non-repository path needs governing | `polispec-register` |

## Commands

Authority per verb; subcommand detail in `docs/cli.md`.

| Who | Verbs |
| --- | --- |
| agent | `resolve` `status` `doctor` `explain` `classify` `digest` `judgments` `changes` `sessions` `editions` `deployments` `version` `validate` `lint` `plan` `behavior` `contract` (not `approve`) `code` `roster` `agents render` `smoke` `author` `ledger init` `manifest` `specs` `judge status\|stop` `promote --to test` `deploy test` `register` `unregister` (plan) `apply` (tightening, non-global) `settings list\|get` `catalog list\|show` `exceptions list` `harness grammar\|parse\|plan\|verify\|scan` and tightening `install` `plane status\|verify` `authorizations status` `delegate list\|status\|unit` |
| agent + yes | `apply --confirm PLAN_ID` (loosening, mixed, global, status flip) `pin` `install` `uninstall --harness` `steward` `settings set\|unset` `contract approve` `register --confirm` |
| operator | `promote --to stable` `deploy stable` `pause` `allow-once` `exceptions add\|promote\|remove` `catalog activate\|deactivate\|provision` `delegate grant\|revoke\|serve` `authorizations serve\|unit\|recover` `uninstall --all` `restore` `manifest index --publish` `harness uninstall` and loosening `web` `specs link` (repoint) |
| sealed operator | `seal` `plane activate\|rollback` |
| internal | `hook` `code-hook` `judge serve` |

## Harness controls

Read `polispec harness grammar --json`, write a control with only that vocabulary, `polispec validate control FILE`, `polispec harness plan FILE --harness H --scope project --project ABS --json`, inspect every disposition, preview with `harness install --dry-run`. Agents add only provably tightening user or project controls. Installation is not activation, and artifacts are not observed enforcement. Report them separately. Never seal, activate or enable a feature to make a command succeed. Control denials, protected paths, the root guard and lock defaults bind even when policy is paused.

## Needs

Ruby with the standard library. A ledger of governed projects (`POLISPEC_LEDGER`, then `polispec.ledger`, then `~/.config/polispec/ledger.yml`). An install: `polispec pin` then `polispec install --harness claude|codex`, the plugin marketplaces, or `rplugin install REPO --ref TAG`. Settings: `polispec settings set` for `polispec.enforce` (`advise` default or `enforce`), `polispec.ledger`, `polispec.operator`, `polispec.code.specs_repo`. New projects serving users stay onboarding until the operator activates them.
