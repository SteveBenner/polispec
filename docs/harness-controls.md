# Harness controls

polispec compiles a deterministic control language into native harness artifacts and records what it owns. Planning, installation, artifact integrity, native enforcement, and lock certification are separate results. A generated configuration is not evidence that a harness enforced it.

The control schema is [`polispec.control/v1`](../schemas/control.v1.yml). The implementation contract is [`specs/harness-controls.impl.yml`](../specs/harness-controls.impl.yml). The calling agent translates a user's request into this grammar or YAML; no model runs inside the control decision path.

## Grammar and preview

```sh
polispec harness grammar --json
polispec harness parse 'when agent write file where path = "/tmp/polispec-control-fixtures/*" then deny because "protect synthetic files"' --json
polispec validate control examples/controls.minimal.yml --json
polispec harness plan examples/controls.minimal.yml --harness codex --scope project --project /absolute/project --json
```

`parse --file FILE` reads grammar text. `plan` and `install` read a YAML control document. `grammar` publishes the accepted verb/object pairs, predicates, effects, schedule syntax, and input limits; use that catalogue rather than inventing synonyms.

```yaml
schema: polispec.control/v1
controls:
  - id: ctl_protect_synthetic_files
    trigger: pre_tool
    action: fs.write
    match:
      path: /tmp/polispec-control-fixtures/*
    effect: deny
    reason: Protect synthetic files.
    fixture:
      input:
        tool_name: Write
        tool_input:
          file_path: /tmp/polispec-control-fixtures/example.rb
        cwd: /tmp/polispec-control-fixtures
        action: fs.write
      expected: deny
```

Effects may need `effect_params`; the schema validates their shape. Every control appears in the plan with its canonical digest and backend disposition, including unsupported controls. Scheduled verification refers to an existing control ID. A scheduler accepting a job is distinct from observing its installation and its eventual execution.

IR input is limited to 1 MiB and 256 controls. Hook input is limited to 64 KiB; the hook budget is ten seconds. Invalid, oversized, or unsupported input produces an explicit error rather than silently dropping a control.

## Install and verify

Since 0.23.0 `harness_controls` is enabled by default and `sealed_plane` stays disabled, both by operator choice. Install and verify run with release defaults; uninstall needs the protected operator except for your own overlay (below), and sealing returns `feature_disabled`. Under a governed baseline the guard recognises harness-internal tools (TodoWrite, Skill, Glob and the like) and fully parsed read-only shell lines as benign, gives WebFetch, WebSearch, Agent and Task known classes, and asks about every undeclared MCP operation, every unknown non-shell tool, and every shell line it cannot parse (or that uses `eval` or `source`); since 0.23.1 a fully parsed shell line goes to policy with whatever classes its commands have, as in 0.22.0; `bin/polispec-guard`'s fast path skips only the tools listed in `fastpath.tools`: harness-internal tools, and Read, Grep and the other read tools unless a global or module rule governs reads (a `secrets.read` class, a `tool` naming a read tool, or a rule with neither `class` nor `shape`). Grammar, validation, planning, verification, and dry-run previews remain available. Publication installs no controls, services, or timers and activates no live project.

Supported backend names are `claude-code`, `codex`, `hermes`, `antigravity`, and `os`. Scopes are `user`, `project`, and `managed`. Project scope requires an absolute `--project` directory; other scopes reject that option.

rplugin's Antigravity integration is skills-only. The separate polispec backend generates agy CLI artifacts through explicit `harness install`; this does not establish native enforcement or GUI hook support.

```sh
polispec harness install controls.yml --harness claude-code --scope project --project /absolute/project --dry-run --json
polispec harness install controls.yml --harness claude-code --scope project --project /absolute/project --json
polispec harness verify INSTALLATION_ID --json
polispec harness scan --json
```

Agents may install provably tightening controls at user or project scope. Loosening, removal, managed scope, and protected core changes require the authenticated operator. Same-user files remain mutable; an unsealed install does not establish a security boundary against that user.

The installer inspects existing files, backs up changed files in place, records owned entries, and preserves unrelated entries. It holds target locks through mutation and receipt readback. An interrupted or unresolved transaction is a recovery finding, never a successful installation. Repeated installation is idempotent only when the actual installed bytes and runtime still agree.

