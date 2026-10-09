# Roster

`specs/polispec/roster.yml` (`polispec.roster/v1`) says which harness, model, effort, budget and agent a role or a pipeline phase gets, and the bounds a profile must stay inside. The guard reads it from the project's trust ref, never the working tree.

## Commands

```
polispec roster resolve <project> (--role R | --pipeline P --phase X) [--env E] [--roster FILE] [--json]
polispec roster check <project> --pipeline P --profile <file|-> [--env E] [--roster FILE] [--json]
```

Without `--roster`, the roster is read with `git show <trust_ref>:<roster path>` in the ledger project's repo. The ledger path resolves from `POLISPEC_LEDGER`, then the `polispec.ledger` setting, then `~/.config/polispec/ledger.yml` (see `docs/schema.md`). The roster must validate against its schema and name the same project.

Exit status: 0 on success, 1 on violations or an error, 2 on a usage error.

### resolve

```
{"default":{...},"bounds":{...},"env_allowed":true,"roster_digest":"sha256:..."}
```

`env_allowed` tests the role, or `<pipeline>.<phase>`, against the `environments.<env>.roles` or `.pipelines` globs (`--env` defaults to `dev`). `roster_digest` is the sha256 of the roster bytes. An unknown role, pipeline or phase returns `{"ok":false,"error":"..."}` and exit 1.

### check

The profile is a JSON or YAML object, either `{"schema":1,"phases":{...}}` or the bare phases map.

```
{"ok":false,"violations":[{"phase":"build","field":"effort","value":"low","bound":"min medium"}]}
```

Checks run in two layers. The baseline holds the worker profile rules and does not depend on bounds: allowed keys per phase, `run` and `on_failure` enums, harness in the known set and `claude` only for intake and ship, model name pattern, effort inside the harness vocabulary, effort empty for haiku on claude, `budget_usd` from 0.5 to 100, and `agent` only on intake, diagnose, spec and build. The bounds layer then applies the slot's `harnesses`, `models`, `effort` min and max, and `budget_usd` min and max. A field that already failed the baseline is not reported again by bounds.

Effort ordering follows the roster's `harness_effort` list for the profile's harness. A null effort is not compared. `budgets.per_run_usd_max` caps every phase budget. With `--env`, each phase must also be permitted by that environment's `pipelines` globs.
