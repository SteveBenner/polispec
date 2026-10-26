# POLISPEC STEWARDSHIP — Change polispec Without Disrupting What It Protects

`rules/polispec.md` governs agents working *inside* a governed project. This rule governs work *on* polispec and its rulebooks: developing polispec, installing, upgrading or repairing it, applying a package or a project's specs, and changing the global shelf or the ledger. A mistake here affects every session and every project on the host at once, so all of it runs through polispec's own previews and gates.

## The runtime is live

The polispec that runs the guard judges every agent tool call on the host. If its code breaks, every non-read call on the host is denied, including the calls that would fix it.

- Find out what the host runs before touching polispec code: `polispec doctor` reports the runtime as `pinned`, `clone`, `sealed` or `unknown`. So does `rplugin doctor polispec`.
- Never edit the running copy. A pinned runtime refuses writes (`R-POLISPEC-RUNTIME`, deny). A working-clone runtime warns on every write into it. Treat that warning as a stop: the clone is the live guard.
- Develop polispec in a separate git worktree or clone. Verify with that tree's own `bin/polispec`, against scratch ledgers and repositories (`POLISPEC_LEDGER`, `POLISPEC_HOME`, `POLISPEC_GLOBAL`, `POLISPEC_STATE_HOME`). Do not redirect `XDG_STATE_HOME`; it hides the rplugin settings. Without `POLISPEC_STATE_HOME`, scratch runs write the live guard's state.
- Before tagging, run `polispec smoke run --against <installed release>` from the candidate tree and read every verdict it reports as changed; each intended change belongs in the changelog. A failing scenario or an unexplained change stops the release.
- Ship by release, never by edit: merge the verified change, tag it, and reinstall with `rplugin install <repo> --ref <tag>`, or `polispec pin --ref <tag>` on a host without rplugin. Until a host is pinned, merge into the running clone only verified code, in a single fast-forward.
- If the guard does break, do not retry your calls in other shapes. Ask the user to restore it from their own prompt, for example `! git -C <polispec clone> stash push -u -- lib schemas`, and only then continue in a worktree.

## Install, upgrade, repair

- Install and upgrade through polispec's own installers only. On an rplugin host that is `rplugin install polispec`, pinned with `--ref <tag>`, then `rplugin doctor polispec` at zero findings. Without rplugin it is `polispec pin --ref <tag>`, then `polispec install --harness <name>` (or the harness's plugin marketplace), then `polispec doctor`. Never copy files into a plugin store, a release directory or a harness's settings by hand, and never edit generated harness artifacts by hand.
- `polispec steward --check` reports whether the host is protected, and `polispec steward` (or `polispec apply --with-stewardship`) checks, and where missing sets up, the installed copy of this rule, the runtime protection, and a pinned runtime at the running version's tag before doing anything else. Use it the first time polispec meets a host or a project.
- Settings change only through `rplugin settings` on an rplugin host, or `polispec settings set` without it. Switching `polispec.enforce` between `advise` and `enforce`, or changing the ledger or global source, needs the user's explicit yes through the question tool.
- Sealing, plane activation, rollback and harness-control loosening belong to the authenticated operator. Give them the command; do not run it.

## Plan before every apply

Every change to a rulebook is planned first and applied through polispec:

| Change | Plan | Apply |
|---|---|---|
| Put a project under polispec, or upgrade a package | `polispec plan environment-control --repo <repo> --variant service\|distributed` | `polispec apply …` with the same arguments |
| A project's own specs | `polispec plan project:<id>` | `polispec apply project:<id>` (commits on main; takes effect when the operator promotes) |
| The global shelf | `polispec plan global` | `polispec apply global --confirm <plan-id>` |
| The ledger | `polispec plan ledger --from <file>` | `polispec apply ledger --from <file> [--confirm <plan-id>]` |
| A host with no ledger | `polispec ledger init --dry-run` | `polispec ledger init`, or let `polispec install` or a package apply create it |

- Read the whole plan: files, ledger effect, composed policy diff, every probe whose verdict changes, and the classification.
- A **tightening** or **neutral** plan, other than one targeting the global shelf, may be applied directly. Adding a new project in `onboarding` status counts as tightening, and so does creating the starter ledger on a host that has none (it lists no project and never overwrites a ledger).
- Anything else — **loosening**, **mixed**, any global-shelf change, a status flip (`onboarding` → `live`, retirement), a profile, trust-ref or repo change — needs the user's explicit yes first. Ask with the question tool, show the plan id and the reasons, and only then run `apply … --confirm <plan-id>`. The guard also asks the user when it sees `--confirm`. Never confirm a plan yourself, and never reshape a change so that it classifies differently.
- A plan id binds the exact proposal. If anything changes, plan again; a stale id is refused.

## When a spec should change

Raise it with the user instead of editing; the `polispec` and `polispec-advise` skills carry the full table.

- **Create** when a project starts serving real users with no `specs/polispec/`, or a new tool, MCP server, service or secret store becomes routine.
- **Modify** when one rule asks or denies benign calls across sessions, or a verdict surprised the user.
- **Delete** a rule or exception that no recent judgment hit, or on retiring a project or path. A removal loosens.
- **Move** a rule between layers, or follow a renamed path, as two plans: add first, remove second. The removal loosens.
- **Register** a path outside a governed repository with `polispec-register`.
- Prefer fewer distinct asks over more exceptions: declare the legitimate thing, then narrow the rule, then an exception the operator records, then allow-once last.

## What agents never do here

- Edit the ledger, the global shelf, `specs/polispec/**`, the plugin store or the polispec runtime by hand.
- Flip a project to `live`, change `polispec.enforce`, or apply a loosening, mixed or global plan without the user's yes.
- Remove, rename or bypass a gate, freeze, rule or module to get a change through.
- Run `git worktree remove --force`, `rm -r`, `git clean` or `find -delete` on polispec trees, releases or backups. Back up in place first.
- Delete a pinned release; older releases are the rollback.
- Put personal policy (a host's own paths, project ids, hostnames or operator name) into the shipped `modules/`, `packages/`, `config/`, `catalog/`, `rules/` or `skills/`; it belongs on the global shelf or in the ledger unless the operator chose to ship it. `polispec doctor` and `polispec steward --check` report it as `personal_default`.
