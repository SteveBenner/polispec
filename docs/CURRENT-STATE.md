# Current State of Polispec

As of **0.47.2** (26 October 2026).

## In one paragraph

polispec is pre-1.0 software that its maintainer uses every day on their own host. The guard is deterministic, judges every tool call against a rulebook read from a trusted branch, and is backed by a bundled smoke suite of 50 scenarios run against scratch fixtures, some with steps that run real headless Claude Code and Codex sessions on request (`polispec smoke run --live`); the last live runs were recorded on 16 October 2026. Every call the guard judges leaves a chained record of the call digest, the rulebook digests and matched rule, the polispec that judged it, and the verdict the harness received (`polispec judgments`, since 0.25.0). Since 0.33.2 the hook launcher fails closed: with no verdict it denies every call except reads. Code specs deny a violating write before it lands by default (`pre_write`). Harness controls are on by default. Three things limit what it can claim today. The sealed authority plane and the lock edition ship enabled since 0.45.1, but installing polispec seals no host, so an unsealed polispec is a guardrail, not a security boundary, and no lock certification is claimed. The default enforcement mode is `advise`, which blocks nothing. Native enforcement has been observed for some harnesses and versions only. Nobody outside the project has yet reproduced any of its enforcement results.

## Independent review of 0.19.1

On 14 October 2026, an acquaintance working in AI research reviewed polispec **0.19.1**, then the latest release on the public `main` branch. The review read the README, the shop example policy, the harness-controls and operator guides, and the smoke ledger. It also ran its own simplified model of the example rules. It did not run polispec, a harness, or adversarial tests, and it is not an audit or a certification. The package is kept unchanged, with provenance and checksums, in [`independent/assessments/2026-10-14-peer-review/`](../independent/assessments/2026-10-14-peer-review/).

The reviewer's overall conclusion: *promising architecture and unusually candid documentation of verification gaps.* The project would benefit most from *a smaller, harder, reproducible enforcement matrix before claiming broad native protections.* The principal concern is qualification completeness rather than a demonstrated design defect.

### Findings and where they stand now

| Finding | In 0.19.1 | Now (0.47.2) | Next |
|---|---|---|---|
| **F-01** Post-write failure path (high) | REPORTED in `smoke.yml`: with `polispec.code.check_at: post_write`, a private-key literal landed on disk, the PostToolUse hook returned nothing (fail open), and a direct `polispec code check` flagged the file. | `pre_write` is the default and denies before anything lands; the recorded case used the opt-in `post_write` mode, which by design lets the write land and then blocks. The bundled `code-hook` scenario asserts a pre-write deny before the file lands and a post-hook block under `post_write`. The live code-write runs are still those of 0.25.0: Claude Code 2.1.300 denied a violating write by rule `code`, with the file absent; Codex 0.162.1 also denied with the file absent, but its recorded reason is `POLISPEC-INTERNAL`, not the code rule, so that result counts as inconclusive and is not yet explained. | P0 below |
| **F-02** Enforcement defaults to advisory (medium) | DOCUMENTED: `polispec.enforce` defaults to `advise`. | Unchanged. `polispec status` and the session-start context in a live project print the guard mode, and the README's honest limits say advise blocks nothing. Neither says, where it prints the mode, that advise blocks nothing, and `doctor` and onboarding do not mention the mode. | Make the active mode unmistakable everywhere it is reported |
| **F-03** Harness-native guarantees incomplete (high) | DOCUMENTED in `docs/harness-controls.md`. | `polispec smoke run --live claude-code\|codex` runs real headless sessions whose hooks run the guard. The last recorded runs, on 16 October 2026, are Claude Code 2.1.300 and Codex 0.163.0 sessions denied a push to stable by the guard and denied by an installed project-scope control. Since 0.33.1 a Hermes block passes through the launcher, shown by a scripted scenario, not a Hermes runtime. The capability table still marks native control denial journeys, Hermes and Antigravity enforcement, and Codex callback failure behaviour as unverified; Pi and the DeepSeek TUI get skills only. No capability-by-version matrix exists yet. | P1 below |
| **F-04** Example policy warns, not denies, on production data writes (contextual) | DOCUMENTED: `R-PROD-DATA` in `examples/policy.shop.yml` is `warn`. | Unchanged and intentional: live data writes are an operator decision in that example. The examples do not yet say plainly that they are illustrations rather than a secure baseline, or which separate boundary should protect live data. | Label example policies as illustrations and name the boundary they assume |
| **F-05** Rule-model consistency (limited positive) | SIMULATED: the reviewer's model returned the expected verdict for all 13 scenarios. | Unchanged. The smoke suite runs scenarios against polispec's own engine, but it does not replay these 13 cases. | Add the 13 cases as a smoke scenario against the real engine |

