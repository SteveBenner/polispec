# Features

Registry version: 0.18.0. Harness-control evidence audited on 2026-10-13. The existing capability table is retained below; the numbered additions distinguish an installed CLI from native or privileged enforcement. Both release feature flags remain disabled by operator direction. No lock certification or live-project activation is claimed.

| Capability | Build | Deployment | Verification |
|---|---|---|---|
| `polispec promote --waive-soak`: operator skips the `soaked` gates of a promotion past test, recorded as `waived` | Implemented in 0.17.0 | Live on this host: `~/.local/bin/polispec` runs this clone; needs an interactive terminal and the typed phrase `waive soak for <project>` | Scratch project with a 4 h soak gate: a dry run without the flag fails `not_soaked`; with it G-SOAK is `waived` and G-TESTED and G-FREEZE pass; a real promote through a pty moved stable and wrote `waived: [soak]` to the record and the event; a wrong phrase, no terminal, `--to test` and a policy without a soak gate are refused; a missing test deploy still fails G-TESTED under the waiver |
| Layered policy: global, repo and child layers, modules, profiles, `fallback_rules`, `resolve --layers` | Implemented in 0.16.0 | Off until the host sets `polispec.global.repo` | Scratch global: a repo allow cannot loosen a global deny unless it is overridable and named; 22 recorded verdicts identical with no global and with a fallback-only global; cycles, missing modules and bad overrides refused |
| Global baseline outside live projects (hook and fast path) | Implemented in 0.16.0 | Off until a global layer has rules | Scratch hook runs in enforce mode: `git add -A` denied in a repo outside the ledger, `git add <path>` allowed, a write into a global protected root denied, its declared writer allowed |
| `fs.delete`, shapes and the live predicates (`lock_held`, `live_binary`, `supervised`, `pin_regress`, `tag_claimed`, `base_unpushed`) | Implemented in 0.16.0 | `supervised` needs `polispec.supervisor.status_command` | 37 recorded commands classify as expected; each predicate matched and stopped matching on scratch processes, locks, binaries and repos |
| Any-named environments and promotion hops; `sha_ran_on`, `logs_quiet`, `requires_live`; profile checks | Implemented in 0.16.0 | `logs_quiet` needs `polispec.logs.count_command` | Scratch three-hop promotion main -> test -> canary -> stable; logs_quiet pass, fail and fail-closed; requires_live on scratch deploy records; old two-hop policies give byte-identical output |
| Environment guard and classifier with allow, warn and deny verdicts | Implemented in 0.15.0 | The host wires the guard hook into each harness (see `docs/operator.md`); `polispec.enforce` defaults to `advise` | Real runs of `polispec resolve`, `polispec doctor` and `polispec hook` against scratch projects |
| Policy, roster, ledger and environments schemas with `polispec validate` | Implemented in 0.15.0 | None needed; runs from a clone or an rplugin install | `polispec validate auto` on every example |
| `polispec promote` and `polispec deploy` with gates and freezes | Implemented in 0.15.0 | Needs a ledger entry, a policy on the stable ref and an interactive terminal for stable | Scratch repositories; freeze windows from `source: command` and its legacy alias |
| `allow-once` and `pause` operator commands | Implemented in 0.15.0 | Needs an interactive terminal and a typed phrase | Refused without a terminal |
| Roster resolution and checks | Implemented in 0.15.0 | The host wires session and subagent start hooks to inject role values | Scratch rosters validated and resolved |
| Behavioral policy compilation and declarative deny evaluation | Implemented in 0.15.0 | The consuming application owns authentication and enforcement | Compile output is deterministic; decide exercised on declarative rules |
| Code specs: language detection, chain injection, changed-line enforcement with ratchet and waivers | Implemented in 0.15.0 | Needs a code specs repository (`polispec.code.specs_repo`) whose `stable` branch carries specs; the host wires the write hooks | Chain and check commands on scratch files |
| Contextual policies through the rplugin decide port | Implemented in 0.15.0 | Needs a decide port from the host; without it the policy defers to task-end review | Defers when the port is absent |
| Environment manifest `specs/polispec/environments.yml` merged into the policy | Implemented in 0.15.0 | Read from the trust ref; a project without the file resolves as before | Inline, split, duplicate and invalid cases on scratch repositories |
| `polispec onboard` for a new user-serving project | Implemented in 0.15.0 | Run per repository; a ledger path must be writable | Both archetypes, dry run, and refusal on a second onboard |
| `[ENVS]` AGENTS.md row, `agents render` and doctor `agents_drift` | Implemented in 0.15.0 | A repository carries the row after `agents render` lands on its stable ref | Row upsert and drift detection on a scratch repository |
| Git hooks per environment (`hook git`) | Implemented in 0.15.0 | Installed per checkout with `hook git install`; silent while a project is `onboarding` | Scratch prod and dev checkouts: commits and ref moves denied where the policy denies them |
| Hermetic runs (`hermetic.<env>.isolate`, `protected_roots`) | Implemented in 0.15.0 | A policy opts in per stage; the host needs nothing beyond a writable `$POLISPEC_HOME/scratch` | Scratch run: a step writing a protected root fails with `wrote outside its location` |
| Per-gate `hermetic: false` for read-only checks of the installed copy | Implemented in 0.15.1 | Installed locally | Scratch promote dry run of a project whose test stage isolates the plugin home and protects its corpus: the two opted-out `check`/`doctor` gates pass and are recorded `"hermetic": false`; before the change the first failed |
| `release_dirs` deploys with drain, drain checks, automatic rollback and `--skip-drain` | Implemented in 0.15.0 | A policy opts in per stage; the first deploy of a project whose live release predates its drain commands needs `--skip-drain` once | Scratch run: swap, failed-health rollback recorded `rolled_back`, drain resume on failure, retention by tag version |
| Gates `soaked` and `health_required`, `to_stable.preflight`, `flip_latest: deferred`, freeze `command` source with `project` | Implemented in 0.15.0 | A policy opts in; a freeze command is any executable in the prod checkout that prints JSON windows | Scratch run for soak hours and preflight; alias parity with the deprecated activity and calendar sources |
| Match keys `crosses: location` and `destructive` | Implemented in 0.15.0 | Active once a policy rule uses them | Destructive SQL and shell samples classify as expected; policies without the keys give identical verdicts |

