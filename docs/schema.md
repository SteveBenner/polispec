# Polispec schemas

Three YAML documents carry every polispec decision. Each has a machine-checkable schema (JSON Schema 2020-12, authored as YAML) under `schemas/`, and `polispec validate` checks a file against it and reports every violation with a JSON pointer.

```
polispec validate <policy|roster|ledger|auto> <file> [--json]
```

`auto` reads the file's `schema:` key. Exit status is 0 when the file is valid, 1 when it is not, and 2 on a usage error. With `--json` the result is `{"ok":bool,"schema":"polispec.policy/v1","errors":[{"pointer":"/rules/3/verdict","message":"must be one of allow, warn, deny"}]}`.

Every object rejects unknown keys, except the free text under `agents.instructions` and the parameters of a freeze (`freezes[]` accepts source-specific keys beside the ones listed here).

## Vocabulary

- Environments: `dev`, `test`, `prod`. `dev` is the `main` branch, `test` the `test` branch, `prod` the `stable` branch.
- Action classes (a closed set): `git.commit`, `git.push`, `git.tag`, `git.merge`, `git.rewrite`, `git.branch`, `release.publish`, `service.control`, `service.config`, `fs.write`, `fs.delete`, `data.write`, `data.copy`, `secrets.read`, `policy.edit`, `promote`, `deploy`, `control.edit`, `mcp.call`, `web.fetch`, `agent.spawn`, `shell.exec`, `fs.walk` (since 0.46.0, a recursive read-only walk that starts at the filesystem root or on a slow mount; see `root_walk` and `slow_mount_walk` under `match.shape`), `proof.write` (since 0.49.0, a write into `proofs/*.jsonl` of a repository that holds `specs/features.yml`; the `environment-control` package's `proof` module denies it with `R-PROOF-WRITE`, and `polispec proof run` and `import` are the only writers).
- Verdicts: `allow`, `warn` (a stern warning plus explicit user confirmation), `deny`.
- Actors: `agent` (any tool call through a harness hook) and `operator` (an interactive terminal with a typed phrase).

## Policy: `specs/polispec/policy.yml` of the project, `polispec.policy/v1`

The guard reads it from the project's trust ref (the committed blob on `stable`), never from the working tree. Examples: `examples/policy.shop.yml` with `examples/environments.shop.yml` (a web service), and `examples/policy.widget.yml` with `examples/environments.widget.yml` (a distributed plugin).

| Key | Type | Meaning |
| --- | --- | --- |
| `schema` | const `polispec.policy/v1` | Document type. |
| `project` | id | Must equal the ledger id of the project. |
| `recorded` | date | When the policy was recorded. |
| `summary` | string | One sentence on the project's stages. |
| `environments.<dev|test|prod>` | object | Required. See below. |
| `rules[]` | list | First match wins, evaluated per (action class, environment). |
| `promotion.to_test`, `promotion.to_stable` | object | How code moves. Required. |
| `freezes[]` | list | Windows during which promotion or desk dispatch stops. |
| `data_classes.<name>` | object | Where a kind of data may live. |
| `observability` | object | Where events go and the digest cadence. |
| `agents` | object | Instructions injected at session start and the roster path. |
| `includes[]` | list | Modules the policy pulls in: a module name, or `{ module: <name>, with: { <param>: <value> } }`. Names resolve to the project shelf (`modules/` beside the policy) or the global shelf. See [Layers](#layers-polispecglobalv1-polispecmodulev1-polispecprofilesv1). |
| `hermetic.<env>` | object | Isolation of the commands that run for a stage. See below. |

### `environments.<env>`

`dev`, `test` and `prod` are required; any other key is an additional environment of the same shape (for example `canary`), whose `tier` is still `dev`, `test` or `prod`.

| Key | Type | Meaning |
| --- | --- | --- |
| `branch` | string | Git branch bound to the stage. Required. |
| `checkout` | string | `repo` for the working repository, otherwise the directory services run from. Required. |
| `tier` | `dev`, `test` or `prod` | Required. |
| `runs` | `branch` or `tag` | Whether the stage runs the branch tip or a promoted tag (`prod`). |
| `worktrees` | list of globs | Worktree directories counted as this stage. |
| `services` | list | Service unit names. |
| `unit_files`, `env_files` | list of globs | Files that configure the services. |
| `url` | string | Where the stage is served. |
| `ports` | list of integers | Ports the stage owns. |
| `data.dirs`, `data.databases` | lists | Data stores the stage owns. |
| `data_classes` | list | Data classes the stage may hold. |
| `secrets` | list of globs | Secret scopes of the stage. |
| `deploy.steps` | list of commands | Run in order by `polispec deploy`. |
| `deploy.health.url`, `.expect_version`, `.timeout_s` | string, bool, integer | Health check that must report the deployed version. |
| `deploy.strategy` | `in_place` or `release_dirs` | Default `in_place`: the stage checkout is updated where it stands. `release_dirs` builds each release in `<envs_root>/<project>/releases/<tag>` and points `<envs_root>/<project>/<env>` at it by an atomic symlink swap, with automatic rollback. |
| `deploy.activate` | list of commands | `release_dirs` only: the restarts, run after the symlink swap and again after a rollback. Default none. |
| `deploy.drain.pause`, `.wait`, `.resume` | string | Quiesce hooks around the swap. `pause` runs once and `resume` up to four times until it exits 0 (since 0.37.4); `wait` repeats until exit 0. All optional. |
| `deploy.drain.timeout_s` | integer | How long `wait` may run (default 300; polled every 5 s). |
| `deploy.drain.checks` | list of commands | Run after pause and wait, before the swap or first step; a failure aborts with `drain_check_failed`. |
| `deploy.drain.run_in`, `.env_from` | `repo` or `active`; env name | Where drain commands run (default `active`) and whose `env_files` they load (default the env being deployed). |
| `deploy.health.run` | string | Command health check, run in the checkout like a deploy step; exit 0 is `ok`. A block may declare `url`, `run` or both; with both, each must pass. |

```yaml
environments:
  prod: { branch: stable, checkout: "~/.polispec/envs/shop/stable", tier: prod, runs: tag, services: [shop-web], data: { dirs: ["~/.shop"], databases: [shop] }, data_classes: [customer_pii], secrets: ["~/.shop/keys/**"] }
```

### `rules[]`

| Key | Type | Meaning |
| --- | --- | --- |
| `id` | `R-…` | Rule id shown in every message. |
| `match.env` | environment | Restrict to a stage. |
| `match.class` | list of action classes | Restrict to these classes. |
| `match.server`, `match.operation` | string | Exact MCP server and operation. A trusted declaration must match each action; one declaration does not cover another call. |
| `match.domain`, `match.tool`, `match.role` | string | Exact domain, native tool name, and agent role respectively; supplied values all have to match. `match.tool` compares case-insensitively; with class `tool.internal` or `tool.read` it declares that tool (see the shipped layer). |
| `match.path` | string | Path glob using the same slash-aware and dotfile-aware matching as harness controls. |
| `match.crosses` | `data_classes` or `location` | `data_classes`, for `data.copy`: matches when the data class is not allowed in the destination. `location`, for `fs.write`, `fs.delete`, `data.write` and `data.copy`: matches when the target is another project or another environment of the same project than the caller's location, and is prod or sits under a protected root (the engine evaluates it). |
| `match.destructive` | `true` | Matches only a `data.write` the shell classifier marked destructive: SQL with TRUNCATE, DROP, ALTER ... DROP, DELETE without WHERE, or UPDATE without WHERE (the classifier sets the mark). |
| `match.ref` | string | Restrict to a git ref. |
| `match.shape` | list of shape names | Matches when the action carries any listed shape. The classifier tags shapes from the parsed script (pipeline, redirects, heredoc and `-c` bodies, and since 0.32.1 the shell script files the line runs), never from raw text. Names: `bulk_stage` (`git add -A`, `--all`, `-u`, `--update`, `.`, `:/`, the repo root; `git commit -a`), `chained_release` (a `git.tag`, `git.push`, `release.publish` or `promote` action in a script of more than one command), `latest_flip` (`gh release create` or `edit` with `--latest`, `gh api` with `make_latest` true), `lockfile_edit` (an Edit or Write tool call, `sed -i`, `perl -i` or a redirect writing `Cargo.lock`, `Gemfile.lock`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`, `uv.lock` or `poetry.lock`), `pattern_kill` (`pkill -f`, `killall`, `kill` or `pkill` fed by `$(pgrep ...)`), `cargo_clean`, `worktree_force` (`git worktree remove --force`, `git worktree prune`), `tmux_kill` (`tmux kill-server` or `tmux kill-session` with no `-L` or `-S` before the subcommand, which also adds a `service.control` action), `xargs_delete` (since 0.33.0, `rm`, `rmdir`, `unlink` or `shred` whose words came through `xargs`, so its targets arrive on stdin and are never seen), `web_local` (since 0.35.0, the `policy.edit` action of a `curl`, `wget`, `http`, `https`, `xh` or WebFetch call to the local `polispec web` port with a mutating method or a plan-apply, exceptions, author, state, register or session path; the catalog subspec `tools/web-agent` matches it, and a policy or control file may name it since 0.47.2), `bulk_write` (since 0.39.0, an `fs.write` of `tar` in create mode, `zip`, `7z`, `7za`, `7zr`, `7zz`, `pg_dump`, `pg_dumpall`, `mysqldump`, `ffmpeg`, `curl`, `wget`, `cp`, `rsync`, `dd`, `git archive` or `git bundle`, or of any command with one of those upstream in its pipeline), `root_walk` (since 0.46.0, an `fs.walk` action for a recursive walker whose start path is `/`, `/.`, `//` or `/*` and which does not stay on one filesystem), `slow_mount_walk` (since 0.46.0, an `fs.walk` action for a recursive walker whose start path lies on a filesystem of type `fuse`, `fuseblk`, `fuse.*`, `nfs`, `nfs4`, `cifs`, `smb3`, `smbfs`, `sshfs` or `9p`, or on any mount under `/run/media`, `/media` or `/mnt`; a walk that does not stay on one filesystem also gets one for the first slow mount under its start path, so `find ~` reaches a FUSE mount in the home directory; a disk filesystem such as vfat at `/boot/efi` is not slow; the action carries the `path`, `walk` (`root` or `slow_mount`), `command` and, for a slow mount, `fstype` hints). The walkers are `find` and `bfs` (leading non-option arguments, default `.`), `du` (positional arguments, default `.`), `fd` and `fdfind` (the second positional argument or each `--search-path`, default `.`), `rg` (arguments after the pattern, default `.`, every positional argument with `--files` or `-e`/`-f`), `grep`, `egrep` and `fgrep` only with `-r`, `-R`, `--recursive` or `--dereference-recursive`, `ls` only with `-R` or `--recursive`, and `tree` (positional arguments, default `.`). `find` and `bfs` with `-xdev` or `-mount`, `du` with `-x` or `--one-file-system`, `rg` with `--one-file-system` and `fd` with `--one-file-system` stay on one filesystem and never get `root_walk`. The mount table is read once per process from `/proc/self/mountinfo`, or from the file named by `POLISPEC_MOUNTINFO` when that is set; an unreadable table yields no `slow_mount_walk`. A walk inside a project emits no action. The shipped policy has no rule on `fs.walk`, so these calls stay allowed until a shelf module matches them. `unresolved_delete` (since 0.55.0, `rm` with a recursive flag and an operand polispec cannot resolve), `find_unfiltered` (since 0.55.0, a `find` that deletes and has no filter test such as `-name`, `-path`, `-type`, `-mtime` or `-size`), `git_clean_dirs` (since 0.55.0, `git clean` with a `-d` flag and no `-n` or `--dry-run`), `opaque_shell` (a governed line that runs `eval`, `source` or `.`; a rule on it declares the line, as the shipped `TOOL-OPAQUE-DEVELOPMENT` does). An unknown name is a validation error. |
| `match.lock_held` | boolean | Matches when the action's target path is listed in `TMP_AGENT_FILE_LOCKS.yml` at the target's git toplevel by a live entry that is not an ancestor of the hook process. An entry with `owner_pid`, `owner_start` and `owner_boot` is live when that process exists with the same start time and boot id; an entry without owner fields is live for 10 minutes from `acquired_at`. |
| `match.live_binary` | boolean | Matches when an `fs.delete` target, or the target directory of a `cargo clean`, contains the resolved `/proc/<pid>/exe` of a running process of the current user. |
| `match.bytes_over` | integer | Since 0.39.0, matches an `fs.write` action whose `bytes` hint is an integer above the value. Only a write tool call carries `bytes`. A write tool call over 8 MiB is already denied by the hook input cap (`INPUT_LIMIT`), so this key matters for caps below that. |
| `match.fsize_unset` | `true` | Since 0.39.0, matches an `fs.write` action from a shell command that has no hard file-size limit in force, that is whose `fsize_blocks` hint is `unlimited`. An action without that hint, as a write tool call, never matches. |
| `match.fsize_above` | integer (bytes) | Since 0.39.0, matches an `fs.write` action whose `fsize_blocks` hint is an integer and 1024 times that integer is above the value. |
| `match.tree_over` | object with `marker` (string) and `bytes` (integer) | Since 0.39.0, matches when the nearest directory named `marker` among the action's path and its ancestors has an apparent size, as `du -sb` reports it, above `bytes`. No such directory, a tree that cannot be measured within 0.8 s, or a missing `du` does not match and raises a finding. A directory that does not exist measures 0. Sizes are cached for 60 s in `scratch-sizes.json` under the state home. |
| `match.text_matches` | string (1 to 4096 characters) | Since 0.40.0, a Ruby regular expression source tested against the action's `text` hint; flags go inline, for example `(?i)`. An action without the hint never matches. The pattern is compiled once per process with a 0.25 s match timeout (Ruby 3.2 and later). A pattern that does not compile is a validation error naming the rule id; one that fails or times out at run time does not match and raises a `text_matches:` finding. |
| `match.delete_protected` | boolean | Since 0.33.0, matches an `fs.delete` that reaches an entry of the effective `delete_protected` list. The target is the action's path; a last component of exactly `*`, `.*`, `.[!.]*`, `..?*` or `.??*` makes it a delete of its directory's contents. Base and every entry are compared lexically (`~` expanded) and with symlinks resolved. It holds when the base equals an `exact` entry; or, for a contents delete, when the base equals or is an ancestor of any entry, or lies under a `tree` entry; or, for a delete carrying the `recursive` hint (`rm -r`, `rm -R`, `rm --recursive`, `rmdir`, a `find` delete, `cargo clean`), when the base is at or under a `tree` entry or is an ancestor of any entry. Equality and ancestry hold in either form; lying under a `tree` entry holds in the lexical form, and in the resolved form only when the entry is a real folder, so a path beneath a symlinked entry's target written by its real path is not covered. `exact` entries do not cover their children. |
| `match.delete_unbacked` | boolean | Since 0.55.0, matches an `fs.delete` from `rm` with the `recursive` hint and no `unresolved` hint, whose target is an existing real directory (not a symlink, not a contents leaf such as `dir/*`) with no non-empty `<parent>/.backup/<name>-*` copy beside it. It does not hold for a backup path (`.backup`, anything inside it, or a directory named `backups`), nor for a directory named in the module key `delete_backup.ignored_names` (`target`, `node_modules`, `dist`, `.next`, `__pycache__`, `.cache`, `build`) that git ignores. The note names the `mkdir` and `cp -a` that make the copy. |
| `match.delete_protected_file` | boolean | Since 0.33.0, matches an `fs.delete` that `delete_protected` does not match, with no `recursive` hint and not a contents delete, whose target is at or under a `tree` entry (`rm`, `unlink`, `shred` of one file). |
| `match.supervised` | boolean | Matches when a `service.control` target (a unit name, or a pid from `kill`) belongs to a component reported by the command in setting `polispec.supervisor.status_command` (argv, no shell, prints `{"units": [...], "pids": [...]}`, 1 s timeout, cached 60 s under `$POLISPEC_HOME/cache`). Unset or failing, the predicate is true for a `pattern_kill` and false for a named unit, with a finding either way. |
| `match.pin_regress` | boolean | Matches a `git.commit` whose index changes a submodule pin to a commit that is not a descendant of the old pin (`git commit -a` also counts the working tree). An object missing from the local clone matches, and the reason says to fetch the submodule. |
| `match.tag_claimed` | boolean | Matches a `git.tag` or tag push of `vX` when `refs/tags/vX` already exists at a different commit, when `X` is lower than the `VERSION` file at `refs/remotes/origin/main`, or when `X` equals it and the tagged commit is not an ancestor of `refs/remotes/origin/main` whose own `VERSION` reads `X`. The tagged commit is the commit-ish `git tag` names, exactly as written (a SHA, `origin/main`), or `HEAD`; for a push it is the local tag. The reason for a lower `X` says it is not greater than origin/main's version; for an equal `X` it says the tag is not on origin/main's release commit for that version. No network is used; the reason says to fetch when the last fetch is older than an hour. |
| `match.base_unpushed` | boolean | Matches a branch creation (`worktree add -b`, `checkout -b`, `switch -c`, `branch X [start]`) whose start point resolves to a local branch with commits not on its upstream. |
| `match.public_remote` | boolean | Since 0.53.0, matches a `git.push` whose target remote is public, and any other `git.*` or `fs.*` action in a repository whose `origin` is public. Visibility comes from the file named by setting `polispec.exposure.visibility_file` (`public_remotes`, then `private_remotes`, each a list of case-insensitive globs over the normalized remote `host/owner/repo`), then for a github.com remote from `gh repo view` (1 s timeout, cached 3600 s under `$POLISPEC_HOME/cache/visibility.json`; PUBLIC and INTERNAL are public). Every other case, including no remote, an unknown host, a missing or slow `gh`, is public. |
| `match.public_path` | boolean | Since 0.53.0, matches an `fs.write` to a path in a repository whose `origin` is public when the path is not ignored by git and looks like a working note: its name matches `*.impl.yml`, `DECISIONS.md`, `TOKENS.jsonl`, `WIP.md` or `NOTES.md`, or one of its directories relative to the repository is `.rproject`, `.scratch` or `.specstory`. The reason names the path and why. |
| `match.push_unscanned` | boolean | Since 0.53.0, matches a push to a public remote that no exposure attestation covers: a push of every ref (`--all`, `--mirror`, `--tags`, `--follow-tags`); a `gh api` contents write to a public github.com repository; a branch push whose local tip differs from `refs/remotes/<remote>/<branch>` (absent counts as the empty tree) unless the latest attestation for that repository, remote and ref has `from` equal to the remote tip and `to` equal to the local tip (since 0.54.2 the local tip of a `<src>:<branch>` refspec is the commit `<src>` names, not the local `<branch>`, and the reason adds `--source <src>`); a tag push whose commit appears in no attestation for the repository. Branch deletions, dry runs, up-to-date pushes and a local `git commit` do not match. The reason says to run `polispec exposure scan <repo> --remote <remote> --ref <ref>`. An attestation made under a different `polispec.exposure.audit_command` covers nothing. |
| `match.in_development` | boolean | Matches when the action's directory and, for an `opaque_shell` line, the directory of every command in it lie only in ledger projects with status `onboarding` (or, for a command directory, in no non-retired project at all) and not in an env checkout. False under the lock edition and under `polispec.relax.dev off`. |
| `verdict` | `allow`, `warn`, `deny` | Required. |
| `reason` | string | Why, shown to the agent. |
| `requires` | `gates.to_test` or `gates.to_stable` | Gates that must pass for the rule to allow. |
| `overridable` | boolean | Marks a rule a lower layer may loosen. Default false. |
| `overrides` | `R-…` | Declares that this rule loosens the named rule of an upper layer. Valid only against a rule marked `overridable`. |

```yaml
- { id: R-PROD-GIT, match: { env: prod, class: [git.push] }, verdict: deny, reason: "stable is production" }
```

Two action hints feed the size keys. An `fs.write` action from a write tool carries `bytes`, the sum of the byte sizes of the strings under `content`, `file_text`, `text`, `new_string`, `new_str`, `new_source` and `contents` in the tool input and in each `edits` entry. An `fs.write` action from a shell command carries `fsize_blocks`, the integer `N` of the last earlier `ulimit -f N`, `ulimit -Hf N` or `ulimit -fH N` in the script, or `unlimited` when there is none, when the last was `ulimit -f unlimited`, or when its value is not a literal integer; `-S` alone changes nothing, and a `ulimit` that is a stage of a multi-stage pipeline does not count. A block is 1024 bytes. `tar` with the archive named in a bundled option cluster (`tar czf X`) or by `--file=X`, and `zip`, `7z`, `ffmpeg`, `mysqldump`, `pg_dump`, `pg_dumpall`, `git archive` and `git bundle create`, yield an `fs.write` for their output since 0.39.0.

The `text` hint feeds `text_matches`. Since 0.40.0 an `fs.write` action from a write tool carries `text`, the strings counted in `bytes` joined with a newline in input order; a policy file write (`policy.edit`) carries none. An action from a shell command carries `text`, the command text followed by a newline and the body of each of that command's heredocs (`<<`, `<<-`), on every action the command produces, `node -e` and `python3 - <<'PY'` included. A text longer than `TEXT_LIMIT` (262,144 bytes) is cut to its first `TEXT_LIMIT` bytes on a character boundary and the action carries `text_truncated` true. `apply_patch` write actions now carry `bytes` and `text` too, the added lines of each file (an Add File's whole body), so a `bytes_over` rule now sees a Codex patch, which it did not before.

### `promotion`

`to_test` keys: `from`, `actor`, `fast_forward_only`, `requires_version_bump`, `tag`, `release.github_prerelease`, `drift`, `gates[]`, `after[]`. `to_stable` keys: `from`, `actor`, `fast_forward_only`, `phrase`, `preflight[]`, `gates[]`, `release.flip_latest`, `after[]`.

`preflight[]` takes gates of the same shape and runs before the other gates and the phrase prompt, so an operator is not asked to type a phrase for a promotion that would fail. `release.flip_latest` is `true`, `false` or `deferred`: `deferred` publishes the release as a full (not pre-) release without `--latest` and records `latest: deferred` in `promotions.jsonl`, leaving the flip to the project's own soak job.

`promotion` also accepts `to_<env>` for any other declared environment (for example `to_canary`), each with `from`, `actor`, `gates[]` and optionally `phrase`, `preflight[]`, `fast_forward_only`, `release.flip_latest` and `after[]`. `to_test` and `to_stable` stay required. See `docs/operator.md`.

A gate is `{ id: G-…, run: <command>, pass: exit_zero }` or `{ id: G-…, builtin: clean_tree | version_homes_agree | sha_ran_on_test | sha_ran_on | not_frozen | soaked | health_required | logs_quiet | requires_live | features_proven }`. `soaked` takes `hours` (integer, at least 1) and `env` (default `test`); `sha_ran_on` takes `env` (default `test`; `sha_ran_on_test` is its alias). `logs_quiet` takes `services[]`, `window_minutes` (default 120) and `max_over_baseline` (default 0). `requires_live` takes `project` and `min_version`, or `min_version_from` with `min_version_key`. `features_proven` (since 0.49.0) takes `mode`: `report` (default; passes and carries its findings in the gate result), `enforce` (fails with `gate_failed`) or `off` (passes without running); the lock edition treats `report` as `enforce` ([proof](#feature-manifest-specsfeaturesyml-polispecfeaturesv1)). A command gate also takes `run_in` (`repo` default, or `active`) and `env_from` (an environment name whose `env_files` are loaded); a gate that touches a live database must use `run_in: active`. Any gate may set `dir`, a subdirectory of the run location (no `..`, no leading `/`) in which its command runs; a missing directory fails the gate. polispec sets `dir` on gates a nested child project contributes. A command gate may set `hermetic: false` to run outside `hermetic.<env>` (see `docs/operator.md`). Commands and phrases may use `{project}`, `{sha}`, `{VERSION}`, `{tag}` and `{stable_tag}` (the highest `v*` tag on the stable branch tip, empty when none). Commands run without a shell; `$HOME`, `${HOME}` and a leading `~` are the only expansions.

```yaml
promotion:
  to_stable: { from: test, actor: [operator], fast_forward_only: true, phrase: "promote {project} to stable", gates: [{ id: G-TESTED, builtin: sha_ran_on_test }] }
```

### `freezes[]`

`id` (`F-…`), `applies_to` (`promote.to_<env>` for a declared environment, such as `promote.to_stable`, or `desk.dispatch`), `source`, `project`, `kind`, `command`, `lead_minutes`, `lead_hours`, and a manual window (`rrule`, `from`, `until`, each nullable). `kind` is a free label; `project` names the ledger project whose prod checkout runs the command (default the policy's own project).

A freeze without `source` is a manual window. `source: command` runs `command`, a list of argv strings, without a shell: the first element is relative to the prod checkout or absolute, the working directory is the prod checkout, and stdout must be JSON of the form `{"windows": [{"kind": "...", "from": "ISO-8601", "until": "ISO-8601", "detail": "..."}]}`. When the freeze sets `kind`, only windows with that `kind` apply; otherwise every returned window applies. Results are cached for five minutes. A missing or failing program yields the finding `freeze_source_unavailable` ("<argv0> is not available in <checkout>") and no windows. Two sources are deprecated aliases with unchanged behaviour: `source: teach.calendar` is `command: [bin/teach, calendar, freezes, --json]` (kind filter always applied), and `source: teach.activity` is `command: [bin/teach, activity, --json]` (no kind filter, `project` selects the checkout).

### `hermetic.<env>`

`isolate` (list of environment variable names) and `protected_roots` (list of paths, `~` and `$HOME` expanded). Declared for `test` or `prod`; applied to the deploy steps, `deploy.health.run` and command gates of that stage. See `docs/operator.md`.

### `data_classes.<name>`

`allowed_in` (list of environments, required), `pii_spec` (path of a personal-data map such as `specs/pii.yml`), `produced_by` (the command that creates the class).

### `observability`, `agents`

`observability.events` is `rlogs`, `local` or `none`; `observability.digest` is `daily`, `weekly` or `none`. `agents.instructions` is a list of free-text lines for the session summary; `agents.roster` is the roster path.

## Roster: `specs/polispec/roster.yml` of the project, `polispec.roster/v1`

Which harness, model and effort each agent role gets, with bounds an edit may not leave. Example: `examples/roster.shop.yml`.

| Key | Type | Meaning |
| --- | --- | --- |
| `schema`, `project` | | As in the policy. |
| `harness_effort.<harness>` | list | The effort vocabulary of each harness, lowest first. |
| `roles.<role>` | slot | Interactive and workflow roles. |
| `pipelines.<name>.phases.<phase>` | slot | A pipeline phase, for example `shop.release`. |
| `workflows.<name>` | object | `build_role`, `verify_role`, `author_role`, `min_effort`. |
| `environments.<env>` | object | `roles` and `pipelines` allowed to act there; `*` matches all. Required for all three. |
| `budgets` | object | `per_run_usd_max` and `per_day_usd.<scope>`. |

A slot is `{ default: <assignment>, bounds: <bounds> }`. An assignment holds `harness`, `model` (required), `effort` (string or null), `agent`, `run` (exactly one of `merge`, `script`, `model`; a worker profile checked against the slot uses `merge` or `own` for diagnose and spec and `script` or `model` for ship), `on_failure` (`stop`, `model`) and `budget_usd`. Bounds hold `harnesses`, `models`, `effort` and `budget_usd`, the last two as `{ min, max }`.

```yaml
roles:
  reviewer: { default: { harness: claude, model: opus, effort: high }, bounds: { effort: { min: high } } }
```

## Ledger: `polispec.ledger/v1`

Names the live projects of the host. The file is resolved in order from the `POLISPEC_LEDGER` environment variable (when non-empty), the `polispec.ledger` rplugin setting, then `$XDG_CONFIG_HOME/polispec/ledger.yml` (`~/.config/polispec/ledger.yml` when `XDG_CONFIG_HOME` is unset). Example: `examples/ledger.example.yml`.

| Key | Type | Meaning |
| --- | --- | --- |
| `schema`, `host` | | Document type and machine name. |
| `envs_root` | path | Where `test` and `stable` checkouts live. |
| `defaults.rules[]` | list | The fail-closed policy for a ledgered project whose stable policy is missing or invalid. Each rule has `match` (`env`, `ref`, `class`), `verdict`, optional `id` and `reason`. |
| `projects[]` | list | `id`, `status` (`live`, `onboarding`, `retired`), `repo`, `remote`, `worktree_globs`, `trust_ref`, `policy`, `roster`, `related`, `onboarded`, `profile` (`personal`, `service` or `live`; default `personal`), `packages` (see below), and since 0.35.0 `owner`, `registered_by` and `description` (see below). |
| `paths[]` | list | Since 0.35.0. Governed software, directories and the system scope that are not git repositories. Each entry has `id`, `kind` (`software`, `directory`, `system`), `path`, `status` (`onboarding`, `live`, `retired`) and optionally `owner`, `registered_by`, `description` and `policy`. The id matches the project id pattern and must be unique across projects and paths. |
| `paths[].policy` | path | The module that governs the entry, relative to the global shelf; defaults to `paths/<id>.yml`. Its schema is `polispec.module/v1`. |
| `owner` | object | `{ uid, name }` of the person who registered the entry: the process uid and its login name (`uid<N>` when the name cannot be read). Present on projects the environment-control package adds and on every entry `polispec register` adds. |
| `registered_by` | string | The actor that registered the entry: `POLISPEC_ACTOR` when set, else `cli`. |
| `description` | string | Optional on a project or path entry, 1 to 4000 characters; the lint rules under [Description](#description) apply. |
| `projects[].packages[]` | list | One record per applied package: `name`, `variant`, `version`, `applied_at` (date) and `files` (repository path to `sha256:<hex>` of the bytes apply wrote). Upgrades compare against these digests. |
| `pauses_log`, `allow_once_log` | path | Append-only JSONL logs. |

```yaml
projects:
  - { id: shop, status: live, repo: ~/src/shop, trust_ref: stable, policy: specs/polispec/policy.yml, roster: specs/polispec/roster.yml }
```

A path entry changes nothing until it is `live`; an `onboarding` entry is listed and judged by nothing. A live entry is judged like a path no project owns, with one extra layer composed after the global layer: the module at the entry's `policy` path on the global shelf. Each rule of that module is scoped to the entry: a rule without `match.path` applies to the entry's directory and everything under it, and a rule with its own `match.path` has that path read relative to the entry's directory. A missing or invalid module file is a `layers_invalid` finding and the global layer alone applies. A path inside a ledgered project's repository or worktree belongs to that project and cannot be registered. The judgment record of an action inside a live path entry names the entry as its project (`project` is the entry id and `policy_source` is `path`); the layer appears as `path:<id>` in the verdict text.

Since 0.35.0 a ledger that carries `paths`, `owner`, `registered_by` or a `description` is rejected by an installed polispec older than 0.35.0 (every object rejects unknown keys). `polispec doctor` reports `ledger_ahead_of_runtime` when that holds, and `polispec register`, `unregister` and the environment-control package refuse with `runtime_behind` until 0.35.0 is installed. See [the rollout order](operator.md#rolling-out-0340).

## Description

Since 0.35.0 every rulebook can say in prose what it does. `description` is an optional string of 1 to 4000 characters on a policy, an environments file, a roster, a global document, a module, a package, a spec, a behavior document, and on each ledger project and path entry. It is documentation: the guard never reads it for a verdict.

`polispec validate` lints it for the kinds policy, environments, roster, global, module, package and spec, and reports each finding as a warning (an error when the setting `polispec.description.strict` is `on`; the default is `off`):

- `description_missing`: the rulebook carries no description.
- `description_invalid`, with one or more of these codes: `too_short` (fewer than 2 sentences or 20 words), `too_long` (more than 8 sentences or 400 words), `restates_summary` (it repeats the `summary` instead of adding to it), `names_nothing` (it names nothing the rulebook declares: an action class, environment, path, tool, module, gate, rule, role or package) and `states_no_effect` (it states no effect in words such as allow, ask, warn, deny, refuse, promote or freeze).

`validate --semantic` additionally asks the decide port whether the description matches what the rules do (`matches`, `partial` or `contradicts`); it needs a configured model and prints a note when none answers. `polispec doctor` reports `description_missing` (info) for a live project's rulebooks and the shelf, `description_invalid` (warn), `description_ahead_of_runtime` (warn) when a description is in use while the installed release is older than 0.35.0, and `description_unchecked` (info) when the check itself failed.

## Editions: `specs/editions.yml`, `polispec.editions/v1`

Lists every feature whose behavior differs between the standard edition and the lock edition (`EDITION` at the plugin root). `polispec editions` prints the table, and `polispec editions --check [--json]` reports drift between the registry and the code; `polispec doctor` repeats those findings as `editions_drift` (warn).

| Key | Type | Meaning |
| --- | --- | --- |
| `schema` | const `polispec.editions/v1` | Document type. |
| `editions` | object | `standard` and `lock`, each a one-line meaning. |
| `values` | list | `included`, `restricted`, `excluded`. |
| `features[]` | list | `id` (dotted lowercase), `standard` and `lock` (a value), `since` (a version), `code` (the file or directory that implements it) and `note`. |

`excluded` means the feature does not exist in that edition, `restricted` that it exists with narrower behavior, and `included` that it is unchanged.

## Delegation grants: `delegate/grants.yml`, `polispec.delegate_grants/v1`

Lives in the polispec state home and is written only by `polispec delegate grant` and `revoke` (never by hand). The file must be a regular file owned by the user and not writable by group or others, or no grant is honored.

| Key | Type | Meaning |
| --- | --- | --- |
| `schema`, `grants[]` | | Document type and the list of grants. |
| `grants[].app` | string | The application, `^[a-z][a-z0-9_-]{0,31}$`. |
| `grants[].token_sha256` | string | SHA-256 of the token shown once at grant time. |
| `grants[].verbs` | list | `promote`, `deploy`, and since 0.35.0 `exceptions-add`, `exceptions-promote`, `exceptions-remove`. |
| `grants[].projects`, `targets` | lists | Ledger project ids, and `test` and or `stable`. |
| `grants[].flags` | list | A subset of `--dry-run`, `--json`, `--tag`, `--waive-soak`, `--skip-drain`, `--verbose` (since 0.44.0; it also admits `--verbose=text` and `--verbose=json`). |
| `grants[].granted_at` | string | UTC timestamp. |

The exceptions verbs are accepted by the schema in both editions, but `delegate grant` refuses them with `edition_excluded` and a runner refuses a request for them under lock (`exceptions.delegate_promote`).

## Manifest: `polispec.manifest/v1`, and the index: `polispec.index/v1`

`polispec manifest <id>` prints the manifest of a project or path entry; `polispec manifest <id> --write` writes `polispec.manifest.json` and `.polispec/badge.svg` into the project's main worktree and commits exactly those two files on main with the message `Update the polispec manifest` (it refuses for a path entry, when the index has staged changes and when the worktree is not on main), and `polispec manifest badge <id>` prints the badge SVG.

| Key | Type | Meaning |
| --- | --- | --- |
| `schema`, `id`, `kind` | | `polispec.manifest/v1`, the id, and `project` or `path`. |
| `path_kind`, `path` | | For a path entry only: its kind and path. |
| `status`, `owner`, `description` | | From the ledger; `owner` and `description` may be null. |
| `host`, `edition`, `enforce` | strings | The machine, the edition and the enforce mode. |
| `policy` | object | `source`, `digest` and `trust_ref` of the policy; absent for a path entry. |
| `environments` | object | Per environment `branch`, `tier` and `policy_digest`. |
| `layers` | object | `profile`, `effective_digest`, `layers[]` (`layer`, `source`, `digest`, `rules`, `modules`) and `packages[]`. |
| `roster`, `promotions`, `findings` | | The roster summary; the latest promotion per target environment (`tag`, `sha`, `at`, `actor`); and the doctor and description findings for the id grouped as `error`, `warn` and `info` lists of `{ kind, detail }`. A path entry has an empty roster and no promotions. |
| `badge_url`, `declared` | | The badge path under the web app, and the contents of the project's `polispec.app.yml` (`polispec.app/v1`: `name`, `description`, `serves`, `owners`, `wants`, `contact`) read from its trust ref, or null. |

`polispec manifest index` prints the index: `schema`, `user`, `host`, `generated_at` and `entries[]` of `id`, `kind`, `status`, `owner`, `description`, `summary` and `policy_digest`, with paths shown home-relative. `--publish` and `--unpublish` are operator actions described in [the operator guide](operator.md#publishing-the-index).

## Package: `packages/<name>/package.yml`, `polispec.package/v1`

A package is a named, versioned setup that `polispec plan` and `polispec apply` carry out against a repository. See [packages](packages.md).

| Key | Type | Meaning |
| --- | --- | --- |
| `schema`, `name`, `version` | | `polispec.package/v1`; the name matches `^[a-z0-9][a-z0-9-]{0,40}$` and equals the directory; the version is semver. |
| `summary` | string | One line shown by plan. |
| `params` | map | Same shape as module parameters: `type`, `default`, `summary`, plus `allowed` (a list of values, string parameters only). Given with `--param name=value`. |
| `variants` | map | `<variant>: { summary, files: { <repo target>: <source in the package> } }`. |
| `default_variant` | string | Used when `--variant` is not given. |
| `files` | map | Files written for every variant; a variant's file wins on the same target. Sources are templates rendered with `{{project}}`, `{{date}}`, `{{envs_root}}`, `{{repo_name}}` and every parameter. |
| `modules` | list | Names of files in the package's `modules/` copied to `specs/polispec/modules/<name>.yml`. |
| `steps` | list | Ordered built-in steps, each `{ kind, when }` or a bare kind: `files`, `manifest`, `ledger`, `render`, `commit`, `branches`, `push`, `checkouts`. `when: { param, equals }` is optional and names a declared parameter. Unknown keys and step kinds, and file paths that are absolute or contain `..`, are errors. |

## Plan: `polispec.plan/v1`

`polispec plan --json` prints `schema`, `target`, `plan_id`, `files[]` (`path`, `action` `add|replace|conflict|unchanged`, `diff`), `ledger` (`before`, `after`) or null, `policy_diff` (per affected project: added, removed and changed rules, gates, freezes and modules, with effective digests before and after), `probes[]` and `journal[]` (`probe`, `before`, `after`, `change` `tighten|loosen|same`), `classification` (`tightening`, `loosening`, `mixed` or `neutral`), `needs_confirm` and `reasons[]`. The `plan_id` is `plan_` plus the first 24 hex digits of the SHA-256 of the target, the proposed and current digests, and the classification, so any change to the proposal changes the id.

## Smoke ledger: `polispec.smoke/v1`

Records smoke tests that proved a spec or sub-spec in reality (`docs/smoke.md`). The file is `smoke.yml` at the git toplevel of the working directory; `POLISPEC_SMOKE`, then the `polispec.smoke.path` setting, override it. Written only by `polispec smoke record`.

| Key | Type | Meaning |
| --- | --- | --- |
| `schema` | `polispec.smoke/v1` | Document type. |
| `entries[]` | list | Append-only, oldest first. |
| `entries[].id` | `smk_` + 12 hex | sha256 prefix of the entry without `id` and `digest`. |
| `entries[].recorded_at`, `started_at`, `finished_at` | ISO 8601 | `recorded_at` is set by `record`; the others are optional. |
| `entries[].proves` | object | `spec` (path relative to the toplevel of a YAML file), `at` (slash path: mapping key or list item `name`/`id`; `~1` is `/`, `~0` is `~`; empty for the whole file), `spec_digest` (sha256 of the file), `at_digest` (sha256 of the canonical JSON of the node). |
| `entries[].verdict` | `pass`, `fail`, `partial`, `blocked` | |
| `entries[].summary` | string | What was shown. |
| `entries[].steps[]` | list | `run`, `exit` (integer or null), `expect`, `observed`. |
| `entries[].evidence[]` | list | `path` (relative to the toplevel, else a basename), `sha256`, `bytes`, `kind`. |
| `entries[].runner` | object | `kind` (`human`, `agent`), `harness`, `harness_version`, `model`, `effort`. |
| `entries[].runtime` | object | Captured OS, kernel, architecture, container and WSL flags, time zone, locale, Ruby, polispec version, edition, commit, dirty flag, install kind, rplugin version, enforce mode. No host or user identity. |
| `entries[].target` | object | Captured `commit`, `branch`, `dirty` (ignoring the ledger file), and `project`, `env`, `policy_digest` when the toplevel is governed. |
| (anchor) | | Not in the file: `record` keeps the head `{digest, count, recorded_at}` per ledger real path in `smoke-heads.json` under the polispec state home; `verify` reports `truncated` against it. |
| `entries[].prev`, `digest` | sha256 or null | `prev` is the previous entry's `digest` (null first); `digest` covers the canonical JSON of the entry without `digest`. |

```yaml
schema: polispec.smoke/v1
entries:
  - { id: smk_4980154c744d, proves: { spec: specs/app.yml, at: "commands/promote, deploy", spec_digest: "…", at_digest: "…" }, verdict: pass, summary: "promote --to test moved test and deploy recorded a verified receipt", steps: [], evidence: [], runner: { kind: agent, harness: claude-code, harness_version: 2.1.296, model: claude-haiku-5-5, effort: null }, runtime: {}, target: {}, recorded_at: "2026-10-13T23:59:00Z", prev: null, digest: "…" }
```

## Feature manifest: `specs/features.yml`, `polispec.features/v1`

Since 0.49.0. Says what a product is made of and where it runs, so that `polispec proof` and the `features_proven` gate can ask for evidence per feature and per target (`docs/operator.md`, proving features). Schema `schemas/features.v1.yml`; `polispec validate features FILE` checks one file. The manifest is read from the committed tree, never the working tree. Every object rejects unknown keys.

| Key | Type | Meaning |
| --- | --- | --- |
| `schema` | `polispec.features/v1` | Document type. |
| `targets[]` | list, at least one | `id` (matches `^[a-z0-9][a-z0-9.-]*$`) and `facts`, a map of string facts such as `os`, `arch`, `ruby`, `runtime` and `harness`, or any other. `proof run` picks the target whose facts match the host. |
| `features[]` | list | One per feature. |
| `features[].id`, `summary` | | `id` has the target id pattern; `summary` is one line of text. |
| `features[].paths[]` | globs | The repository paths the feature is made of. |
| `features[].shared[]` | globs | Optional. Paths this feature also depends on. |
| `features[].spec` | `{file, at}` | Optional. The same spec reference smoke records use; its `at_digest` joins the feature's digest. |
| `features[].targets[]` | target ids | Optional. A subset of the manifest's targets; default every target. |
| `features[].min_rung` | 1 to 4 | Optional, default 2. The lowest rung of a record that proves the feature. |
| `features[].smoke` | object | `run` (an argv, no shell), `rung` (1 to 4), optional `timeout_s` (default 900), and optional `per_target`, a map from target id to `{run, rung, timeout_s}` that overrides the feature's values on that target. |
| `shared[]` | globs | Paths every feature's digest covers: lockfiles, core libraries. |
| `ignore[]` | globs | Paths no feature owns: docs, changelogs. A changed file that matches no feature, `shared`, `ignore`, `proofs/` or the manifest itself is reported as `unmapped_files`. |
| `trusted_producers[]` | list | `id`, `key` (one OpenSSH public key line), `kind` (`host`, `peer` or `ci`) and optional `note`. A record counts only when its signature verifies under one of these. |
| `exceptions[]` | list | `feature`, optional `targets` (default every target of the feature), `reason`, `owner`, `added` and `expires` (dates, `YYYY-MM-DD`). `expires` is at most 90 days after `added`; `proof except` refuses a longer one. An unexpired exception lifts one `features_proven` cell; it is not an entry of the exceptions delegate. |

Globs use `File.fnmatch` with `FNM_PATHNAME` and `FNM_DOTMATCH`: `*` stays inside one directory, `**/` crosses directories, and a trailing `/**` (or a bare `**`) also crosses directories, so `lib/**` matches `lib/a/b/c.rb`.

The digest of a feature on a target is the sha256 of the canonical JSON of the feature entry, the target entry, the sorted `[path, git blob id]` pairs of every file at the commit that matches the feature's `paths` or `shared` or the manifest's `shared`, and the spec anchor's `at_digest` or null. It is computed from the commit's tree. A record proves a cell while its digest equals the current one.

## Proof record: `proofs/<feature>.jsonl`, `polispec.proof/v1`

Since 0.49.0. One signed, chained record per line, one file per feature, in the repository that holds the manifest. Schema `schemas/proof.v1.yml`; `polispec validate proof FILE` checks one record. Written only by `polispec proof run` and `import`, under a lock in the state home keyed by the file's real path. The output of a run stays outside the repository.

| Key | Type | Meaning |
| --- | --- | --- |
| `schema` | `polispec.proof/v1` | Document type. |
| `id` | `prf_` + 12 hex | sha256 prefix of the canonical record without `id`, `signature`, `prev` and `hash`. |
| `feature`, `target` | ids | The cell the record proves. |
| `digest` | sha256 | The cell's digest when the command ran. |
| `commit` | 40 hex | The commit the command ran at. |
| `rung` | 1 to 4 | The rung the manifest declared for the command. It is declared, not measured. |
| `verdict` | `pass`, `fail`, `blocked` | Only `pass` proves a cell. |
| `started_at`, `finished_at`, `duration_ms`, `exit` | | Timing and the command's exit status (an integer or null). |
| `evidence[]` | list | `name`, `sha256` and `bytes` of each output file the run kept. |
| `runtime` | object | The smoke runtime capture: os, kernel, arch, ruby, polispec version, edition. |
| `producer` | string | The `trusted_producers` id that signed. |
| `signature` | string | An SSH signature (`ssh-keygen -Y sign`, namespace `polispec-proof`) over the canonical JSON of the record without `signature`, `prev` and `hash`. |
| `prev`, `hash` | sha256 or null | The chain link: `prev` is the previous record's `hash` in the same file (null first), and `hash` covers the record with `prev`. |

A broken chain is a finding, and records after the break prove nothing. `proof run` and `import` refuse with `chain_broken` and append nothing to a file whose chain is broken until it is repaired from git.

## Judgment record: `polispec.judgment/v1`

One record per call the guard judged (`docs/operator.md`, judgment records). The stream is `judgments.jsonl` under the polispec state home, one JSON record per line, rotated at 16 MiB to `judgments.<utc timestamp>.jsonl`; `judgments.head.json` beside it anchors the head. Written by the pretool hook and the git hooks; read by `polispec judgments`, `digest`, `plan` and `doctor`. `polispec validate judgment FILE` checks one record.

| Key | Type | Meaning |
| --- | --- | --- |
| `schema` | `polispec.judgment/v1` | Document type. |
| `id` | `jdg_` + 12 hex | sha256 prefix of the record without `id` and `digest`. |
| `ts` | ISO 8601 | When the record was sealed. |
| `action` | object | `tool`, `harness`, `event`, `session_id`, `agent_type`, home-relative `cwd`, `call_digest` (sha256 of the canonical JSON of `tool`, `arguments` and `cwd`), and `raw` only while `polispec.records.raw` is on (at most 2048 bytes). |
| `targets[]` | list | One per governed project or global baseline the call touched: `project`, `env`, `policy_source`, `policy_digest`, `verdict`, `rule_id`, and `rows[]` with `action_class`, `env`, `ref`, home-relative `path`, `crosses`, `destructive`, `shape`, `verdict`, `rule_id`. Empty for an ungoverned call. |
| `control` | object or null | `control_digest`, `edition`, `verdict`, `ask_ids` when the control ceiling ran. |
| `engine` | object | `version`, `runtime` (`pinned`, `sealed`, `clone`, `unknown`), `commit`, `tree_digest` (pinned only), `edition`, `enforce`, `plane` (`status`, `generation`), `fastpath_key`. |
| `outcome` | object | `verdict`, `rule_id`, `enforced`, `allow_once_id`, `rendered` (`allow`, `ask`, `deny`, `context`, `none`), `governed`, `error` (the exception class of a fail-closed denial), `duration_ms`. |
| `prev`, `digest` | sha256 or null | `prev` is the previous record's `digest` across rotations (null first); `digest` covers the canonical JSON of the record without `digest`. |
| (anchor) | | Not in the stream: `judgments.head.json` holds `{digest, count, file}` and `verify` reports `truncated` against it, expecting a count that leaves out the records it lists as `interrupted_append`. |
| (skips) | | Not in the stream: `skips.jsonl` holds one `{ts, tool, session, key, skip}` line per call `bin/polispec-guard` skipped; counted, never chained. |

## Layers: `polispec.global/v1`, `polispec.module/v1`, `polispec.profiles/v1`

A policy is composed from layers: since 0.45.0 the catalog layer (empty until the operator activates a catalog spec), then the global layer, the repo policy, then every ledgered child project nested under the repo that contains the path, nearest last, to any depth. The outermost ledgered repo or worktree root containing a path owns it, whatever the ledger order. The global layer is `global.yml`, `profiles.yml` and `modules/<name>.yml` read from the `polispec.global.*` settings (see `docs/operator.md`). With no global source configured and no includes, verdicts are exactly those of the repo policy alone.

- `global.yml` (`polispec.global/v1`): `includes`, `rules`, `fallback_rules`, `gates` (`to_test`, `to_stable`), `preflight`, `freezes`, `hermetic`, `protected_roots` (`path`, `writers`), `delete_protected` (`exact`, `tree`: lists of paths, `~` expanded; since 0.33.0, extends the shipped list and never removes an entry).
- `modules/<name>.yml` (`polispec.module/v1`): `name` (equal to the file name), `params`, `includes`, `rules`, `gates`, `preflight`, `freezes`, `hermetic`, `delete_protected`.

### Catalog layer

Since 0.45.0 nothing is composed from the release by default. The release ships a catalog of optional specs under `catalog/<spec>/`; each is a `catalog.yml` (`polispec.catalog/v1`) plus one `polispec.module/v1` file per subspec. The operator activates a spec per host (see [the catalog](operator.md#catalog)), and the active subspecs are composed first in every chain, on that host, as the layer named `catalog` (source `catalog:<version>`, one module label `catalog:<spec>/<subspec>` per active subspec). The layer is absent while nothing is active. Rules appear in catalog order: `tools`, `delete-guard`, `delete-backup`, `mcp`, then `harness`, and within a spec in the order its `catalog.yml` lists the subspecs. Every shipped rule is `overridable: true`: a shelf or project rule tightens one with a plain rule and loosens one only by naming it in `overrides`. The layer's digest is part of every effective digest, so activating or deactivating a spec changes the fast-path key.

| Spec | Subspec | Content |
| --- | --- | --- |
| `tools` | `declared` | The harness-internal tools (`TOOL-<NAME>`, `match.tool` plus class `tool.internal`), the read tools (`TOOL-READ-<NAME>`, class `tool.read`) and the development relaxation of `eval`, `source` and `.` lines (`TOOL-OPAQUE-DEVELOPMENT`, shape `opaque_shell` with the `in_development` predicate). |
| `tools` | `unknown` | No rules. Active, the guard asks (lock: denies) about a call it cannot positively classify, `POLISPEC-TOOL-UNKNOWN`. |
| `tools` | `web-agent` | `G-WEB-AGENT`, which warns on an agent call to the local web app. |
| `delete-guard` | `protected` | The `delete_protected` list (exact: `/`, `~`, `/home`, `/etc`, `/usr`, `/var`, `/boot`, `/bin`, `/sbin`, `/lib`, `/lib64`, `/opt`, `/root`, `/sys`, `/proc`, `/dev`, `/usr/bin`, `/usr/sbin`, `/usr/lib`, `/usr/lib64`; tree: `~/.ssh`, `~/.claude`, `~/.config`, `~/.rplugins`, `~/.polispec`), `G-DELETE-PROTECTED` (class `fs.delete`, predicate `delete_protected`, deny) and `G-DELETE-PROTECTED-FILE` (predicate `delete_protected_file`, warn). |
| `delete-guard` | `xargs` | `G-DELETE-XARGS` (shape `xargs_delete`, warn). |
| `delete-backup` | `copy` | The module-only data key `delete_backup: {ignored_names: [...]}`, `G-DELETE-UNBACKED` (class `fs.delete`, predicate `delete_unbacked`, warn), `G-DELETE-BACKUP-DIR` (path `/**/.backup`), `G-DELETE-BACKUP-CONTENTS` (path `/**/.backup/**/*`) and `G-DELETE-BACKUPS-NAMED` (path `/**/backups`), all warn. |
| `delete-backup` | `opaque` | `G-DELETE-UNRESOLVED` (shape `unresolved_delete`), `G-DELETE-FIND-UNFILTERED` (shape `find_unfiltered`) and `G-DELETE-GIT-CLEAN-DIRS` (shape `git_clean_dirs`), all warn. |
| `mcp` | `undeclared` | No rules. Active, the guard asks (lock: denies) about an MCP operation no protected control or committed policy declares, `POLISPEC-MCP-UNDECLARED`. |
| `mcp` | `declared` | Empty in the release. The operator provisions the host's own declarations from a file. |
| `harness` | `hook-files` | Since 0.52.0. Nine warn rules `G-HOOK-FILE-*` (classes `fs.write` and `fs.delete`, one `path` glob each, `**/`-anchored so they match under the home directory and under a repository) over the files Claude Code (`.claude/settings*.json`, `.claude/skills/`, `.claude/agents/`, `.claude/hooks/`), Codex (`.codex/config.toml`, `.codex/hooks.json`), Hermes (`.hermes/config.yaml`) and Antigravity (`.gemini/config/hooks.json`, `.agents/hooks.json`) load hooks, skills and agents from. |

The effective `delete_protected` list is the union of the active modules' key, the global layer's top-level `delete_protected` and every shelf module's; a live project's policy does not contribute. A catalog module is read only from the release tree, except a provisioned file, which is read from the host's catalog state directory and checked against the sha256 recorded when it was provisioned. A shelf module of the same name is an ordinary shelf module.

`catalog.yml` (`polispec.catalog/v1`): `schema`, `name` (equal to the directory), `summary`, and `subspecs`, a list of `{ id, summary, module, gate, provision }`. `id` is lowercase and hyphenated, `module` is a file in the same directory, `gate` is optional and one of `unknown_tool` or `mcp_undeclared` (a subspec that names a gate switches that guard branch on while it is active), and `provision` is optional and means the module is supplied by the operator. Validate it with `polispec validate catalog FILE`.

The host's state file `<state home>/catalog/active.yml` (`polispec.catalog-state/v1`) holds `active`, a list of `{ spec, subspec, activated_at, release }`, and `provisioned`, a list of `{ spec, subspec, file, sha256, provisioned_at }` with `file` relative to the catalog state directory. Validate it with `polispec validate catalog-state FILE`. A state file that does not parse or does not validate fails closed: every subspec without `provision` counts as active, every provision subspec as inactive, and `polispec doctor` reports `catalog_state_invalid`.

### Module shelves

A module name resolves on one of two shelves:

- **Global shelf:** `modules/<name>.yml` under the `polispec.global.*` source, shared by every project on the host.
- **Project shelf:** `modules/<name>.yml` in the directory of the project's policy (normally `specs/polispec/modules/`), read from the same source as the policy: the trust ref, the bootstrap ref during promotion bootstrap, or the sibling directory of a policy file passed to `validate policy` or `POLISPEC_POLICY`.

A project module may include project and global modules; a global module sees only the global shelf. A name present on both shelves is an error (`module <name> is ambiguous`) and that include is not applied. Edits under `specs/polispec/` classify as `policy.edit`.

### Module parameters

```yaml
schema: polispec.module/v1
name: soak
params:
  hours: { type: integer, default: 24, summary: "minimum hours on test" }
gates:
  to_stable:
    - { id: G-SOAK, builtin: soaked, hours: "{{hours}}" }
```

- `params.<name>` (lowercase, digits, `_`): `type` (`string`, `integer`, `number`, `boolean`, `list`; required), `default`, `summary`.
- An include is a module name or `{ module: <name>, with: { <param>: <value> } }`. A parameter without a default must be given.
- A string that is exactly `"{{name}}"` becomes the typed value. `{{name}}` inside longer text is replaced by the value as text; a `list` cannot be used inside text. Keys are never substituted.
- A module's own `includes` are substituted too, so `with: { hours: "{{soak_hours}}" }` passes a parameter down.
- Each instance is validated against `polispec.module/v1` after substitution. An unknown, missing or mistyped parameter, an unresolved placeholder, or an invalid instance is an error and the instance is not applied.
- One module with different parameters gives separate instances, each expanded once per layer. Two instances in one layer that produce the same rule, gate or freeze id is an error.
- A layer digest covers each instance's text and resolved parameters.

### Nested projects

A child layer is built like the repo layer: the child's includes (from its own project shelf and the global shelf) come before its own rules. When the owning project is promoted, every nested project contributes its `promotion.to_test.gates`, `promotion.to_stable.gates` and `preflight`, its `freezes` and `hermetic`, and those of its modules. A gate a child contributes carries `dir` set to the child's path relative to the owner, so it runs in the child's directory. A contributed gate or freeze whose id is already defined by the owner or the global layer is an `id_collision` error and the child copy is not applied.

### Merging
- `profiles.yml` (`polispec.profiles/v1`): `profiles.personal`, `profiles.service`, `profiles.live`, each a list of module names. A ledger project gets its `profile` (default `personal`); a path outside the ledger gets only the global layer without profile modules. A policy may set `profile` only to a stricter one than its ledger entry.
- Within a layer rules stay first-match. A layer's included modules (depth-first, each once; a cycle or a missing module is an error) come before the layer's own rules. Across layers the strictest verdict wins (`deny`, then `warn`, then `allow`); on equal severity the lowest layer's rule is reported.
- A lower layer loosens an upper rule only when that rule has `overridable: true` and the lower layer's rule names it in `overrides`. Overriding a rule that is not overridable, or that no upper layer defines, is a validation error naming both rules, and the override is not applied.
- Layers merge `rules`, `gates`, `freezes` and `hermetic`, never `environments`. Inside the owner, the repo policy's own gate or freeze replaces a module's one with the same id.
- Every composition error (cycle, missing or ambiguous module, parameter error, duplicate instance id, id collision, invalid override) is reported by `validate`, `doctor` (`layers_invalid`) and `resolve --layers`, and makes `promote` refuse with `policy_invalid`.
- `fallback_rules` in `global.yml` replace the ledger `defaults.rules` as the repo layer of a project whose policy is missing at its trust ref. They never join the composed global layer. The pretool hook evaluates a live project in that state under them (or under `defaults.rules` when no global layer is configured), never with an internal denial. When `polispec.global.repo` is set and `global.yml` is absent or invalid, doctor and validate report it and the global layer contributes no rules; the repo layer still applies.

`polispec resolve <path> --layers --json` prints each layer with its source, digest, rule count and modules, then the effective digest (sha256 over the ordered layer digests). `polispec validate policy`, `validate global`, `validate module` and `polispec doctor` report override, include and profile errors, and an environment that deploys without a health check.

## Behavior contract: `polispec.contract/v1`, `polispec.contract-vocabulary/v1`

Since 0.43.0, `specs/polispec/contracts/*.yml` holds one versioned behavior contract per file, and `specs/polispec/contracts/vocabulary.yml` holds the project's vocabulary. `polispec validate contract FILE` and `polispec validate contract-vocabulary FILE` check them, and `validate auto` picks them up by schema id. Both reject unknown keys. See [contract](contract.md).

## Candidates for schema v2

- SUG-1 `approvals.quorum`: N named humans must confirm a prod promotion (a second owner or reviewer).
- SUG-2 `change_classes`: classify a diff (hooks, wire files, migrations, agent control) and attach stricter gates or a soak per class.
- SUG-3 `coupling`: cross-project promotion constraints, for example a plugin's stable may not advance past a wire version the service's stable does not serve.
- SUG-4 `slos`: per-environment objectives that block promotion when test missed them (error rate, p99).
- SUG-5 `incident.runbooks`: named rollback and incident runbooks the guard links in deny messages.
- SUG-6 `providers_by_data_class`: which model providers may see which data classes.
- SUG-7 `network.egress`: allowed outbound hosts per environment, enforced through harness sandboxes.
- SUG-8 `exceptions`: expiring, named policy exceptions with an owner, replacing ad-hoc pauses.
- SUG-9 `release_gate.POL-*`: a release-gate check that the target ref carries a valid policy.
- SUG-10 `retention`: per-environment data retention and automatic test-data expiry.
- SUG-11 `notify`: route warn and deny digests to Telegram or desktop notification through the notify port.
- SUG-12 `compliance_tags`: regulatory tags such as GDPR on environments and data classes, surfaced in the daily digest.

## Harness controls

`polispec.control/v1` is a separate deterministic control document, validated with `polispec validate control FILE`. It composes as a severity ceiling over environment policy in enforce mode. See [the grammar and lifecycle guide](harness-controls.md).

Policy, module, global, and ledger rule match objects accept the six exact-control selector keys above as nonempty strings bounded to 4096 characters. Only `path` is a glob; the others compare exact strings. Unknown selectors are invalid. A mutable overlay cannot remove the undeclared MCP default; a trusted committed policy or protected core must declare the actual matching server and operation. Every declared environment and selector must still match.
