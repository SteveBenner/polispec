# When a change takes effect

A polispec change is a new policy promoted to `stable`, an edit to the ledger or the global shelf, a persistent exception, a setting, or a new polispec release pinned on the host. This page says when a Claude Code or Codex session that is already running starts obeying each of them, whether it must restart, and how to confirm that the change landed.

Short answer: for Claude Code, the guard follows every change on the next tool call without a restart. Three things do not follow on their own: the wiring the harness loaded at session start, the text polispec injected into the model at session start, and (on Codex) the harness's own trust review of a changed hook, which also needs a new session.

## Why most changes need no restart

The harness does not hold polispec's policy. It holds a hook definition that runs `bin/polispec-guard` once per tool call as a new process. That script finds the `polispec` binary (`POLISPEC_BIN`, then `polispec` on `PATH`, then `~/.rplugins/polispec`) and the binary reads the policy again from disk and git on every call. The fast path (`fastpath.txt`, `fastpath.watch`) compares the modification times of the ledger, the global shelf, the settings files and the control plane with the key it last wrote. A newer file, or a different key, sends the call down the full path, which recomputes the key.

So a re-pin of the runtime, a promoted project policy, an applied plan, a new exception and a settings change all apply on the first tool call after they land, in every session on the host, including sessions that started before the change.

Measured on this host from the judgment stream (`polispec judgments list --since 4d`, 47,006 records, 2026-10-16 to 2026-10-20):

- The runtime was re-pinned 15 times, from 0.26.0 to 0.33.0. After each re-pin, no judgment was written by the previous version. The first record of each new version followed the last record of the old one by seconds (for example 12:05:28 to 12:05:39 on 2026-10-16).
- Single Claude Code sessions ran across two and three versions without restarting (session `b739927d` went 0.26.0, 0.27.0, 0.27.1 over 1,303 calls).
- 32 session and project pairs saw their policy digest change mid-session.

## What does not follow on its own

| What | Why | How it takes effect |
|---|---|---|
| Hook wiring in `hooks.json`: events, matchers, timeouts, a new event | Claude Code loads plugin hooks at session start and keeps the previous version's path after a plugin update. | `/reload-plugins` in the session, or a new session. |
| The launcher script `bin/polispec-guard` itself | It runs from the plugin cache copy that was loaded at session start (`~/.claude/plugins/cache/polispec/polispec/<version>`). Claude Code keeps older cache copies for 14 days. | A stale launcher still calls the current runtime, because it looks the binary up on every call. Use `/reload-plugins` when a release says the launcher changed. |
| The `SessionStart` and `SubagentStart` text (policy digest, guard mode, role defaults) | The harness adds it to the conversation once and replays it on resume. The model keeps reading the old line. | A new session or a new subagent. Verdicts are not affected: the guard judges against the current policy whatever the model was told. |
| Managed settings delivered by MDM or the console | They reach a running Claude Code session on a schedule, not on save. | Wait for the delivery interval, or restart the session. |
| A changed or new Codex hook definition | Codex trusts a non-managed hook by a hash of its definition (command string, timeout; see Codex below) and skips a new or changed one until it is reviewed. A Codex session that is already running keeps the hooks it loaded at start. | A new Codex session after the hook is trusted in `/hooks`. Until then the guard is not running for that session. A change to the script behind the command needs neither a review nor a restart. |

## Claude Code

Sources: the Claude Code documentation for hooks, settings, plugins and subagents (read 2026-10-20), and the live run below.

- Settings files are watched. Edits to `permissions` and `hooks` in settings reach the running session without a restart. The harness-control overlay that polispec writes to settings therefore applies live.
- Plugins are different. `/reload-plugins` applies plugins installed, updated, enabled, disabled or edited on disk since the session started. After a plugin update, hook commands keep using the previous version's path until the reload.
- Hooks fire for subagents too, so the parent's policy also binds them. A subagent starts with a fresh context, so the `SubagentStart` text is current at its start.
- `additionalContext` from a hook is inserted into the conversation at the point the hook fired, and `permissionDecisionReason` reaches the model on a deny.
- Claude Code has `ConfigChange` (settings and skills files; not MDM or console managed settings), `FileChanged`, `InstructionsLoaded`, `SessionStart` and `SessionEnd` events. polispec registers none of them today.
- The documentation does not say whether hooks are snapshotted at session start or whether a subagent re-reads them. The live run below settles both for project settings.

### Measured: hooks edited in a running Claude Code session

