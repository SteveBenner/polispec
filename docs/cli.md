# Command reference

Every `polispec` verb with who may run it. `polispec help` lists what the installed version registers; when this table and `help` disagree, `help` wins and this file is stale.

Authority values:

| Value | Meaning |
| --- | --- |
| agent | An agent may run it. A live project may still judge the call; obey the verdict. |
| agent + yes | An agent may run it only after the user's explicit yes through the question tool. |
| operator | The person named by `polispec.operator`, on a terminal, with a typed phrase. Give the exact command; never run it. |
| sealed operator | The operator authenticated through the protected launcher. A terminal and phrase alone are insufficient. |
| internal | Called by a harness, the launcher or another command. Not run by hand. |

Read-only means no file, ledger, shelf or state write. `--json` is accepted where listed in `polispec help`. `--verbose` traces any run to stderr.

## Inspect

| Verb | Use | Authority | Reads or writes |
| --- | --- | --- | --- |
| `resolve PATH [--layers]` | Which project, environment, layers and digest govern a path | agent | reads |
| `status [PROJECT]` | Project state, packages, findings | agent | reads |
| `doctor` | Runtime, wiring, ledger, shelf, lint and drift findings | agent | reads |
| `explain --harness H < hook.json` | The verdict a real hook payload would get, with exceptions applied | agent | reads, records nothing |
| `explain TOOL INPUT [--cwd DIR] [--json]` | The classified actions, every rule that matched in every layer with file, line, module instance and package, the winner and why, and the `plan` invocation or other lever that would change it; INPUT is the shell command for Bash, else a JSON object of tool input (a bare path for Read, Write and Edit) | agent | reads, records nothing |
| `classify < hook.json` | The actions a payload classifies as | agent | reads |
| `digest [--since 24h]` | Warn and deny counts by rule | agent | reads |
| `judgments list\|show\|verify` | The chained record of every judged call | agent | reads |
| `replay --runtime TREE [--baseline TREE] [--days N] [--json]` | Replay the recorded judgment corpus through a candidate tree and the installed runtime and list every verdict that changes; exit 1 when a change is not named in the candidate's CHANGELOG section | agent | reads |
| `shadow status\|report [--json]` | Where a candidate runtime running in shadow disagrees with the live guard | agent | reads |
| `changes list\|show\|verify\|await` | Effect records of rulebook changes | agent | reads |
| `sessions list` | Recent sessions and the policy each started under | agent | reads |
| `editions [--check]` | What the standard and lock editions allow | agent | reads |
| `deployments [--scan]` | Where polispec is installed | agent | reads; `--scan` backfills the manifest |
| `settings list\|get` | Effective settings and their source | agent | reads |
| `version` | Installed version | agent | reads |

## Validate and plan

| Verb | Use | Authority | Reads or writes |
| --- | --- | --- | --- |
| `validate KIND FILE` | Schema check with JSON pointers | agent | reads |
| `lint [PATH] [--host] [--shipped]` | Loader safety, drift, refs, descriptions | agent | reads |
| `plan TARGET` | Preview files, ledger effect, policy diff, probes, journal replay, classification, plan id | agent | reads; never applies exceptions |
| `apply TARGET` | Carry out a plan | agent for a tightening or neutral plan that is not global; otherwise agent + yes with `--confirm PLAN_ID` | writes files, commits with `--commit` |
| `behavior compile\|decide\|render\|drift\|lint\|export-package` | Application behavioral policy | agent | `render --write` writes surfaces |
| `contract check\|render\|digest\|diff\|export` | Behavior contracts | agent | `render --write` writes surfaces |
| `contract approve` | Record an approval | agent + yes | writes |
| `code detect\|chain\|show\|list\|check\|validate\|controls` | Code-spec packs | agent | reads |
| `code baseline\|generate\|classify` | Record a baseline, derive artifacts, propose classifications | agent | writes repository files |
| `roster resolve\|check` | Harness, model and effort of a role | agent | reads |
| `author draft\|adapters` | A validated draft and its plan | agent; not in the lock edition | starts a model session, writes nothing |
| `agents render PROJECT [--check]` | The `[ENVS]` row and `envs.md` | agent | writes generated files |

Plan targets: a package (`environment-control` and others), `project:ID`, `global`, `ledger --from FILE`. A plan is tightening, loosening, mixed or neutral. Loosening, mixed and global plans, status flips and enforce-mode changes need the user's yes before `apply --confirm PLAN_ID`.

## Install and operate

