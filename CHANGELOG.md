# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.37.1] - 2026-10-21

### Fixed
- Recognize static noninteractive shell noexec checks without classifying the checked script as executed. Retain caller redirects, substitutions, privilege, and surrounding commands, and classify the script operand as a read. Unsupported option combinations stay conservative.
- Treat stdin supplied to an interpreter with a literal existing script operand as data, rather than extracting shell commands from its JSON input.
- Detect Codex guard bridges launched through known interpreters instead of inspecting only the interpreter binary. Wiring discovery still makes no trust or enforcement claim.
- Keep smoke runs on their own Codex home with an empty configuration, so doctor findings and hook discovery do not depend on the operator's running harness configuration.
- Refuse judgment appends on an unreadable tail or divergent head and detect short writes before advancing the anchor. Verification takes the append lock in shared mode and names malformed archive records without altering historical evidence.

## [0.37.0] - 2026-10-20

### Added
- Optional `polispec.web.public_origin` for serving the existing web UI through an external HTTPS proxy while retaining a loopback backend. Initial and fresh links use the origin recorded by the running server, cookies carry Secure, and Host and Origin checks admit only the configured public authority.
- Agent web API classification recognizes the configured and running HTTPS origins as well as existing loopback endpoints. Routing and supervision remain external; the standalone plugin requires neither rStack nor Tailscale.

## [0.36.0] - 2026-10-20

### Added

- Optional guided-learner catalog package with six canonical public presentation policies and bounded explicit-violation detector data. Applying it writes only its behavior source, without changing environments, the ledger, or host enforcement.
- Read-only `polispec behavior export-package NAME` for consumers that ship compiled policy through their own adapters without a runtime Polispec dependency. Unsupported external body references are refused.


## [0.35.1] - 2026-10-20

### Added

- The packaged `polispec-specs` agent skill: how to identify, draft, validate, plan, and safely apply environment policies, modules, rosters, ledger proposals, behavioral policies, and code-spec packs; it explains candidate refs, generated surfaces, exact-plan approvals, runtime compatibility, and operator promotion boundaries.

### Changed

- The main agent skill now locates the installed CLI and plugin-relative documentation, resolves the target environment, explains actual hook calls, and routes spec authoring and registration to dedicated skills. Corrected the obsolete claim that harness controls ship disabled.
- Registration guidance reuses supplied context and authorization, and routes shelf and ledger modifications through the spec-authoring workflow.

### Fixed

- Standalone installation and removal cover every shipped skill directory for Claude Code user/project scope and Codex user scope, preserving foreign links and receipt ownership. Previously only the main skill was installed.
- Description-lint documentation names the supported strict setting rather than a nonexistent `validate --strict` flag.

## [0.35.0] - 2026-10-20

### Fixed

- The edition registry's epoch notice entry points to `lib/polispec/effect.rb`, so `polispec editions --check` can verify its implementation.

### Upgrade and rollback

- 0.35.0 adds keys that every earlier release rejects as unknown: `description` on every rulebook and ledger entry, and `paths`, `owner` and `registered_by` in the ledger. A ledger or trust ref that uses them is invalid to 0.34.0 and older, and a guard running such a release judges the affected projects by their fallback rules. Pin 0.35.0 on every host that reads a ledger or trust ref before writing these keys into it. Writers check the installed release first (`Description::RUNTIME_FLOOR`, read from the native pin, the rplugin store or the pinned runtime) and refuse with `runtime_behind`.
- To roll back after 0.35.0 has written the ledger, restore the ledger backup that `apply ledger` left beside it (or remove `paths`, `owner`, `registered_by` and `description` by hand through `polispec plan ledger --from FILE` on 0.35.0) before reinstalling 0.34.0.

### Added

- `polispec web`, a local web app over the files polispec already keeps: the map of projects and governed paths with their layers, project detail, the rulebook manager with a CodeMirror editor, live lint and blast radius, plans and applies through the same plan and apply path as the CLI, pipeline, sessions, timeline, feed and heatmap views, the playground and explainer, history, the gallery, exceptions, manifest and register views, six themes through one switcher, and a command palette. Loopback by default, one-time exchange links (`polispec web url`), session cookie plus CSRF for every mutating route, `--read-only`, and `G-WEB-AGENT` classifying an agent's call to it as `policy.edit`. Routes are glob-loaded from `lib/polispec/web/routes/*.rb`; the contract is `web/public/openapi.yml`. No database: browser storage caches views and `web/state/*.yml` keeps layout, pins and saved playground calls.
- The `author` port: `polispec author draft <kind> --intent TEXT` drafts a rulebook or description, validated and planned before anyone sees it, and writes nothing. The standalone adapter runs a read-only harness CLI session (Read, Grep and Glob only, one Read rule per root, scratch `POLISPEC_*` variables stripped); rplugin extensions add adapters through the declared port (`polispec.rplugin.yml` `ports.declared: [author]`, rplugin 1.17.0 or later).
- `description` on every rulebook and ledger entry, with a deterministic lint (`missing`, `too_short`, `too_long`, `restates_summary`, `names_nothing`, `states_no_effect`), warnings in `polispec validate`, `POLISPEC_DESCRIPTION_STRICT=on` to fail on them, `--semantic` to judge a description against the rules (`matches`, `partial`, `contradicts`), and the doctor finding `description_ahead_of_runtime`.
- Governed path entries: `polispec register <path> --kind software|directory|system` and `polispec unregister <id>` plan and apply a `paths` entry in the ledger with owner stamping, so software, a directory or the system scope that is not a git repository with branches can be governed; judgments on a path entry are labelled with it.
- Effect tracking: the policy epoch, chained change records, session records, `polispec changes list|show|await|verify`, `polispec sessions list|show`, and a once-per-epoch notice line on the next pretool call after a change.
- `polispec manifest` and `manifest index`: a per-project `polispec.manifest.json` and badge, committed on main with `--write`, and a publishable index (`POLISPEC_INDEX_DIR`).
- The edition registry `specs/editions.yml` and `polispec editions [--check]`, which list every feature that differs between the standard and lock editions; lock comparisons now go through it.
- Delegate grants may name `exceptions-add`, `exceptions-promote` and `exceptions-remove`; refused under lock.

### Changed

- The shell parser follows `source` and `.` files as it follows scripts, bounded in commands and time, and treats a same-line rewrite of a followed file as opaque, so a sourced file's commands are judged instead of asking `POLISPEC-TOOL-UNKNOWN`.
- Hook latency: plane, ledger, settings and shelf reads, ownership, location and canonical-path resolution are memoized within one hook or explain process, and classifier modules are preloaded.
- `polispec smoke run` gives every scenario a scratch `RPLUGINS_HOME` and `POLISPEC_DATA_HOME`, so a scenario no longer reads the host's rplugin store or native pin.

## [0.34.0] - 2026-10-20

### Added

- `polispec.behavior/v2` (`schemas/behavior.v2.yml`), a superset of v1 selected by its schema id. Directives gain `scope`, `duplicate_of` and `body_ref: {path, sha256}`; a referenced body is checked against its hash at compile time and the compiled form carries `body_sha256`, never the text. New maps `surfaces`, `frames`, `antifeatures`, `controls`, `messages` and `overlays.cutout`. v1 files validate and compile byte for byte as before.
- `polispec behavior render`, `drift` and `lint`. `render` writes a surface from its template; `drift` exits 1 when a generated target differs from its rendering; `lint` exits 1 when a sentence of 8 or more tokens restates a directive (0.8 token overlap) without naming it. `duplicate_of` exempts only the linked pair from each other.
- `polispec behavior compile --root DIR`; the v2 compiled form `polispec.behavior.compiled/v2` adds a `surfaces` map with the sha256 of each generated surface, so a consumer without polispec can detect a hand-edited projection. Compile fails, naming the surface, when a surface cannot render.
- `Polispec::Surfaces` (resolve, render, drift, lint, `when_matches?`) and `AgentsRender.directive_row`/`directive_rows`, which render any directive set in the `[OPCODE] rule d/x ⚙ enforce ⚡ [when]` row format.

## [0.33.2] - 2026-10-20

### Fixed

- The guard launcher fails closed. `bin/polispec-guard` denies every non-read call when polispec is missing, exits with an unexpected status, or runs past the launcher deadline. Each harness gets the reply the hook's own internal failure gives: Claude Code, Codex, Antigravity, Pi and DeepSeek exit 0 with their deny or block JSON, Hermes exits 2 with its block, and an unknown harness name gets the reason on stderr and exit 2. Read tools (`polispec-guard --read-tools` lists them) and session start still pass, and an exit 0 with no output is still an allow. The 0.33.1 fallback denied only shell calls that matched a prod-shaped pattern and let every other call through. Each failure appends one line to `launcher.jsonl` in the state directory: ts, tool, session, harness, mode, cause (`no_binary`, `timeout` or `exit_<status>`) and decision.
- The launcher runs the hook under an 8 s deadline (`POLISPEC_GUARD_DEADLINE`, an integer from 1 to 9), through `timeout -k 1` or, where `timeout(1)` is missing, a bash watchdog. The hook's own budget drops from 9.5 s to 7 s, so polispec answers before the harnesses' 10 s hook timeout cuts it off.
- A hook call composes each project's policy once. For every path in a command the engine recomposed each live project's policy: `Atlas#lookup` cached per locator and `Envs.spec_owner` not at all. On this host one ordinary Bash call composed policies 2,101 times, ran out the 9.5 s budget and was denied as an internal failure, and a five-word command composed 1,570 times. `PolicySource.memoize` keeps each composed policy for the length of one hook call and gives every caller its own copy. The same two commands now take about 0.7 s with nine compositions.
- Hook input up to 8 MiB is judged. The cap was 64 KiB, so a Write or Edit of a larger file was denied as "guard unavailable". Input over 8 MiB is denied with "[POLISPEC internal] hook input exceeds 8 MiB; call denied. Split the change into smaller calls." The launcher reads at most one byte past the cap.
- The launcher maps the harness name `deepseek-tui` to `deepseek`, as it maps `claude-code` to `claude`.
- `polispec smoke run` runs each scenario file once when the tree is reached through a symlink. It deduplicated files by `File.expand_path`, so with `--live` a scenario found both through `--scenarios <symlinked tree>/smoke/live` and through the tree's real path ran twice. The second fixture build then failed `git commit` with nothing to commit. Every rplugin store reaches its release through such a link (`~/.rplugins/polispec`). It now deduplicates by `File.realpath`.

### Added

