---
name: polispec-specs
description: >
  Create, edit, validate, and safely apply polispec environment rulebooks,
  modules, rosters, ledger proposals, application behavioral policies, and
  code-spec packs. Use when an agent must modify polispec specs or migrate
  directives into them. Not for generic product requirements or bypassing a
  guard denial.
---

# Edit polispec specs

Use [polispec](../polispec/SKILL.md) to locate the installed CLI and plugin root. Read the plugin's `rules/polispec-stewardship.md` before changing a governed rulebook. The commands below use uppercase placeholders for values you must obtain from the actual project, not defaults to copy literally.

## Identify the spec and its authority

Start with `polispec version`, `polispec help`, and `polispec resolve .` in the target project. Read its instructions and the relevant source before proposing changes. Distinguish these documents:

| Document | Purpose | Read when authoring |
| --- | --- | --- |
| `specs/polispec/policy.yml`, `environments.yml`, `roster.yml`, and sibling modules | Development environments, allowed actions, release gates, data boundaries, and agent roles | `docs/schema.md`, `docs/environments.md`, and `docs/operator.md` |
| Global shelf and host ledger | Shared rules, composition, and which projects or paths are governed | `docs/schema.md` layers and ledger sections; `rules/polispec-stewardship.md` |
| `polispec.behavior/v1` or `polispec.behavior/v2` | An application's directives, bindings, and generated agent-facing surfaces | `docs/behavior.md` and the matching schema under `schemas/` |
| Code-pack `specs/.../spec.yml`, `polispec.spec/v1` | Language and domain rules applied when agents write code | `docs/code-specs.md` and `schemas/spec.v1.yml` |
| `polispec.control/v1` | Native harness controls with a separate authority ceiling | Main skill's harness-controls workflow and `docs/harness-controls.md` |
| An application's own `specs/app.yml` | That application's implementation contract | Its repository instructions and contract; it is not automatically an environment policy |

Paths above are conventions. Resolve actual rulebook paths, project ids, trust refs, shelf locations, and code-pack settings from this installation. Documentation and schema paths are relative to the plugin root. Do not assume every project has `dev=main`, or that a repository's current files govern running sessions.

Preserve rule ids, foreign contributions, and unrelated behavior. Use the published schema and matching examples; never invent keys, action classes, predicates, or model names. Define the intended outcome in terms of concrete calls and expected allow, warn, or deny verdicts. Do not translate a reported denial into permission to remove its rule.

## Environment policy, environments, roster, and modules

1. Inspect `polispec resolve . --layers` and `polispec status`. Identify the trusted policy and all layers that may override or tighten the proposed rule. The guard reads the trust ref, normally `stable`, rather than a draft working tree.
2. Prepare the smallest candidate change in an authorized development checkout or separate worktree. A policy-edit warning still needs the user's explicit approval. Never edit a production checkout. For a separate worktree, commit the candidate to a named draft ref, then select that ref explicitly in the plan. `--from worktree` reads the ledger project's configured repository, not whichever directory the shell happens to be in.
3. Validate each changed source with `polispec validate auto FILE --json`. Check sibling environments and modules as well as the policy. Use explicit kinds from `polispec help` when auto-detection is ambiguous. A valid file proves schema acceptance, not safe composition or actual enforcement. Read warnings. With runtime 0.35.0 or later on an unsealed installation, `env POLISPEC_DESCRIPTION_STRICT=on polispec validate auto FILE --json` additionally fails description lint for this invocation; `validate` has no `--strict` flag. Do not persist settings merely to validate a draft.
   After validating, run `polispec lint` (project scope) and read its findings; a clean lint proves loader-safe YAML and agreement with source, not safe composition.
4. Preview the entire proposal:

   ```sh
   polispec plan project:PROJECT_ID --from DRAFT_REF --json
   ```

   When intentionally using the configured repository's uncommitted candidate, use `--from worktree` instead. Read files, ledger effects, composed policy differences, unreachable gates, every changed probe or replayed call, classification, and effect classes. Resolve invalid composition or unexplained verdict changes before applying.
5. Apply from the project's authorized main checkout, using exactly the same target and source:

   ```sh
   polispec apply project:PROJECT_ID --from DRAFT_REF
   ```

   Non-global tightening or neutral plans may apply within the user's authorized task. Loosening, mixed plans, status flips, profile changes, trust-ref changes, and repository moves require the user's explicit yes to the exact plan id and reasons before adding `--confirm PLAN_ID`. Use the available question tool. If inputs change, re-plan and obtain approval for the changed proposal; never self-confirm, reuse a stale id, or reshape a change to avoid confirmation. Sealed or protected operator actions still belong to the authenticated operator.
6. Inspect the resulting commit and state. Project apply commits on main; it does not advance the trust ref. Promote to test only through `polispec promote PROJECT_ID --to test` and its gates. Only the operator promotes to stable. Report separately that a candidate validates, that it is committed, that it has reached test, and that a trusted policy actually governs running calls.