| Verb | Use | Authority | Reads or writes |
| --- | --- | --- | --- |
| `pin [--ref TAG] [--dry-run]` | Install a read-only release and swap `current`, after replaying the judgment corpus through it; refuses with `pin_unexplained_verdicts` | agent + yes | writes the data home |
| `shadow start --runtime TREE`, `shadow stop` | Run a candidate runtime in shadow beside the live guard, then end it | agent + yes | writes `shadow.json` in the state home |
| `install --harness H` | Wire hooks and skill links | agent + yes | writes harness settings, with backups |
| `uninstall --harness H` | Remove marked hooks and links | agent + yes | writes |
| `uninstall --all`, `restore` | Remove or restore every deployment | operator | writes, needs `uninstall polispec` or `restore polispec` |
| `steward [--check]` | Stewardship rule links, runtime protection, pinned runtime | agent; `steward` itself agent + yes | `--check` reads |
| `settings set\|unset` | Change a setting | agent + yes | writes the settings file; refused while sealed |
| `ledger init` | Starter ledger, never overwrites | agent | writes a new file |
| `register PATH`, `unregister ID` | Govern a path outside a repository | agent for the plan; agent + yes with `--confirm` | writes the ledger through the plan path |
| `manifest ID [--write]` | Project manifest and badge | agent | `--write` commits on main |
| `manifest index --publish\|--unpublish` | Share the host index | operator | writes |
| `specs link\|status\|promote` | The `~/.polispec/specs` link | agent; repointing an existing link needs the operator's typed phrase | writes a link |
| `smoke record\|list\|show\|verify\|coverage\|run` | The smoke ledger and bundled suite | agent | `record` and `run` write the ledger unless `--no-record` |
| `judge status\|stop` | The resident judge | agent | `stop` ends the process |
| `judge serve`, `hook`, `code-hook` | Launcher and harness entry points | internal | |
| `web`, `web url` | Local web app for the person | operator; never driven by an agent | opens a server |

## Release

| Verb | Use | Authority | Reads or writes |
| --- | --- | --- | --- |
| `promote PROJECT --to test` | Fast-forward `test`, tag, run the gate | agent | writes branches and tags |
| `promote PROJECT --to stable` | Flip prod | operator | |
| `deploy PROJECT test` | Deploy the test checkout | agent | |
| `deploy PROJECT stable` | Deploy or roll back prod | operator | |
| `pause PROJECT`, `allow-once ID` | Suspend the guard briefly, redeem one grant | operator | |

An agent never pushes `test` or `stable` and never runs git against `stable`.

## Authority and exceptions

| Verb | Use | Authority |
| --- | --- | --- |
| `catalog list\|show` | Shipped catalog specs and which are active | agent |
| `catalog activate\|deactivate\|provision` | Switch a catalog subspec or supply a host declaration | operator; refused while sealed |
| `exceptions list` | Entries and recorded proposals | agent |
| `exceptions add\|promote\|remove` | Persist a lift for an ask or a rule warn | operator; refused while sealed |
| `harness grammar\|parse\|plan\|verify\|scan` | Native harness controls, read side | agent |
| `harness install` | Add a provably tightening user or project control | agent, after `--dry-run`; loosening, removal and managed scope are operator |
| `harness uninstall` | Remove an overlay | operator; a non-root user may remove their own unsealed overlay after the typed phrase |
| `plane status\|verify` | The sealed authority plane | agent |
| `plane activate\|rollback`, `seal` | Activate or seal | sealed operator |
| `authorizations status` | Protected authorization service | agent |
| `authorizations serve\|unit\|recover` | Run or render the service | operator |
| `delegate list\|status\|unit` | Application delegation | agent |
| `delegate grant\|revoke\|serve` | Let an application run granted verbs | operator |

## Which document explains a verb

| Verb family | Document |
| --- | --- |
| install, uninstall, promote, deploy, pause, sealing, exceptions, delegation | `docs/operator.md` |
| harness, plane, authorizations | `docs/harness-controls.md` |
| plan, apply, packages, modules | `docs/packages.md`, `docs/schema.md` |
| environments, resolve | `docs/environments.md` |
| behavior, contract, code | `docs/behavior.md`, `docs/contract.md`, `docs/code-specs.md` |
| roster | `docs/roster.md` |
| smoke | `docs/smoke.md` |
| web, author, register, manifest | `docs/web.md` |
| changes, sessions, editions | `docs/effect.md` |
| every key of every file | `docs/schema.md` |
| writing an agent that uses polispec | `docs/agent-guide.md` |
