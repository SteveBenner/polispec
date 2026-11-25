# Smoke ledger

A smoke test is a short run, against a real installation, that shows one spec or sub-spec working: the guard denying a push to the production branch, a promotion moving `test`, a code spec blocking a write. polispec ships a suite of smoke tests (`polispec smoke run`, below), and you can run your own beside it, on the machines and harnesses you care about, recording each result in a smoke ledger. polispec captures the runtime the test ran in, chains the entries so edits show, and reports which parts of a spec have a current pass.

## The file

`SMOKE-TESTS.md` (`polispec.smoke/v1`, `schemas/smoke.v1.yml`) sits at the root of the repository whose spec or features it proves. The location is `POLISPEC_SMOKE`, then the `polispec.smoke.path` setting, then `SMOKE-TESTS.md` at the git toplevel if it exists, then the legacy `smoke.yml` there if it exists, else `SMOKE-TESTS.md`. Commit it with the code: an entry is evidence about a commit of that repository.

A path ending in `.md` is a markdown container, rendered whole on every write:

- `# Smoke tests` and one sentence saying `polispec smoke record` writes the file;
- a summary table with one row per subject (a feature slug, or `spec#at`) holding its latest verdict, `recorded_at`, entry id and summary cut to 120 characters;
- `## Ledger` and one fenced `yaml` block holding the whole `polispec.smoke/v1` document.

Reading takes the first `yaml` fence after the `## Ledger` line. A missing file reads as an empty ledger, and a `.md` file without that block is an error naming the file. A path that does not end in `.md` is read and written as plain YAML, as before. An entry's id and digest cover the entry body only, so the same entries chain identically in either container.

The file is append-only, and is written only by `polispec smoke record` and `polispec smoke migrate`. A hand edit is detected by `polispec smoke verify`.

### Moving a smoke.yml

```sh
polispec smoke migrate --dry-run
polispec smoke migrate
polispec smoke migrate --from old/smoke.yml --to SMOKE-TESTS.md --keep
```

`migrate` moves every entry of `smoke.yml` (default `<toplevel>/smoke.yml`) unchanged into `SMOKE-TESTS.md` (default `<toplevel>/SMOKE-TESTS.md`), checks that the entries survive the round trip and verify cleanly, writes the file, verifies it again, re-anchors the head in `smoke-heads.json` for the new path, and removes `smoke.yml` unless `--keep` is given. It refuses and writes nothing when the target already holds entries, when `--to` does not end in `.md`, or when the source has a blocking finding. `--dry-run` reports the move without writing, and `--json` prints the result.

## Recording a test

```sh
polispec smoke record \
  --spec specs/polispec/policy.yml --at rules/R-PROD-GIT \
  --verdict pass \
  --summary "an agent's git push origin main:stable was denied with R-PROD-GIT; stable did not move" \
  --step-file steps.yml \
  --evidence transcript.jsonl:transcript --evidence hook.jsonl:events \
  --runner agent --harness claude-code --model claude-haiku-5-5
```

- `--feature SLUG` (matching `^[a-z0-9][a-z0-9._-]*$`) replaces `--spec` and `--at` when the entry proves a feature rather than a spec node, for example `polispec smoke record --feature export-csv --verdict pass --summary "the export downloaded and opened"`. Exactly one of `--spec` and `--feature` is required. A feature entry has no digest to go stale; `list --feature SLUG` filters by it and `coverage --feature` lists the feature subjects with their latest status.
- `--spec` is a YAML file inside the repository that parses to a mapping or a list, and `--at` a slash path into it. A segment is a mapping key, or a list item whose `name` or `id` equals it; write `~1` for `/` and `~0` for `~`. Without `--at` the entry proves the whole file. A reference that does not resolve, or resolves to an empty node, is refused.
- `--verdict` is `pass`, `fail`, `partial` (some of the sub-spec was shown) `blocked` (the test could not run, for example because the feature needs an activation that has not happened) or `inconclusive` (a live session never attempted the forbidden action, so the guard was not exercised; `coverage` ignores it and it neither proves nor revokes a unit) or `unsmokable` (no real run can observe the change). `unsmokable` needs `--reason TEXT`, stored as the entry field `reason`, and `--reason` is refused on any other verdict. `coverage` reports it as `unsmokable`: neither proven nor failing.
- `--step-file` is YAML or JSON: a list of `{run, exit, expect, observed}`.
- `--evidence PATH[:KIND]` records the file's sha256 and size, not its content. Keep the files where your evidence lives; the ledger proves which bytes you looked at.
- `--runner`, `--harness`, `--model` and `--effort` name who ran the test. Inside Claude Code or Codex the runner defaults to `agent` and the harness is detected.