- Finding `gate_unreachable`. Some promotion setups can never pass: a gate that needs a passing deploy of an environment with no `deploy:` (`G-TESTED`, or any `sha_ran_on`, `sha_ran_on_test` or `soaked` gate), or an `after:` step that deploys such an environment. `polispec doctor` reports each one as blocking, and `polispec status` shows it as the project's finding. `polispec validate policy` reports it at `/promotion`, and `polispec plan project:<id>` lists it under notes without changing the classification or the plan id. `promote` and `deploy` are unchanged.
- environment-control 1.1.0. The distributed variant declares placeholder deploy blocks for test and prod, as the service variant does, so a project applied from it no longer starts with unreachable gates.
- Smoke scenarios `guard-failclosed`, `gate-unreachable` and `policy-memo`. `examples/environments.widget.yml` declares deploy blocks for test and prod.

## [0.33.1] - 2026-10-20

### Fixed

- `bin/polispec-guard` passes a Hermes block through. The Hermes adapter answers a deny with exit status 2 and `{"action":"block",...}` on stdout, and so does its fail-closed internal denial. The shim treated every nonzero exit as a runtime failure, dropped the reply, applied the inline fallback and exited 0. On every Hermes host wired through the shim (the rplugin hook manifest wires every harness that way), a deny was an allow unless the command matched the fallback pattern for prod-shaped git, `systemctl` or `gh release`. A pretool reply with exit status 2 and a JSON object on stdout now reaches the harness unchanged with status 2; any other nonzero exit still takes the fallback. Claude Code, Codex and Antigravity replies exit 0 and are unchanged.

### Added

- Smoke scenario `guard-shim` (unit `commands/hook pretool|session`) drives the shim for Hermes (a deny, an allow and a malformed call) and for Claude Code and Codex (a deny each) in a live fixture project.

## [0.33.0] - 2026-10-19

### Added

- A shipped delete guard. `modules/delete-guard.yml` composes in the shipped layer beside `modules/tool-declared.yml` on every host, with three overridable rules. `G-DELETE-PROTECTED` denies a delete that reaches a protected path. `G-DELETE-PROTECTED-FILE` asks before a single, non-recursive file delete under a protected folder. `G-DELETE-XARGS` asks before a deleter fed through `xargs`, whose targets polispec cannot see.
- The data key `delete_protected` holds `exact` entries (the path itself) and `tree` entries (the path and everything below it). The shipped list is exact `/`, `~`, `/home`, the system folders and `/usr/bin`, `/usr/sbin`, `/usr/lib` and `/usr/lib64`, and tree `~/.ssh`, `~/.ai`, `~/.claude`, `~/.config`, `~/.rplugins` and `~/.polispec`. The global doc and every shelf module may add entries; nothing removes one, and a global plan classifies an added entry tightening and a removed one loosening (`delete:exact:<path>`, `delete:tree:<path>`).
- Match predicates `delete_protected` and `delete_protected_file`. A delete of a directory's contents (`*`, `.*`, `.[!.]*`, `..?*`, `.??*`) is judged as a delete of that directory. A recursive delete is denied at or under a tree entry or at an ancestor of any entry. Paths are compared lexically and with symlinks resolved, so a tree entry that is a symlink also protects the folder it points to, and every ancestor of it. Beneath a tree entry the resolved form counts only when the entry is a real folder: `~/.ssh` is covered through any alias, while a path inside a symlinked entry's target written by its real path (a build directory in the git repo `~/.rplugins` points into) is not judged.
- `fs.delete` actions carry the `recursive` hint for `rm -r`/`-R`/`--recursive`, `rmdir`, find deletes and `cargo clean`. A deleter whose words come through `xargs` carries the shape `xargs_delete`.

## [0.32.2] - 2026-10-19

### Fixed

- `Engine::Envs.under?` holds every path under the root `/`. It tested the prefix `//`, so a root of `/` contained nothing and `match.live_binary` missed `rm -rf /`: the shelf's `G-LIVE-BINARIES` denied `rm -rf /usr/lib` and `rm -rf ~` but allowed `rm -rf /`. The same helper decides protected roots, hermetic protected roots, policy checkouts, spec data dirs and the runtime guard, which now also contain everything when their root is `/`.

## [0.32.1] - 2026-10-18

### Fixed

- A command placed in a shell script file no longer escapes classification. `bash run.sh`, `sh -e run.sh`, `sudo bash run.sh` and `./run.sh` (an executable with a shell shebang, or no shebang and `.sh`) used to parse as fully classified lines whose script was never read, so every deny rule could be walked past by writing the command to a file, while `source run.sh` asked. The parser (`Shell::Parser#follow_script`) now classifies the script's commands as if written in the line, taking the content a `cat > FILE` or `tee FILE` heredoc earlier in the same line wrote, else the file on disk up to 1 MB (`Shell::MAX_SCRIPT_FILE`), to `MAX_DEPTH`. A dynamic operand, a missing, unreadable or oversized file, exhausted depth, or a path the same line wrote with unknown content marks the line opaque, judged as `eval` and `source` are (`opaque_shell`). A followed script's host is not counted for `chained_release`, as a `-c` host is not.

### Added

- Shape `tmux_kill` (`Classify::Shapes.tmux_kill?`): `tmux kill-server` or `tmux kill-session` with no `-L` or `-S` before the subcommand, which also adds a `service.control` action. On 2026-10-17 an agent's scratch script ran `tmux kill-server` with an inherited `TMUX` and killed the live rterm agent server. `schemas/policy.v1.yml` and `schemas/control.v1.yml` accept the name; no shipped rule uses it.

## [0.32.0] - 2026-10-18

### Added

- `modules/tool-declared.yml`, a module polispec ships and composes first in every chain as the `shipped` layer, on every host, before the global shelf. It declares the harness-internal tools (`TOOL-<NAME>`, `match.tool` with class `tool.internal`), the read tools called without a path (`TOOL-READ-<NAME>`, class `tool.read`) and the development relaxation of `eval`, `source` and `.` lines (`TOOL-OPAQUE-DEVELOPMENT`, shape `opaque_shell` with the new `in_development` predicate). Every rule is overridable: the shelf declares another tool or tightens a shipped one with a plain rule, narrows the relaxation with a rule on `opaque_shell`, and loosens a shipped rule only through `overrides`, all through `polispec plan global` and `apply global`. `polispec resolve <path> --layers` prints the layer; `Layers.shipped_rules` exposes its rules.
- Action classes `tool.internal` and `tool.read`, shape `opaque_shell` and the `in_development` predicate in the policy, module, global, control and ledger schemas. `in_development` applies `Ledger#development` to the line's directory and to every command directory as 0.30.2 did, and is false under the lock edition and under `polispec.relax.dev off`, which is now the predicate's kill switch.
- An unknown-tool action is declared the way an MCP operation is: a trusted rule whose `match.tool` names the exact tool (case-insensitive) or whose `match.shape` includes `opaque_shell`, matching the action in full, lifts the unknown mark; the declared action is then judged by environment policy, so a stricter shelf rule on the same tool wins. With no trusted policy at all only the shipped rules declare.

### Changed

- The library keeps detection and the edition default only: `Classify::Benign::INTERNAL_TOOLS` and `HookCommand#dev_projects` are gone. A non-shell tool with no classified action yields a `tool.internal` action, a read tool with no path a `tool.read` action, an opaque shell line a `shell.exec` action with shape `opaque_shell`, each marked unknown until a rule declares it. An undeclared tool asks exactly as before. `match.tool` compares case-insensitively.
- `fastpath.tools` derives from the shipped layer (the declared `tool.internal` and `tool.read` names, minus the read tools when the shelf governs reads, minus every tool a shelf rule names) instead of the two library lists.
- `Layers.fingerprint` and every effective digest include the shipped layer digest, so the baseline target digest, the fast-path key and `resolve --layers` output change with this release while every verdict stays: the 0.30.2 development matrix, the recorded non-Bash judgments since 0.30.2 and the smoke suite against the pinned 0.31.0 give the same verdicts as an unmodified 0.31.0 tree.

## [0.31.0] - 2026-10-17

### Added

- `polispec delegate` lets an application run `polispec promote` and `polispec deploy` for the operator through a local runner (`lib/polispec/delegate.rb`, `lib/polispec/delegate/`, `lib/polispec/commands/delegate.rb`, `schemas/delegate_grants.v1.yml`). `grant APP` at a terminal, with a typed phrase, stores a scope of verbs, ledger projects, targets and flags and prints a one-time app token. Only the token's sha256 is kept, in `<state home>/delegate/grants.yml`. `revoke`, `list`, `status` and `unit` manage it. `serve` is the runner: a Unix socket private to the user, with a peer-uid check, per-app token authentication, a rate limit of 60 a minute, and runs forked into their own session with output kept by byte offset. Each run has an hour's timeout and at most 8 MiB of readable output. It refuses on a sealed plane and while `<state home>/delegate/delegate.disabled` exists.
- `Operator::Tty.confirm!` and `Gates.interactive?` honor an in-process delegated confirmer that only the runner's child sets. It relays the phrase an application's user typed to the same exact-match check, once per prompt, waits at most 10 minutes, and never logs the typed text. Without a confirmer nothing changes: `deploy <project> stable` from a non-terminal still fails `not_tty` with the same message.
- Promotion and deploy records and the `polispec.promote` and `polispec.deploy` events carry `via: delegate:<app>:<by>` for delegated runs. The new event `polispec.delegate` reports each run's result.

### Changed

- The guard classifies a Write, Edit or shell redirect into the grants file as `policy.edit`, and also `polispec delegate grant`, `revoke` and `serve`. The host defaults and the environment-control packages warn on that class, so an agent cannot quietly grant itself a scope or start its own runner. `delegate list`, `status` and `unit` stay benign.

## [0.30.2] - 2026-10-17

### Fixed

- The 0.30.0 relaxation kept the `POLISPEC-TOOL-UNKNOWN` ask on lines that change into a directory outside development before they source an env file. Real calls showed it: since 0.30.0 went live on this host it relaxed 84 calls and still asked 27, and 25 of those 27 touched the session scratchpad under `/tmp`, where agents write and source an env file (24 in rdemo, 1 in rEach, 1 in rllm). `dev_projects` (`lib/polispec/commands/hook.rb`) now accepts a command directory that is in development or that no non-retired ledger project contains (`Ledger#locate` returns nil). A line that changes into a live project or a checkout, a session that itself starts in an unowned path, the lock edition and `polispec.relax.dev off` keep the ask, and the visible commands of the line are judged as before. The `relaxed` field lists the development projects only.