The run used `claude` 2.1.304 with `claude-haiku-5-5`; the subagent ran `claude-sonnet-5-5`. One session, `claude -p --input-format stream-json --output-format stream-json --verbose --setting-sources project --permission-mode bypassPermissions --no-session-persistence`, started in a scratch git project whose `.claude/settings.json` held one `PreToolUse` hook (matcher `*`) that appended a tag, its stdin's `hook_event_name`, `tool_name` and any `agent_id` to a log. The session stayed open across three user messages; between messages a script rewrote the settings file with tag `B`, then `C`. No user or global settings were loaded or touched.

| Turn | Settings tag when the message was sent | Log line |
|---|---|---|
| 1 `echo one` | A | `A PreToolUse Bash` |
| 2 `echo two` | B (edited after turn 1) | `B PreToolUse Bash` |
| 3 subagent runs `echo three` | C (edited after turn 2) | `C PreToolUse Agent`, then `C agent_id=a9c9552e14d0dceca agent_type=general-purpose PreToolUse Bash` |

Answers: a hooks change in project settings reached the running session on its next tool call, and the subagent's own tool call ran the current definition (`C`). Neither a snapshot at session start nor a re-read by the subagent is needed to explain it. Limits: the edits happened between turns, not during a tool call; only project settings were tested, which is the same watched file class as user settings but not the same file; plugin `hooks.json` was not tested and the documentation says it needs `/reload-plugins`. Cost: 3 turns, about 0.07 USD in total.

## Codex

Sources: the Codex hooks documentation, the host's `~/.codex/config.toml`, the Codex bridge in the host's AI home (written `<ai home>` below: a directory of agent configuration that host keeps outside polispec), installed `codex-cli` 0.163.0 (read-only inspection plus the scratch runs below), and the Codex source checkout kept for the 2026-10-05 agent-caching investigation (a snapshot, which may differ from the installed Codex).

- Hooks come from `hooks.json` files, inline `[hooks]` tables in `config.toml`, and plugins. Project-local hooks load only for a trusted project.
- Non-managed hooks must be reviewed and trusted before they run. Codex records `trusted_hash` per hook in `config.toml` under `[hooks.state."<file>:<event>:<group>:<handler>"]`, and `/hooks` shows new or changed hooks for review.
- Hook commands for one event run concurrently with the session `cwd`. Subagent hooks receive the parent's `session_id`.

### How Codex reaches polispec on this host

There is no polispec plugin or polispec entry in `~/.codex`. Searched: `~/.codex/config.toml`, every plugin in `~/.codex/plugins/cache` (none mentions the guard or registers a polispec hook), `~/.codex/rules`, `~/.codex/agents`, the other `*.config.toml` files in `~/.codex`, and `<ai home>/codex` plus the files it calls. `~/.codex/hooks` does not exist. The wiring is the AI home's bridge:

1. `~/.codex/config.toml` holds one inline hook group per event, each running the same command:

```toml
[[hooks.PreToolUse]]
matcher = "Bash|apply_patch"

[[hooks.PreToolUse.hooks]]
type = "command"
command = "/usr/bin/python3 <ai home>/codex/bridge.py hook"
timeout = 120
```

   The same command is registered for `SessionStart` (matcher `startup|resume|clear|compact`, timeout 90), `UserPromptSubmit` (20), `PostToolUse` (`Bash|apply_patch`, 120), `PermissionRequest` (`*`, 15), `Stop` (150), `Interrupt` (3), `SessionEnd` (3) and `SubagentStop` (`*`, 15). `~/.codex/AGENTS.md` links to `<ai home>/codex/AGENTS.md`. The hooks around it are installed by a script in the AI home, whose README says it never writes a `trusted_hash`.