## What an entry carries

Each entry stores what it proves (`spec`, `at`, the file's digest and `at_digest`, the digest of the node it proves, or a `feature` slug), the verdict, the `reason` of an unsmokable entry, summary, steps and evidence, the runner, and two captured blocks:

- `runtime`: OS id, name and version, kernel release, architecture, container and WSL flags, time zone, locale, Ruby, the polispec version, edition, commit, dirty flag and install kind, the rplugin version, and the enforce mode.
- `target`: the repository's commit, branch and dirty flag (the ledger file itself is ignored), and, when the repository is governed, its project id, environment and policy digest.

No hostname, user name or absolute path is recorded. In summaries, steps and evidence paths the home directory becomes `~` and the repository root becomes `.`.

`prev` is the previous entry's `digest`, and `digest` is the sha256 of the entry's canonical JSON, so the entries form a chain.

## Reading it back

```sh
polispec smoke list --verdict fail
polispec smoke show smk_4980154c744d --json
polispec smoke verify
polispec smoke coverage
```

`verify` exits 1 on a schema error, a digest mismatch, a broken chain, a duplicate id, or truncation (`truncated`). The chain cannot show that the newest entries were removed, so each `record` also stores the ledger's head (digest and entry count) in `smoke-heads.json` in the polispec state home, keyed by the ledger's real path, and `verify` reports `truncated` when that head is missing from the file. The anchor exists only on the machine and state home that recorded the entries; a ledger checked elsewhere has no truncation check, and committing `smoke.yml` lets git history show the rest. It also reports, without failing, entries whose reference no longer resolves or whose node has changed since it was recorded (`stale`).

`coverage` lists the units of a spec and the status of each: `proven` (the latest entry is a pass and the node is unchanged since), `stale` (the latest pass is for an older version of the node), `failing`, `partial`, `blocked` or `none`. The default spec is `specs/app.yml` and the default units come from its `smoke.coverage_units` list, else `commands/*`. Pass `--spec` and repeated `--at PATTERN` for any other file; a trailing `*` expands the keys of a mapping or the named items of a list:

```sh
polispec smoke coverage --spec specs/polispec/policy.yml --at 'rules/*'
```

## Writing good smoke tests

- Prove the behaviour from evidence outside the actor: a hook log, the git state, the files, the exit codes. An agent's own account of what happened is not evidence.
- Use scratch projects, an isolated ledger, global shelf and state home (`POLISPEC_LEDGER`, `POLISPEC_GLOBAL`, `POLISPEC_HOME`, `POLISPEC_STATE_HOME`) so a test never touches a real project or the live guard's state. Do not redirect `XDG_STATE_HOME` or `XDG_CONFIG_HOME`: they also hold rplugin's settings, so redirecting them silently drops `polispec.enforce` and every other setting.
- Make every dangerous step harmless if the guard wrongly allows it.
- Record failures and blocked tests too. A ledger of passes only says nothing about what was tried.

## The promote warning

`polispec promote <project> --to test` looks at the commits from the test tip to the candidate. When files changed in that range and no smoke ledger entry (`SMOKE-TESTS.md` or `smoke.yml` at the candidate) and no `proofs/` record has a `target.commit` or `commit` inside it, the gates gain a result `smoke_current` with result `warn`, `since`, `count` and up to 50 `unsmoked_file` findings, the text output prints `WARNING: no smoke entry for N changed files since <short sha>`, and the `polispec.promote` event carries it in `gates`. The warning never fails a promotion. With no test branch yet the range is every commit. `polispec.smoke.promote_warn off` (or `RPLUGIN_POLISPEC_POLISPEC_SMOKE_PROMOTE_WARN=off`) removes it; the default is `on`.

## Under a sealed plane

A sealed plane makes polispec ignore the variables that point a fixture at its scratch ledger and state, so scenarios cannot be set up against the host. Since 0.60.5 `polispec smoke run` then starts itself again inside bubblewrap, where the seal is not visible:

- The filesystem is read-only and only the run directory is writable. `/tmp`, `/run` and `/etc/polispec` are empty, and there is no network.
- `--out` must name a directory that does not exist yet.
- Recording is refused (`smoke_record_sealed`); pass `--no-record`. `polispec proof run` already does.
- `--live` and `--host-copy` need the real host, so they run outside the sandbox and behave as before.
- When bubblewrap cannot start, the run warns and continues outside it, and fixtures that need a scratch ledger are blocked.

Only the smoke run is affected. The guard and every other command keep honoring the seal.

## The bundled suite

`polispec smoke run` runs the scenarios shipped in `smoke/scenarios/` against the polispec tree it runs from. Run it from a candidate worktree before tagging a release.

```sh
polispec smoke run                               # every scenario, recorded
polispec smoke run --unit commands/resolve --no-record
polispec smoke run --against ~/.rplugins/polispec # also run the installed release and diff every verdict
polispec smoke run --host-copy --no-record       # replay host probes on copies of your ledger and global shelf
polispec smoke run --live claude-code --live codex
```

- A scenario (`polispec.smoke-scenario/v1`, `polispec validate smoke-scenario FILE`) names the coverage unit it proves, builds a fixture in scratch (projects created by the tree's own `apply environment-control`, a global shelf, files), and lists steps: a command, a canned hook payload, or a live harness session, each with expectations (exit status, output, JSON, files, a git ref left unchanged, the hook's decision and rule).
- Every step runs with `POLISPEC_LEDGER`, `POLISPEC_GLOBAL`, `POLISPEC_HOME`, `POLISPEC_SMOKE`, `POLISPEC_SPECS_REPO`, `POLISPEC_STATE_HOME` and `POLISPEC_SETTINGS` pointing into its scratch directory, which defaults to `$TMPDIR/polispec-smoke/<timestamp>-<id>/`. A scenario step may set `POLISPEC_SETTINGS` itself through `env`. Since 0.57.1 the scratch `gitconfig` points `init.templateDir` at a template with only empty `hooks` and `info` directories, so a repository a scenario creates carries no sample hooks. The runner never writes your ledger, shelf, settings or polispec state. A run without `--out` first removes the runs under `$TMPDIR/polispec-smoke` whose names match the run naming pattern and whose directory is more than 24 hours old, never the current run, never a symlink and never a path outside that directory; a run with `--out` prunes nothing. At the end a run prints its run directory and the size of its output (`out` and `out_bytes` in `--json`, with the pruned paths in `pruned`). `--verbose` traces a live session as a step, with one line per hook wrapper run recorded in its hook log. Since 0.47.4, when a scenario's steps end the runner stops any resident judge a launcher step started in that scenario's state home (or its scratch `xdg-state/polispec`), sending TERM only to a pid whose command line is `judge serve`; before, each run left one judge per launcher scenario and pass for up to 30 idle minutes, including every test deployment's health check.
- Each unit is recorded once per run with runner kind `suite` and the worst verdict of its scenarios. A scenario whose `requires` flag is off is recorded `blocked`.
- `--strict` fails the run when any scenario was blocked or inconclusive, or when no scenario matched. Without it those runs exit 0. Since 0.60.1 a strict run whose only problems are blocked or inconclusive scenarios exits 3, and every other strict failure exits 1, so a caller can tell "nothing proved" from "something broke". `polispec proof run` adds `--strict` to a `smoke run` command itself and records exit 3 as `blocked`, so a run which proved nothing is not signed as a pass.
- `--against TREE` runs every scenario again with another polispec tree (a worktree at the previous tag, or a pinned release) and lists every changed verdict or output; the run fails on any difference unless `--accept-changes`. This is the release gate: review the list, and name every intended change in the changelog.
- `--host-copy` copies your configured ledger and global shelf, then replays `smoke/host-probes.yml` against every project and prints the decision and rule for each probe. It is never recorded.
- `--live claude-code` and `--live codex` run `smoke/live/*.yml` in real headless sessions (Claude Code with Haiku, Codex with its smallest model) whose hooks run the tree's `bin/polispec-guard`. They cost money: one session at a time, at most `POLISPEC_SMOKE_LIVE_MAX` (default 6) per run, each with a timeout and a budget, and `polispec.smoke.live off` or `POLISPEC_SMOKE_LIVE=off` stops them. Expectations come from the hook log, the files and git, never from what the agent says. When a live step fails only because the expected deny or write was never observed (the guard was never called, or the expected hook verdict or file is missing) and nothing forbidden happened (every `files_absent` and `git` expectation still holds), the scenario runs once more; if the second session also does not attempt the action, the step and scenario are recorded `inconclusive`. An `inconclusive` scenario does not fail the run, is counted in the summary line and shown by `smoke list`. A forbidden action that landed, such as a file under `files_absent` or a moved ref, always fails with no retry.