## [0.30.1] - 2026-10-17

### Fixed

- A hook process killed after it appended a judgment record and before it moved `judgments.head.json` no longer forks the chain. `Judgments.read_head` (`lib/polispec/judgments.rb`) compares the anchor with the last record of the stream; when the records after the anchored digest chain unbroken from it within the last 256 KiB, the next append chains to the last record and counts the ones the anchor missed. An anchor the stream does not chain from is still not adopted, so a truncated stream or a foreign head forks and is reported as before. Before the fix the next append chained to the stale digest, and the anchored count stayed short for good: this host had three such forks (01:53, 05:48 and 07:40 UTC on 2026-10-17, two of them with a zero-byte `judgments.head.json.<pid>.tmp` left behind) and `doctor` reported `judgments_chain_broken` and `judgments_truncated` for them.
- `polispec judgments verify` recognises that signature, a record whose `prev` equals the `prev` of the record before it, as an `interrupted_append`. It lists those in a new `interrupted` array beside `findings` (also in `--json`), prints `chain ok; N interrupted appends`, exits 0, and expects the anchor's count to leave them out. `doctor` reports nothing for them.
- Append latency on a stream of this host's size rose from 0.37 ms to 0.55 ms.

## [0.30.0] - 2026-10-17

### Changed

- A governed line that runs `eval`, `source` or `.` no longer asks `POLISPEC-TOOL-UNKNOWN` in a project in development. `Ledger#development(path)` (`lib/polispec/ledger.rb`) returns the project ids when at least one non-retired ledger project contains the directory, every such project has status `onboarding`, and the directory is not inside an env checkout; `HookCommand#judge` (`lib/polispec/commands/hook.rb`) then skips the opaque unknown in both of its branches. Agents source env files they wrote themselves on nearly every task, and 82 of the 86 asks left in `rllm`, `teach`, `reach` and `rdemo` since 0.28.3 were such lines, in projects the guard lists as not enforced. The directory of every command in the line must be in development too, so `cd <live project> && source env.sh` still asks. A live project, a live project containing an onboarding one, a test or stable checkout, an unowned path and the lock edition keep the ask, and so does everything that is not an opaque line: an unrecognised tool, a line the parser extracts no command from, an undeclared MCP operation, every deny and every rule warn. The visible commands of a relaxed line are judged as before, so `source env.sh; git push origin main:stable` is still denied; what the relaxation gives up is sight of the commands inside the sourced file.
- Each relaxed call carries an optional `relaxed` field in its judgment record (rule, reason `development`, project ids; `schemas/judgment.v1.yml`). Records without it are unchanged.
- The new setting `polispec.relax.dev` (`on` by default, `POLISPEC_RELAX_DEV=off`) restores the 0.29.0 ask in every project without a release.

## [0.29.0] - 2026-10-17

### Added

