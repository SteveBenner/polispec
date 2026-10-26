# Pattern catalog

Used by `polispec-advise`. Each pattern is a signal, an inference, a lever and a draft sketch in pseudocode. Names in angle brackets are placeholders to fill from evidence. Keys and their minimum versions are in the last table; a key newer than the host's runtime makes the file invalid, so check `polispec version` first.

Notation: `count(x, over w)` is how many records match `x` in window `w`. `sessions(x)` is the number of distinct sessions. `->` is "suggest".

## Reading order

Posture, then structure, then domain, then rule, then match. Stop at the first level that solves the problem.

## A. Repeated asks

Thresholds are starting points, not rules: three sessions in a week is a pattern, one session is noise.

| ID | Signal | Inference | Lever and draft | Confirmer |
| --- | --- | --- | --- | --- |
| A1 | `count(ask POLISPEC-TOOL-UNKNOWN, tool=<harness-internal or read tool>) >= 3` across `sessions >= 2` | A benign built-in tool is not declared | activate catalog `tools/declared` | operator, terminal |
| A2 | same, tool=<single named tool> | one tool is legitimate and recurring | shelf rule: `match{tool=<exact name>, class=[tool.internal or tool.read]} verdict=allow` | `plan global`, user's yes |
| A3 | `count(ask POLISPEC-MCP-UNDECLARED, server=<S>, operation=<O>) >= 3` | a known MCP operation is undeclared | shelf rule: `match{server=<S>, operation=<O>, class=[mcp.call]} verdict=allow`, one per operation; or provision `mcp/declared` with the host's list | `plan global`, user's yes; or operator for provision |
| A4 | `count(ask rule=<R> in env dev)` on calls that are the same command shape | the rule is too broad for development | narrow `<R>`'s `match` in its owning layer; do not add an allow rule above it | `plan project:ID` or `plan global`; a loosening, user's yes |
| A5 | many asks whose text starts with a directory change, then an eval, source or dot line, in a directory the classifier cannot tie to a project | opaque shell, not a policy gap | keep work in an onboarding project, or run a script file by path; do not add an exception per variant | none, or operator for one exception |
| A6 | `count(ask rule=<R>) >= 3` with identical command text | a stable command | exception kind rule or control, glob over the exact text, project scope first | operator, terminal; none under lock or while sealed |
| A7 | asks that disappear after allow-once | single-use grants do not scale | replace with A1 to A6 | |
| A8 | `warn` rendered as `deny` on Codex with an allow-once id | harness difference, not a rule change | read the recorded verdict; route through A1 to A6 | |

Order inside a pattern: declare, then narrow, then exception, then allow-once. Prefer one declaration over many exceptions.

## B. Denies that point somewhere

| ID | Signal | Inference | Lever and draft |
| --- | --- | --- | --- |
| B1 | `count(deny rule=<R>)` high and the reason names a sanctioned tool | the guard is steering; the agent keeps choosing the other path | advisory directive: use `<sanctioned tool>` for `<task>` first; no spec change |
| B2 | `count(deny rule=<R>)` high on calls the person confirms are legitimate | the rule's `match` is too wide | narrow `match`, or a lower-layer rule `overrides=<R>` where `<R>` is `overridable`; a loosening |
| B3 | a deny on a rule in the never-override list | working as intended | explain the next step; no suggestion to loosen |
| B4 | desire to steer agents from a hand-built script to an approved tool | a redirect rule | new rule: `match{class, text_matches=<pattern of the hand-built form>} verdict=deny reason="use <tool and command>"` with `overridable=true` |

## C. Posture, a first policy

| ID | Signal | Inference | Draft |
| --- | --- | --- | --- |
| C1 | repository serves users, no `specs/polispec/` | needs environments | `plan environment-control --repo <R> --variant service` (or `distributed`); set real health commands before promoting |
| C2 | project is not a git repository, or a directory or system | not a repository project | polispec-register |
| C3 | several repositories share the same wishes | wants a shared module | module with `params`; include from each policy or the shelf; one instance per distinct parameter set |
| C4 | a subtree has different rules from its parent | a nested child project | register the subtree as a ledgered project; it stacks beneath its owner |
| C5 | a secrets file or credential store is read in test or prod | data boundary | rule: `match{class=[secrets.read], env=<E>, path=<glob>} verdict=deny`; test holds de-identified data only |
| C6 | writes land in a production checkout | prod must be changed by promotion | confirm a rule exists with `match{class=[fs.write], env=prod} verdict=deny`; add it if missing |
| C7 | a service unit is started or edited by an agent | operator-only | rule: `match{class=[service.control]} verdict=deny` in prod |

