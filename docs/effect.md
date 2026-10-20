# When a change takes effect

A polispec change is a new policy promoted to `stable`, an edit to the ledger or the global shelf, a persistent exception, a setting, or a new polispec release pinned on the host. This page says when a Claude Code or Codex session that is already running starts obeying each of them, whether it must restart, and how to confirm that the change landed.

Short answer: for Claude Code, the guard follows every change on the next tool call without a restart. Three things do not follow on their own: the wiring the harness loaded at session start, the text polispec injected into the model at session start, and (on Codex) the harness's own trust review of a changed hook.

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
| A changed or new Codex hook definition | Codex trusts a non-managed hook by its hash and skips a new or changed one until it is reviewed. Plugin hooks are not trusted when a plugin is installed or enabled. | `/hooks` in Codex: review and trust the hook. Until then the guard is not running for that session. |

## Claude Code

Sources: the Claude Code documentation for hooks, settings, plugins and subagents (read 2026-10-20).

- Settings files are watched. Edits to `permissions` and `hooks` in settings reach the running session without a restart. The harness-control overlay that polispec writes to settings therefore applies live.
- Plugins are different. `/reload-plugins` applies plugins installed, updated, enabled, disabled or edited on disk since the session started. After a plugin update, hook commands keep using the previous version's path until the reload.
- Hooks fire for subagents too, so the parent's policy also binds them. A subagent starts with a fresh context, so the `SubagentStart` text is current at its start.
- `additionalContext` from a hook is inserted into the conversation at the point the hook fired, and `permissionDecisionReason` reaches the model on a deny.
- Claude Code has `ConfigChange` (settings and skills files; not MDM or console managed settings), `FileChanged`, `InstructionsLoaded`, `SessionStart` and `SessionEnd` events. polispec registers none of them today.
- The documentation does not state that hook commands are a new process per call, and does not state whether hooks are snapshotted at start or whether a subagent re-reads them. The measurements above are the evidence for polispec's own behavior.

## Codex

Sources: the Codex hooks documentation, the host's `~/.codex/config.toml`, and the Codex source checkout kept for the 2026-10-05 agent-caching investigation (a snapshot, which may differ from the installed Codex).

- Hooks come from `hooks.json` files, inline `[hooks]` tables in `config.toml`, and plugins. Project-local hooks load only for a trusted project.
- Non-managed hooks must be reviewed and trusted before they run. Codex records `trusted_hash` per hook in `config.toml` under `[hooks.state]`, and `/hooks` shows new or changed hooks for review.
- The documentation does not say whether hooks reload while a session runs. The source does: `Session::refresh_hooks` is reached from `reload_user_config_layer`, `refresh_runtime_config` and the plugin install, upgrade and reconcile paths, and the tests `reload_user_config_layer_refreshes_hooks` and `refresh_runtime_config_refreshes_hooks` cover it. Treat a restart as unnecessary for hook definitions, but confirm it on the installed version.
- Hook commands for one event run concurrently with the session `cwd`. Subagent hooks receive the parent's `session_id`.
- polispec reaches Codex through the `~/.ai` bridge, which calls `bin/polispec-guard`, so runtime re-pins follow on the next call exactly as for Claude Code. The open risk is the trust hash: a change to the hook definition that Codex hashes would leave the guard skipped until someone trusts it. Whether the hash covers the command text only, or also the script behind it, is not established.

## Confirming that a change landed

Nothing is announced to the running session today. Confirm from the record:

1. `polispec judgments list --session <id> --since 1h --json`: each record carries the policy digest of every project it was judged against (`targets[].policy_digest`) and the runtime (`engine.version`, `engine.commit`). The change has taken effect in that session at the first record that shows the new digest or version.
2. `polispec resolve <path>` and `polispec explain` evaluate under the current state, so they show the verdict a new call would get.
3. `polispec exceptions list` shows the entries and the pending proposals.
4. `polispec status` and `polispec doctor` show the ledger, the runtime and the findings.

What the record cannot answer: which sessions are still running, what a session was told at its start (session events are not recorded as judgments), whether a session is waiting on `/reload-plugins` or a Codex trust review, and when a particular exception was first used. The proposed features in `TODO.md` ("Change receipts and effect tracking") close those gaps.
