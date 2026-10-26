# Agent guide

How an agent should understand, obey and improve the policy around it. The skills are short routers into this file and the other `docs/`; read the part you need.

## What polispec is

A guard that judges every tool call an agent makes against a versioned rulebook, and the tooling to author, preview and promote that rulebook. Policy lives in git, not in the model's memory. A call gets one verdict from the policy: `allow`, `warn` or `deny`, each with a reason and a next step.

- **Positioning.** It is a seatbelt and a ledger for agentic work, not a sandbox. It judges what the classifier can read; an opaque program is judged conservatively.
- **Reach.** Claude Code and Codex natively through hooks. Hermes through a native pre-tool backend. Pi, DeepSeek TUI and Antigravity receive skills only. A skills-only harness has no judgments, no proposals and no enforcement; the guidance still applies as discipline.
- **What it governs.** Shell, file, MCP, web, agent and delegation calls, by class (`fs.write`, `fs.delete`, `fs.walk`, `secrets.read`, `mcp.call`, `policy.edit`, `tool.internal`, `web.fetch`, `agent.spawn`, and others) in a project's environments: dev on `main`, test on `test`, prod on `stable`.
- **What it does not do.** It does not run a model to decide a verdict. It does not certify enforcement from generated files.

## Layers, abstract to minutiae

Think about a policy from the top down and stop at the first level that solves the problem.

| Level | Question | Where it lives |
| --- | --- | --- |
| 0 Posture | Does this serve real users? Which environments exist? Who is the operator? | ledger status, `environments.yml` |
| 1 Structure | Which layer should own the rule: host, shared module, one project, one subtree? | shelf, module, project policy, child project |
| 2 Domain | Which class of call: tools, MCP, shell, filesystem, network, secrets, data, release? | catalog spec, module |
| 3 Rule | Verdict, scope (environment, role, class, tool, shape), overridable or not | rule in a module or policy |
| 4 Match | The narrowest key that selects exactly the calls meant: exact tool, exact server and operation, path glob, text pattern | `match` keys |

Composition: the global shelf, its modules, the project policy and nested child projects stack; the strictest verdict wins; a lower layer loosens only a rule marked `overridable` that it names in `overrides`. The catalog layer comes first and holds only subspecs the operator activated on the host.

## Operating rules

1. Before writing in a project: `polispec resolve .`. Obey the verdict.
2. On `warn`: ask the user with the question tool, say what and why, proceed only on an explicit yes.
3. On `deny`: stop and relay the next step. Never retry in another shape, never change tools to reach the same effect, never edit the ledger or `specs/polispec/**` to change a verdict.
4. Never self-redeem `allow-once`, pause, promote to stable, deploy stable, seal or activate. Give the operator the exact command.
5. Never edit the running polispec. Develop in a separate worktree with scratch state.
6. A draft is not trusted policy. The trust ref in effect is what judges.
7. Check the edition, the sealed plane and the kill switches before proposing a lever: `polispec doctor`, `polispec settings get polispec.exceptions`, `polispec editions`.

## Anatomy of an ask

A call asks (warns) for one of four reasons. The lever depends on which.

| Source | Looks like | Why it asks |
| --- | --- | --- |
| Unknown tool | `POLISPEC-TOOL-UNKNOWN` | The classifier cannot positively classify the tool, or a shell line runs `eval`, `source` or `.`, or cannot be parsed. Active only while catalog `tools/unknown` is. |
| Undeclared MCP | `POLISPEC-MCP-UNDECLARED` | No trusted rule declares that server and operation. Active only while catalog `mcp/undeclared` is. |
| Environment rule warn | rule id such as `R-*` or `G-*` | A rule in a rulebook says `warn` for this class in this environment. |
| Control ask | `POLISPEC-CONTROL-*` | The harness-control ceiling needs consent. |

A `deny` is not an ask. No exception lifts it.

## Cutting repeated asks

Each ask blocks unattended runs, so the goal is fewer distinct asks, not faster approvals. In order of preference:

1. **Declare** what is legitimate and recurring, so it classifies as known. Harness-internal and read tools: activate catalog `tools/declared` (operator). An individual unknown tool: a shelf rule matching the exact tool. An MCP operation: a rule with class `mcp.call` and an exact server and operation, or `catalog provision mcp/declared` (operator).
2. **Narrow the rule** that warns, so it stops matching benign calls: a tighter `match` in the owning layer. A project-layer warn cannot be loosened from the shelf; change the project policy through `plan project:ID`, which is loosening and needs the user's yes, and takes effect after the operator promotes to stable.
3. **Persist an exception** for a stable, exactly-worded command: the operator promotes a recorded proposal. It lifts only an ask or a Bash rule warn, only for commands whose text matches, never a deny, never under lock or while sealed.
4. **Allow once** last. It is single use, so it never removes a repeated ask; it matters on Codex, where a warn becomes a deny, and for control asks.

Plan the work to stay inside what is declared: run a script file by path rather than `eval`, `source` or `.`; name tools exactly; keep commands in one parseable line. That is planning ahead. It is never a way to rework a call that was already refused.

## When a spec should change

| Event | Signal | Route |
| --- | --- | --- |
| Create | A project starts serving real users with no `specs/polispec/`; a new service, secret store or data environment; a new tool or MCP server used repeatedly | `plan environment-control`, or polispec-specs for a module or rule |
| Modify | The same rule asks or denies across sessions on benign calls; a verdict surprised the user; a role runs on the wrong harness or model | polispec-specs, `plan project:ID` or `plan global` |
| Delete | A rule or exception that no recent judgment hit; a retired project; an unregistered path | A removal loosens: the user's yes and `--confirm` |
| Move | A rule belongs in a wider or narrower layer; a repository path or id changed | Two plans: add in the new place, remove from the old. The removal loosens. The web Manager does it as one paired plan for the person |
| Register | Software, a directory or a system outside a governed repository needs governing | polispec-register |

## Where the evidence is

| Source | Reads | Limit |
| --- | --- | --- |
| `polispec digest` | Counts of warn and deny by rule | no command text |
| `polispec judgments list --json` | Per-call rule, class, tool, verdict, outcome | no command text unless `polispec.records.raw` is on; never turn that on without the user's yes |
| `polispec exceptions list --json` | Entries and recorded ask proposals | proposals last seven days, at most 256, none under lock or while sealed or with exceptions off |
| `polispec explain` | The verdict a real payload gets | needs the real hook payload |
| `polispec explain TOOL INPUT [--cwd DIR]` | For a call you type, the classified actions, each matching rule per layer with file, line, module and package, the winner, why it won, and the lever that would change it | judges as the project at `--cwd`; a shell line is classified, not run; a rule with no layer match shows as an engine guard |
| The harness's own history | What the person kept asking for | read only named paths on one filesystem; never walk from `/`; redact secrets and never read production data or env files |

Codex renders a warn as a deny: read the recorded verdict, not the rendered reply.

## Edition and switch differences

| Condition | Effect on levers |
| --- | --- |
| lock edition | No exceptions, no proposals; unknown and undeclared MCP are denied, not asked; no web app, author or exceptions delegate; only managed-scope controls count |
| sealed plane | `exceptions add\|promote\|remove`, `catalog activate\|deactivate\|provision` and `settings set\|unset` are refused; changes go through the authenticated operator and the protected generation |
| `polispec.exceptions` off | No exception honored, none recorded |
| `polispec.relax.dev` off | Opaque shell lines ask even in onboarding projects |
| `polispec.author.enabled` off | `author draft` unavailable |

## Rules agents never suggest overriding

`G-WEB-AGENT`, `G-DELETE-PROTECTED`, `G-DELETE-PROTECTED-FILE`, `G-DELETE-XARGS`, `R-POLISPEC-RUNTIME`, `POLISPEC-CONTROL-PROTECTION`, the container root guard and anything under a broken seal. `G-WEB-AGENT` applies only while catalog `web-agent` is active; the agent never drives the web API either way.

## Related

- Every verb and who runs it: `docs/cli.md`.
- Keys of every file: `docs/schema.md`.
- Operator procedures: `docs/operator.md`.
- Harness controls: `docs/harness-controls.md`.
- Behavioral policy directives: `docs/behavior.md`. Suggest wording against the canonical directive and run `polispec behavior render`; never edit generated rows.