Verification checks current owned entries, permissions, provenance, and backend evidence. Native probes report unavailable or unverified when a runtime or privilege is missing. A lock request returns a prerequisite failure unless every required axis is supported and verified. Generated files, parser acceptance, and a version string cannot certify lock.

Unsealed callbacks use `polispec.enforce`; select `enforce` for blocking behavior. `advise` reports decisions without blocking. Protected plane settings force `enforce`. Native permissions generated into a harness remain subject to that harness's own behavior.

The guard loads the protected core and validated user/project installation receipts. A callback's `--controls-file` argument cannot replace protected authority. Mutable overlays may tighten the result but cannot declare an otherwise undeclared MCP operation allowed. An MCP operation is declared by a rule with an exact `server` and `operation` in any layer the engine composes for the call: the global shelf, a module it includes, or a live project's committed policy, for example `{ id: MCP-DESK-PAGE, match: { class: [mcp.call], server: teach-service-desk, operation: page }, verdict: allow }`. Keep `class: [mcp.call]` on the rule so it does not count as governing reads. The rule's verdict then applies as usual. Under Codex with no sealed plane an undeclared operation is denied rather than asked, because a control ask needs the plane.

## Decisions and editions

Environment policy keeps its existing rule order. Harness controls add an independent ceiling: the strictest applicable decision wins. Pause and legacy allow-once permissions affect only environment policy; they cannot erase a control deny, protected-path refusal, broken authority, root guard, or a lock default.

| Behavior | Standard | Lock |
|---|---|---|
| Undeclared MCP call, while `mcp/undeclared` is active | Ask | Deny |
| Unknown non-read-only call in enforcing governed scope, while `tools/unknown` is active | Ask | Deny |
| Requested OS isolation | Restricted paths, open network | Restricted paths, network allowlist |
| Initial network allowlist | Not applicable | Empty |
| Missing enforcement evidence | Report limitations | Lock inactive |
| Root-equivalent container access | Advise, then arm root guard on a distinct follow-up detection | Refuse lock, force root guard, report fallback |

