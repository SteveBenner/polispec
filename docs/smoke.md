# Smoke ledger

A smoke test is a short run, against a real installation, that shows one spec or sub-spec working: the guard denying a push to the production branch, a promotion moving `test`, a code spec blocking a write. polispec ships a suite of smoke tests (`polispec smoke run`, below), and you can run your own beside it, on the machines and harnesses you care about, recording each result in a smoke ledger. polispec captures the runtime the test ran in, chains the entries so edits show, and reports which parts of a spec have a current pass.

## The file

`smoke.yml` (`polispec.smoke/v1`, `schemas/smoke.v1.yml`) sits at the root of the repository whose spec it proves. `POLISPEC_SMOKE`, then the `polispec.smoke.path` setting, override the location. Commit it with the code: an entry is evidence about a commit of that repository.

The file is append-only, and is written only by `polispec smoke record`. A hand edit is detected by `polispec smoke verify`.

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

- `--spec` is a YAML file inside the repository that parses to a mapping or a list, and `--at` a slash path into it. A segment is a mapping key, or a list item whose `name` or `id` equals it; write `~1` for `/` and `~0` for `~`. Without `--at` the entry proves the whole file. A reference that does not resolve, or resolves to an empty node, is refused.
- `--verdict` is `pass`, `fail`, `partial` (some of the sub-spec was shown) `blocked` (the test could not run, for example because the feature needs an activation that has not happened) or `inconclusive` (a live session never attempted the forbidden action, so the guard was not exercised; `coverage` ignores it and it neither proves nor revokes a unit).
- `--step-file` is YAML or JSON: a list of `{run, exit, expect, observed}`.
- `--evidence PATH[:KIND]` records the file's sha256 and size, not its content. Keep the files where your evidence lives; the ledger proves which bytes you looked at.
- `--runner`, `--harness`, `--model` and `--effort` name who ran the test. Inside Claude Code or Codex the runner defaults to `agent` and the harness is detected.

## What an entry carries

Each entry stores what it proves (`spec`, `at`, the file's digest and `at_digest`, the digest of the node it proves), the verdict, summary, steps and evidence, the runner, and two captured blocks:

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
- Every step runs with `POLISPEC_LEDGER`, `POLISPEC_GLOBAL`, `POLISPEC_HOME`, `POLISPEC_SMOKE`, `POLISPEC_SPECS_REPO` and `POLISPEC_STATE_HOME` pointing into its scratch directory, which defaults to `$TMPDIR/polispec-smoke/<timestamp>/`. The runner never writes your ledger, shelf, settings or polispec state, and never deletes its output. Since 0.47.4, when a scenario's steps end the runner stops any resident judge a launcher step started in that scenario's state home (or its scratch `xdg-state/polispec`), sending TERM only to a pid whose command line is `judge serve`; before, each run left one judge per launcher scenario and pass for up to 30 idle minutes, including every test deployment's health check.
- Each unit is recorded once per run with runner kind `suite` and the worst verdict of its scenarios. A scenario whose `requires` flag is off is recorded `blocked`.
- `--against TREE` runs every scenario again with another polispec tree (a worktree at the previous tag, or a pinned release) and lists every changed verdict or output; the run fails on any difference unless `--accept-changes`. This is the release gate: review the list, and name every intended change in the changelog.
- `--host-copy` copies your configured ledger and global shelf, then replays `smoke/host-probes.yml` against every project and prints the decision and rule for each probe. It is never recorded.
- `--live claude-code` and `--live codex` run `smoke/live/*.yml` in real headless sessions (Claude Code with Haiku, Codex with its smallest model) whose hooks run the tree's `bin/polispec-guard`. They cost money: one session at a time, at most `POLISPEC_SMOKE_LIVE_MAX` (default 6) per run, each with a timeout and a budget, and `polispec.smoke.live off` or `POLISPEC_SMOKE_LIVE=off` stops them. Expectations come from the hook log, the files and git, never from what the agent says. When a live step fails only because the expected deny or write was never observed (the guard was never called, or the expected hook verdict or file is missing) and nothing forbidden happened (every `files_absent` and `git` expectation still holds), the scenario runs once more; if the second session also does not attempt the action, the step and scenario are recorded `inconclusive`. An `inconclusive` scenario does not fail the run, is counted in the summary line and shown by `smoke list`. A forbidden action that landed, such as a file under `files_absent` or a moved ref, always fails with no retry.