## What we intend to do

**Committed.** Until both P0 items are done, polispec claims no preventive enforcement:

1. **Reproduce the failure and prove prevention.** Pin the exact commit and harness versions, run in `enforce` mode, reproduce the post-write secret case alongside a pre-write control, and inspect the resulting filesystem, exit codes, and event traces. A pass means prohibited content never persists, or a documented corrective action prevents its use. The Codex `POLISPEC-INTERNAL` denial gets explained as part of this work.
2. **Test the authority boundary's failure modes:** malformed events, hook timeouts, callback process death, a missing or modified trusted policy, a corrupt installed receipt, renamed protected paths, symlink traversal, direct shell equivalents, and stale approval replay. Each test asserts the side effects it observes, not only the verdict returned. Since 0.33.2 the launcher denies every non-read call when polispec is missing, exits with an unexpected status, or passes its 8 second deadline, and the hook denies input over 8 MiB; the bundled `guard-failclosed` scenario asserts the denial bytes, the read pass-through and the `launcher.jsonl` record on scratch fixtures. That covers part of the timeout and malformed-event cases, but no case has yet been recorded to the acceptance standard below.

The P0 work follows the review's acceptance standard. Each case records its scenario id, policy and trust-ref hashes, implementation commit, runtime and harness versions, environment, exact tool event, expected and observed decisions, the resulting side effect, a raw-log checksum, and the cleanup outcome. Results are reported as PASS, FAIL, NOT TESTED, or INCONCLUSIVE. A reported block with the forbidden file already written counts as a FAIL for preventive enforcement. Since 0.25.0 the guard records the policy digest, the implementation commit and runtime, the exact tool event as a digest, and the expected and rendered decision itself, per call, in the judgment stream; the harness version, the side effect and the cleanup still come from the smoke entry.

**Intended**, in the review's order of priority:

- **P1, cross-harness matrix:** concrete allow, deny, and ask flows on named versions of Claude Code and Codex first, then Hermes and Antigravity where real runtimes are available. Absent runtimes are marked NOT TESTED, and parser acceptance is reported separately from enforcement.
- **P1, race, recovery, and consistency:** concurrent tool calls, interrupted installation, atomic mutation and rollback, trusted-ref drift, and event and receipt integrity.
- **P2, usability and overhead:** denial true-positive and false-positive rates, evaluation latency, workflow disruption, the quality of recovery guidance, and maintenance cost on representative legitimate tasks.
- The follow-ups from F-02, F-04, and F-05 in the table above.

Progress is recorded in this file, in [`CHANGELOG.md`](../CHANGELOG.md), and as evidence in [`smoke.yml`](../smoke.yml).

## Open questions from the review

These are still open. Their answers will be recorded here.

- Is post-write checking meant to be preventive or detective? Today the setting documents `post_write` as letting the write land, so preventive claims rest on `pre_write`.
- Which harness and version combinations are genuinely enforced?
- What is the fail-closed policy when a hook fails? Since 0.33.2 the launcher's answer is to deny every non-read call and record the failure, with no setting that turns it off; how each harness treats a hook that it cannot start at all is still unverified.
- Which production operations intentionally stay warn-only, and which independent controls constrain them?
- What evidence is needed before an enforcement or lock claim is made?

## How to read claims about polispec

This page uses the review's evidence labels. **DOCUMENTED** means the repository says so. **REPORTED** means the maintainer recorded an observation, usually in `smoke.yml`. **SIMULATED** means a model of the rules, not polispec itself. **UNVERIFIED** means it still needs a real run. A smoke entry is first-party evidence until someone outside the project reproduces it.
