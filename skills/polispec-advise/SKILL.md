---
name: polispec-advise
description: >
  Scan an agent's history, a project, or named files and data to suggest
  polispec specs and directives for the use case: spec drafts for the person to
  plan, and advisory guidance. Use when asks repeatedly block unattended runs,
  when a project needs a first policy, or when the user asks what polispec
  should govern. Read-only. Not for applying a spec or changing a verdict.
---

# polispec-advise

Suggest; never apply. Output is a spec draft to hand to `polispec-specs`, advisory directive text, or both, each labelled tightening or loosening with who must confirm. This skill writes no spec, ledger, exception, hook or setting, runs no `apply`, and records no proposal.

## Start

1. Find the installed CLI as `polispec` does: `command -v polispec`, `polispec version`, `polispec doctor`. Never use a repository's `bin/polispec` as the host.
2. Read the context that removes levers: edition (`polispec editions`), sealed plane (`polispec plane status`), kill switches (`polispec settings get polispec.exceptions`). Drop levers that are unavailable and say so.
3. Read `docs/agent-guide.md` for the lever model and `patterns.md` beside this file for the catalog.

## Choose the evidence

Ask which scope the person means if it is unclear, using the question tool. Then use only these read-only sources, in this order of cost:

| Need | Source |
| --- | --- |
| Which rules fire and how often | `polispec digest --since 7d` |
| Which calls, by rule, tool, class, verdict | `polispec judgments list --json --since 7d` |
| Asks an exception could cover | `polispec exceptions list --json` |
| Why one call got its verdict | `polispec explain` with the real payload |
| What a project is and needs | `polispec resolve . --layers`, `polispec status`, the project's own files |
| What the person kept doing | the harness's history, only paths the person named |

Limits that change the advice: judgments hold no command text unless `polispec.records.raw` is on (never suggest turning it on without the user's yes); proposals last seven days; skills-only harnesses have no judgments; Codex shows a warn as a deny, so read the recorded verdict.

Scanning discipline: named paths only, one filesystem, never from `/` or a slow mount; never read a production checkout's data or env files; redact tokens, keys and credentials from any snippet; quote counts and ids, not raw secrets.

## Find the pattern

Match what you see against `patterns.md`. Reason from the top: posture, structure, domain, rule, match. Take the highest level that solves it. Prefer fewer distinct asks over more exceptions.

## Write the suggestion

For each suggestion give:

- **Evidence**: counts, rule ids, sessions, window. No secrets.
- **Lever**: one of declare, narrow, exception, allow-once, or new rule, in that preference order.
- **Draft**: a spec fragment as pseudocode or a short skeleton with placeholders, or advisory directive text. State the minimum polispec version for each key it uses (`patterns.md` lists them) and that unknown keys make a schema reject the file.
- **Classification and confirmer**: tightening or neutral (agent may apply the plan), loosening, mixed or global (user's yes and the plan id), catalog or exception (operator at a terminal), sealed (authenticated operator).
- **Effect**: a project change takes effect after the operator promotes to stable. A catalog activation changes every effective digest.

Then hand the draft to `polispec-specs` to validate, lint and plan. `polispec author draft` can produce a validated draft and its plan when the author port is available and the edition allows it; it starts a model session and writes nothing.

Directive text targets the canonical behavior directive followed by `polispec behavior render`, never a generated row such as the `[ENVS]` line. Do not reuse the exact wording of an existing directive.

## Never

- Coach evasion: no rewording a refused call, no moving work to another tool, no editing a spec or the ledger to change a verdict, no self-redeemed `allow-once`.
- Suggest overriding `G-WEB-AGENT`, `G-DELETE-*`, `R-POLISPEC-RUNTIME`, `POLISPEC-CONTROL-PROTECTION`, the root guard or a broken seal. These cannot be lifted by exception.
- Suggest an exception for a deny, under lock, or while sealed.
- Put host paths, project ids, host names or operator names in a suggestion destined for a shipped default; those belong on the person's shelf or ledger.
- Apply, confirm, promote or record anything.