No tests were added. Application adapters own authentication, native enforcement and domain parameter validation. A declared binding and matching artifact are traceability evidence, not a formal proof of behavioral equivalence.

| Read-only deployment receipts in `status --json` | Implemented in 0.17.1 | Active on this host through ~/.local/bin/polispec -> source main 87f39a9; no separate installer rewrite or release tag | Scratch status CLI consumes deployment state written by the real record_state function; successful receipt verifies, an in-progress or newer failed attempt, legacy identity, unchecked health, pin, SHA mismatch, tag mismatch, and malformed state fail closed in Teach's actual shipping script; native Teach test promotion dpl_c67a77af62577cdf8cd7 reports verified true for v0.83.3 with matching health, SHA, tag, and receipt identity |
| Smoke ledger `smoke.yml` and `polispec smoke record\|list\|show\|verify\|coverage` | Implemented in 0.18.2 | Runs from any install; ships no smoke suite (bundled suite is on `ROADMAP.md`). Truncation detection exists only where the recording state home's head anchor exists | Worker acceptance runs in scratch repos (chain, digest, stale, truncation, privacy grep, 8 concurrent records); then real headless Claude Code Haiku runners exercised every app.yml coverage unit in isolated scratch projects with the guard wired, recorded in this repository's `smoke.yml`: 49 entries, coverage 14/26 proven, 5 partial, 4 blocked by activation, 2 failing. The bugs found were fixed in 0.18.3 to 0.19.0 and re-smoked by Haiku runners and scripted agent checks: 73 entries, verify finds only stale (superseded) entries, coverage 22/26 proven, 4 blocked by activation (`plane`, `authorizations`, `harness_controls`, `protected_authorizations`; those flags stay off) |

## Harness controls in 0.18.0

### 1. Deterministic control language

Build: implemented. Deploy: installed CLI 0.18.0, verified for parsing, validation, and planning. Blocker: none for these operations.

