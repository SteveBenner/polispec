# POLISPEC STEWARDSHIP — Change polispec Without Disrupting What It Protects

`rules/polispec.md` governs agents working *inside* a governed project. This rule governs work *on* polispec and its rulebooks: developing polispec, installing, upgrading or repairing it, applying a package or a project's specs, and changing the global shelf or the ledger. A mistake here affects every session and every project on the host at once, so all of it runs through polispec's own previews and gates.

## The runtime is live

The polispec that runs the guard judges every agent tool call on the host. If its code breaks, every non-read call on the host is denied, including the calls that would fix it.

- Find out what the host runs before touching polispec code: `polispec doctor` reports the runtime as `pinned`, `clone`, `sealed` or `unknown`. So does `rplugin doctor polispec`.
- Never edit the running copy. A pinned runtime refuses writes (`R-POLISPEC-RUNTIME`, deny). A working-clone runtime warns on every write into it. Treat that warning as a stop: the clone is the live guard.
- Develop polispec in a separate git worktree or clone. Verify with that tree's own `bin/polispec`, against scratch ledgers and repositories (`POLISPEC_LEDGER`, `POLISPEC_HOME`, `POLISPEC_GLOBAL`). Do not redirect `XDG_STATE_HOME`; it hides the rplugin settings.
- Ship by release, never by edit: merge the verified change, tag it, and reinstall with `rplugin install <repo> --ref <tag>`. Until a host is pinned, merge into the running clone only verified code, in a single fast-forward.
- If the guard does break, do not retry your calls in other shapes. Ask the user to restore it from their own prompt, for example `! git -C <polispec clone> stash push -u -- lib schemas`, and only then continue in a worktree.

## Install, upgrade, repair

- Install and upgrade through rplugin only: `rplugin install polispec`, pinned with `--ref <tag>`, then `rplugin doctor polispec` at zero findings. Never copy files into the plugin store or edit generated harness artifacts by hand.
- `polispec apply --with-stewardship` checks, and where missing sets up, the installed copy of this rule, the runtime protection, and a pinned runtime at the running version's tag before doing anything else. Use it the first time polispec meets a host or a project.
- Settings change only through `rplugin settings`. Switching `polispec.enforce` between `advise` and `enforce`, or changing the ledger or global source, needs the user's explicit yes through the question tool.
- Sealing, plane activation, rollback and harness-control loosening belong to the authenticated operator. Give them the command; do not run it.

## Plan before every apply

Every change to a rulebook is planned first and applied through polispec:

| Change | Plan | Apply |
|---|---|---|
| Put a project under polispec, or upgrade a package | `polispec plan environment-control --repo <repo> --variant service\|distributed` | `polispec apply …` with the same arguments |
| A project's own specs | `polispec plan project:<id>` | `polispec apply project:<id>` (commits on main; takes effect when the operator promotes) |
| The global shelf | `polispec plan global` | `polispec apply global --confirm <plan-id>` |
| The ledger | `polispec plan ledger --from <file>` | `polispec apply ledger --from <file> [--confirm <plan-id>]` |

- Read the whole plan: files, ledger effect, composed policy diff, every probe whose verdict changes, and the classification.
- A **tightening** or **neutral** plan, other than one targeting the global shelf, may be applied directly. Adding a new project in `onboarding` status counts as tightening.
- Anything else — **loosening**, **mixed**, any global-shelf change, a status flip (`onboarding` → `live`, retirement), a profile, trust-ref or repo change — needs the user's explicit yes first. Ask with the question tool, show the plan id and the reasons, and only then run `apply … --confirm <plan-id>`. The guard also asks the user when it sees `--confirm`. Never confirm a plan yourself, and never reshape a change so that it classifies differently.
- A plan id binds the exact proposal. If anything changes, plan again; a stale id is refused.

## What agents never do here

- Edit the ledger, the global shelf, `specs/polispec/**`, the plugin store or the polispec runtime by hand.
- Flip a project to `live`, change `polispec.enforce`, or apply a loosening, mixed or global plan without the user's yes.
- Remove, rename or bypass a gate, freeze, rule or module to get a change through.
- Run `git worktree remove --force`, `rm -r`, `git clean` or `find -delete` on polispec trees, releases or backups. Back up in place first.
- Delete a pinned release; older releases are the rollback.
