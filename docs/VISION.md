# Where polispec is going

polispec began as a guard: a rulebook that keeps AI agents out of the live copy of an app. With recursive composition, that rulebook can become something larger: a **library of operating practice**. A release train, a data-handling regime, or a quiet-hours policy is written once, given parameters, and composed into every project that needs it, at any depth. Every agent inherits it and can show that it follows it.

This page describes that direction. It is not a commitment to a release. Every item carries a maturity label:

| Label | Meaning |
|---|---|
| **Built** | In the current release; see the README and `specs/app.yml`. |
| **Partial** | Some of it exists; the gap is named. |
| **Planned** | On the roadmap (`ROADMAP.md`), not built. |
| **Idea** | A direction worth exploring; no design yet. |

## Contents

- [The arc](#the-arc)
- [Composition](#composition)
- [Specs as a shared library](#specs-as-a-shared-library)
- [Every document composes](#every-document-composes)
- [Understanding a composed rulebook](#understanding-a-composed-rulebook)
- [Proving the rulebook holds](#proving-the-rulebook-holds)
- [Enforcement everywhere an agent runs](#enforcement-everywhere-an-agent-runs)
- [Beyond one host](#beyond-one-host)
- [Principles that do not change](#principles-that-do-not-change)

## The arc

1. **Guard.** One project and one rulebook, with allow, warn, and deny. *Built.*
2. **Pipeline.** Environments, promotion hops, gates, freezes, soak periods, and deploy receipts. *Built.*
3. **Composition.** Modules within modules, project and global shelves, typed parameters, and nested projects that carry everything they declare. *Built in 0.20.0.*
4. **Library.** Versioned specs imported across repositories and organisations, with a lock on exactly what was imported. *Idea.*
5. **Proof.** Every composed rule paired with evidence that it holds: negative controls, smoke coverage, and receipts. *Partial.*

## Composition

| Capability | Status | Notes |
|---|---|---|
| Modules include modules, to any depth, each instance once, cycles refused | **Built** | Since 0.16.0. |
| Global shelf shared by every project on a host, with profiles (`personal`, `service`, `live`) | **Built** | Since 0.16.0. |
| Strictest verdict wins across layers; loosening only through `overridable` and `overrides` | **Built** | Since 0.16.0. |
| Project shelf: a repo's own `specs/polispec/modules/`, read from its trust ref | **Built** | Since 0.20.0. A name on both shelves is an error. |
| Typed module parameters passed down through includes | **Built** | Since 0.20.0. Types are `string`, `integer`, `number`, `boolean`, and `list`. |
| Nested projects contribute their modules, gates (run in their own directory), freezes, and hermetic settings | **Built** | Since 0.20.0. Id collisions are errors. |
| Outermost project owns a nested path, whatever the ledger order | **Built** | Since 0.20.0. |
| Code specs as a tree of composite policies mounted at paths | **Built** | Since 0.15.0. |
| Parameter constraints (`enum`, `min`, `max`, `pattern`) and parameter documentation in `resolve` output | **Idea** | Today parameters are typed but unconstrained. |
| Conditional includes: include a module only for some environments, profiles, or facts (for example `when: { serves: real_users }`) | **Idea** | Today an include always applies to its layer. |
| Organisation layers above the host: organisation → team → service → subservice | **Idea** | Today the top layer is one global shelf per host. |
| Profiles that take parameters | **Idea** | Profiles list module names only. |
| Packages: named, versioned setups (files, modules, parameters, ordered steps) applied by `polispec apply` and recorded in the ledger | **Built** | Since 0.21.0; `environment-control` is the first. |

## Specs as a shared library

The step after composition is distribution. A clinic, a school, and a shop all want "no release while people are using it." Each should import one well-tested module, not copy it.

| Capability | Status | Notes |
|---|---|---|
| Versioned imports: `{ module: release-train, from: <repo>@<version> }`, resolved to a digest and recorded in a lock file | **Idea** | Today modules come from the host's global shelf or the project's own shelf. |
| A catalogue of practice modules: release trains, quiet hours, data residency, de-identification, on-call rotations, regulated-data handling | **Idea** | The clinic example's `release-train`, `soak`, `quiet-hours`, and `patient-data` are the seed. |
| Upgrade review: when an imported module changes, show which rules tighten or loosen before the project accepts it | **Partial** | Since 0.21.0 `polispec plan` classifies any project, global or ledger change, and package upgrades keep edited files as conflicts; versioned module imports do not exist yet. |
| Signed modules, and a sealed host that accepts only signed imports | **Idea** | The sealed plane already pins the global shelf to an exact commit. |

## Every document composes

Environment policy composes today. The other documents polispec governs could compose the same way.

| Document | Status | Direction |
|---|---|---|
| Environment policy (`polispec.policy/v1`) | **Built** | Modules, parameters, layers, nested projects. |
| Code specs (`polispec.spec/v1`) | **Built** | Tree of composite policies, referenced by spec path or policy id. |
| Environments (`environments.yml`) | **Idea** | The `environment-control` package ships variant templates; composable environment fragments (a standard `test` shape, say) do not. |
| Roster (`roster.yml`) | **Idea** | Shared role definitions included per project. |
| Behavioral policy (`polispec.behavior/v1`) | **Idea** | Shared directive sets for applications. |
| Harness controls (`polispec.control/v1`) | **Partial** | Controls compose as a severity ceiling over policy; they are not yet packaged as modules. |

## Understanding a composed rulebook

A deep rulebook needs equally good tools for reading it.

| Capability | Status | Notes |
|---|---|---|
| `resolve --layers`: every layer, its source, digest, rule count, and module instances, plus one effective digest | **Built** | |
| Verdicts name the rule id and the layer that decided | **Built** | |
| Rule provenance: for any verdict, the include path that brought the rule in (policy → release-train → soak) | **Idea** | |
| What-if replay: run recorded tool calls against a proposed rulebook before it is promoted, and list every verdict that would change | **Built** | Since 0.21.0: `polispec plan` replays synthetic probes and, when `polispec.verdicts.journal` is on, recent journaled actions. |
| A rendered map of the composition tree for a project | **Idea** | |

## Proving the rulebook holds

A rule nobody can show working is a claim, not a control.

| Capability | Status | Notes |
|---|---|---|
| Negative-control fixtures for code-spec enforcers (`code controls`) | **Built** | |
| Smoke ledger: chained records that a spec node was shown to work, with the runtime it ran on | **Built** | |
| Deployment receipts: proof that the deployed SHA passed its health check | **Built** | |
| A bundled smoke-test suite with scenario definitions, fixture builders, and headless harness runners | **Planned** | See `ROADMAP.md`. |
| Modules that ship their own negative controls and smoke checklist, so a project inherits proof obligations along with rules | **Idea** | |
| Coverage per composed rule: which rules in the effective rulebook have a current passing proof | **Idea** | Smoke coverage works per spec node today. |

## Enforcement everywhere an agent runs

| Capability | Status | Notes |
|---|---|---|
| Guard hook for Claude Code and Codex | **Built** | Since 0.22.0 Claude Code gets it from the plugin's native install; Codex still calls the shim from a host bridge. |
| Native artifacts for Hermes and Antigravity CLI | **Partial** | Generated; native runtime enforcement unverified on the release host. |
| Pi and DeepSeek TUI | **Partial** | Skills only; no native control backend. |
| OS sandbox (Bubblewrap) launch | **Partial** | Planning only; launch unavailable on the release host. |
| Sealed authority plane and lock edition | **Partial** | Built and published with feature flags off; no lock certification claimed. |

## Beyond one host

| Capability | Status | Notes |
|---|---|---|
| Ledger, receipts, and events per host | **Built** | |
| Cross-project freezes and gates (a release waits on another project's calendar or live state) | **Built** | Freeze `command` sources with `project`, and the `requires_live` gate. |
| A fleet view across hosts: one ledger, shared receipts, organisation layers | **Idea** | |

## Principles that do not change

However far composition goes, these hold:

- **Agents never write their own rules.** Every layer and module is read from a trusted ref or a sealed source, never from the working tree.
- **Composition only tightens by default.** A lower layer loosens an upper rule only where the upper rule allows it, by name.
- **Nothing is dropped silently.** A part of the rulebook that cannot be applied is an error that blocks promotion. It is never quietly skipped.
- **Judgement is deterministic.** Environment verdicts, gates, freezes, and composition use no model.
- **Claims carry evidence.** Native enforcement, certification, and deployment are claimed only where they were observed.