The undeclared-MCP and unknown-call defaults in the table apply only while the operator has activated `mcp/undeclared` or `tools/unknown` on the host (see [the catalog](operator.md#catalog)). With neither active, those calls get no special verdict from the guard and the rest of the policy judges them as it judges any other call.

An unknown call is one the classifier gives no class: a non-shell tool with no classified action (class `tool.internal`), a read tool called without a path (class `tool.read`) or an `eval`, `source` or `.` line (class `shell.exec`, shape `opaque_shell`). Since 0.32.0 such a call is declared the way an MCP operation is: by a rule in trusted policy, an active catalog spec included, whose `match.tool` names the exact tool (case-insensitive) or whose `match.shape` includes `opaque_shell`, and that matches the action in full. polispec ships those declarations in the catalog spec `tools/declared` (`catalog/tools/declared.yml`) (see [the schema reference](schema.md#shipped-layer)); an undeclared call gets the default in the table.

A native ask remains an ask. A harness without native ask blocks a standard ask pending an exact protected one-use authorization. The authorization binds the request to its tool arguments, working directory, classified actions, complete tagged environment/control ask set, trusted policy digests, effective control digest, generation, user, harness, and actual session. An unavailable authorization service grants nothing. See [the operator guide](operator.md).

The guard protects authority files, pinned runtime and SDK, protected records, installed owned entries, and the authorization socket directory. Patch renames classify both old and new endpoints. Deleting or renaming an ancestor of a protected path is also a protected edit. Positive diagnostic-read tools remain available when judgement fails; a shell command is not assumed read-only from its name. Malformed input receives a minimal native denial.

Standard runs without the lock branch or its protected setup. Lock runs from its own checkout without a standard installation or a mutable local `main` ref. Doctor verifies lock against its embedded immutable parent; advancing main does not invalidate an older lock release. A lock executable refuses an active standard-plane mismatch instead of downgrading its edition. Shared source and release ancestry do not create a runtime dependency between editions. One authority plane is selected per host; simultaneous independent editions in that namespace are not claimed.

`main` carries `EDITION` containing `standard`. `polispec-lock` has the same code and a single `EDITION` change to `lock`. Lock is a requested edition, not a promise that this machine satisfies it. `polispec doctor` checks local edition provenance; the maintainer's `scripts/release-lock` creates or refreshes the edition-only branch from an exact accepted main commit.

## Container exposure

`harness scan` detects Docker/LXD access, rootless engines, and root-equivalent authority separately. The first detection advises remediation. A distinct follow-up detection arms the initially disabled root guard; an armed state is monotonic across sealed generations. A sealed scan by an unprivileged process is diagnostic only until the authenticated operator records it. Every record names the UID actually probed; a root scan is not evidence about another user's process.

The hook reads the recorded guard state without running environment probes. Root guard refuses classified risky container operations. It is not a proof of isolation, and rootless detection alone does not prove containment.

## Native capability evidence

The machine-readable inventory is [`data/harness-capabilities.yml`](../data/harness-capabilities.yml). Plans and verification output carry finer per-control findings.

| Backend | Evidence collected for this release | Remaining boundary |
|---|---|---|
| Claude Code | Installed 2.1.296; emitted configuration accepted by its parser | Native hook and sandbox denial journeys unverified. `onFailure: block` requires 2.1.295 or later; sandbox settings require 2.1.285 or later. Bash sandboxing does not cover every tool. Explicit standard open-network behavior is unsupported by this backend. |
| Codex | Installed 0.162.1; emitted TOML accepted; direct `--yolo` invocation rejected by the emitted exec policy | Hooks need explicit trust. Callback failure may allow execution. Hosted and nested execution boundaries remain unverified. No native ask response is claimed. |
| Hermes | Native `pre_tool_call` configuration and protocol compiled | Runtime absent during verification; consent and enforcement unverified. Project hooks live in the user's profile-global config and carry an explicit project boundary. |
| Antigravity | agy CLI artifacts and native protocol compiled | Runtime absent; managed staging is not an established native managed path. GUI surfaces are directive-only. Antigravity never receives lock certification. |
| OS | Bubblewrap 0.11.1 was invoked in an isolated probe | User namespaces unavailable on this host; no containment axis certified. Arbitrary pre-tool controls need a harness callback. |

These observations are dated 2026-10-13. No paid model call, root-owned host seal, live-project activation, or real protected service installation was performed for this release. Artifact verification and scratch transport evidence are recorded separately from native and privileged verification.

## Results and recovery

JSON commands return `polispec.harness.result/v1` with `ok`, `operation`, `operation_id`, `edition`, `data`, and structured `findings`. Findings include a code, detail, capability, and next step. Exit 0 means the command completed its stated operation; inspect findings before making an enforcement claim. `harness scan` exits 1 with `environment_scan_failed` and the underlying cause when the scan cannot run. `harness uninstall --dry-run` without `--owner` previews from the world-readable protected record stream and needs no root; with `--owner` it previews without root too: it reads only what the current uid can read (the protected record stream, and the owner's state when the current uid is the owner's), writes nothing, and adds an `owner_check_unverified` finding for each owner check it could not perform, such as mutable receipt validation. The real owner uninstall still needs the privileged launcher. One narrow path needs no root: while no sealed plane is active, a non-root user may run `harness uninstall INSTALLATION_ID` (no `--owner`) for a user-scope or project-scope overlay that user installed. The receipt must be unprotected and carry an `owner_uid` equal to the caller's uid; receipts written before this change carry none and are not eligible. The command needs a TTY and the typed phrase `uninstall INSTALLATION_ID`; without a TTY or with a wrong phrase it refuses with `operator_required` and exit 3. It uses the same removal as the operator path: every changed file is backed up first and foreign contributions are kept. Protected receipts, managed scope, another owner's receipt and every host with an active sealed plane still require the protected operator. Usage errors use exit 2. Missing privileges, unavailable features, and unmet lock prerequisites commonly use exit 3; invalid inputs or failed operations use exit 1.

The `operation_id` has several stable shapes. A plan or installation carries the 64-hex SHA-256 of its canonical material, or `op_` plus its first 24 hex for the codex backend; both are persisted in transaction records and receipts, so they are not rewritten. An uninstall transaction is `uninstall_` plus 24 hex. A command result that has no plan, such as `grammar`, `parse`, `verify` or `scan`, gets `op_` plus 24 hex derived from the operation and its data. Treat the value as opaque and compare it only for equality.

Keep installation IDs, receipts, and in-place backups. Uninstall restores authenticated historical contributions rather than overwriting the current file wholesale. A stale authorization socket requires explicit operator recovery. Never delete an active socket or edit a transaction journal to force a green result.
