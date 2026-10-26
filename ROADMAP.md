# Roadmap

Planned work, not yet built. Nothing here is a commitment to a release, except where an item says so.

## Independent review follow-up

The qualification work from the independent review of 0.19.1. The two P0 items are committed: polispec claims no preventive enforcement until both are done. The rest is intended. The full list, the acceptance standard, and current status are in [`docs/CURRENT-STATE.md`](docs/CURRENT-STATE.md).

- **P0:** reproduce the post-write failure and prove prevention.
- **P0:** test the authority boundary's failure modes.
- **P1:** cross-harness execution matrix; race, recovery, and consistency.
- **P2:** usability and overhead benchmark.

## Standing exemptions: what remains after 0.29.0

0.29.0 built the core of this item as persistent exceptions (`polispec exceptions list|add|promote|remove`, `exceptions.yml` on the global shelf). An ask records a proposal, and the operator promotes it from a separate terminal with a typed phrase. Each grant and removal is a planned and applied commit on the shelf, a lifted call's judgment record carries the exception id, and an agent can never grant, widen or renew one. Exceptions lift only asks and warns, never a deny, and match the unexpanded command text, scoped to one project or the whole host. What the original plan named and is still unbuilt:

- **Grant at the prompt:** the user's *yes, and stop asking* at the ask itself creates the exception, under the same operator authority as other loosening in a live project or under the sealed plane.
- **Lapse with the rule:** an exception lapses on its own when the rule it lifts changes (its digest moves), so the prompt returns for the new rule.
- **Target patterns beyond command text:** a scope by action class and path glob, so a file tool's ask can be lifted for one directory rather than by the text of a shell line.
- **Review rhythm:** every `promote` preview lists the open exceptions, and `polispec status` and `doctor` list them, not only invalid ones.

Open question: how an exception should interact with the strictest-verdict-wins composition when the asking rule comes from a project policy rather than the shelf the exception lives on.