## D. Hygiene domains

| ID | Signal | Draft | Min version |
| --- | --- | --- | --- |
| D1 | recursive delete near system or home roots | activate catalog `delete-guard/protected`; add host trees to `delete_protected` | 0.45.0 |
| D2 | delete through `xargs` | catalog `delete-guard/xargs` | 0.45.0 |
| D3 | `find`, `grep -r`, `rg` or `du` from `/` or on a FUSE, network or removable mount | rule: `match{class=[fs.walk], shape=[root_walk, slow_mount_walk]} verdict=deny` or warn, in a shelf module | 0.46.0 |
| D4 | large writes to scratch, unset file-size limit | rule on `fsize_unset` or `fsize_above` and a scratch path | 0.39.0 |
| D5 | a pattern in command text must be recognised, not a tool | `match{class, text_matches=<pattern>}`; keep the pattern as narrow as the evidence and bounded to 4096 characters | 0.40.0 |
| D6 | two tags, pushes or releases chained in one command | rule on `shape=[chained_release]` | |
| D7 | repeated lock-held denials | not a rule problem; wait or work elsewhere | |
| D8 | an agent edits generated directive rows | edit `environments.yml` or `policy.yml` and run `polispec agents render`; for behavior surfaces, edit the canonical directive and run `polispec behavior render` | 0.34.0 |

## E. Spec lifecycle

| Event | Evidence | Route |
| --- | --- | --- |
| create | C1 to C7 | polispec-specs or environment-control plan |
| modify | A4, B2, a role on the wrong harness, a verdict that surprised the person | `plan project:<ID>` or `plan global`; classification decides the confirmer |
| delete | a rule with `count(hit, over 90d) == 0`; a retired project | removal loosens; user's yes with plan id |
| move | a rule used in many projects (-> shelf module); a rule used in one (-> project); a repository path or id change | two plans: add first, remove second; a ledger repo or id change is a loosening |
| register | C2 | polispec-register |

## F. Reading history and files

| Source | Pattern to look for | Meaning |
| --- | --- | --- |
| harness history, named paths | the same instruction repeated across sessions | a directive candidate |
| harness history | the same refused action followed by a rephrase | evasion; report it, never encode it |
| judgments | `rule` x `tool` x `class` histogram | A and B patterns |
| judgments | clusters by working directory | C3 and C4 candidates |
| project files | service units, deploy scripts, env templates, lockfiles | posture and C5 to C7 |
| MCP configuration | list of servers and operations | A3 declarations; read names only, not tokens |

Never record a secret. Quote ids and counts.

## G. Classification quick reference

| Change | Class | Who confirms |
| --- | --- | --- |
| add a rule, gate, freeze, module, protected root, when probes only get stricter | tightening | none for a project plan; global always needs the user's yes |
| remove any of those, or a change that makes a probe verdict softer | loosening | user's yes and `--confirm PLAN_ID` |
| both in one plan | mixed | user's yes |
| edit that changes no probe verdict | neutral | none, unless global |
| catalog activate or deactivate or provision | no plan | operator at a terminal; refused while sealed |
| exception add, promote or remove | no plan; commits through a global apply | operator at a terminal; refused while sealed |
| any change under the sealed plane | | authenticated operator |

A project change takes effect only after the operator promotes the project to stable. Previewing with `polispec plan` replays the last 14 days of recorded calls against the proposal; it never applies exceptions.

## H. Minimum versions of keys

| Key or feature | Since |
| --- | --- |
| exceptions, `polispec exceptions` | 0.29.0 |
| `in_development`, relaxed opaque shell | 0.30.0 |
| module `params`, nested child projects | 0.20.0 |
| behavior v2 surfaces and `behavior render` | 0.34.0 |
| web app, author, register, manifest, changes, sessions | 0.35.0 |
| scratch size keys `fsize_unset`, `fsize_above` | 0.39.0 |
| `text_matches` | 0.40.0 |
| `polispec lint` | 0.42.0 |
| behavior contracts | 0.43.0 |
| catalog, `tools/declared`, `mcp/declared`, `delete-guard` | 0.45.0 |
| `fs.walk`, `root_walk`, `slow_mount_walk` | 0.46.0 |

Every schema rejects unknown keys. Hand any draft to polispec-specs to validate, lint and plan before it is shown as ready.
