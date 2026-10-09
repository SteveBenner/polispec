# POLISPEC — Obey the Policy of a Live Project

A live project is listed in the host's ledger (`POLISPEC_LEDGER`, else the `polispec.ledger` setting, else `~/.config/polispec/ledger.yml`) with `status: live` and carries a versioned policy under `specs/polispec/`. The guard reads that policy from the project's stable ref, never from the working tree, so no agent can loosen its own rules. A project with `status: onboarding` is listed but not enforced.

## Three verdicts

Every tool call in a live project gets one verdict from the policy: `allow`, `warn`, or `deny`. Each carries a reason and a way forward. `deny` stops the call. `warn` is stern: it needs explicit confirmation from the user. Dev work on main stays frictionless.

## What agents never do

- Run git against the `stable` branch, or push, tag, or reset `test` or `stable` directly.
- Start, stop, restart, enable, or edit a live service unit.
- Edit files in a production checkout.
- Read or write production secrets.
- Copy data between environments. Test holds de-identified data only.

## Warn handling

On a `warn` verdict, ask the user with the question tool. State what you are about to do and why, and proceed only on an explicit yes. Never self-redeem `polispec allow-once`, never retry the call in another shape, and never edit the ledger or `specs/polispec/**` to change a verdict (those edits are `warn` tier themselves).

## Promotion paths

Branches run main (dev) to test to stable (prod). Test fast-forwards only from main, and stable fast-forwards only from test; neither is ever rewritten. An agent promotes with `polispec promote <repo> --to test`, which allows on a green gate and denies on red, and tags the release. An agent never pushes `test` or `stable` directly. Only the operator (the person named by the `polispec.operator` setting) runs `polispec promote <repo> --to stable`, `polispec deploy <repo> stable`, `polispec pause`, and `polispec allow-once`, each from a TTY with a typed phrase. The operator may hotfix stable directly; the drift rule then forces the patch back into main before the next promotion.

## Roster

The project's `specs/polispec/roster.yml` governs the harness, model, and effort of every role, including interactive subagents and skill workflows. Session and subagent start inject the role's values. Spawn only within them.

## Environments

Projects use branches main, test, stable. Environment checkouts live at `~/.polispec/envs/<repo>/<env>`.

- Only the operator runs `polispec promote --to stable`, which flips the release to Latest. Rollback is `polispec deploy <repo> stable --tag vPREV`, also the operator only.
