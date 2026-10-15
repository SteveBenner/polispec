# Roadmap

Planned work, not yet built. Nothing here is a commitment to a release, except where an item says so.

## Independent review follow-up

The qualification work from the independent review of 0.19.1. The two P0 items are committed: polispec claims no preventive enforcement until both are done. The rest is intended. The full list, the acceptance standard, and current status are in [`docs/CURRENT-STATE.md`](docs/CURRENT-STATE.md).

- **P0:** reproduce the post-write failure and prove prevention.
- **P0:** test the authority boundary's failure modes.
- **P1:** cross-harness execution matrix; race, recovery, and consistency.
- **P2:** usability and overhead benchmark.

## Standing exemptions

When polispec blocks or warns, the user can answer *yes, and stop asking* to create a standing exemption. Today an allow-once covers a single action, so the same prompt comes back on the next matching call. An exemption stops that rule from firing again for the same kind of action until the exemption is retired.

- **Scope:** one exemption covers one rule, in one project, for one action class and one target pattern, such as a path glob or a command family. It never covers the whole rule, and never other projects.
- **Granted by a person:** the exemption is created only from the user's explicit yes at the prompt. An agent can never grant, widen, or renew one, in the same way it can never redeem an allow-once. In a live project, and under the sealed plane, granting follows the same operator authority as other loosening.
- **Recorded and versioned:** every grant and every retirement is a recorded polispec change. Each change is a commit on the project's polispec specs and an event, carrying who granted it, when, the verdict it answered, its scope, and the reason. `polispec plan` classifies it as loosening, and the history of what was exempted, and when, stays in git.
- **Retirement:** `polispec exemption retire <id>`, recorded like the grant. An exemption also lapses on its own when the rule it exempts changes (its digest moves), so the prompt returns for the new rule. Every `promote` preview lists the open exemptions, so they are reviewed on a regular rhythm.
- **Visibility:** `polispec status` and `doctor` list open exemptions, and a verdict that an exemption suppressed is still logged with the exemption id.

Open questions: whether an exemption granted on `main` takes effect at once or only after promotion, like other policy edits; and how exemptions interact with the strictest-verdict-wins composition when the exempted rule comes from the global shelf.
