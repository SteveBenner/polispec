# Independent peer review, 14 October 2026

An acquaintance working in AI research reviewed polispec on 14 October 2026 and shared this package with the maintainer. The reviewer has no affiliation with the project, and the review is not an audit or a certification. It is kept here unchanged, as received.

What polispec does with it is described in [`docs/CURRENT-STATE.md`](../../../docs/CURRENT-STATE.md).

## What was reviewed

- **Version:** polispec **0.19.1**, the public `main` branch of `github.com/SteveBenner/polispec` as fetched on 14 October 2026. That was the latest release then: 0.19.1 shipped on 13 October and 0.20.0 the following day. Every file the review cites is the same in 0.19.0 and 0.19.1, apart from smoke records added in 0.19.1.
- **Files read:** `README.md`, `examples/policy.shop.yml`, `docs/harness-controls.md`, `docs/operator.md`, and `smoke.yml`.
- **Not performed:** full source inspection, checkout of a pinned revision, native harness execution, privileged host setup, and adversarial runtime tests.

## Files

| File | What it is | sha256 |
|---|---|---|
| [`polispec_peer_review.pdf`](polispec_peer_review.pdf) | The review: an assessment, five findings, a 13-scenario matrix, a qualification roadmap (P0 to P2), an acceptance standard, and questions for the maintainer | `0e8c19451ad6ea1b764d69f55fb78a06820e41a179caee7fb9ac00fc1af12991` |
| [`polispec_scenario_sim.py`](polispec_scenario_sim.py) | The reviewer's simplified first-match model of the `examples/policy.shop.yml` rules (standard-library Python) | `e5d162dc85074867934e161518c5cd8947c0588a6d960a01adba6c0a59759664` |
| [`polispec_simulation_results.csv`](polispec_simulation_results.csv) | The model's output for 13 synthetic scenarios | `851af02fcfde9c42a38a95ba5272eba663b814fb63de67956819585630336ff1` |

To reproduce the modelled outcomes, run `python3 polispec_scenario_sim.py` from this directory. It rewrites the CSV beside it.

## Reading it correctly

The review's own labels are **DOCUMENTED** (repository claims or configuration), **REPORTED** (an observation the maintainer recorded), **SIMULATED** (the reviewer's simplified model), and **UNVERIFIED** (needs a real run).

The simulator is **not** polispec and **not** a runtime test. It shows that the example rules read the way they are meant to. It does not exercise polispec's parsers, hooks, authority, or fail-closed behaviour. Every finding labelled REPORTED comes from the maintainer's own `smoke.yml`, which the reviewer did not reproduce.