`AGENTS.md` environment rows and `.agents/directives/envs.md` are generated projections. Change their policy or environment source, then use `polispec agents render` in the authorized checkout; do not hand-edit generated instructions.

## Shared shelf, ledger, packages, and registration

Never edit the live ledger or global shelf by hand. Prepare a proposal outside the live authority source, validate it, and use the matching plan/apply pair:

| Target | Preview | Apply within the authorized scope |
| --- | --- | --- |
| Global shelf backed by git | `polispec plan global --from DRAFT_REF --json` | `polispec apply global --from DRAFT_REF --confirm PLAN_ID` after the user's yes |
| Ledger proposal file | `polispec plan ledger --from FILE --json` | `polispec apply ledger --from FILE`, adding `--confirm PLAN_ID` only after required approval |
| Package or onboarding | `polispec plan environment-control --repo REPO --variant service` | `polispec apply environment-control --repo REPO --variant service` when the reviewed plan permits it |

Use `--variant distributed` for installed software such as a plugin or CLI, and `--variant library` for a library or tool with no running instance (its deploy is a no-op that moves the checkout to the tag). A plain-directory global source can preview with `--from DIR`, but `apply global` requires a configured git shelf; report that prerequisite instead of copying files into place. Every global plan requires explicit user approval, including neutral or tightening changes. Adding an onboarding entry is distinct from making it live.

For non-repository software or directories, use [polispec-register](../polispec-register/SKILL.md). Before writing `description`, `paths`, `owner`, or `registered_by`, ensure every runtime that reads that ledger or trust ref supports them (0.35.0 or later). Honor `runtime_behind`; do not bypass it with an older writer or manual edit. Retain the apply backup for rollback. Do not inspect or modify a sealed authority plane as if it were an ordinary editable ledger.

## Application behavioral policies and agent-facing surfaces

Read `docs/behavior.md` and the schema matching the file's `schema` field. Keep v1 as v1 unless migration is requested; v2 adds canonical directives and generated surfaces. Edit canonical directives once and reference their ids from surfaces; do not duplicate rule bodies in skills, messages, or generated instructions. Preserve `body_ref` privacy: never print, copy, or publish a private body's contents; maintain its declared path and hash through the application's authorized workflow.

For a v2 policy with a declared surface:

```sh
polispec validate behavior POLICY.yml --json
polispec behavior compile POLICY.yml --root APP_ROOT
polispec behavior render POLICY.yml --surface SURFACE_ID --root APP_ROOT
polispec behavior lint POLICY.yml --root APP_ROOT --json
```

Review the rendered output before using `render ... --write`, which changes the declared target. Back up changed native or protected artifacts and preserve foreign contributions. Then run `polispec behavior drift POLICY.yml --root APP_ROOT --json` and the application's existing verification. For v1 use validation and compilation without assuming v2 surfaces exist. `polispec behavior decide POLICY.yml EVENT FACTS.json` exercises declarative predicates only; it does not execute native bindings or authenticate an authority. Compilation is not signing, installation, activation, or proof of application enforcement. Ship through that application's own release procedure.

## Code-spec packs

Read `docs/code-specs.md`; locate the pack through the installed configuration rather than editing the plugin's own schemas. Inspect the active chain first:

```sh
polispec specs status --json
polispec code chain SOURCE_FILE --json
polispec code show SPEC_PATH --repo PACK_REPO --ref main
```

Hooks normally read the pack's stable ref. Author on main or an authorized candidate worktree, and select the exact candidate with `--repo PACK_REPO --ref worktree` or a named ref. Do not change `POLISPEC_CODE_REF` on a live host to make an unpromoted pack effective.

```sh
polispec code validate --repo PACK_REPO --ref DRAFT_REF
polispec code check SOURCE_FILE --repo PACK_REPO --ref DRAFT_REF --json
polispec code controls --repo PACK_REPO --ref DRAFT_REF
```

Use the pack's existing semantic validator and negative controls. Do not generate new test machinery or baselines merely to erase violations. Preserve qualified rule ids, levels, enforcers, lenses, and control bindings according to the pack contract. `code generate` derives artifacts and may write files; inspect its usage and output scope before invoking it. Pack promotion is the operator's `polispec specs promote --repo PACK_REPO`, after clean validation and controls; agents do not move stable directly or link a different pack silently.

## Drafting and reporting

When the user requests the optional author adapter, `polispec author draft KIND --intent TEXT --for PROJECT_ID --json` can draft and validate a proposal without applying it. It may launch a model session; respect authorization, budgets, kill switches, and rate limits. Read its output as a proposal, then run the relevant workflow above. Do not call the web API to impersonate a person's approval or read its launch secret or delegate token.

Finish with the changed sources, validation and composition evidence, expected verdict changes, applied plan or commit ids, and the environment or trust ref actually in effect. Name missing verification and pending operator actions. Never claim a draft is live because its YAML validates.