`harness grammar`, `parse`, and `plan` publish a bounded deterministic language and `polispec.control/v1`. The calling agent translates intent; a model never participates in the control judgement. Every requested control retains an explicit backend disposition, including unsupported behavior.

### 2. Native backend artifacts

Build: implemented artifact generation. Deploy: CLI planning and isolated fixtures; native enforcement remains unverified. Blocker: access and human operation of isolated native journeys.

Claude Code, Codex, Hermes, Antigravity CLI, and OS backends emit their own protocols and configuration paths. Claude and Codex parser acceptance was observed, and Codex's direct `--yolo` exec-rule refusal was observed. Hermes and agy were absent; Bubblewrap could not start a user namespace. Antigravity GUI remains directive-only, and Antigravity lock certification is unsupported. The detailed evidence is in `data/harness-capabilities.yml`.

### 3. Tightening installation and authenticated removal

Build: implemented. Deploy: mutation flag OFF; lifecycle verified on scratch fixtures. Blocker: explicit operator activation, plus protected setup for managed and sealed use.

The lifecycle backs up owned changes, preserves foreign configuration, checks actual contributions, and records bounded transactional receipts. Agents can add provably tightening user/project controls. Removal, uncertain comparisons, and loosening require operator authority. Explicit owner handoff drops groups, GID, and UID before touching the selected user's mutable files or SDK state.

### 4. Protected authority plane

Build: implemented. Deploy: sealed-plane flag OFF; no host installation or activation. Blocker: explicit operator activation, independently protected SDK/runtime, privileged installation, and native evidence.

A fixed root-owned authority record selects verified generations and a pinned launcher. Standard sources come from exact Git commits; lock sources are root-authored under `/etc/polispec/source`. Invalid existing authority cannot fall back to mutable settings. Preparation, switching, activation, and rollback are explicit authenticated operator actions. No project serving real users was activated during this release.

### 5. One-use authorization service

Build: implemented. Deploy: scratch Unix transport exercised; host service not installed or started. Blocker: operator setup of the protected plane and service.

The service authenticates kernel peer identity, binds exact action and complete ask context, and records durable consumption before replying. Competing consumers, replay, changed bindings, timeouts, and lost replies cannot create another grant. Redemption stays local to the protected operator; the fixed kill marker and explicit stale-socket recovery fail closed. A rendered unit is not a running service.

### 6. Guard ceilings and failure behavior

Build: implemented. Deploy: new automatic ceilings OFF; existing callbacks retain legacy policy behavior. Explicit-control and sealed paths were exercised on fixtures. Blocker: operator activation and backend-specific native callback trust and failure semantics.

In enforce mode, independent control ceilings compose with environment policy without changing its first-match rule order. MCP declarations match every action's trusted selectors. Fixed native denial bytes handle judgement failure, positive diagnostic reads remain available, and incomplete stdin cannot hang past the hook budget. Multi-edit and rename endpoints are all classified. Environment pause or a legacy pass cannot erase protected denials or lock defaults.

### 7. Exposure history and root guard

Build: implemented. Deploy: CLI and isolated state journeys; no host guard was armed by development. Blocker: operator recording for protected history.

The first root-equivalent exposure advises remediation; a distinct continuing scan arms root guard. Rootless detection is recorded separately. Protected records validate schema, provenance, actual probed UID, observations, and sequence, and corrupt history conservatively arms. The classifier refuses known risky container operations but does not certify isolation.

### 8. Standard and lock release provenance

Build: implemented. Deploy: independent edition checkouts and release operation verified on scratch remotes; runtime activation remains OFF. Blocker: none for source distribution; activated lock still needs every native and protected prerequisite.

`main` carries standard, and `polispec-lock` has the same code with one `EDITION` change. The release operation validates the accepted main commit, pins one fetch/push endpoint, archives a prior local ref, and uses an exact lease for the lock ref only. Ambiguous pushes report recovery-required. Doctor checks local provenance against immutable release ancestry without requiring the other edition checkout. A lock executable refuses a standard active plane instead of silently downgrading.

The standalone plugin has no matching compiled rhomeostasis obligation verifier. Reviewed commits and real CLI/rplugin checks proceed under the operator's recorded exception; attestation is unavailable, not passed.
