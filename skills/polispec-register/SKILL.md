---
name: polispec-register
description: >
  Put software, a directory or the system scope that is not a git repository
  under polispec. Use when the user asks to govern, protect, register or
  unregister a directory, an installed program, a data folder or the home
  directory, to see what polispec says about one, or to publish the index of
  what is governed.
---

# polispec-register

A path entry in the ledger brings something that has no git repository under polispec's guard. The registration only ever adds an `onboarding` entry, which changes no verdict until an operator makes it `live`, so it is safe to propose.

## When to use it

- The user names a directory, a program, a data folder, or "my machine" or "my home directory" and wants agents held to rules there.
- The path is not inside a ledgered project's repository or worktree. If it is, the project's own policy governs it: use the `polispec` skill instead.
- The user wants an entry retired (`unregister`) or the registration listed.

## How to do it

1. Interview first. Ask what it is, who it serves, what must never happen to it, and who else uses the machine. Do not guess the answers.
2. Pick the kind from the answers: `directory` (the default) for a folder, `software` for an installed program or tool tree, `system` for the home directory only (any other path is refused).
3. Pick an `--id` (lowercase letters, digits and hyphens, at most 41 characters, unique across projects and paths) and write a `--description` of two to eight sentences and at least 20 words that names what the entry governs and states an effect in words (allow, ask, warn, deny, refuse, promote or freeze). `polispec validate` and `polispec doctor` lint it; a description that repeats a summary or names nothing is reported.
4. Dry run first. This prints the plan and writes nothing to the ledger:

   ```
   polispec register <path> --id ID --kind KIND --description TEXT --dry-run
   ```

   Read the plan. It should classify as `tightening` and say it adds the path with status `onboarding`. The entry records the owner (your uid and login name) and `registered_by` (`POLISPEC_ACTOR`, else `cli`), so another user on the machine sees whose it is.
5. After the person says yes, run the same command without `--dry-run`. A tightening plan applies; a plan that needs confirmation prints its plan id, and the operator runs `--confirm PLAN_ID`.
6. Offer a starter module. The entry's rules live in `paths/<id>.yml` on the global shelf (schema `polispec.module/v1`), for example a `fs.delete` deny scoped to the directory. Propose it as a file, validate it with `polispec validate module <file>`, and give the person `polispec plan global` and `polispec apply global` to run; never edit the ledger or the shelf by hand. The entry stays inert until the operator sets it `live` through a confirmed ledger plan.
7. `polispec unregister <id>` retires an entry; it is a loosening, so it needs `--confirm PLAN_ID` from the plan it prints.

## What it refuses

- A missing path (`path_missing`), a path inside a ledgered project (`inside_project`), a repeated id (`id_collision`) and an already registered path (`path_registered`).
- Under the lock edition, every governed path (`edition_restricted`): only the protected ledger the sealed plane names can add one.
- With `runtime_behind` while the installed polispec release is older than 0.34.0, because that runtime rejects a ledger with `paths`, `owner` or `registered_by`. Tell the person to install 0.34.0 first; a dry run still previews.

## Publishing the index (opt-in)

`polispec manifest index` prints the machine's index of governed projects and paths. Publishing it for other local users is the person's own decision and an operator action: `polispec manifest index --publish` needs their terminal and the phrase `publish polispec index for <user>`, and writes a world-readable file with owners and governed paths. Never run it for them, and never suggest it unprompted. It does not exist under the lock edition.

## Rules

- Never edit the ledger, `smoke.yml` or the global shelf by hand; every change goes through `register`, `plan` and `apply`.
- Do not register a path the user did not name, and do not widen a path to its parent.
- Moving an entry to `live`, retiring one and publishing are the operator's. Give the exact command.
