# polispec

<p align="center">
  <img src="assets/logo/polispec-threshold-frost-bottom-center.png" alt="polispec: a white robotic hand points at a frosted glass pane where a Claude Code push to stable is denied by the polispec rule R-PROD-GIT shown in the policy spec below it, above the polispec wordmark" width="100%">
</p>

> **AI agents:** read [`AGENTS.md`](AGENTS.md) first.

**A written rulebook for AI coding agents that work on software real people use.** You write down, once, what an agent may do in each copy of your project. polispec checks every agent action against that rulebook before it happens. It answers *go ahead*, *are you sure?*, or *no*, and always says why and what to do instead.

## Contents

- [In plain words](#in-plain-words)
  - [The problem](#the-problem)
  - [What polispec does](#what-polispec-does)
  - [Who it is for](#who-it-is-for)
- [A worked example: a clinic's booking app](#a-worked-example-a-clinics-booking-app)
  - [The story](#the-story)
  - [A day with the rulebook](#a-day-with-the-rulebook)
  - [The rulebook itself](#the-rulebook-itself)
  - [Try it](#try-it)
- [How a verdict is made](#how-a-verdict-is-made)
- [Composition: specs inside specs](#composition-specs-inside-specs)
- [Core ideas](#core-ideas)
- [Feature tour](#feature-tour)
- [Looking after polispec itself](#looking-after-polispec-itself)
- [Install](#install)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Settings](#settings)
- [Compared to alternatives](#compared-to-alternatives)
- [Current State of Polispec](#current-state-of-polispec)
- [Honest limits](#honest-limits)
- [FAQ](#faq)
- [Where polispec is going](#where-polispec-is-going)
- [Documentation](#documentation)
- [License](#license)

## In plain words

### The problem

AI coding agents can now do almost anything a developer can do at a keyboard: edit files, run commands, commit, push, restart services, and read secrets. That speed is the point. The same agent that fixes a typo in a minute can also overwrite the live copy of an app, push half-finished work to the version customers download, or copy real customer records into a test database. Usually that happens because nobody told it where the edges are, not because it meant harm.

Most teams handle this with habit and trust: "don't touch production," written in a chat message or a prompt. Habits are not checked, prompts get forgotten, and a new agent session starts with no memory of either.

### What polispec does

polispec turns those habits into a short, versioned rulebook that lives in the project's own repository. It enforces that rulebook on every agent action.

Think of the access-card system in an office building. Most doors open for anyone. Some ring a bell at the front desk and wait for a yes. A few stay locked, and only the building manager has that key. polispec gives your software project the same three answers:

| Verdict | What happens | Typical use |
|---|---|---|
| **allow** | The action runs. | Everyday work on the development copy. |
| **warn** | The agent must stop and get an explicit yes from a person. | Rewriting shared history, writing real data, editing the rulebook itself. |
| **deny** | The action does not run. The agent is told why and what to do instead. | Editing the live copy, pushing to the release branch, reading production secrets. |

Around those verdicts, polispec covers the rest of the journey from "an agent wrote code" to "real people use it":

- **Separate copies of the project.** Each copy is an environment with its own branch and its own rules: development (`main`), a rehearsal copy (`test`), and the live copy (`stable`).
- **A promotion pipeline.** Code moves forward one step at a time. Each step has *gates*, which are checks that must pass. The last step needs a person, a typed confirmation phrase, and sometimes a waiting period.
- **Freeze windows.** Releases can be blocked automatically during busy hours, before a deadline, or while people are actively using the app. The windows can come from another system's calendar.
- **Protected paths.** Deleting the filesystem root, the system folders, or anything inside `~/.ssh`, `~/.ai`, `~/.claude`, `~/.config`, `~/.rplugins` and `~/.polispec` is refused on every host, whatever shape the command takes; deleting a single file inside those folders, or feeding deletes through `xargs`, asks first. When one of those folders is a symlink, the folder it points to is protected too, but what lies inside that target is judged only when written through the `~/.` path, so cleaning a build inside a symlinked working repo is not refused. The global layer can add paths but never remove one.
- **Data boundaries.** You declare which kinds of data may live in which copy, and copying across them is refused.
- **Who does the work.** A roster says which AI tool, model, and effort level each agent role uses.
- **Rules for the code itself.** Code specs apply per programming language whenever an agent writes a file. A hard violation blocks the write; a soft one is reported.
- **Specs made of specs.** Rules come in reusable modules that include other modules, take parameters, and stack across nested projects to any depth. See [composition](#composition-specs-inside-specs).
- **A record of what happened.** Every verdict, promotion, deploy, and smoke test is recorded, so you can show what ran, when, and on which commit.

Agents never write their own rules. polispec reads the rulebook from the project's *trusted* branch (normally `stable`), which only the operator can move. An agent that edits the rulebook on `main` changes nothing until a person promotes that edit.

### Who it is for

- **A solo developer or small team** whose agents write most of the code for an app that strangers use. polispec lets the agents keep their speed on `main` while the live app stays out of reach.
- **Anyone who ships software people install themselves:** a desktop app, a plugin, a CLI. "Stable" there is a download channel, and a bad push reaches every user at once.
- **A service with busy hours.** Examples are a booking system, a shop, a classroom tool, or an internal app during payroll week. Releases should wait for a quiet window, and the calendar that defines "quiet" already exists somewhere else.
- **A team running many agents at once.** Each role needs the right model and effort, and one policy has to govern every harness (Claude Code, Codex, Hermes, Antigravity CLI) the same way.
- **An operator who wants an audit trail.** Every promotion and deploy carries the commit, the gates that passed, and the health check that proved it.

## A worked example: a clinic's booking app

This example generalizes the pipeline polispec was first built for: a classroom app that students install, released through `main` → `test` → `stable`, with releases frozen during class and before assignment deadlines. Here the same pattern runs a medical clinic's booking app. The files are real: they live in [`examples/clinic/`](examples/clinic/), and `polispec validate` checks them.

### The story

Northside Clinic has a small web app where patients book, move, and cancel appointments. The front desk uses it all day. One developer maintains it with the help of AI coding agents. The app exists in three copies:

| Copy | Branch | Who uses it | Data in it |
|---|---|---|---|
| **Workshop** (dev) | `main` | The developer and the agents | Made-up patients |
| **Rehearsal** (test) | `test` | The developer and two front-desk staff who try new versions | De-identified copies, never real records |
| **Live** (prod) | `stable` | Patients and the front desk | Real patient records |

The developer wants three things. Agents should move fast in the workshop. Nothing should reach the rehearsal copy without passing the checks. Nothing should reach the live app unless a person decides it should, the version has run on rehearsal for a day, and the clinic is closed.

### A day with the rulebook

**9:10.** An agent fixes a bug in the reminder emails on `main`. It edits files, runs the app locally, and commits. polispec's answer each time is **allow**, and nothing slows down.

**9:40.** The same agent tries to patch the live checkout directly to "hotfix" the bug for patients:

```
[POLISPEC R-PROD-FS] DENIED: the live checkout is not edited by agents; layer repo sha256:3f1c09d2a7b4 (env prod, fs.write: ~/.polispec/envs/clinic/stable/app/mailers/reminder.rb) Make the change in the dev checkout and promote it through test; the production checkout is not edited by agents.
```

The agent does what the message says.

**10:05.** It runs `polispec promote clinic --to test`. polispec runs the to-test gates: the working tree is clean, the version was bumped in every place it appears, and `bin/check --all` passes. The `test` branch then fast-forwards, the release is tagged, and the rehearsal copy is deployed and health-checked. If any gate failed, `test` would not move, and the agent would see which gate failed and its output.

**10:30.** The agent wants to load last month's real bookings into the rehearsal copy to reproduce a report bug. The copy crosses from `patient_records`, which is allowed only in prod, into an environment that holds de-identified data only:

```
[POLISPEC R-PHI-COPY] DENIED: patient records may not leave production; test holds de-identified data only; layer repo sha256:3f1c09d2a7b4 (env test, data.copy: clinic -> clinic_test) Copy only data classes the destination environment allows (deidentified or synthetic data into test and dev).
```

**10:45.** The agent edits the rulebook on `main` to relax a rule. polispec answers **warn**: the agent must ask the developer, and the edit has no effect anyway until the developer promotes it to `stable`.

**Next morning, 7:35.** The developer runs `polispec promote clinic --to stable` before work. The release has soaked on test for 21 hours of the required 24, and the clinic opens at 8:00 with a 60-minute lead. Two gates refuse: `G-SOAK` (not soaked yet) and `G-FREEZE` (inside the `F-OPEN` window, which comes from the clinic's own opening-hours calendar).

**That evening, 19:10.** The clinic is closed and the soak is complete. The developer runs the promotion again from a terminal and types the confirmation phrase `promote clinic to stable`. `stable` moves, the live app is deployed, and a health check proves the new version is serving. The deploy receipt records the commit, the tag, and the health result.

### The rulebook itself

The project carries its rulebook in `specs/polispec/` (here, `examples/clinic/`):

```
specs/polispec/
├── environments.yml        # the three copies: branch, checkout, data, deploy and health check
├── policy.yml              # the rules, the promotion pipeline, data classes
└── modules/                # reusable pieces the policy includes
    ├── patient-data.yml    # no secrets, no copying patient records out of prod
    ├── release-train.yml   # the road to the live app, which itself includes:
    ├── soak.yml            #   … "ran on test for N hours"
    └── quiet-hours.yml     #   … "not while the business is open"
```

The policy's rules read top to bottom; within one file the first match wins:

```yaml
rules:
  - { id: R-PROD-FS, match: { env: prod, class: [fs.write] }, verdict: deny,
      reason: "the live checkout is not edited by agents" }
  - { id: R-TEST-PROMOTE, match: { env: test, class: [promote] }, verdict: allow, requires: gates.to_test }
  - { id: R-POLICY, match: { class: [policy.edit] }, verdict: warn,
      reason: "policy files take effect only after the operator promotes them to stable" }
  - { id: R-DEV, match: { env: dev }, verdict: allow }
```

The release pipeline is not written out inline. The policy *includes* it, with this clinic's settings:

```yaml
includes:
  - patient-data
  - { module: release-train,
      with: { soak_hours: 24, calendar: [bin/clinic-calendar, open-hours, --json], lead_minutes: 60 } }
```

`release-train` is itself built from two smaller modules. It passes its own parameters down to them:

```yaml
# modules/release-train.yml
params:
  soak_hours:   { type: integer, default: 24 }
  calendar:     { type: list }
  lead_minutes: { type: integer, default: 30 }
includes:
  - { module: soak,        with: { hours: "{{soak_hours}}" } }
  - { module: quiet-hours, with: { command: "{{calendar}}", lead_minutes: "{{lead_minutes}}" } }
gates:
  to_test:
    - { id: G-CHECKS, run: "bin/check --all", pass: exit_zero }

# modules/quiet-hours.yml
params:
  command:      { type: list }
  lead_minutes: { type: integer, default: 30 }
freezes:
  - { id: F-OPEN, applies_to: [promote.to_stable], source: command,
      command: "{{command}}", kind: open_hours, lead_minutes: "{{lead_minutes}}" }
```

A shop could include the same `release-train` with its own sale-hours calendar, and a school with its class timetable. The module stays the same; only the parameters change.

### Try it

From a clone:

```sh
bin/polispec validate policy examples/clinic/policy.yml
bin/polispec validate module examples/clinic/modules/release-train.yml
```

On a real project, `polispec apply environment-control --repo <repo>` scaffolds the same three files ([quick start](#quick-start)). `polispec resolve <path> --layers` then shows exactly which layers and modules govern a path.

## How a verdict is made

Every tool call an agent makes passes through the same steps. Nothing in this path asks a model; it is deterministic.

```
 agent tool call (shell command, file write, MCP call, web fetch, subagent spawn)
        │
        ▼
 1. classify     what kind of action is this?   git.push · fs.write · secrets.read · data.copy · deploy …
        │
        ▼
 2. locate       which project and which copy?  path, branch, remote, unit file, database → project + env
        │
        ▼
 3. load         read the rulebook from the trusted branch (stable), never from the working tree
        │
        ▼
 4. compose      global layer → profile modules → repo policy + its modules → nested child projects
        │
        ▼
 5. match        first matching rule in each layer; the strictest verdict across layers wins
        │
        ▼
 6. cap          deterministic harness controls may only tighten that verdict, never loosen it
        │
        ▼
 7. answer       allow · warn · deny, with the rule id, the reason, and the next step
```

1. **Classify.** A command like `git push origin stable` or `rm -rf data/` becomes one or more *action classes* such as `git.push` or `fs.delete`, with facts about it (the branch, the path, whether it is destructive). Shell commands are parsed; they are not pattern-matched as raw text.
2. **Locate.** polispec finds the project and the environment the action touches. A path inside the live checkout is `prod`. A push to `test` is `test`. A database name, service unit, or secret file can identify an environment too. When ledgered projects nest, the outermost one owns the path.
3. **Load.** The policy and environments come from the project's trust ref. If they cannot be loaded for a live project, an enforcing guard refuses every non-read action rather than guessing.
4. **Compose.** The effective rulebook is assembled from layers and modules. See [composition](#composition-specs-inside-specs).
5. **Match.** Within a layer the first matching rule wins. Across layers the strictest verdict wins (`deny` beats `warn` beats `allow`). A lower layer can loosen an upper rule only if that rule is marked `overridable` and the lower rule names it.
6. **Cap.** Optional harness controls (`polispec.control/v1`) act as an independent severity ceiling. They can turn an allow into a deny; they can never do the reverse.
7. **Answer.** The verdict goes back to the harness with the rule id, the reason, and a way forward. In `advise` mode every verdict is logged and nothing blocks; in `enforce` mode the verdict is applied.

Promotions and deploys run through the same rulebook: `polispec promote` checks the actor, the gates, the freezes, and the soak, then moves the branch and records the result.

## Composition: specs inside specs

A polispec rulebook is built from parts. Each part can contain other parts, to any depth, and the result stays predictable because the composition rules are few and strict.

**Modules include modules.** A module is a named file of rules, gates, freezes, and hermetic settings. A policy, the global layer, and any module may `include` modules. Includes expand depth-first, each instance is used once, and a cycle is an error.

```
policy.yml
├── patient-data
└── release-train  (soak_hours: 24, lead_minutes: 60)
    ├── soak         (hours: 24)
    └── quiet-hours  (lead_minutes: 60)
```

**Modules come from two shelves.** The *global shelf* is shared by every project on the host (`polispec.global.repo`, `modules/<name>.yml`). The *project shelf* is a project's own `specs/polispec/modules/`, read from the same trusted branch as its policy. A project module may include project and global modules. A global module sees only the global shelf. A name that exists on both shelves is an error, so an include always means exactly one file.

**Modules take typed parameters.** A module declares `params` with a type (`string`, `integer`, `number`, `boolean`, `list`) and an optional default. An include passes values with `{ module: name, with: { … } }`. A value written as exactly `"{{name}}"` keeps its type; a placeholder inside longer text is interpolated. A missing, unknown, or mistyped parameter is an error. The same module included twice with different parameters gives two instances, and if two instances produce the same rule or gate id, that is an error too.

**Layers stack, and the strictest wins.** The effective policy for a path is a stack:

| Layer | Comes from | Contributes |
|---|---|---|
| global | the host's global shelf: `global.yml` and its modules | rules, gates, freezes, hermetic, protected roots |
| profile | modules the ledger profile requires (`personal`, `service`, `live`) | the same, as part of the global layer |
| repo | the project's policy and the modules it includes | rules, gates, freezes, hermetic |
| child, child, … | every ledgered project nested inside the repo down to the path, nearest last | rules, gates, freezes, hermetic, and their own modules |

Rules merge by severity: a lower layer cannot loosen an upper rule unless the upper rule says `overridable: true` and the lower rule names it in `overrides`. Gates, freezes, and hermetic settings accumulate. A gate contributed by a nested project runs in that project's directory. If a nested project's gate or freeze reuses an id that is already taken, that is an error, not a silent replacement.

**Nothing is dropped silently.** Every composition problem is reported. That covers a missing or ambiguous module, a parameter error, a cycle, an id collision, and an invalid override. `polispec validate`, `polispec doctor`, and `polispec resolve --layers` all show it, and `polispec promote` refuses to run with fewer gates than the rulebook declares.

```sh
polispec resolve services/api/handler.rb --layers
```

That command prints every layer that governs the path, with its source, digest, rule count, and module instances, plus one effective digest for the whole stack.

The same idea runs through [code specs](docs/code-specs.md). A spec is a tree of policies mounted at paths such as `code`, `code/ruby`, and `code/ruby/code_quality`. A policy with subpolicies is composite, and the chain for a language collects every spec that applies.

## Core ideas

| Term | Meaning |
|---|---|
| **Project** | A repository polispec governs, listed in the host's *ledger*. `onboarding` projects are checked but not enforced; `live` projects are enforced. |
| **Environment** | One copy of the project, such as dev, test, or prod. Each has a branch, a checkout, data, services, and a deploy with a health check (`environments.yml`). |
| **Trust ref** | The branch the rulebook is read from, normally `stable`. Agents cannot move it. |
| **Rule** | A match (environment, action class, path, ref, tool …) plus a verdict and a reason. |
| **Action class** | What an action *is*: `git.push`, `fs.write`, `secrets.read`, `data.copy`, `deploy`, `mcp.call`, `agent.spawn`, and so on. |
| **Gate** | A check a promotion must pass: a command (`run`) or a built-in (`clean_tree`, `soaked`, `sha_ran_on_test`, `not_frozen`, `logs_quiet` …). |
| **Freeze** | A window in which a promotion is refused: manual, recurring, or read from a command such as a calendar. |
| **Module** | A reusable, parameterised piece of policy, on the global or the project shelf. |
| **Layer** | One level of the composed policy: global, repo, or a nested child. |
| **Operator** | The person who moves `stable`, waives a soak, redeems an allow-once, or pauses a project, always from a terminal with a typed phrase. |
| **Roster** | Which harness, model, and effort each agent role gets. |
| **Seal** | An optional root-owned authority plane that pins the runtime and the global layer, so an agent cannot redirect them. |

## Feature tour

**Environment guard.** One guard hook per harness judges every tool call ([operator guide](docs/operator.md)). `polispec.enforce` is `advise` by default (log only) and `enforce` to apply verdicts. Undeclared MCP calls and unknown non-read actions in governed scope ask (standard edition) or deny (lock edition).

**Promotion and deploy.** `polispec promote <project> --to <env>` fast-forwards one hop (main → test → stable, or any named hops such as a canary ring). It runs that hop's gates and preflight, checks freezes and the soak, tags the release, and runs the deploy. `polispec deploy` runs the environment's steps, a health check, and an automatic rollback for `release_dirs` deploys. A policy that deploys without a health check is refused. The operator may waive a soak (`--waive-soak`) with a typed phrase, and the waiver is recorded.

**Freezes.** Manual windows, recurring rules, or a command that prints JSON windows. The command can be another project's calendar, as in the classroom pattern where releases stop before class and before deadlines.

**Hermetic runs.** `hermetic.<env>` isolates environment variables into scratch space and fails a gate or step that writes under a protected root.

**Data classes.** Declare where each kind of data may live; `data.copy` across classes is refused.

**Git hooks.** `polispec hook git install <project> <env>` adds the same judgement to plain `git` outside any harness. It is a seatbelt, not a security boundary.

**`[ENVS]` directive.** `polispec agents render` writes a one-line summary of the environments into the project's `AGENTS.md` and `.agents/directives/envs.md`. `doctor` reports when the summary drifts from the trusted rulebook.

**Roster.** `specs/polispec/roster.yml` assigns harness, model, and effort per role. Session and subagent start inject the values ([roster](docs/roster.md)).

**Behavioral policy.** A separate contract for an application's own directives, parameters, and enforcement bindings. It is compiled to data that the application's adapter consumes, with no running polispec service ([behavior](docs/behavior.md)). Since 0.34.0 a v2 document also owns every surface a rule reaches (rows, rules files, stubs, persona and skill files, messages), renders them, and fails on drift or on a rule restated without its id.

**Code specs.** When an agent writes a file, polispec detects the language and applies the code specs from the code specs repository (`~/.polispec/specs`, read from its `stable` branch). The spec chain is injected before the first write. MUST violations on changed lines are refused; SHOULD violations are reported. Agent-judged policies are reviewed at task end, and a ratchet baseline keeps legacy code from blocking new work ([code specs](docs/code-specs.md)).

```sh
polispec code chain app.rb
polispec code check app.rb --json
polispec code controls
polispec specs promote
```

**Harness controls and sealed authority.** Harness controls are on by default since 0.23.0 (`harness_controls`): the guard caps every verdict with the installed controls, asks about unknown non-read calls and undeclared MCP operations in governed scope, and `harness install` and `verify` work. Built-in harness tools and read-only shell commands are recognised and stay allowed. The sealed plane stays off (`sealed_plane`), so sealing, the authorizations service and uninstall remain gated, except that since 0.24.0 you may remove your own user- or project-scope overlay on an unsealed host by typing `uninstall INSTALLATION_ID` on a terminal. Lines that run `eval`, `source` or `.` ask, since what they run cannot be seen. Declare the MCP operations you use (an exact `server` and `operation` in a rule of your global shelf or project policy) before you install a release with controls on, or every MCP call asks. Backends cover Claude Code, Codex, Hermes, Antigravity CLI, and OS sandbox planning. Capability reports keep generated artifacts, parser acceptance, native enforcement, and lock certification separate. The `polispec-lock` branch is the same code with `EDITION` set to `lock`; one edition is selected per installation ([harness controls](docs/harness-controls.md)).

```sh
polispec harness grammar --json
polispec validate control examples/controls.minimal.yml --json
polispec harness plan examples/controls.minimal.yml --harness codex --scope project --project /absolute/project --json
polispec plane status --json
```

**Plan and apply.** Every rulebook change, from putting a project under polispec to editing the global shelf, is previewed with `polispec plan` and carried out with `polispec apply`. A plan judges probe actions and, when the journal is on, recent real actions against the current and the proposed rulebook, and classifies the change as tightening, loosening, mixed, or neutral. Loosening needs the plan id as a confirmation, and the guard asks the user before an agent gives it ([packages, plan and apply](docs/packages.md)).

```sh
polispec plan project:clinic-booking
polispec apply project:clinic-booking --confirm plan_3f9c0d2e1a7b4c58e6d09a12
```

**Packages.** A package is a named, versioned setup: templates, modules, parameters, and ordered steps. `environment-control` (variants `service` and `distributed`) is the first. The ledger records each package a project carries, `doctor` reports available upgrades and edited files, and an upgrade never overwrites a file you changed.

**Smoke ledger and suite.** polispec ships a smoke suite and records smoke tests. `polispec smoke run` runs the bundled scenarios against the tree it runs from, in scratch fixtures, compares every verdict with another release (`--against`), replays probes on copies of your ledger (`--host-copy`), and drives real Claude Code and Codex sessions (`--live`). Each entry names the spec node it proves, the verdict, the steps, the evidence digests, and the runtime, with no host or user identity. Entries are chained, `verify` detects edits, and `coverage` shows which units have a current pass ([smoke](docs/smoke.md)).

**Judgment records.** Every call the guard judges leaves one chained record: what was judged (tool, harness, session, a digest of the call), against which rulebook (each project's policy digest, the matched rule, one row per classified action), by which polispec (version, runtime, commit, edition, enforce mode), and what the harness was told. Allows are recorded too. The record holds no command text unless `polispec.records.raw` is on. `polispec judgments list|show|verify` reads the stream, `doctor` reports a broken or truncated chain, `digest` and `plan` are built from it, and a copy without raw text goes through the events port. The shim counts the calls its fast path skipped beside it ([operator guide](docs/operator.md), [schema](docs/schema.md)).

```sh
polispec smoke record --spec specs/app.yml --at commands/resolve --verdict pass --summary "resolve named the stable checkout prod"
polispec smoke verify
polispec smoke coverage
polispec smoke run --against ~/.rplugins/polispec
```

**Web app.** `polispec web` serves a local web app over the files polispec already keeps: a map of every governed project and path with the layers that reach it, the pipeline from `main` to `stable`, live sessions and judgments, a heatmap of rule hits, a playground and explainer for why a call was judged, a manager and gallery for changing rulebooks, exceptions, registration, and the manifest. It has no database. Every change is a plan, the same plan `polispec plan` prints: a tightening or neutral plan that is not global applies on one click, a loosening, mixed, global, move, reorder, regroup, or status plan applies only after the person types the plan id, and an operator action (promote to stable, deploy, pause, allow-once, seal, plane) is shown as the exact command to run in a terminal and never as a button. It listens on `127.0.0.1:7421` by default, trades a one-time link for an `HttpOnly` session cookie, requires a CSRF header and a matching `Origin` on every change, and is excluded from the lock edition. An agent never drives its API: a call that does warns with `G-WEB-AGENT`, and an agent that wants the user to make a change points them to `polispec web`. An optional author panel drafts rulebooks from an intent in plain words, read-only and behind a kill switch (`POLISPEC_AUTHOR=off`) ([web app](docs/web.md)).

```sh
polispec web
polispec web --read-only
polispec web url
```

**Descriptions.** Since 0.35.0 every rulebook may carry a `description` beside its one-line `summary`: the prose a person reads on a card about what the rulebook governs, for whom, and what it refuses. `polispec validate` lints it without a model call and reports a warning, or an error when `polispec.description.strict` is `on`; the guard never reads it for a verdict. A policy that uses one is invalid to a runtime older than 0.35.0, so write descriptions into live rulebooks only after 0.35.0 is pinned on every host that reads them ([schema](docs/schema.md#description), [rollout](docs/operator.md#rolling-out-0340)).

**Effect and the epoch notice.** The guard follows every policy change on the next call; the epoch, the change records, and the session records show which running sessions have crossed over and what still needs a new session, a reload, or a trust review. `polispec changes list|show|verify|await` reads the chained change records, `polispec sessions list` the sessions, and `doctor` reports a stale launcher and, for Codex, an untrusted hook. On the first call of a session after its epoch changes, the hook adds one bounded line naming the change, once per session per epoch; `polispec.notice off` turns it off ([when a change takes effect](docs/effect.md), [the epoch notice](docs/operator.md#when-a-change-lands-the-epoch-notice)).

```sh
polispec changes list --since 24h
polispec changes await chg_3f9c0d2e1a7b
polispec sessions list --active 1h
```

**Registration.** `polispec register <path>` puts software, a directory, or the system scope that is not a git repository under polispec, as a governed path entry in the ledger with its owner and who registered it. It is a ledger plan: an onboarding entry tightens and applies directly, and `polispec unregister <id>` retires one with a confirmed plan id. The `polispec-register` skill interviews the person and proposes the entry and a starter policy ([schema](docs/schema.md#registering-software-directories-and-the-system-scope), [operator guide](docs/operator.md#registering-software-directories-and-the-system-scope)).

```sh
polispec register ~/tools --id tools --kind directory --dry-run
polispec register ~/tools --id tools
```

**Manifest and index.** `polispec manifest <id>` prints the generated manifest of a project or path (`polispec.manifest/v1`: owner, environments with digests, the layer chain, roster roles, edition, findings, and a badge); `--write` commits it and an SVG badge on `main`. An app may describe itself in a `polispec.app.yml` that the manifest shows beside the generated one and that grants nothing. `polispec manifest index --publish` shares the owner and description of what a user governs with other users of the host, and the web app shows what others published ([schema](docs/schema.md#manifest-polispecmanifestv1-and-the-index-polispecindexv1), [publishing the index](docs/operator.md#publishing-the-index)).

**Editions.** `specs/editions.yml` lists every feature that differs between the standard edition and the lock edition, as included, restricted, or excluded. The web app, the author, the exceptions delegate, and the published index are excluded from lock, and registering a governed path is restricted to the protected ledger. `polispec editions --check` and `doctor` report drift between the registry and the code ([schema](docs/schema.md#editions-specseditionsyml-polispeceditionsv1), [harness controls](docs/harness-controls.md)).

**Deployment receipts.** `polispec status <project> --json` includes `projects[].deployments` (contract `polispec.status.deployments/v1`). Each environment carries `receipt`, `latest_attempt`, and `verified`:

- **Receipt.** It identifies the last successful deployment by record id, SHA, tag, health, pin status, and time.
- **Verified.** This requires the receipt to match the latest attempted deployment, with health `ok` and no pin.
- **Fails closed.** An in-progress or newer failed attempt, an unchecked health result, or a legacy receipt without record identity all count as unverified.

Consumers must also match the current remote environment ref and tag, because branch promotion alone does not prove deployment. The field exposes no state paths, health output, or secrets. It is evidence from deployment time, not continuous health.

## Looking after polispec itself

polispec guards every agent on the host, so a broken polispec breaks every agent at once. 0.21.0 adds a pattern for changing polispec and its rulebooks safely:

- **A shipped rule for agents.** `rules/polispec-stewardship.md` ships with the plugin. Claude Code (through `polispec install`, `polispec steward`, or rplugin 1.15.0 or later) and Antigravity CLI load it as an always-on rule; Codex, Hermes, Pi and the DeepSeek TUI have no rules directory and reach it through the polispec skill and the `[POLISPEC]` directive. It tells agents that the running polispec is live, that they build changes in a separate worktree and ship them by release, that every rulebook change is planned before it is applied, and which changes need the user's yes.
- **A pinned runtime.** `polispec pin --ref <tag>` (or `rplugin install <repo> --ref <tag>` on an rplugin host) installs a read-only copy of one release. polispec knows whether it runs from a pinned release or a working clone (`polispec doctor` prints `runtime:`).
- **Self-protection.** A built-in protected root covers the runtime: writes into a pinned release are denied, and writes into a clone runtime are warned (`R-POLISPEC-RUNTIME`).
- **One switch.** `polispec steward` (or `polispec apply --with-stewardship` before an apply) checks the rule is installed, checks the protection, and pins a clone runtime to the release it is running, before applying anything.

The full procedure is in the [operator guide](docs/operator.md#the-runtime-and-stewardship).

## Install

polispec needs Ruby 2.6 or later and git, and no gems beyond the standard library. It works with Claude Code and Codex out of the box. Pick one way in:

**One line.** Fetches the latest release, pins it read-only under `~/.local/share/polispec`, puts `polispec` in `~/.local/bin`, wires the guard into every harness it finds (Claude Code, Codex), and creates an empty starter ledger when the host has none:

```sh
curl -fsSL https://raw.githubusercontent.com/SteveBenner/polispec/main/install.sh | sh
```

`POLISPEC_REF=v0.27.0` picks a release, `POLISPEC_HARNESS=claude` (or `codex`, or `claude,codex`) picks the harnesses, and `POLISPEC_DRY_RUN=1` shows every step without changing anything. Read [`install.sh`](install.sh) first if you prefer; it is short.

**From a clone.** The same steps by hand:

```sh
git clone https://github.com/SteveBenner/polispec.git && cd polispec
bin/polispec pin                        # read-only copy of this release; links ~/.local/bin/polispec
polispec install --harness claude       # or codex, or all; --scope project for one repository; --dry-run to preview
```

`polispec install` adds three hooks (before every tool call, at session start, at subagent start) to `~/.claude/settings.json` or `~/.codex/config.toml`, links the skill and the rules, backs up every file it changes beside the original, and keeps every hook that is not its own. `polispec uninstall --harness <name>` takes out exactly what it added. Codex asks you to trust new hooks the next time it starts.

**As a Claude Code or Codex plugin.**

```sh
claude plugin marketplace add SteveBenner/polispec && claude plugin install polispec@polispec
codex plugin marketplace add SteveBenner/polispec && codex plugin add polispec@polispec
```

The plugin brings the hooks and the skill. It runs from the harness's plugin cache, which polispec cannot protect, and it puts no `polispec` on your `PATH`. Ask your agent to "set up polispec stewardship", or run `bin/polispec steward` from the plugin's directory, to pin a read-only release and link the rules. Use the plugin or `polispec install`, not both: the guard would run twice, and `polispec install` refuses when it sees the plugin.

**As a gem.** `gem build polispec.gemspec && gem install polispec-*.gem` from a clone gives you `polispec`; then `polispec pin` and `polispec install` as above.

**With rplugin.** If you already use the [rplugin SDK](https://github.com/SteveBenner/rplugin) for agent-harness plugins (1.17.0 or later): `rplugin install polispec`, then `rplugin doctor polispec`. This is the path for Hermes, Pi, the DeepSeek TUI, and Antigravity CLI as well. `rplugin install <polispec clone> --ref v<version>` pins a release. On an rplugin host, `polispec steward` pins and links through rplugin as before.

polispec starts in `advise` mode: it logs every verdict and blocks nothing. When the rulebook is ready, `polispec settings set polispec.enforce enforce`. Check the result any time with `polispec doctor`.

## Agent skills

The plugin packages three skills for AI models:

- [`polispec`](skills/polispec/SKILL.md) locates the installed CLI, resolves the target environment and governing layers, explains verdicts, and routes operational tasks.
- [`polispec-specs`](skills/polispec-specs/SKILL.md) creates and modifies specs through the appropriate validation, planning, approval, and release workflow. It distinguishes environment rulebooks, application behavioral policies, code-spec packs, and ordinary application contracts.
- [`polispec-register`](skills/polispec-register/SKILL.md) registers software or directories outside governed repositories without editing the ledger or shelf directly.

Skills refer to the installed plugin's documentation and schemas, preserve the user's authorization boundaries, and distinguish a validated draft from the trusted policy in effect. They ship through the plugin installers; no personal skill-directory copy is required.

## Quick start

```sh
polispec plan  environment-control --repo <repo>                       # preview
polispec apply environment-control --repo <repo> --with-stewardship    # protect the host, then scaffold
polispec doctor                                                        # what is missing or invalid
polispec resolve .                                                     # which project and environment is this?
```

Applying the `environment-control` package does the setup in one pass:

- It scaffolds `specs/polispec/environments.yml`, `policy.yml`, and `roster.yml` from a template (`--variant service` for a hosted service, `distributed` for software users install).
- It points the component manifest at them.
- It adds a ledger entry with status `onboarding`, records the package and the files it wrote, and renders the `[ENVS]` row. On a host with no ledger yet, it first creates a starter ledger at `~/.config/polispec/ledger.yml` (no projects, default rules only), and the plan shows that as a tightening change.

The ledger is the list of projects polispec governs on this host. `polispec install` (and so `install.sh`) creates the starter ledger when there is none, and `polispec ledger init` creates it on its own. Neither ever overwrites an existing ledger. A starter ledger changes no verdict: its default rules apply only to projects listed in it, and it lists none.

`--with-stewardship` first makes sure the host is safe to change: the installed plugin carries the stewardship rule, and the polispec runtime is pinned to a read-only release ([stewardship](#looking-after-polispec-itself)). Add `--commit` to commit exactly the scaffold files on main, and add `--push` to publish main, test, and stable as well. Replace the placeholder health check before the first deploy. The operator flips the ledger status to `live` when the rulebook is ready to enforce.

## Commands

| Command | Purpose |
|---|---|
| `polispec pin [--ref <tag>] [--source <repo>] [--dry-run]` | Install a read-only copy of one release under `~/.local/share/polispec/releases/` and point `current` and `~/.local/bin/polispec` at it; older releases stay as the rollback |
| `polispec install` / `uninstall --harness claude\|codex\|all [--scope user\|project] [--dry-run]` | Wire the guard hooks, the skill and the rules into Claude Code or Codex without rplugin, with in-place backups and a receipt; uninstall removes only what install added |
| `polispec ledger init [--dry-run]` | Create a starter ledger (no projects, default rules) at the resolved ledger path when the host has none; never overwrites one, and refuses on a sealed host |
| `polispec settings list\|get\|set\|unset` | Show and change settings without rplugin, in `~/.config/polispec/settings.yml`; rplugin's settings and environment variables still win where present |
| `polispec steward [--check]` | Protect the host: the stewardship rule installed, the runtime protected, the runtime pinned; `--check` only reports |
| `polispec plan <target>` | Preview a change: files, ledger, composed policy diff, verdicts that would change, and whether it tightens or loosens |
| `polispec apply <target> [--confirm <plan-id>] [--with-stewardship]` | Carry out a plan; loosening, mixed, and global changes need `--confirm`. Targets: a package such as `environment-control --repo <repo>`, `project:<id>`, `global`, `ledger --from <file>` |
| `polispec validate <kind\|auto> <file> [--json]` | Check a policy, environments, roster, ledger, global, module, profiles, behavior, control, smoke, or judgment file |
| `polispec resolve <path> [--layers] [--json]` | Name the project, environment, and layers that govern a path |
| `polispec doctor` / `status <project>` / `digest` | Report findings, project state, deployment receipts, and a daily digest |
| `polispec promote <project> --to <env> [--dry-run]` | Move code one hop through the gates |
| `polispec deploy <project> <env> [--tag vX.Y.Z]` | Deploy an environment with a health check and rollback |
| `polispec pause` / `allow-once` | Operator-only: pause a project, or redeem a single warned action |
| `polispec exceptions list\|add\|promote\|remove` | Persistent exceptions to guard asks, kept in the global shelf; changes are operator-only |
| `polispec agents render <project\|repo>` | Write the `[ENVS]` directive from the trusted rulebook |
| `polispec hook git install <project> <env>` | Install git hooks that apply the same rules outside a harness |
| `polispec roster resolve\|check` | Resolve and check role assignments |
| `polispec behavior compile\|decide\|render\|drift\|lint` | Compile and evaluate a behavioral policy; render its surfaces, check them for drift, and lint for restated rules (v2) |
| `polispec code …` / `polispec specs …` | Code specs: detect, chain, check, baseline, controls; link and promote the specs repository |
| `polispec harness …` / `seal` / `plane` / `authorizations` | Harness controls and the sealed authority plane |
| `polispec smoke record\|list\|show\|verify\|coverage\|run` | The smoke ledger and the bundled suite |
| `polispec judge serve\|status\|stop` | The resident judge that answers the guard hook from memory over 127.0.0.1 with a cold fallback; `POLISPEC_JUDGE=off` skips it, `POLISPEC_JUDGE_BUDGET` (seconds, default 0.5) bounds the launcher's wait, `POLISPEC_JUDGE_IDLE` (seconds, default 1800) ends an idle judge ([operator guide](docs/operator.md#the-resident-judge)) |
| `polispec judgments list\|show\|verify` | The chained record of every judged call, and a count of the calls the fast path skipped |
| `polispec web [--bind ADDR] [--port N] [--read-only] [--open]` / `web url` / `web token set` / `web unit` | Serve the local web app, print a fresh one-time link, store the delegate token, or print a systemd user unit ([web app](docs/web.md)) |
| `polispec author draft <kind> --intent TEXT` / `author adapters` | Draft a rulebook with an AI session that can only read; it writes nothing |
| `polispec register <path>` / `unregister <id>` | Govern software, a directory, or the system scope that is not a git repository, through a ledger plan |
| `polispec manifest <id> [--write]` / `manifest index [--publish]` | Generate a project or path manifest, commit it with its badge, and publish the host index |
| `polispec changes list\|show\|verify\|await` / `sessions list` | The chained change records, how many running sessions crossed over, and the sessions the guard has seen |
| `polispec editions [--check]` | Print the edition registry or check it for drift |

`specs/app.yml` is the full contract for every command.

## Settings

Change settings with `polispec settings set <key> <value>`, which writes `~/.config/polispec/settings.yml` (`POLISPEC_SETTINGS` names another file), or on an rplugin host with `rplugin settings`. Each setting also has a short environment variable for one run: `polispec.enforce` is `POLISPEC_ENFORCE`, `polispec.code.check_at` is `POLISPEC_CODE_CHECK_AT`, and so on (`polispec.operator` is `POLISPEC_OPERATOR_NAME`; `polispec.edition` has none). Unsealed, a value is taken from the first of: the `RPLUGIN_POLISPEC_*` variable, the short variable, rplugin's settings, the settings file, the default. `polispec settings list` shows each value and where it came from. A sealed installation resolves protected settings first and ignores the settings file, the short variables, and authority redirects from the calling process.

- `polispec.enforce`: `advise` (log verdicts, never block) or `enforce`; default `advise`. It governs environment and enabled harness-control verdicts. Code specs have their own settings: `polispec.code.enforce` (`advise` or `tiered`), `polispec.code.check_at` (`pre_write` or `post_write`), and `polispec.code.inject` (`once` or `every_write`).
- `polispec.ledger`: path of the ledger of governed projects; default `~/.config/polispec/ledger.yml`. `POLISPEC_LEDGER` overrides it.
- `polispec.edition`: `standard` or `lock`, default `standard`. The lock branch requests lock regardless of a mutable downgrade. A request alone does not certify enforcement.
- `polispec.root_guard`: initially `false`. Recorded exposure can arm it, and lock fallback forces it on.
- `polispec.operator`: how messages name the person who promotes to stable; default `the operator`.
- `polispec.code.specs_repo`: path of the code specs repository; default `~/polispec-specs`. `POLISPEC_SPECS_REPO` overrides it.
- `polispec.smoke.path`: path of the smoke ledger. Empty means `smoke.yml` at the git toplevel of the working directory. `POLISPEC_SMOKE` overrides it.
- `polispec.smoke.live`: `on` (default) or `off`. Off stops `polispec smoke run --live` from launching any harness session; `POLISPEC_SMOKE_LIVE=off` does the same for one run.
- `polispec.relax.dev`: `on` (default) or `off`. On, the `in_development` predicate holds when a directory lies only in ledger projects with status `onboarding` (projects in development), so the shipped rule `TOOL-OPAQUE-DEVELOPMENT` lets a governed `eval`, `source` or `.` line through without the `POLISPEC-TOOL-UNKNOWN` ask; off makes the predicate false everywhere and restores the ask. `POLISPEC_RELAX_DEV=off` does the same for one run.
- `polispec.exceptions`: `on` (default) or `off`. Off honors no entry of the global shelf's `exceptions.yml`, records no proposal and adds no promote hint to asks.
- `polispec.records.raw`: `off` (default) or `on`. When on, each judgment record also keeps the classifier's raw view of the command or target, at most 2048 bytes, in local state only; it never goes through the events port.
- `polispec.web.bind` (default `127.0.0.1`), `polispec.web.port` (default `7421`; `0` picks a free port), `polispec.web.public_origin` (optional exact HTTPS origin for an external proxy; empty by default), and `polispec.web.theme` (`system`, `light`, `dark`, `apple-noir`, `apple-austere`, or `tronwave`; default `system`): the web app. A public origin supplies HTTPS links, exact Host/Origin checks, and Secure cookies; it does not expose the listener. A bind address that is not a loopback address needs `--expose` and a typed phrase ([web app](docs/web.md)).
- `polispec.author.enabled`: `on` (default) or `off`; `POLISPEC_AUTHOR=off` does the same for one run. Off refuses every author request. `polispec.author.adapter` names the built-in adapter, default `harness-cli`.
- `polispec.description.strict`: `off` (default) or `on`. On, a missing or failing description is an error in `validate` instead of a warning ([schema](docs/schema.md#description)).
- `polispec.notice`: `on` (default) or `off`. Off stops the hook from adding the one-line epoch notice ([effect](docs/effect.md)).
- `polispec.global.repo`, `polispec.global.ref` (default `main`), and `polispec.global.path` (default `polispec`): where the optional global shelf of shared rules, modules, and profiles is read from. Unset means no global layer. `POLISPEC_GLOBAL` points at a plain directory for scratch runs. See [schema](docs/schema.md).

Optional integrations: none is required. Policy `observability.events` may name an `rlogs` sink, and `polispec apply environment-control` recognises a `*.rstack_component.yml` manifest as well as `*.rplugin.yml`.

## Compared to alternatives

| Tool | What it does well | What polispec adds |
|---|---|---|
| **Branch protection** (GitHub, GitLab) | Stops pushes to a branch on the server. | Judges the action *before* it leaves the machine, covers more than git (files, services, secrets, data copies, MCP calls), and explains the way forward. Branch protection is still worth keeping. |
| **CI/CD pipelines** | Run checks after code is pushed. | Gates run as part of the promotion itself. Freezes, soak periods, and operator phrases are part of the rulebook, and the same rulebook governs the agent's every action in between. |
| **OPA / Rego and other policy engines** | General-purpose policy over any JSON input. | A ready model of the agent-development domain: environments, promotion hops, action classes, freezes, rosters, and a classifier that turns real tool calls into those terms. You write YAML in that vocabulary instead of building the model yourself. |
| **Harness permission settings** (allow/deny lists in an agent tool) | Quick per-tool rules for one harness. | One rulebook for every harness, read from a trusted branch rather than from user-editable settings, aware of which copy of the project a path belongs to, and composable across projects. polispec can generate native harness controls from the same grammar. |
| **Code review** | A person reads the change. | Review still matters. polispec makes sure the change reaches users only through the path where review and checks happen. |

## Current State of Polispec

polispec is pre-1.0 software in daily use by its maintainer. The guard is deterministic and is backed by a bundled smoke suite that includes live Claude Code and Codex sessions. The sealed plane ships disabled, the default mode is `advise`, and native enforcement is verified only for some harnesses.

On 14 October 2026, an acquaintance working in AI research independently reviewed polispec **0.19.1**. They found a promising architecture and unusually candid documentation of its verification gaps. They asked for a smaller, harder, reproducible enforcement matrix before any broad claim of native protection. We intend to act on the review's recommendations. Its two highest-priority items come first: reproduce the post-write failure and prove prevention, and test the authority boundary's failure modes. Until both are done, polispec makes no claim of preventive enforcement.

[`docs/CURRENT-STATE.md`](docs/CURRENT-STATE.md) has the full picture: each finding, where it stands in the current release, and what comes next. The review itself is kept unchanged in [`independent/assessments/2026-10-14-peer-review/`](independent/assessments/2026-10-14-peer-review/).

## Honest limits

- **Unsealed polispec is a guardrail, not a security boundary.** Without the sealed authority plane, a process with your user's rights can change settings, edit the ledger, or bypass the hook. It stops agents from doing the wrong thing by accident or by drift. It does not stop a determined adversary on the same account.
- **Advise mode blocks nothing.** The default is `advise`. Enforcement starts when you set `polispec.enforce` to `enforce` and the operator flips a project to `live`.
- **Native enforcement is verified per harness, and not everywhere.** Capability reports state what was observed. Hermes and Antigravity runtime enforcement is unverified on the release host, and Pi and the DeepSeek TUI receive skills only. Lock certification needs observed evidence, and none is claimed.
- **The sealed plane ships disabled.** Harness controls are on, but without a sealed plane a harness with no native ask (Codex) resolves a control ask as a denial; environment-policy warnings still get an allow-once id.
- **Classification is deterministic, so it can miss.** An action that hides its effect from the classifier (a renamed binary, a program that shells out, a script reached through `PATH` or run by a non-shell interpreter) is judged by what it appears to be. Since 0.32.1 a shell script the line runs by path (`bash run.sh`, `./run.sh`) is read and its commands judged, and one that cannot be read makes the line opaque. Unknown non-read actions in governed scope ask or deny rather than allow, which narrows that gap.
- **Git hooks are a seatbelt.** They help with plain `git` outside a harness, and `--no-verify` skips them.
- **The smoke suite proves what it covers.** Units behind the sealed plane (`plane`, `authorizations`, `protected_authorizations`) record `blocked`, and `--live` runs cost money.
- **Deployment receipts are evidence from deployment time.** They are not continuous health monitoring.

## FAQ

**Does polispec call an AI model to decide?**
No. Environment verdicts, gates, freezes, and composition are deterministic. Only some code-spec policies (`agent`, `hybrid`, `contextual`) use a model, and they are labelled as such.

**Can an agent change its own rules?**
It can edit the files on `main`. That edit is a `policy.edit` (warn), and it has no effect until the operator promotes it to the trust ref. The guard never reads the working tree. `polispec plan project:<id>` shows whether such a change loosens anything, and applying a loosening plan needs the user's confirmation.

**Can an agent break polispec itself?**
It is told not to (`rules/polispec-stewardship.md`), and a pinned runtime denies writes into itself. On a host still running from a working clone, writes into the clone are warned, and `polispec apply --with-stewardship` pins it.

**What happens if the rulebook is broken?**
For a live project whose policy cannot be loaded, the guard falls back to the global layer's `fallback_rules` (or the ledger defaults). With no usable rules at all, it refuses non-read actions. A composition error makes `promote` refuse rather than run with fewer gates.

**Do I need the rStack platform or a running service?**
No. polispec is a plugin built on the rplugin SDK. It also runs from a plain clone with Ruby's standard library. Integrations such as an `rlogs` event sink are optional.

**Can one rulebook cover several projects?**
Yes. Shared rules go on the global shelf as modules, profiles bundle them by how much a project serves, and nested projects stack beneath their parent. See [composition](#composition-specs-inside-specs).

**What if my release path has more than three steps?**
Environment names and hops are free: `main → test → canary → stable` works, each hop with its own gates, actor, and phrase.

**How do I see why a verdict happened?**
The verdict names the rule id and the layer. `polispec resolve <path> --layers` shows the whole stack, and every judged call leaves a chained record (`polispec judgments list`, `show <id>`) naming the rulebook digest, the rule, the polispec that judged it, and the reply the harness received.

## Where polispec is going

Today polispec governs where an agent may act and how code travels to users. With recursive composition in place, it can grow into a shared, versioned library of operating practice. Imagine an organisation's release, data, and quality rules as importable, parameterised specs that every project and every agent inherits and can prove it follows. [`docs/VISION.md`](docs/VISION.md) lays out that direction, with each item marked **Built**, **Partial**, **Planned**, or **Idea**.

## Documentation

- [`docs/CURRENT-STATE.md`](docs/CURRENT-STATE.md): where polispec stands today, the independent review of 0.19.1, and the plan that follows from it.
- [`docs/schema.md`](docs/schema.md): every key of the policy, roster, ledger, global layer, modules, and profiles, with examples.
- [`docs/environments.md`](docs/environments.md): the environment manifest, applying environment control, `[ENVS]`, and git hooks.
- [`docs/packages.md`](docs/packages.md): packages, `plan`, `apply`, classification, verdict replay, and `--with-stewardship`.
- [`rules/polispec-stewardship.md`](rules/polispec-stewardship.md): the rule agents follow when they install, change, or repair polispec and its rulebooks.
- [`docs/operator.md`](docs/operator.md): sealed authority, protected allow-once, promote, deploy, pause, and host wiring.
- [`docs/harness-controls.md`](docs/harness-controls.md): grammar, native installation, authority ceilings, editions, and verification limits.
- [`docs/web.md`](docs/web.md): the local web app: starting it, sessions and CSRF, every view, write safety, the author panel, the exceptions delegate, registration, the lock edition, local storage, and the API.
- [`docs/effect.md`](docs/effect.md): when a change reaches running Claude Code and Codex sessions, what needs a reload, and how to confirm it landed.
- [`docs/roster.md`](docs/roster.md): the roster resolver.
- [`docs/behavior.md`](docs/behavior.md): behavioral policy.
- [`docs/code-specs.md`](docs/code-specs.md): code specs.
- [`docs/smoke.md`](docs/smoke.md): the smoke ledger and the bundled suite.
- [`docs/VISION.md`](docs/VISION.md): where polispec is going.
- [`examples/`](examples/): the `clinic` (booking app with nested modules), `shop` (web service), and `widget` (distributed plugin) projects, harness controls, and an example ledger.
- [`specs/app.yml`](specs/app.yml): the contract.

## Guided learner policies

The optional `guided-learner` catalog package defines six policies for nontechnical learning workflows: no code in replies, no terminal handoffs, no implementation disclosures, released-assignment scope, plain-language coaching, and truthful essential disclosures. `polispec plan guided-learner --repo PATH` previews a files-only installation. It changes no development environment policy, ledger entry, or host enforcement setting.

`polispec behavior export-package guided-learner` exports the compiled policy for a consuming application's own adapter. That adapter owns native hook integration and reports display replacement, after-display correction, and advisory coverage honestly. The package itself does not intercept replies or establish semantic compliance. See [behavior policy](docs/behavior.md) for the contract and limitations.

## License

MIT. See `LICENSE`.