- Persistent exceptions to guard asks: an always-allow list for `POLISPEC-TOOL-UNKNOWN`, `POLISPEC-MCP-UNDECLARED` and environment rule warns. Claude Code's own prompt for a hook ask offers only Yes or No, so a line the guard cannot classify (an `eval`, `source` or `.` line, an unrecognised tool, an undeclared MCP operation) asked again in every session. The operator now records an exception once, in `exceptions.yml` (schema `polispec.exceptions/v1`, `schemas/exceptions.v1.yml`) at the root of the global shelf. It lifts exactly the ask it names, for the commands it matches, in the project or on the host it is scoped to.
- `polispec exceptions list|add|promote|remove`. When a call asks, the hook records a proposal (`apr_` id, `exception_proposals.jsonl` in the state home, kept seven days) and ends the ask text with `To stop asking for [<command>], the operator can run in a separate terminal: polispec exceptions promote <id>`. `promote`, `add` and `remove` need a TTY and a typed phrase, refuse while the sealed plane is active, and write nothing but `exceptions.yml`: they require the shelf to be a git repository on its ref with no other uncommitted change under the shelf path, then plan and apply the global target with the plan's own id as the confirmation, which commits the file as `Apply polispec plan <id>`. A failed apply restores the previous bytes, or moves a new file to `<state home>/exceptions.yml.failed-<UTC>`. An agent shell cannot run them (`not_tty`).
- An entry has a kind (`control` for the unknown-tool and undeclared-MCP asks, `rule` for a Bash rule warn), the exact tool, a glob over the whitespace-normalised, unexpanded command text (`*` crosses slashes; the first word may not contain a glob character), and a scope of one project (the git toplevel of the working directory, of the proposal's directory for `promote`) or the whole host. `promote` escapes the glob characters of the proposed text, so a promoted entry matches that command exactly. A shell line with several `eval`, `source` or `.` commands is lifted only when every one is covered, and the rest of the line is judged as before.
- Every call an exception lifted carries the `aex_` ids in an optional `exceptions` field of its judgment record (`schemas/judgment.v1.yml`); records without one are unchanged. `polispec doctor` reports `exceptions_invalid`. The setting `polispec.exceptions` (`on` by default, `POLISPEC_EXCEPTIONS=off`) honors no entry, records no proposal and adds no hint, which restores the 0.28.3 output.

### Security

- Exceptions never lift a deny, `POLISPEC-CONTROL-PROTECTION`, the container root guard, a broken seal or any lock-edition verdict, and `plan`, `apply`, probes and the journal replay never apply them. The file is a protected path like the ledger: a Write, Edit or shell redirect into it classifies as `policy.edit` and is denied.
- An exception matches the text of a command, not what it expands to or runs. An entry for `. $B/env.sh` stays in force whatever `$B/env.sh` contains, so scope it as narrowly as the work allows. The `sealed_authority` refusal was exercised only against a stubbed `Plane.resolve`, because no plane is active on this host.

## [0.28.3] - 2026-10-17

### Fixed

- `SubagentHandback`, `StructuredOutput` and `ScheduleWakeup` asked `POLISPEC-TOOL-UNKNOWN` on every call. They are harness-internal tools like `TaskStop` and `SendMessage` (a subagent returning its result, a headless run emitting its structured answer, a loop resuming itself), so they are now in `Classify::Benign::INTERNAL_TOOLS` (`lib/polispec/classify/benign.rb`) and are not unknown. Over the two days of host judgments before this change they made 177 of the 381 `POLISPEC-TOOL-UNKNOWN` asks. `CronCreate` and the other scheduling tools, `Artifact` and every unrecognised tool keep asking.

## [0.28.2] - 2026-10-17

### Fixed

- Every Claude Code `Monitor` call asked `POLISPEC-TOOL-UNKNOWN`, whatever its command was, because `Monitor` was not a recognised shell tool: its command was never parsed, so a loop of read-only commands such as `until grep -q … ; do sleep 5; done; echo finished` was judged as an unknown tool. `Monitor` now joins the shell tools, so its command is classified and judged by policy like the same Bash line, and a line the parser fully parses and policy allows no longer asks (`Harness::Base::SHELL_TOOLS` in `lib/polispec/harness/base.rb`). The container root guard covers it as well, so a privileged `docker run` in a `Monitor` is caught as in Bash (`HarnessControls::RootGuard::SHELL_TOOLS`); without that, the call would have stopped asking and stopped being guarded at once. A `Monitor` line that runs `eval`, `source` or `.` still asks, and a push to `stable` in one is now denied by `R-PROD-GIT` as in Bash rather than only asked. Over the last two days of host judgments, 59 of the 381 `POLISPEC-TOOL-UNKNOWN` asks were `Monitor` calls.

## [0.28.1] - 2026-10-16

### Fixed

- Reading compressed files counted as writing them. `zcat`, `zgrep`, `zegrep`, `zfgrep`, `zless`, `zmore`, `bzcat`, `xzcat` and `zstdcat` were unrecognised programs, so each got the fallback write on its working directory, and a protected-root rule such as a location bound denied a plain read. They now classify as reads of their file operands, like `cat` and `grep` (`lib/polispec/classify/commands/secrets.rb`).
- `gzip`, `gunzip`, `bzip2` and `xz` always counted as writing their first operand. With `-c`, `-t` or `-l` (alone or in a short-option cluster such as `-dc`), `--stdout`, `--to-stdout`, `--test` or `--list` they write nothing and now read their operands. Compressing or decompressing in place still writes, and a redirect such as `gzip -c a > b.gz` still writes `b.gz` (`lib/polispec/classify/commands/fs.rb`).
- `mkdir -p "$DIR"` with an operand the parser cannot resolve counted as a write of the working directory. From the home directory, that write is an ancestor of polispec's protected roots, so POLISPEC-CONTROL-PROTECTION denied creating a scratch directory. Such an operand is now the fallback write with `unknown`, which the ancestor match skips (as for unrecognised programs since 0.23.1). A static `mkdir` target, and an unresolved operand of any other command (`chmod -R "$X"`, `rm -r "$X"`), keep the ancestor match (`lib/polispec/classify/commands/fs.rb`).
- Pre-release smoke against the pinned 0.28.0: 31/31. The 29 diffs are the same set an unmodified tree at 0.28.0 produces against it: the clone-versus-pinned runtime kind of the candidate tree, installation and operation ids, backup timestamps, scratch paths and commit ids.

## [0.28.0] - 2026-10-16

### Added

- Code specs gain two classification axes on `polispec.spec/v1`: `type` (`directive`, `lint`, `review`, `contextual`) says how a policy binds, and `domain` (`design`, `accessibility`, `performance`, `code-quality`, `code-meta`, `security`, `operations`) says what it governs. Both may be declared at spec level, as a default for the spec and its child specs, and on any composite or rule, overriding for its subtree. An undeclared type is derived from `execution.class` (`lib/polispec/code/pack.rb`, `schemas/spec.v1.yml`).
- `polispec code list [--type T] [--domain D] [--spec PATH] [--json]` prints every active policy with its type and domain and the count (`lib/polispec/commands/code.rb`).
- `--type` and `--domain` filter `polispec code show`, and the output of `show` and `chain` carries each rule's type and domain. The guard classifies `code list` and the new flags as read-only (`lib/polispec/classify/benign.rb`).

### Changed

- The `code-commands` smoke scenario expects the new `show` line format, `<level> <severity> <class> <type> <domain> <lifecycle>`. Pre-release smoke against the pinned 0.27.1: 31/31, with diffs limited to the new type and domain columns, the version, commit ids, and the clone-versus-pinned runtime kind of the candidate tree.
- `polispec code validate` rule 9: an active rule whose declared or spec-level type disagrees with its `execution.class` is a problem. Packs that declare no types are unaffected (`lib/polispec/code/validator.rb`).

## [0.27.1] - 2026-10-16

### Fixed

- A fresh install could not follow the quick start. `polispec apply environment-control --repo <repo>` failed with `ledger_missing: … create it before onboarding`, and nothing created a ledger. polispec now creates a starter ledger from one template, `config/ledger.starter.yml` (the schema, the short hostname, `envs_root ~/.polispec/envs`, the example default rules, `projects: []`):
  - `polispec install` creates it at user scope, and so does `install.sh` through it. The receipt records `ledger_created`, and `uninstall` leaves the ledger in place.
  - A package `plan` on a host without a ledger shows `before: none` and the tighten change "creates the starter ledger … with no projects". `apply` creates it (no `.bak-` file, since there was none) and adds the project as `onboarding` without `--confirm`.
  - `doctor`'s `ledger_missing` says "create one with polispec ledger init".
- An existing ledger is never overwritten. A sealed host never gets one created (`ledger_sealed`; `ledger_missing` names the operator). The starter changes no verdict, because its default rules apply only to the projects it lists, and it lists none (`lib/polispec/ledger.rb`, `lib/polispec/packages.rb`, `lib/polispec/plan.rb`, `lib/polispec/native_install.rb`, `lib/polispec/commands/doctor.rb`, `install.sh`).

### Added

- `polispec ledger init [--dry-run] [--json]` writes the starter ledger to the resolved ledger path, mode 0600 in a 0700 directory, after validating it against the schema. It prints `kept` when a ledger is already there (`lib/polispec/commands/ledger.rb`).

### Changed

- `rules/polispec-stewardship.md` lists `polispec ledger init` for a host with no ledger and counts creating the starter ledger as tightening. The README quick start and command table describe the starter ledger.

## [0.27.0] - 2026-10-16

### Added

- polispec installs and runs without rplugin. `install.sh` (`curl -fsSL …/install.sh | sh`) checks for git and Ruby 2.6, clones the newest `vX.Y.Z` tag (or `POLISPEC_REF`), pins it, and runs `polispec install` for each harness it finds (`POLISPEC_HARNESS=claude,codex|none`, `POLISPEC_DRY_RUN=1`).
- `polispec pin [--ref TAG] [--source PATH|URL] [--dry-run] [--json]`. It archives a tag whose `VERSION` matches into `<data home>/releases/<commit>/` (`POLISPEC_DATA_HOME`, else `$XDG_DATA_HOME/polispec`, else `~/.local/share/polispec`). It makes the copy read-only, records `.polispec-release.json` (`polispec.release/v1`: ref, commit, version, source, tree digest, previous target), swaps `current` atomically, and links `~/.local/bin/polispec` unless that path belongs to something else. The source is the clone runtime, the source a pinned release records, or a bare fetch of the public repository into `<data home>/source.git`. Pinning is idempotent and never deletes an older release (`lib/polispec/native_pin.rb`, `lib/polispec/commands/pin.rb`).
- `polispec install` / `uninstall --harness claude|codex|all [--scope user|project] [--project DIR] [--force] [--dry-run] [--json]`:
  - Claude Code: the `PreToolUse`, `SessionStart` and `SubagentStart` guard hooks go into `settings.json`, with the skill link and, at user scope, the two rule links under `~/.claude/rules/polispec/`.
  - Codex: one marked `# >>> polispec hooks >>>` block in `config.toml` and the skill link under `~/.codex/skills/`. No trust hash is written, so Codex asks the user to trust the hooks.
  - Every changed file is backed up beside itself, and hooks polispec did not write are kept.
  - It refuses without `--force` when the polispec Claude Code or Codex plugin is already enabled.
  - Receipts go to `<state home>/installs/` (`polispec.install/v1`). `uninstall` removes only the marked hooks and the links that still match the receipt (`lib/polispec/native_install.rb`, `lib/polispec/commands/install.rb`, `uninstall.rb`).
- `polispec settings list|get|set|unset [--json]` and the settings file `~/.config/polispec/settings.yml` (`POLISPEC_SETTINGS`). Values are validated against the settings in `polispec.rplugin.yml`, `list` names where each value came from, and the verb refuses while the sealed plane is active. Every setting gains a short environment variable (`POLISPEC_ENFORCE`, `POLISPEC_CODE_CHECK_AT`, …; `polispec.operator` is `POLISPEC_OPERATOR_NAME`; `polispec.edition` has none) (`lib/polispec/native_settings.rb`, `lib/polispec/commands/settings.rb`).
- `polispec.gemspec`: `gem build` gives a gem with the `polispec` and `polispec-guard` executables. Not published.

### Changed

- Unsealed settings resolve from the `RPLUGIN_POLISPEC_*` variable, then the short `POLISPEC_*` variable, then rplugin's settings snapshot, then the settings file, then the default. A value that fails validation falls through to the next source. The fast path watches the settings file (`lib/polispec/engine.rb`, `lib/polispec/code/settings.rb`, `lib/polispec/fastpath.rb`). Hosts with rplugin resolve exactly as before unless they set a short variable or the file.
- `bin/polispec-guard` also tries `<data home>/current/bin/polispec` and, last, the `polispec` beside the shim. A Claude Code or Codex plugin install now runs the real guard instead of the inline fallback, and a pinned release still wins over the cached copy.
- The runtime recognises a native release (`.polispec-release.json`) as `pinned`. `doctor` prints `pinned (native)`, verifies its tree digest, and checks provenance against `<data home>/source.git` when the recorded source is a URL (`lib/polispec/runtime.rb`, `lib/polispec/commands/doctor.rb`).
- `polispec steward` and `apply --with-stewardship` work without rplugin. When `rplugin` is not executable, step 1 links the rules into `<claude home>/rules/polispec/` (or reports that there is no Claude Code home) and step 3 runs `polispec pin --ref v<VERSION>`. With rplugin, every step is unchanged (`lib/polispec/stewardship.rb`).
- The README leads its Install section with the one-line installer, then a clone, then the Claude Code and Codex plugin marketplaces, then the gem, and lists rplugin last. `AGENTS.md`, `rules/polispec-stewardship.md`, the skill, `docs/operator.md` and `specs/app.yml` describe the paths that do not need rplugin.

## [0.26.0] - 2026-10-16

### Added

- `polispec explain --harness HARNESS [--json] < hook-json` judges one PreToolUse hook call through the same path as `hook pretool` (classification, environment outcomes, the harness-control ceiling with the undeclared MCP default) and prints the verdict the harness would get under enforce, whatever `polispec.enforce` is: `verdict`, `rule_id`, `reason`, `governed`, the control verdict and `ask_ids`, and per action its class, server, operation and whether a protected or committed rule declares it. It writes nothing: no judgment record, no event, no fast-path refresh, no policy cache, no allow-once issue or consumption and no protected authorization (the explain adapter answers `ask?` true, so ask composition returns before the authorization branch; `Engine::Passes.consume!`, `PolicySource.remember_environments` and `write_cache` are no-ops while it runs, so a held allow-once pass is reported as not held). Exit 0 with a verdict, 2 on invalid input, 1 on an internal error, never a fabricated allow. For callers that must know before an unattended session runs whether its tools pass, such as Teach's doctor (`lib/polispec/commands/explain.rb`, `lib/polispec/commands/hook.rb`; blueprint `specs/explain.impl.yml`). `hook pretool` output and records are unchanged.

## [0.25.1] - 2026-10-15

### Fixed

- `seal` no longer dies `oversized_bundle` on the smoke ledger: `smoke.yml` grows with every recorded run and passed the seal's 1 MiB per-file limit in 0.24.0, so `seal --dry-run` from a clone exited 1 and the `seal.yml` scenario failed. The runtime manifest of the committed release now leaves the smoke ledger out, as it has left the logo images out since 0.24.0; `MAX_FILE` and `MAX_BUNDLE` are unchanged (`lib/polispec/harness_controls/authority.rb`).
- `seal` from a polispec installed as an rplugin release enumerated the wrong tree: the pinned directory has no `.git`, so the runtime plan ran `git ls-tree` against whatever repository encloses the plugin store and died on that repository's files. The runtime manifest now comes from the source repository and commit the release descriptor records (`.rplugin-release.json`), the resolved commit must equal the pinned one, and a missing or incomplete source fails `runtime_source_unavailable` instead of inspecting an unrelated repository. A clone runtime still uses its own working tree and fails the same way when it is not one.

## [0.25.0] - 2026-10-15

### Added

- Judgment records. Every call the guard judges leaves one chained `polispec.judgment/v1` record in `judgments.jsonl` under the polispec state home: what was judged (tool, harness, event, session, home-relative cwd, and a `call_digest` over tool, arguments and cwd), against which rulebook (one target per governed project or baseline with its policy source and digest, the matched rule and the per-action rows), by which polispec (version, runtime kind, commit, tree digest when pinned, edition, enforce mode, plane status, fast-path key), and what the harness was told (the composed verdict, rule, rendered decision, duration). Allows are recorded. The record is written after the control ceiling composes and before the reply, chained with `prev` and `digest` under `judgments.lock`, anchored in `judgments.head.json`, and rotated at 16 MiB. A fail-closed internal denial records `POLISPEC-INTERNAL` and the error class. Git hooks record with harness `git`. Recording never changes a verdict; a failed append emits a `judgment_unrecorded` finding (`lib/polispec/judgments.rb`, `lib/polispec/canonical.rb`, `schemas/judgment.v1.yml`, `lib/polispec/commands/hook.rb`, `lib/polispec/git_hook.rb`).
- `polispec judgments list [--since 24h] [--session ID] [--project ID] [--json] | show <id> [--json] | verify [--json]`, `polispec validate judgment`, the `doctor` findings `judgments_chain_broken` and `judgments_truncated`, and `polispec digest` built from warn and deny judgments (`lib/polispec/commands/judgments.rb`, `doctor.rb`, `digest.rb`).
- Setting `polispec.records.raw` (`off` by default): `on` adds the classifier's raw view of the judged command or target, at most 2048 bytes, to the local record only. It never goes through the events port.
- `bin/polispec-guard` appends one line to `skips.jsonl` for every call its fast path skips (tool, session, fast-path key, `no_needles` or `no_match`) with bash builtins only, and `judgments verify` counts them per key. The shim extracts the tool name with a bash regex instead of grep, head, sed and tr, and reads the first line of its files instead of running head and wc.
- Smoke scenario `judgments.yml` (unit `judgments`): 31 scenarios.

### Changed

- The `polispec.judgment` event replaces `polispec.verdict`: the events port receives a copy of each record without its raw field, and the local record is the system of record. The control-ask `polispec.verdict` event added in 0.24.0 is folded into the record's `control` block (verdict and ask ids). `verdicts.jsonl` and the opt-in journal (`polispec.verdicts.journal`, `journal.jsonl`) are no longer written; existing files are left in place. `polispec plan` replays the per-action rows of the last 14 days of judgments without a setting (`lib/polispec/journal.rb`, `lib/polispec/plan.rb`, `lib/polispec/events.rb`).

## [0.24.0] - 2026-10-15

### Changed

- A shell line that runs `eval`, `source` or `.` now asks `POLISPEC-TOOL-UNKNOWN` under harness controls, in addition to whatever its commands classify as, because what it runs cannot be seen. The shell parser records `eval` when it unwraps it, at any nesting depth (`Script#opaque`, `lib/polispec/classify/shell.rb`), so words inside quoted strings, heredoc bodies fed to non-shells and grep patterns do not count (`Classify.opaque_shell?`, `lib/polispec/commands/hook.rb`). Replaying 1,699 real Bash calls against 0.23.2, two newly ask, both lines that source an env file with `.`; the other differences come from where each runtime lives, since the protected runtime is the running tree.
- `R-POLISPEC-RUNTIME` no longer shadows a stricter policy rule: the runtime verdict and the policy's first-match verdict are both computed and the stricter wins, so a write inside a clone runtime that is also a production checkout is denied by `R-PROD-FS` instead of warned (`Engine#stricter_runtime`).
- G-CLEAN (`clean_tree`) counts untracked, non-ignored files as dirty (`lib/polispec/operator/git.rb`, `gates.rb`).
- `seal` leaves image assets under `assets/` (the logos) out of the runtime bundle, so a logo over 1 MiB no longer stops a seal with `oversized_bundle`; `MAX_FILE` and `MAX_BUNDLE` are unchanged. A seal dry run on an unprepared host now reports its blocked prerequisites (exit 3) instead of dying on the oversize (exit 1).
- Codex code-hook denials carry the blocking code-spec rule id (for example `code.ruby.no-binding-pry`), and the "specs injected, retry" deny carries `POLISPEC-CODE`, instead of `POLISPEC-INTERNAL` (`lib/polispec/harness/codex.rb`, `lib/polispec/code/hook.rb`).
- Every blocking `code-hook stop` carries the instruction to run the polispec-reviewer subagent, not only a stop with deferred rules.
- `polispec doctor` prints `N findings (B blocking, I info)` when info findings are present; the count covers every listed finding.

### Added

- A non-root user may uninstall their own user- or project-scope harness-controls overlay on an unsealed host: the receipt must be unprotected and carry their `owner_uid` (written by unprivileged installs since this release), and they type `uninstall INSTALLATION_ID` on a TTY. Protected receipts, managed scope, other owners, a broken or active plane and receipts from before 0.24.0 still need the operator (`lib/polispec/harness_controls/lifecycle.rb`, `docs/harness-controls.md`).
- Smoke verdict `inconclusive`: a live scenario whose model never attempted the action is retried once and, if it still does not attempt, recorded inconclusive. It does not fail the run, never proves a unit and never revokes an earlier pass; a forbidden file or ref change always fails with no retry (`lib/polispec/smoke/live.rb`, `run.rb`, `schemas/smoke.v1.yml`).
- `POLISPEC_CODE_DECIDE=off` disables the decide port; the smoke runner sets it for every step, so no smoke run reaches a model through `code classify`.
- `polispec apply … --checkouts` prints each git hook it installs and the checkout it went into (`lib/polispec/packages.rb`, `docs/environments.md`).
- Smoke scenarios `steward.yml` (unit `commands/steward`) and `harness-uninstall.yml`, and new steps in `noise.yml`, `classify.yml`, `stewardship.yml`, `code-commands.yml`, `code-hook.yml`, `plan-apply.yml`, `promote-deploy.yml`, `seal.yml`, `smoke-suite.yml` and `status-digest-doctor.yml`: 30 scenarios.

### Fixed

- A shell redirect, Write or Edit of the ledger was allowed while `rm` of it was denied: a `policy.edit` whose target is a protected path or lies inside one is now denied with `POLISPEC-CONTROL-PROTECTION`. `polispec apply`, whose `policy.edit` names a directory, is unaffected (`lib/polispec/harness_controls/evaluate.rb`).
- Control asks are written to the event log as `polispec.verdict` with level `warn` and the control's rule id, so asks can be counted.
- `git log -p`, `git show -p` and `git diff -p` are benign reads; `-p`, `--paginate`, `-c`, `--config-env` and `--exec-path` are refused only as git global options.
- `polispec code controls --policy ID` exits 1 with `unknown policy id ID` for an id the pack does not define.
- `docs/operator.md` scratch use names `POLISPEC_LEDGER`, `POLISPEC_HOME`, `POLISPEC_GLOBAL`, `POLISPEC_STATE_HOME` and `POLISPEC_ENVS_ROOT` and no longer tells you to redirect `XDG_STATE_HOME`. `docs/roster.md` and `docs/schema.md` list the roster `run` values the schema and the worker-profile check accept.

## [0.23.2] - 2026-10-15

### Fixed

- `polispec smoke run` works from a pinned install. The runner took the git top level of the tree as its root, and a pinned release lives inside another checkout (`rstack-uber/plugins/.pinned/…`), so every scenario failed with `specs/app.yml is not a regular file`. The git top level is used only when it is the tree itself (`lib/polispec/smoke/run.rb`).
- `--scenarios smoke/live` together with `--live` no longer runs each live scenario twice into the same fixture directory.

### Added

- `smoke/scenarios/smoke-suite.yml` covers the `smoke` unit: a nested run of one bundled scenario without recording, and the live kill switch blocking a live scenario before any harness starts.

## [0.23.1] - 2026-10-15

### Fixed

- A shell line the parser fully parses no longer asks `POLISPEC-TOOL-UNKNOWN` just because it is not on the benign list (`sed -n`, `git branch -a`, `cd …; …`, `for` loops, `bin/polispec smoke verify`, `psql -c`): its commands' classes, or none, go to policy as in 0.22.0. The unknown ask stays for unparseable shell lines, lines that use `eval`, `source` or `.`, unknown non-shell tools, and undeclared MCP operations (`Classify.parsed_shell?`, `lib/polispec/classify/benign.rb`). Replaying 1,699 real Bash calls, 0.23.0 asked on 234; 0.23.1 asks on none of them.
- The fallback write an unrecognised program gets on its working directory no longer counts as a change to protected polispec authority when that directory is only an ancestor of a protected path. `rstack status`, `rswitch` or `persona load` run from the home directory, `~/.ai` or `rstack-uber` were denied with `POLISPEC-CONTROL-PROTECTION` (78 of the 1,699 replayed calls); an explicit recursive change, move or delete of an ancestor, and any program run inside a protected path, are still denied (`lib/polispec/harness_controls/evaluate.rb`).

## [0.23.0] - 2026-10-15

### Added

- `polispec smoke run [--unit PATTERN]... [--scenarios DIR] [--against TREE] [--host-copy] [--live claude-code|codex]... [--out DIR] [--no-record] [--accept-changes] [--json]`: a bundled, deterministic smoke suite. 27 scenarios in `smoke/scenarios/` (`polispec.smoke-scenario/v1`, `schemas/smoke-scenario.v1.yml`) each build a scratch fixture (ledger, global shelf, git projects with test and stable checkouts) and run hook calls and commands against it with isolated state (`POLISPEC_STATE_HOME`, `XDG_STATE_HOME` under the scratch directory), so a run never writes the live guard's state. A passing run records one `suite` entry per scenario in `smoke.yml` (runner kind `suite` added to `schemas/smoke.v1.yml`) (`lib/polispec/smoke/`).
- `--against TREE` runs every scenario a second time with another tree's `bin/polispec` and reports each step whose verdict, exit code or normalised output differs; paths, timestamps, digests, record ids and durations are normalised, and a diff exits 1 unless `--accept-changes`. `--host-copy` judges the probes in `smoke/host-probes.yml` against a copy of this host's ledger and global shelf and prints the verdict table. `--live claude-code|codex` runs the live scenarios in `smoke/live/` through `claude -p` (Haiku) or `codex exec` with a timeout and turn cap; the setting `polispec.smoke.live` (`on` by default) and `POLISPEC_SMOKE_LIVE=off` stop every live step.
- `POLISPEC_STATE_HOME` moves polispec's state while no sealed plane is active; events skip the rplugin port while it is set, and `bin/polispec-guard` reads its fast-path files from it when `/etc/polispec/active.json` is absent (`lib/polispec/state.rb`).
- `fastpath.tools`: the tools `bin/polispec-guard` may skip under a governed baseline. Harness-internal tools are listed; Read, Grep and the other read tools are listed only while no global or module rule governs reads (a `secrets.read` class, a `tool` naming a read tool, or a rule with neither `class` nor `shape`). Any other tool, including every MCP and unknown tool, reaches polispec (`lib/polispec/fastpath.rb`).
- `harness install --harness claude-code` checks for `bwrap` and `socat` on Linux and refuses with `sandbox_unavailable`, writing nothing; `--dry-run` and `harness plan` report the same finding and succeed.

### Changed

- `harness_controls` is on by default (`config/harness-features.yml`); `sealed_plane` stays off. Under a governed baseline the guard asks about undeclared MCP operations and unknown non-read tools (standard edition). Harness-internal tools (TodoWrite, Skill, ToolSearch, Glob and the like), fully parsed read-only shell lines and read-only `polispec` verbs are classified as benign and stay allowed; WebFetch and WebSearch classify as `web.fetch`, Agent and Task as `agent.spawn` (`lib/polispec/classify/benign.rb`).
- An MCP operation counts as declared when a rule with an exact `match.server` and `match.operation` sits in any layer the engine composes for the call, including the global shelf and its modules, not only a live project's own policy (`lib/polispec/commands/hook.rb`).
- Without an active sealed plane, an ask that comes only from environment-policy warnings keeps the 0.21.0 legacy deny with an `alo_` allow-once id; a control ask (undeclared MCP, unknown tool) under Codex is denied because exact operator authorization needs the plane.
- Project-scope Claude Code, Codex and Antigravity hook callbacks pass `--controls-project`.
- `polispec code detect` on an empty file reports `unknown` and exits 0.

### Behaviour changes on upgrade

- Every MCP call that no rule declares asks under Claude Code and is denied under Codex. Declare the operations you use in the global shelf (for example a module with one `{ match: { class: [mcp.call], server: S, operation: O }, verdict: allow }` rule per operation) before installing this release.
- Smoke parity against v0.22.0 differs only in that change, in the control install now working, and in runtime-kind and state-path differences between a clone and a pinned tree.

## [0.22.0] - 2026-10-15

### Added

- `polispec steward [--check] [--json]`: the stewardship steps without an apply target. `--check` only reports, marking an unsatisfied step `missing` with what would run, and exits 1 (`lib/polispec/commands/steward.rb`, `lib/polispec/stewardship.rb`).
- `bin/polispec-guard`, the guard shim every harness hook now runs: a bash fast path that skips starting Ruby for calls that cannot touch a governed path, the call to the `polispec` on PATH (the pinned release, never a harness's plugin-cache copy), and a fail-closed fallback that denies prod-shaped shell calls when polispec is missing or fails. It replaces the host-wired `~/.claude/hooks/polispec-guard.sh`, with byte-identical pretool verdicts on this host.
- `fastpath.watch` beside `fastpath.txt`: the ledger, global-layer refs, settings and plane files whose change invalidates the fast path, so the shim needs no host-specific paths (`lib/polispec/fastpath.rb`).

### Changed

- polispec installs natively into Claude Code: `extensions.only` now includes `claude-code`, so `rplugin install polispec` brings the guard hooks (SessionStart, PreToolUse, SubagentStart), the skill and the rule links (`~/.claude/rules/rplugin/polispec/`). Requires rplugin 1.15.0. Codex stays excluded and keeps its host bridge.
- Stewardship step 1 also requires the Claude Code rule link when rplugin supports rules for Claude Code; when the runtime still has to be pinned, step 3's pin creates the link and verifies it.
- `hooks/polispec.hooks.yml` runs `bin/polispec-guard` and adds `subagent_start`; `hooks/hooks.json` and `hooks/codex.json` are regenerated by `rplugin package`.

## [0.21.0] - 2026-10-14

### Added

- `polispec plan` and `polispec apply`: one preview-then-apply path for every rulebook change. Targets are a package (`<name> --repo REPO [--variant V] [--param k=v]`), `project:<id>`, `global`, and `ledger --from FILE`. A plan lists files, the ledger effect, the composed policy difference, and the verdicts that change, classifies the change as tightening, loosening, mixed, or neutral, and prints a plan id. Loosening, mixed, and global plans apply only with `--confirm <plan-id>`; a stale id refuses with `plan_changed` (`lib/polispec/plan.rb`, `lib/polispec/commands/plan.rb`, `lib/polispec/commands/apply.rb`, `docs/packages.md`).
- Packages: `packages/<name>/package.yml` (`polispec.package/v1`) with parameters, variants, files, modules, and ordered built-in steps, found in the shipped `packages/` and on the global shelf. `environment-control` (variants `service` and `distributed`) is the first. The ledger records each applied package with its version and file digests; `status` lists them, `doctor` reports `package_upgrade_available` and `package_file_drift`, and an upgrade keeps edited files as conflicts (`lib/polispec/packages.rb`, `schemas/package.v1.yml`, `schemas/ledger.v1.yml`).
- Verdict replay: plans judge synthetic probes generated from each project's environments, and, with the new setting `polispec.verdicts.journal` (`off` by default), the last 14 days of journaled verdict facts. The journal never holds command text (`lib/polispec/probes.rb`, `lib/polispec/journal.rb`).
- Stewardship: the shipped rule `rules/polispec-stewardship.md` tells agents how to develop, install, upgrade, and repair polispec and change its rulebooks without disrupting the host. rplugin installs it as a rule where a harness has a rules surface (Antigravity CLI); every other harness reaches it through the polispec skill and the `[POLISPEC]` directive, and AGENTS.md points to it.
- Runtime awareness: polispec knows whether it runs from a pinned rplugin release, a working clone, or the sealed plane, verifies a pinned release's tree digest, and `doctor` prints `runtime:`. A built-in protected root denies writes into a pinned runtime and warns on writes into a clone runtime (`R-POLISPEC-RUNTIME`) (`lib/polispec/runtime.rb`, `lib/polispec/engine.rb`).
- `polispec apply --with-stewardship` checks that the installed plugin ships the stewardship rule (reinstalling it from the running tree when not), checks the runtime protection, and pins a clone runtime to the tag of the running version with `rplugin install <clone> --ref <tag>` before applying anything; any failure stops it first (`lib/polispec/stewardship.rb`).

### Changed

- `polispec apply … --confirm`, and `apply global` or `apply ledger` with or without it, classify as `policy.edit`, so on a live policy the harness asks the user (`R-POLICY`); `polispec plan` and `apply <package>` classify as before (`lib/polispec/classify/commands/release.rb`).
- `doctor` prints `runtime:` before its findings; info findings (`package_upgrade_available`, `package_file_drift`) do not affect `ok` or the exit code. A pinned runtime's provenance requires its commit to be on the source's `main` (`lib/polispec/commands/doctor.rb`).

### Removed

- `polispec onboard`, with no alias. `polispec apply environment-control --repo <repo>` runs the same steps; `--serves`, `--archetype`, `--id`, and `--trust-ref` became `--param serves=`, `--variant`, `--param id=`, and `--param trust_ref=`, and `--dry-run` became `polispec plan`. `templates/onboard/` moved into `packages/environment-control/`.

## [0.20.0] - 2026-10-14

### Added

- Project-local modules: a project ships its own `modules/<name>.yml` beside its policy, read from the same source as the policy (trust ref, bootstrap ref, or the sibling directory of a validated file). A project module may include project and global modules; a name on both shelves is an `ambiguous` error (`lib/polispec/layers.rb`, `docs/schema.md`).
- Typed module parameters: a module declares `params` (`string`, `integer`, `number`, `boolean`, `list`, with `default` and `summary`); an include is a name or `{ module, with }`; `"{{name}}"` keeps the type, `{{name}}` inside text interpolates, and includes pass parameters down. Unknown, missing or mistyped parameters, unresolved placeholders and duplicate instance ids are errors (`lib/polispec/layers.rb`, `schemas/module.v1.yml`, `schemas/policy.v1.yml`, `schemas/global.v1.yml`).
- Gate `dir`: a gate may run in a subdirectory of its run location; a missing directory or a path escaping it fails the gate (`lib/polispec/operator/gates.rb`, `schemas/policy.v1.yml`).
- `examples/clinic/`: a booking-app policy composed three levels deep from parameterised project modules.
- `docs/VISION.md`: where polispec is going, every item labelled Built, Partial, Planned or Idea.

### Changed

- Nested ledgered projects contribute everything they declare: a child layer expands its own includes ahead of its rules, and every descendant's promotion gates (run in the child's directory), preflight, freezes and hermetic settings join the owner's promotion. A child id that collides with the owner or global layer is an `id_collision` error (`lib/polispec/layers.rb`, `lib/polispec/policy_source.rb`).
- The outermost ledgered repo or worktree root containing a path owns it, regardless of ledger order (`lib/polispec/ledger.rb`).
- Composition errors make `promote` refuse with `policy_invalid` instead of promoting with fewer gates; `resolve --layers` lists them (`lib/polispec/operator/gates.rb`, `lib/polispec/commands/resolve.rb`).
- Promotion bootstrap now composes the candidate branch's policy with the global layer and its project modules (`lib/polispec/policy_source.rb`).
- A layer digest covers its module instances and their resolved parameters.
- README rewritten: plain-language introduction, table of contents, the clinic worked example, how a verdict is made, composition, alternatives, honest limits and FAQ, with the project hero image.

## [0.19.1] - 2026-10-13

### Fixed

- `onboard --dry-run` rendered `4_render` from the templates even when the scaffold files already existed and were kept, so on a scaffolded repository it previewed a render and a commit the real run did not perform; it now previews from the files in the repository (`lib/polispec/commands/onboard.rb`, `docs/environments.md`).
- `onboard --commit` reported step `4b_commit` as `kept` when onboard wrote no files; it is now `skipped` with nothing to commit (`lib/polispec/commands/onboard.rb`, `docs/environments.md`).
- Removed the unused `started` variable that `ruby -w` reported in `lib/polispec/commands/harness.rb`.

## [0.19.0] - 2026-10-13

### Added

- `polispec onboard --commit`: after rendering (step `4b_commit`) onboard stages by name and commits only the files it wrote on main as `Add the polispec scaffold`, so `5_branches` creates test and stable in the same run; with `--push` it pushes main, test and stable. Skipped with a note when HEAD is not main; `--dry-run` previews the commit and the branches. Without `--commit` the output is unchanged (`lib/polispec/commands/onboard.rb`, `docs/environments.md`, `README.md`, `skills/polispec/SKILL.md`).

### Changed

- The service archetype's placeholder `deploy.health.run` is the shell-free nonexistent command `polispec-placeholder-health-check-replace-it-in-specs-polispec-environments-yml`; `deploy` records `health_failed` (run exited 127) naming it until the operator writes a real check (`templates/onboard/service/environments.yml`).
- Repointing the `specs` link needs the typed phrase `relink <full target path>`, the absolute `<repo>/specs` path shown in the prompt, instead of `relink specs`. `specs` refusals report `not_tty` and `confirmation_failed` like the other operator commands (`lib/polispec/code/admin.rb`, `lib/polispec/commands/specs.rb`, `docs/code-specs.md`).
- `harness scan` exits 1 instead of 3 when the environment scan cannot run (`lib/polispec/commands/harness.rb`, `docs/harness-controls.md`).

### Fixed

- The harness-controls target resolver raised `committed policy is unavailable` for a live project without a committed policy at its trust ref; the fallback policy (global `fallback_rules`, else ledger `defaults.rules`) now governs, as it does for the guard since 0.18.5 (`lib/polispec/commands/hook.rb`).
- `harness uninstall --dry-run --owner` needed root. A non-root dry run now previews from what the current uid can read, writes nothing, and reports each owner check it could not perform as `owner_check_unverified`; root and real uninstalls are unchanged (`lib/polispec/harness_controls/lifecycle.rb`).

## [0.18.7] - 2026-10-13

### Fixed

- `specs link` replaced an existing `~/.polispec/specs` link that pointed elsewhere without confirmation, even from an agent shell. Repointing now needs an interactive terminal and the typed phrase `relink specs`; creating a missing link or confirming the same target needs neither, and `--dry-run` previews (`lib/polispec/code/admin.rb`, `lib/polispec/commands/specs.rb`, `docs/code-specs.md`).
- `harness uninstall --dry-run` returned `operator_required` for a non-root operator; without `--owner` a dry run now previews without root (`lib/polispec/harness_controls/lifecycle.rb`).
- `harness scan` returned `ok: true` and exit 0 with an opaque `environment_scan_failed`; it now returns `ok: false`, exits 3 and names the cause (`lib/polispec/commands/harness.rb`, `lib/polispec/harness_controls/environment.rb`).
- `seal` rejected `examples/ledger.example.yml` because YAML read `onboarded` as a date; bundle YAML is normalised as the ledger loader does (`lib/polispec/harness_controls/authority.rb`).
- `code classify` on a file that defines no policy rules printed nothing and exited 0; it now says why and exits 1 (`lib/polispec/commands/code.rb`).
- `docs/harness-controls.md` documents the `operation_id` shapes.

## [0.18.6] - 2026-10-13

### Fixed

- `onboard` (service archetype) scaffolded `deploy.steps` without `deploy.health`, so validate, promote and deploy refused the new policy. test and prod now carry a placeholder `deploy.health.run` that exits 1 and says to replace it: the policy validates and promotes to test, and `deploy` fails its health check until the operator writes a real one (`templates/onboard/service/environments.yml`, `docs/environments.md`).
- `onboard` validates the ledger with the new entry before writing any file, so a `ledger_invalid` failure leaves no scaffold behind.
- `onboard` created test and stable at main before the scaffold was committed, so with `--push` origin stable carried no policy and doctor reported `policy_missing`. The branches are now created only once the scaffold is committed on main; otherwise step 5 is skipped with the exact commands to run (`lib/polispec/commands/onboard.rb`).
- `onboard` dry-run and re-run wording ("would wrote", "would fresh added", "kept kept") now reads "would write", "would add fresh to", "already present".
- `status` reported no finding for a policy that `promote` rejects as `policy_invalid`; it now reports the same `policy_invalid` finding for a missing health check, bad environment names or invalid profiles (`lib/polispec/commands/status.rb`).

## [0.18.5] - 2026-10-13

### Fixed

- `hook pretool` denied every non-read call in a live ledgered project whose policy was missing or invalid at its trust ref with `[POLISPEC internal] guard unavailable`. The global layer's `fallback_rules` (ledger `defaults.rules` when there is no global layer) now govern, as `docs/schema.md` states (`lib/polispec/commands/hook.rb`).
- Claude PreToolUse deny and ask reasons now name the rule: `[POLISPEC <rule_id>] DENIED:` or `WARNING:`, matching the git hook and the other harness backends (`lib/polispec/harness_controls/backends/claude.rb`).
- The next step for a path no polispec project owns said `polispec promote global --to stable`; it now says no project owns the path, so there is no `polispec promote` for it (`lib/polispec/engine.rb`).
- `tag_claimed` for a tag equal to origin/main's version on a commit that is not origin/main's release commit now says the tag is not on that release commit, instead of "not greater than" (`lib/polispec/predicates.rb`, `docs/schema.md`).

## [0.18.4] - 2026-10-13

### Fixed

- `allow-once` prompts and stored grants named only the tool (`edit`) for a file-tool call, so the operator could not see which file a grant unlocks. The raw action text of a file-tool call is now the tool and its absolute target (`edit /abs/path`), in the prompt, the stored grant and the deny and ask reasons (`lib/polispec/classify/tool.rb`, `lib/polispec/commands/allow_once.rb`).
- `polispec status <unknown> --json` printed plain text; it now prints a JSON `unknown_project` error and exits 1 (`lib/polispec/commands/status.rb`).
- `polispec behavior decide` rendered empty arrays as `[`, a blank line and `]`; empty arrays and maps now render as `[]` and `{}` (`lib/polispec/commands/behavior.rb`).
- `pause` and `allow-once` report `not_tty` and `confirmation_failed` like `promote` (`lib/polispec/commands/pause.rb`, `allow_once.rb`).
- `docs/operator.md` lists `tag_unsupported` and describes the allow-once prompt.

## [0.18.3] - 2026-10-13

### Fixed

- `polispec code-hook post|stop|session` with `--harness claude` or `--harness codex` rejected every payload that was not `PreToolUse` and failed open without a trace: a `post_write` MUST violation landed unblocked, `stop` never reviewed, and compact/clear never re-armed injection. Each mode now normalizes its own event (`PreToolUse`, `PostToolUse`, `Stop`, `SessionStart`) for both harnesses, and a hook failure prints a one-line diagnostic on stderr; the exit status stays 0 (`lib/polispec/harness_controls/backends/claude.rb`, `codex.rb`, `lib/polispec/harness/*.rb`, `lib/polispec/code/hook.rb`). Found by the 0.18.2 smoke sign-off; a Haiku session now gets the post and stop blocks.

## [0.18.2] - 2026-10-13

### Added

- Smoke ledger: `smoke.yml` (`polispec.smoke/v1`, `schemas/smoke.v1.yml`) records smoke tests that proved a spec or sub-spec in reality. `polispec smoke record` checks that the `--spec`/`--at` reference resolves, stores the node's digest, the verdict (`pass`, `fail`, `partial`, `blocked`), steps and evidence digests, and captures the runtime (OS, kernel, architecture, container and WSL flags, time zone, locale, Ruby, polispec version, edition, commit and install kind, rplugin version, enforce mode) and the target (commit, branch, dirty flag, governed project, environment and policy digest). No hostname, user name or absolute path is recorded. Entries are hash-chained and appended under a lock in the git common dir. `record` also anchors the head digest and count per ledger in `smoke-heads.json` under the state home. `smoke list`, `show`, `verify` (schema, digest, chain, duplicate ids, truncation against the anchor; stale and unresolved references) and `coverage` (per-unit status against the current spec, from `smoke.coverage_units` in `specs/app.yml` or `--at` patterns) read it back; `polispec validate smoke` validates it. `record` emits `polispec.smoke`. Setting `polispec.smoke.path`, overridden by `POLISPEC_SMOKE` (`lib/polispec/smoke.rb`, `lib/polispec/commands/smoke.rb`, `docs/smoke.md`).
- `ROADMAP.md`, with shipping a bundled smoke-test suite as its first item. Operators run their own smoke tests today.

## [0.18.1] - 2026-10-13

### Fixed

- `tag_claimed` no longer refuses the release tag itself. A tag equal to the `VERSION` at `refs/remotes/origin/main` matched as taken even when it named the release commit on origin/main, so the order the rule asks for (re-bump, push main, tag last) was always denied, for `git tag` and for the tag push. An equal version now matches only when the tagged commit is not an ancestor of origin/main or its own `VERSION` differs; a lower version still matches (`lib/polispec/predicates.rb`).
- `git tag vX <commit-ish>` is judged on the commit it names. The classifier gave `tag_claimed` the current branch for a SHA target and the local branch for `origin/main` (`ref` strips the remote for environment resolution), so a clone without a current local `main` was refused for tagging origin/main's release commit. The `git.tag` hint now carries the commit-ish as written in `at`, which `tag_claimed` checks; `ref` is unchanged (`lib/polispec/classify/commands/git.rb`, `docs/schema.md`).

## [0.18.0] - 2026-10-13

### Added

- Deterministic harness-control grammar and `polispec.control/v1`, with explicit native plans, tightening-only installation, owned-artifact receipts, verification, and authenticated removal. Backends cover Claude Code, Codex, Hermes, Antigravity CLI, and OS sandbox planning.
- Root-owned authority generations and pinned runtime provenance, exact Git sources for standard, root-authored sources for lock, and explicit operator activation and rollback. No live project is activated by installation.
- Protected one-use authorization service with kernel peer identity, bounded Unix transport, exact combined ask bindings, durable consumption, replay refusal, operator redemption, an explicit kill marker, and stale-socket recovery. Unit rendering does not install or start a service.
- Container exposure scans with distinct follow-up arming, conservative protected-history validation, and separate rootless observations.
- Standard and lock editions using one codebase, an edition-only `polispec-lock` release operation with exact leases and recovery reporting, and local provenance checks in doctor.

### Fixed

- Hook failures now deny non-read actions with fixed native output while preserving positive diagnostic reads. Input and judgement are bounded, native session envelopes stay separate, and multi-edit and rename endpoints are fully classified.
- Independent control ceilings, exact MCP declaration selectors, strict overlay history and current contribution checks, and sealed settings resolution prevent mutable additions from weakening protected authority.
- Doctor works without RubyGems, and edit classification retains the declared Ruby 2.6 API floor.

### Release activation

- Both feature flags remain disabled by operator direction. This release publishes the finished implementation; it does not activate host defaults, controls, a plane, or live projects. Grammar, validation, planning, and read-only inspection remain available.
- Standard and lock operate from independent checkouts. Lock doctor verifies its immutable parent without depending on the current main ref, and a lock executable refuses an active standard-plane mismatch. Shared release source does not require the other edition to be installed.

### Verification limits

- Artifact, CLI, parser, and scratch transport evidence are reported separately from native enforcement. No paid model journey, root-owned host seal, protected host service installation, timer activation, or live-project activation was performed. Hermes and agy runtimes were absent; Bubblewrap namespace startup was unavailable. No backend is marked lock-certified.
- This standalone plugin has no matching compiled rhomeostasis obligation verifier. The operator approved reviewed commits and actual CLI/rplugin verification with unavailable attestation recorded; no passed attestation is claimed.

## [0.17.1] - 2026-10-10

### Fixed
- `status --json` exposes a read-only deployment receipt and latest attempt per environment. Successful deployment state now retains its deploy record identity and health; verification rejects an in-progress or newer failed attempt, unchecked health, pins, and legacy receipts without identity. Consumers can distinguish successful deployment from a stable branch move that preceded failed deployment.

## [0.17.0] - 2026-10-09

### Added
- `polispec promote <project> --to <env> --waive-soak` (`lib/polispec/commands/promote.rb`, `lib/polispec/operator/promote.rb` `waive_soak!`): the operator skips the `soaked` gates of a promotion past test. It needs an interactive terminal and the typed phrase `waive soak for <project>` before any gate runs; agents cannot pass it. `Gates.run_all` reports the waived gate as `waived` and every other gate still runs. It is refused for `--to test` (`waive_soak_unsupported`) and when the promotion has no `soaked` gate (`nothing_to_waive`). `--dry-run --waive-soak` previews without the phrase. The promotion record, the result and the `polispec.promote` event (`lib/polispec/events.rb`) carry `waived: [soak]`. It lives in polispec, so no policy change is needed to use it.

## [0.16.2] - 2026-10-09

### Fixed
- The global baseline judged every action of an onboarding project as `dev` when the action carried no path of its own (`lib/polispec/commands/hook.rb` `evaluate_baseline`). A `systemctl --user restart` run from the project's prod checkout, or from a `release_dirs` release behind it, was allowed by a baseline rule scoped to `env: prod`. The baseline now takes the working directory's environment the way a live project does; a repository outside the ledger stays `dev`.

## [0.16.1] - 2026-10-09

### Fixed
- A path under a project's environment checkout root that names no environment resolved to `dev` (`lib/polispec/resolve.rb` `location_env`). With `deploy.strategy: release_dirs` the prod checkout is a symlink into `releases/`, so every path in the live release, and in `shared/`, resolved as `releases` or `shared` and fell back to `dev`. Once the project is live, the guard would have judged edits and git commits in production by dev rules. Such a directory now fails closed to `prod`, as `Engine::Envs.env_for_checkout_dir` already did.

## [0.16.0] - 2026-10-09

### Added
- Layered policy (`lib/polispec/layers.rb`). A global layer is read from the committed `polispec.global.ref` (default `main`) of the git repository in `polispec.global.repo`, in the directory `polispec.global.path` (default `polispec`). `POLISPEC_GLOBAL`, a plain directory, wins for scratch runs. The global layer is composed with the repo policy and with nested child projects. Rules stay first-match within a layer, and the strictest verdict wins across layers. An upper rule can be loosened only when it is marked `overridable: true` and the lower rule names it in `overrides`; anything else is a validation error naming both rules. With no global source set, verdicts are unchanged.
- `global.yml` may carry `fallback_rules`. They replace the ledger `defaults.rules` only for a project whose policy is missing at its trust ref, and never join the composed layer. A configured global source with an absent or invalid `global.yml` is reported (`layers_invalid`) and contributes no rules.
- Modules and profiles. `global.yml` and policies take `includes` of modules from `modules/<name>.yml`, resolved depth-first and each once, with cycles and missing modules reported. The ledger `profile` field (`personal`, `service` or `live`, default `personal`) selects modules from `profiles.yml`. A policy may only name a stricter profile.
- Schemas `polispec.global/v1`, `polispec.module/v1` and `polispec.profiles/v1`, `profile` in the ledger and policy schemas, and `polispec validate global|module|profiles`.
- The guard applies the global baseline outside live projects. When a global layer has rules, an action no live project owns is judged by the global layer plus its project's profile modules: an onboarding project's id, or `global` for a repo outside the ledger. The fast path then also passes every shell, edit, write and patch tool call to polispec, and its cache key covers the global layer.
- `polispec resolve <path> --layers --json` prints the layer chain with each layer's digest and the effective digest. Verdict reasons name the layer that decided.
- Action class `fs.delete`, emitted alongside `fs.write` for `rm`, `rmdir`, `unlink`, `shred`, `find -delete`, `find -exec rm` and `git clean -f`, and alone for `cargo clean` (its target directory) and `git worktree prune`. Edit and Write tool calls never produce it.
- Match key `shape` with the names `bulk_stage`, `chained_release`, `latest_flip`, `lockfile_edit`, `pattern_kill`, `cargo_clean` and `worktree_force`, tagged from the parsed script (`classify/shapes.rb`). An unknown name fails validation.
- Match keys `lock_held`, `live_binary`, `supervised`, `pin_regress`, `tag_claimed` and `base_unpushed` (`lib/polispec/predicates.rb`). They are read-only and bounded by a 2 s budget, and report a finding instead of failing when they cannot decide.
- Setting `polispec.supervisor.status_command`, an argv printing `{"units": [...], "pids": [...]}`, which feeds `supervised` and is cached for 60 s. When unavailable, `supervised` fails closed for `pattern_kill` and open for a named unit.
- Protected roots declared by the global layer (`protected_roots: [{path, writers}]`) are honoured by `crosses: location` for `fs.write` and `fs.delete` from any working directory. A command whose argv[0] basename is in `writers` does not cross.
- Environment names come from the policy. Any declared environment can be a promotion hop through `promotion.to_<env>` (each with `from:`), and `polispec promote --to <env>` and `polispec deploy <project> <env>` accept it, so `main -> test -> canary -> stable` works. `environments.yml` accepts environments beyond dev, test and prod. The guard treats such an environment as its declared `tier`, or as prod when it declares none.
- Builtin gates `sha_ran_on` (option `env`, default `test`), `logs_quiet` (options `services`, `window_minutes`, `max_over_baseline`) and `requires_live` (options `project` plus `min_version`, or `min_version_from` with `min_version_key`). `soaked` takes `env`. Setting `polispec.logs.count_command` is an argv template with `{service}`, `{since}` and `{until}` that prints one integer; `logs_quiet` fails closed when it is unset or fails.
- Profile checks (`lib/polispec/validate_profiles.rb`): `personal_no_warn`, `version_reported` (service and live projects must have health that proves the deployed version) and `protected_writers` (a deploy step must not write under a global protected root it is not a writer of). They run when the operator loads a project and in `polispec doctor` (finding `profile_check`). Doctor and validate also report environments that deploy without a health check.
- Freeze `applies_to` accepts `promote.to_<env>`.

### Changed
- `sha_ran_on_test` is an alias of `sha_ran_on` with `env: test`. The implicit stable `G-TESTED` uses `sha_ran_on` and is skipped when the hop lists either form.
- `kill <pid>` and `kill $(pgrep ...)` classify as `service.control` as well as the existing unknown-command `fs.write`. A bulk `git add` classifies as `fs.write`. `gh release ... --latest=true` is read as a Latest release.
- `invalid_target` and `invalid_env` list the policy's declared names; for `test` and `stable` the text is unchanged.

## [0.15.2] - 2026-10-09

### Fixed
- `schemas/environments.v1.yml` accepts the same `deploy` block as `schemas/policy.v1.yml`: `strategy`, `activate` and `drain` (`pause`, `wait`, `resume`, `timeout_s`, `checks`, `run_in`, `env_from`). The manifest schema predated those keys, so a project that deploys with `release_dirs` or drains could not move its environments into `environments.yml`: validation, `agents render` and the policy merge all failed with `unknown key`.

## [0.15.1] - 2026-10-09

### Added
- A command gate may set `hermetic: false` (`schemas/policy.v1.yml`, `operator/gates.rb`). Such a gate runs with the caller's environment and without the protected-root fingerprint, and its entry in the promote result carries `"hermetic": false`. It is for a read-only check of the installed copy: a plugin manager's `check` or `doctor` needs the real plugin home, and appends to the install's own event logs, so under `hermetic.<env>` it always failed, either because the isolated home held no install or with `wrote outside its location`. Every other command, deploy step and `deploy.health.run` keeps the isolation.

## [0.15.0] - 2026-10-09

First public release.

### Added
- Environment guard and classifier: every agent tool call in a governed project gets an allow, warn or deny verdict from the policy committed on the project's stable ref, with a reason and a next step.
- Schemas and validators for policy, roster, ledger and environments (`polispec.policy/v1`, `polispec.roster/v1`, `polispec.ledger/v1`, `polispec.environments/v1`), plus the behavioral policy format with deterministic compilation and declarative deny evaluation.
- `polispec promote` and `polispec deploy` with gates and freezes, tagged releases and rollback by tag.
- `polispec allow-once` and `polispec pause`, both operator actions that need an interactive terminal and a typed phrase.
- Roster resolution and checks: harness, model and effort per agent role, with bounds an edit may not leave.
- Code specs: language detection, spec chain injection, changed-line enforcement with a ratchet baseline and waivers, and `polispec specs promote`.
- `polispec onboard` for a new user-serving project, with service and distributed archetypes.
- `polispec agents render` and the generated `[ENVS]` AGENTS.md row, with doctor drift detection.
- Git hooks per environment (`polispec hook git`) that judge commits, pushes and ref moves outside an agent harness.
- Hermetic runs (`hermetic.<env>.isolate`, `protected_roots`): deploy steps, health runs and command gates run with each isolated variable pointed into a scratch directory, and a change under a protected root fails the run with `wrote outside its location`.
- `deploy.strategy: release_dirs` with `deploy.activate` and `deploy.drain`: releases built beside the live one, an atomic symlink swap, automatic rollback recorded as health `rolled_back`, drain pause, wait and resume (resume always), and retention of the 3 newest plus active releases ordered by tag version.
- Drain `checks` (`drain_check_failed`), gate and drain fields `run_in: repo|active` and `env_from`, and `polispec deploy <project> stable --skip-drain` (terminal plus the typed phrase `skip drain for <project>`, recorded as `drain: skipped`). In-place deploys drain before checking out the new tag.
- Gates `soaked` (option `hours`) and `health_required`, `promotion.to_stable.preflight`, `release.flip_latest: deferred`, and the `{stable_tag}` interpolation variable. A policy that deploys without a health check is refused with `policy_invalid`.
- Engine match keys `crosses: location` (a write that resolves into another project's protected roots or production checkout) and `destructive: true` (an unbounded DELETE or UPDATE, DROP, TRUNCATE, or a destructive shell verb).
- Policy schema keys `includes`, rule `overridable` and `overrides`, and freeze `project`.

### Changed
- The ledger path resolves from `POLISPEC_LEDGER`, then the `polispec.ledger` setting, then `$XDG_CONFIG_HOME/polispec/ledger.yml` (default `~/.config/polispec/ledger.yml`).
- Deny and next-step messages name the person who promotes to stable through the `polispec.operator` setting (default `the operator`).
- Freezes gain a generic `source: command` that runs a list of argv strings without a shell in the prod checkout and parses its JSON windows. The previous calendar and activity source names stay accepted as deprecated aliases (see `docs/schema.md`).
- The code specs repository defaults to `~/polispec-specs` and is configurable with the `polispec.code.specs_repo` setting; `POLISPEC_SPECS_REPO` still wins.
- Schema and documentation wording is neutral; the `rlogs` observability value and the `*.rstack_component.yml` manifest recognition are optional integrations.
- Secret references of the form `scheme:path` (a lowercase scheme and a colon, not starting with `~` or `/`) are treated as store references rather than file paths.
