# Lint

`polispec lint [PATH...] [--host] [--shipped] [--ref REF] [--only RULE[,RULE]...] [--strict] [--json]` is read-only. It sweeps generated and shipped files for schema, hygiene, drift, reference and description findings with the loader the guard uses. `docs/operator.md` lists the `polispec.lint.*` settings.

## Linting a ref

By default `lint` reads a project's working tree, so a clean run says nothing about what the trust ref holds. `--ref REF` reads the files of each project root from the commit `REF` names instead, through `git cat-file`, and lints that copy. Findings name their files as `<repo>@REF:<path>`.

```sh
polispec lint . --ref stable
polispec lint --host --ref stable
```

- A `REF` that does not resolve to a commit in a root is an error (exit 1, `ref REF not found in ROOT`); a `--ref` with no value is a usage error (exit 2).
- With `--host`, `REF` applies to every ledgered project; a project that lacks the ref is reported as the info finding `ref_missing` and skipped.
- Drift checks that compare the working tree with a render (`agents_drift`, `manifest_drift`) do not run for a ref; the behavior and contract surface checks do.
- Without `--ref` nothing changes.

## doctor

`polispec doctor` lints the host's projects at each project's trust ref, through the same reader as `--ref`, and files the findings as `lint_<code>`. A defect that exists only on the development branch no longer makes `doctor` exit 1. A project whose ledger entry names no trust ref is linted from its checkout.

## Deployments manifest

`deployments` is a schema kind (`schemas/deployments.v1.yml`). The write gate on `deployments.json` and `lint --host` both validate it through `Schema.validate`, so an invalid manifest is reported by both with the same schema finding.