2. `<ai home>/codex/bridge.py hook` (`directive_guards`, `lifecycle`, `polispec_hook`) calls polispec in two places only: on `PreToolUse` (every `Bash` and `apply_patch` call; for `apply_patch` it adapts each target path to a Claude-style `Edit`) and on `SessionStart`. It runs `bash <ai home>/claude/hooks/polispec-guard.sh pretool|session` with `POLISPEC_HARNESS=codex`, a 10 second limit, and the Codex payload on stdin, then rewrites some skill-invocation wording in the reply. Other Codex tools (MCP calls, web, anything not matched by `Bash|apply_patch`) are not sent to polispec.
3. `<ai home>/claude/hooks/polispec-guard.sh` is not the plugin's `bin/polispec-guard`. It is a separate, older launcher kept in the AI home (modified 2026-10-09). It exits 0 with no output when `<ai home>/polispec/ledger.yml` is missing; it has its own fast path over that ledger, the global shelf's `refs/heads/main` and `~/.config/rplugin/polispec/settings.yml`; and it finds the binary by `polispec` on `PATH`, then `POLISPEC_BIN`, then `bin/polispec` in a fixed polispec checkout path. When the binary is missing or exits non-zero it applies an inline fallback that denies `git push|merge|tag|reset` to `test` or `stable`, `systemctl` and `gh release`. It calls `polispec hook pretool|session --harness codex`, so a runtime re-pin follows on the next call exactly as for Claude Code, but a change to the launcher is a change in the AI home, not in a polispec release.

The `[env]` table in `config.toml` sets `SOLVENCY_HOOKS_DISABLED = "1"`. That disables the bridge's solvency hooks but not the polispec call on `PreToolUse`, because `directive_guards` runs before the solvency switch is read. The roughly 2,800 Codex judgment records come from this path.

Trust is stored in `~/.codex/config.toml` itself, in `[hooks.state."<home>/.codex/config.toml:<event>:<group>:<handler>"]` tables, each with one `trusted_hash = "sha256:<64 hex>"`. `<event>` is the snake case event name, `<group>` the zero-based index of the `[[hooks.<Event>]]` group among that event's groups in file order, and `<handler>` the index inside the group. On the measured host the bridge hooks are `pre_tool_use:0:0`, `session_start:1:0`, `user_prompt_submit:0:0`, `post_tool_use:0:0`, `permission_request:0:0`, `stop:0:0`, `interrupt:0:0`, `session_end:0:0`, and `subagent_stop:0:0`; the host's other hook groups on those events hold the remaining indexes. Codex computes the hash; nothing on the host computes it, and polispec cannot reproduce it.

### Measured: trust and reload on Codex 0.163.0

Method: a scratch `CODEX_HOME` under the scratchpad (own `config.toml` with one inline `PreToolUse` hook, `auth.json` symlinked to the real one so the model could be reached, no other file shared), a scratch git project, `model = "gpt-6-luna"` at low reasoning effort, and a hook script that appends a version tag and its arguments to a log. `~/.codex/config.toml` was not read for the runs and not written.

Trust coverage (no model tokens): `codex app-server` over stdio answers `hooks/list` with each hook's `trustStatus` (`managed`, `untrusted`, `trusted`, `modified`) and its `currentHash`, and `config/batchWrite` on `hooks.state` records a trust. Sequence on one app-server process:

| Step | trustStatus | currentHash |
|---|---|---|
| New hook (`command = ".../hook.sh defA"`, `timeout = 5`) | `untrusted` | `b4cd871f...` |
| `trusted_hash` written for that key | `trusted` | `b4cd871f...` |
| The script file `hook.sh` gets an extra line (definition unchanged) | `trusted` | `b4cd871f...` |
| Command text changed to `hook.sh defB` | `modified` | `e2ad4e4e...` |
| Command text restored | `trusted` | `b4cd871f...` |
| `timeout = 5` changed to `6` | `modified` | `018b0b38...` |
| `timeout` restored | `trusted` | `b4cd871f...` |

Answer (b): the hash covers the hook's definition, shown to include the command string and the timeout, and not the script behind it. A restored definition is trusted again without a new review, because the stored hash matches. The matcher and the `type` were not varied, so whether they are part of the hash is not measured. The live run confirmed it in execution: with the hook trusted, replacing `hook.sh` with a new body between two tool calls made the second call log `script-v2` while Codex still reported the hook as `trusted` and ran it.

Reload (model run, once): `codex exec --json` with a prompt that asked for four separate shell calls, each `sleep 12; echo N`, so the session stayed open about 50 seconds. A watcher waited for each log line and then edited files while the next call was still about 12 seconds away.

| Tool call | Edit made before it | Log line |
|---|---|---|
| 1 | none | `script-v1 defA` |
| 2 | script body replaced, definition unchanged | `script-v2 defA` |
| 3 | `config.toml` rewritten (see the defect below) | `script-v2 defA` |
| 4 | none further | `script-v2 defA` |

