# Behavior contracts

A behavior contract is a versioned document that describes one agent behavior and binds it to what enforces it. It is generic: polispec ships the kind (`polispec.contract/v1`), the verb (`polispec contract`), these docs, and a neutral demo fixture. Names of locations, annotations, and facts belong to the project, in its vocabulary file.

A contract lives at `specs/polispec/contracts/NAME.yml`, beside an optional `vocabulary.yml` and the `approvals.jsonl` that `polispec contract approve` writes. A runtime older than 0.43.0 reports these files as unknown; add them only after 0.43.0 is pinned on every host that builds or lints them (`doctor` reports `contract_ahead_of_runtime`). The guard never reads contract files, so no verdict changes.

## The document

Required: `schema`, `id`, `version` (semver), `lifecycle`, `intent`, `scope`, `trigger`, `precedence`, `behavior`, `guards`, `probes`, `owner`, `change`.

- `lifecycle`: `draft` (never rendered or exported), `advise` (rendered and evaluated, guards report only), `enforce` (needs a current approval), `retired` (renders nothing, keeps history).
- `scope`: `application`, and optional `course`, `assignment`, `module`, `step` (null means every one) and `harnesses` (opaque names; empty means all).
- `trigger`: the condition grammar of behavior v2 `when`: `always`, `event:NAME`, `task:NAME`, `tool:NAME`, `path:GLOB`.
- `precedence`: `rank` (lower outranks higher) and `outranks`, a list of contract ids.
- `behavior`: `{path, sha256}` of a `polispec.behavior/v2` document, relative to the repository root.
- `directive`: optional opcode or id in that document. Several contracts may name the same directive; without it the directive ref check is skipped and the digest carries `referenced.directive: null`.
- `guards`: `{rule, location, decision, harnesses}` with `decision` one of `deny`, `block`, `reroute`, `report`, `instruct`. A guard with `harnesses` runs only there; elsewhere the contract is advisory and `check` says so.
- `messages`: per message id, ordered `clauses` `{id, text_ref, shown_when}` and `compose` (`sentence` joins shown texts with one space, `list` prefixes each with a dash and joins with newlines).
- `constraints`, `annotations`, `external_tests`, `trace_refs`, `effective_at`, `rollback`: documentation and traceability. Annotations are validated only against the vocabulary.
- `probes`: `positive` and `negative`, each at least one: `{id, event, facts, expect: {verdict, message_id, clauses, hidden}}`.

`shown_when` and probe facts use `{fact, equals}`, `{fact, in}`, `{fact, present}`, `{all: [...]}`, and `{any: [...]}`. A missing fact is false for `equals` and `in`.

## Digest and approvals

`polispec contract digest FILE` prints `sha256:` over the canonical JSON of the contract (without `behavior.sha256`) and only the behavior parts it references: the directive row with its body hash, the referenced rules, and the referenced message and clause texts. An edit elsewhere in the behavior document leaves it unchanged, though `behavior.sha256` must still match the file for `check` to pass.

`polispec contract approve FILE --actor NAME --role ROLE` appends `{contract, version, digest, actor, role, at, prev, hash}` to `approvals.jsonl`, hash-chained, and records a `contract_approval` change. It refuses while `check` reports an error other than `contract_unapproved` and `behavior_surface_drift`. It classifies `policy.edit`, so a live project warns and the harness asks the user. A contract in `enforce` needs an approval at its current digest from every role in the vocabulary's `approvals.required_roles`. polispec has no key infrastructure; a project that serves contracts signs the exported bundle itself.

## Check

`polispec contract check FILE|DIR [--vocabulary FILE] [--runner CMD] [--root DIR] [--format text|json]` validates the schema, resolves the behavior ref and its sha256, confirms the directive, rule, message, and text refs, validates against the vocabulary, runs every probe, reports conflicts, approval state, and surface drift. Findings: `contract_schema`, `contract_ref_missing`, `contract_vocabulary`, `contract_probe_failed`, `contract_probe_unrun`, `contract_conflict`, `contract_unapproved`, `contract_untested`, `contract_advisory_on_harness` (info), `vocabulary_absent` (info), `behavior_surface_drift`. Exit 0 without an error, 1 with one, 2 for usage.

Probes whose guards are all declarative rules run inside polispec. Others go to `--runner CMD` (words, no shell; project root as working directory; one JSON line per probe on stdin `{contract, version, id, event, facts, guards}`, one `{id, verdict, message_id, clauses}` line per probe on stdout; 30 seconds in total). A probe nothing evaluates is `contract_probe_unrun`: a warning in `draft` and `advise`, an error in `enforce`.

Two advise or enforce contracts conflict when their scopes overlap, their triggers can match one event, guards on each share a location with different decisions, and neither precedes the other. `check` reports both ids and never picks a winner.

## Diff, render, export

- `polispec contract diff FILE|DIR --from REF` classifies the change since REF as tightening, loosening, mixed, or neutral with a reason per item, and reports `contract_version_unchanged` when guards, referenced rules, or the directive changed under the same version.
- `polispec contract render FILE|DIR [--surface ID] [--write]` prints or writes the behavior surfaces whose refs name the contract's directive or messages.
- `polispec contract export DIR [--out FILE]` writes `polispec.contract.compiled/v1` for the advise and enforce contracts.

## Surfaces

Behavior v2 gains the surface kinds `policy_json` (the compiled bundle of the contracts that reference the listed refs, canonical JSON) and `locale` (a mapping of message id to text for one locale, limited to the listed refs; the surface key `locale` defaults to `en-US`). Both are wholly generated and drift-checked, and neither needs a `template`.

## Plan, lint, doctor

`polispec plan project:<id>` classifies each contract change as above; a contract whose document or referenced behavior changed without a probe change is loosening, and appended approval lines are neutral. `polispec lint` validates contract documents by schema id and reports contract surface drift as `behavior_surface_drift`.