Answer (a), as far as it was measured: a running Codex session did not stop running, or re-read, its hook when `config.toml` was edited on disk by another process. The run had a defect: the watcher opened `config.toml` for writing before it read it, so the edit before call 3 left an empty file instead of a `defB` definition. The hook, its trust record and its table were all gone from the file, and the session still ran the `defA` hook on calls 3 and 4. That shows the session works from the hooks it loaded at start and does not re-read the file by itself. It does not show what happens when a hook definition is changed through the app-server API with `reloadUserConfig`, or when the definition changes to a different, untrusted one in a session that does reload; those paths were not run. The script change in call 2 is the case that matters for polispec, and it is settled: the new script runs at once, with no review. Cost: one `codex exec` turn with `gpt-6-luna` low, 69,448 input tokens (64,256 cached), 184 output tokens; an earlier attempt hung on stdin before any model call and cost nothing.

What this means for polispec on Codex: editing `<ai home>/claude/hooks/polispec-guard.sh`, `<ai home>/codex/bridge.py` or a polispec release applies on the next hook call with no trust review. Editing a bridge hook definition in `config.toml` (the command, a timeout, probably the matcher) makes Codex mark it `modified`, and the guard does not run for new sessions until someone trusts it in `/hooks`.

## The `codex_hook_untrusted` doctor check

Purpose: tell the operator that the polispec path into Codex is not running for new Codex sessions. Built from the findings above; none of it needs a Codex plugin.

1. Locate Codex's user config: `$CODEX_HOME/config.toml`, else `~/.codex/config.toml`. If it does not exist, the check reports nothing (Codex is not installed for this user). It reads the file and never writes it.
2. Collect hooks in file order: every `[[hooks.<Event>]]` group and each `[[hooks.<Event>.hooks]]` handler, keyed `<config path>:<snake_case event>:<group index among that event>:<handler index>`. Only handlers with `type = "command"` are considered.
3. A handler reaches polispec when its command text contains `polispec-guard` or `polispec hook`, or when its command names a file (the first absolute path or `~/` path token) that exists and, read one level down, mentions `polispec-guard.sh` or `polispec hook`. On this host that finds `bridge.py hook` (it references `polispec-guard.sh`), and the check reports the matching events: all nine bridge events register it, but polispec is reached only on `PreToolUse` and `SessionStart`, so only those two decide the severity.
4. Decide trust, in order of authority:
   - If `codex` is on `PATH` (or `POLISPEC_CODEX_BIN`), start `codex app-server` with `CODEX_HOME` set, send `initialize` then `hooks/list` with the home directory as `cwd`, read `trustStatus` for each matching key, and stop the process. `untrusted` or `modified` gives the finding; `trusted` and `managed` give none. The session needs no model, so the check costs no tokens. A timeout of 5 seconds and a clean kill bound it.
   - Otherwise, read `[hooks.state]` from the file: a missing table for a matching key gives the finding (`untrusted`); a present `trusted_hash` gives `unverified`, because polispec cannot reproduce Codex's hash, so a changed definition is not detectable offline.
5. Output: a `warn` finding `codex_hook_untrusted` per untrusted or modified matching event, with the event, the hook key, the status, the source (`app-server` or `config`), the config path, and the next step "open `/hooks` in Codex, review the definition, trust it, and start a new Codex session". When only `unverified` applies it reports `info` `codex_hook_unverified` instead. A host with no matching hook reports `info` `codex_not_wired`, so doctor can say that Codex is not guarded rather than saying nothing.
6. Limits to state in the finding text: a running Codex session keeps the hooks it loaded at start, so a trust given now takes effect in new sessions; the check cannot see which sessions are running; and it says nothing about whether the guard launcher script is current, which is the `launcher_stale` check and is not covered for `<ai home>/claude/hooks/polispec-guard.sh`.

## Confirming that a change landed

Nothing is announced to the running session today. Confirm from the record:

1. `polispec judgments list --session <id> --since 1h --json`: each record carries the policy digest of every project it was judged against (`targets[].policy_digest`) and the runtime (`engine.version`, `engine.commit`). The change has taken effect in that session at the first record that shows the new digest or version.
2. `polispec resolve <path>` and `polispec explain` evaluate under the current state, so they show the verdict a new call would get.
3. `polispec exceptions list` shows the entries and the pending proposals.
4. `polispec status` and `polispec doctor` show the ledger, the runtime and the findings.

What the record cannot answer: which sessions are still running, what a session was told at its start (session events are not recorded as judgments), whether a session is waiting on `/reload-plugins` or a Codex trust review, and when a particular exception was first used. The proposed features in `TODO.md` ("Change receipts and effect tracking") close those gaps.
