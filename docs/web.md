# polispec web

`polispec web` serves a local web app over the files polispec already keeps. It reads the ledger, the rulebooks, the judgment stream, the change records and the session records through the same library the command line uses, and it changes a rulebook only by creating a plan and applying it through the same apply path as `polispec apply`. It has no database. Since 0.35.0.

- [Starting it](#starting-it)
- [Sessions, CSRF and the Origin check](#sessions-csrf-and-the-origin-check)
- [The views](#the-views)
- [Write safety](#write-safety)
- [The limiter](#the-limiter)
- [The author panel](#the-author-panel)
- [Exceptions through the delegate runner](#exceptions-through-the-delegate-runner)
- [Registering from the web](#registering-from-the-web)
- [The lock edition](#the-lock-edition)
- [Local storage](#local-storage)
- [The API](#the-api)

## Starting it

```sh
polispec web [--bind ADDR] [--port N] [--expose] [--open] [--read-only] [--json]
polispec web url [--json]
polispec web token set
polispec web unit [--json]
```

- `--bind ADDR` and `--port N` override the settings `polispec.web.bind` (default `127.0.0.1`) and `polispec.web.port` (default `7421`). `--port 0` asks the system for a free port and prints the one it got. A port setting outside 0 to 65535 falls back to 7421.
- `polispec.web.public_origin` optionally names one HTTPS origin, such as `https://policy.example.net:8443`, for an external reverse proxy. Keep the backend on loopback and have the proxy preserve that Host header. The setting does not create a proxy, a certificate, or a network mapping. Credentials, paths, queries, fragments, and non-HTTPS schemes are refused at startup. Initial links and `web url` use the origin captured by the running server; restart after changing it. Sessions use Secure cookies and mutations require that exact HTTPS Origin. HTTP loopback remains available for unauthenticated probes. Forwarded headers do not establish trust. Leave the setting empty for the existing local HTTP flow.
- A bind address that is not a loopback address needs `--expose`, a terminal, and the typed phrase `expose polispec web`. Without `--expose` the command exits 2 with `expose_required`; without a terminal it exits 3 with `not_tty`. Anyone holding a link can change policy, so only expose it on a network you trust.
- `--open` hands the link to `xdg-open` or `open` when one is on `PATH`; otherwise it prints a note and you open the link by hand.
- `--read-only` starts the server so that every route that writes answers 405 `read_only` (see [The limiter](#the-limiter) for the routes that stay open), and `config.read_only` tells the browser, which shows a Read-only banner and disables every write control with that reason. Use it when you only want to look.
- `--json` prints one line, `{"url", "bind", "port", "pid", "read_only"}`, instead of the text below.

When it is ready it prints:

```
polispec web: serving 127.0.0.1:7421; stop with Ctrl-C
open this link within 120 seconds, it works once:
http://127.0.0.1:7421/#k=<one-time code>
```

Only one server runs per state home. The server records itself in `<state home>/web/server.json` (`pid`, `port`, `bind`, `started_at`); a second start exits 1 with `already_running`, and a record whose process is gone is renamed aside. Ctrl-C or SIGTERM closes any open author sessions and shuts the server down; the exit also removes `server.json`.

- `polispec web url` prints a fresh one-time link for the server that is already running. It signs the code with the same launch secret, so it needs no contact with the server process.
- `polispec web token set` asks, on a terminal and without echo, for the delegate token that lets the web app relay `exceptions` requests (see [Exceptions through the delegate runner](#exceptions-through-the-delegate-runner)). It stores it at `<state home>/web/delegate.token` with mode 0600.
- `polispec web unit` prints a systemd user unit for `polispec web` and the two commands that install and start it. It writes nothing.

A line that runs `polispec web` in a live project classifies as `policy.edit`, so an agent that tries to start the server is asked about first; `polispec web unit` and `--help` do not. See [G-WEB-AGENT](#g-web-agent).

## Sessions, CSRF and the Origin check

At the first start the server creates a launch secret, 32 random bytes in hex, at `<state home>/web/launch.secret` (mode 0600, the directory 0700). The secret lives on across restarts. A write to it or to `delegate.token` classifies as `policy.edit`.

1. **The one-time code.** The link carries a code of the form `nonce.expiry.mac`, where `mac` is the first 32 hex characters of an HMAC-SHA256 over the nonce and the expiry. A code is good for 120 seconds and works once; the server remembers the nonces it has seen. The code sits in the URL fragment (`#k=`), so it is not sent in any request line or logged.
2. **The exchange.** The page posts the code to `POST /api/v1/session`. A valid code answers 200 with `{"csrf", "expires_at"}` and a `Set-Cookie: ps_session=...; HttpOnly; SameSite=Strict; Path=/`. A used, expired or forged code answers 401 `unauthorized`. The server keeps at most 64 sessions and drops the least recently used one beyond that.
3. **The session.** A session expires after 12 hours without a request. `GET /api/v1/session` returns its CSRF token and expiry, and `DELETE /api/v1/session` ends it. Every route except `POST /session` answers 401 without a valid cookie.
4. **CSRF.** Every request that is not `GET` or `HEAD` must carry `X-Polispec-CSRF` equal to the session's token, or it answers 403 `forbidden`.
5. **The Origin check.** Every such request must also carry an `Origin` that names this server (`http://localhost:<port>`, the bind address, or, when exposed on a wildcard bind, an IP literal), or it answers 403. `POST /session` accepts a request with no `Origin` and refuses one whose `Origin` is another site.
6. **The Host check.** Every request, static files included, must carry a `Host` header that names this server with this server's port, or it answers 403. This is what keeps a page on another site from reaching the server through DNS rebinding.

When `polispec.web.public_origin` is configured, its exact host and effective HTTPS port are additionally admitted by the Host check, and only that origin passes the Origin check. Login and logout cookies carry `Secure`. The existing cookie, CSRF, session expiry, and mutation limits still apply. The agent API classifier also recognizes this origin, including the one recorded by a running server.

A request body larger than 2 MiB answers 413. Every response carries `X-Request-Id`, and every error is `{"error", "message", "request_id"}` plus fields specific to the error. API responses are `Cache-Control: no-store`; the static files are served with an ETag and `no-cache`. A content security policy restricts the page to its own origin.

A session is the unsealed terminal confirmation made reachable from a browser. It is not operator authentication: whoever holds the cookie and types a plan id can apply that plan.

## The views

The navigation groups the views by what you are doing. The keyboard shortcuts `g` then a letter jump between them, and `?` lists them all.

### Observe

- **Map** (`g m`). Every ledger project and path entry as a card with its name, summary, description, digest, status and the counts of allow, warn and deny judgments in the window (1 hour, 24 hours or 7 days). The shipped layer, the global shelf and the exceptions file are drawn above the cards, with an edge from each layer and module instance to every project it reaches. Hovering a card highlights what it shares. Card positions you drag are saved. A list view shows the same entries as a table.
- **Pipeline** (`g p`). Per project: the `main`, `test` and `stable` refs with their policy digests, policy not yet promoted, package drift, doctor findings, freezes and the gate to test. Promotion to `test` and every operator action appear as the exact command to run in a terminal.
- **Sessions** (`g s`). Every harness session seen in the window (1, 6 or 24 hours): harness, agent, start, last call, runtime version, policy digest per project and epoch, with a badge for current, pending, needs reload, stale briefing or untrusted hook (Codex).
- **Feed** (`g f`). Judgments as they are recorded, streamed with server-sent events from the judgment stream and filterable by verdict, session, project or rule.
- **Timeline** (`g t`). Change records as events with their effect classes and, per change, how many active sessions have crossed over to the new epoch.
- **Heatmap** (`g h`). Rule hit counts per project and environment from the judgment stream over 7, 14 or 30 days, the rules that never fired in the window, and the actions no rule covered. A hot spot opens a draft rule in the manager.

### Understand

- **Playground** (`g y`). Type a tool call or a shell line, or pick a recorded judgment, and see the verdict in every environment of every project with the full rule trace. Read-only.
- **Explainer** (`g x`). Paste the text of a deny or a warn, or give a judgment id, and see the rule, its layer, its description and the legitimate way forward, with a draft exception and an allow-once id for the operator.
- **History** (`g i`). A scrubber over a rulebook's git history and release tags. Two refs give a semantic diff of rules, gates, freezes and modules.
- **Detail**. Reached from a card or a rule. One rulebook's composition: the layer chain from shipped to child, each module instance with its resolved parameters, each rule with its verdict and what it overrides, and the winning rule per environment for a chosen action.
- **Blast radius**. While a draft is open, the last 14 days of judgment rows are replayed against it and the counts that would get stricter, looser or stay the same are shown per project, with the largest flip.

### Change

- **Manager** (`g c`). Edit any rulebook in a YAML editor checked as you type against its schema and the description lint. Compose by adding and parameterizing modules; move a rule or a module include between the project, the global shelf and another project; reorder and regroup rules within a layer. Every save is a plan (see [Write safety](#write-safety)). The author panel docks beside it (see [The author panel](#the-author-panel)).
- **Gallery** (`g a`). Packages, shelf modules and example policies as cards. Fill the parameters, preview the plan, then apply it.
- **Exceptions** (`g e`). The persistent exceptions to guard asks with scope, command glob, who added it, first and last use, hit count and the sessions that used it, and the inbox of proposals. Add, promote and remove relay through the delegate runner.
- **Register** (`g r`). Put software, a directory or the system scope under polispec (see [Registering from the web](#registering-from-the-web)).

### Publish

- **Manifest** (`g n`). Per app, the generated manifest (`polispec.manifest/v1`) beside the authored `polispec.app.yml`, the badge, and the index of what other users on the host have published. See [the manifest and index](schema.md#manifest-polispecmanifestv1-and-the-index-polispecindexv1).

The top bar shows the current epoch and flags a change since you last looked. The theme switcher cycles `system`, `light`, `dark`, `apple-noir`, `apple-austere` and `tronwave`; the setting `polispec.web.theme` names the one used on a first visit (default `system`), and the choice you make is remembered in the browser.

## Write safety

A change is never a single call that writes. It is a plan, then an apply.

1. `POST /api/v1/plans` takes a `target` (`{"kind": "project"|"path"|"global"|"module"|"ledger", "id": ...}`) and a `change`. The `change.kind` is one of:
   - `replace`: the whole new YAML of the rulebook.
   - `compose`: add, change or remove a module include, or start from an example; or name a `package` with `with` parameters (and a `variant`) to upgrade a package a project already carries.
   - `reorder` and `regroup`: change only the order or the grouping of the rules. A plan that adds or removes a rule is refused.
   - `move`: relocate a rule or a module include to another scope. It makes two plans, the destination first and the source second, and the second can be applied only after the first (`requires`).
   - `status`, on the `ledger` target: set a project or path entry to `onboarding`, `live` or `retired`.
2. The server writes the proposed text to a ref under `refs/polispec/proposals/` in the target repository (never a branch). For a project, that ref is `main`'s tree with the edited files replaced, and the manager edits `main`'s text: `GET /api/v1/rulebooks/project/<id>/source` answers `ref` (`main@<sha>`), `trust_ref`, `ahead` (commits on `main` not yet on the trust ref that touch the policy directory) and `ahead_files`. The plan compares the trust ref with the proposal, exactly as `polispec plan project:<id>` compares the trust ref with the worktree, so its classification, probes and journal replay include `main`'s unpromoted changes, and its notes say so when `ahead` is above 0. A tightening edit on top of an unpromoted loosening therefore classifies `mixed` and needs its id typed. The server then runs the same `Plan.build` as `polispec plan`, and answers with the plan: `plan_id`, `classification` (`tightening`, `loosening`, `mixed` or `neutral`), `needs_confirm`, `reasons`, `files` with their diffs, the ledger change, the composed `policy_diff`, the `probes` whose verdict changes, the replay of the journal, `effects` (who is reached on the next call, at a new session, after a reload or after a trust review, with the sessions active in the last hour), and `notes`. A proposal that does not validate against its schema, that names another project, or whose `base` digest is no longer the rulebook's answers 422 or 409 and creates nothing. Plans live in the server's memory (at most 200); a proposal ref older than 7 days is removed. A restarted server no longer knows a plan: apply answers 404 and you create it again.
3. `POST /api/v1/plans/<plan_id>/apply` carries the plan out through `polispec apply --confirm <plan_id>`, as the user `web:<name>`, and records a change record. It answers `{plan_id, commit, change_id, epoch_before, epoch_after, committed}` and, when the project's trust ref is not `main`, `operator_command`: the `polispec promote <project> --to stable` that makes the change live. A project plan commits on `main`; the web app never writes `stable`, a production checkout or a secret.

What the person must do before the apply is accepted:

| Plan | What the apply needs |
| --- | --- |
| A tightening or neutral plan that is not global and is not a move, reorder, regroup or status change | Nothing. One click; the call carries no `confirm`. |
| A loosening or mixed plan | The plan id typed: `{"confirm": "<plan_id>"}`. |
| Any plan that targets the global shelf: the global document, a shelf module, or the policy of a path entry | The plan id typed. |
| A `move`, `reorder`, `regroup` or ledger `status` plan | The plan id typed, whatever its classification. |
| A register plan | The plan id typed when it is loosening or mixed, which an onboarding entry is not. |

An apply that needs a typed id and gets none answers 422 `confirm_required` with the plan id. A `confirm` that is not the plan's id answers 422, or 409 `conflict` when it is the id of a plan that has since changed. The plan id covers the exact files, ledger and verdicts; the apply recomputes it, so a plan that went stale because the rulebook, the ledger or the world moved after you looked answers **409 `conflict`**, never a silent apply. Every 409 carries a `reason`: `plan_changed` (the rulebook, `main`, the ledger or the world moved after the plan was made), `already_applied`, `requires_destination` (a `move` source applied before its destination) or `base_moved` (the draft's base digest no longer matches `main`, or the `main` checkout has uncommitted changes to a file the plan writes). Only the edited files are committed onto `main`. When the sealed plane is active the global layer and the ledger belong to it: such a plan is shown as `operator_only` with `polispec plane status`, and an apply answers 403 `sealed_authority`.

**Operator actions are commands, never buttons.** Promotion to `stable`, deploy, `pause`, `allow-once`, `seal` and `plane` are never run by the server. The views render each as the exact command in a block you copy into a terminal: the pipeline shows `polispec promote <project> --to test` and the operator's `polispec promote <project> --to stable`, and an applied plan hands you the promote command in `operator_command`. A request for `pause`, `allow-once`, `seal`, `plane` or `deploy` sent to `POST /exceptions/<verb>` is answered 422 `operator_only` with the command to run, for example `polispec pause shop`, and nothing else happens.

### G-WEB-AGENT

The web app is for the person at the browser. An agent that calls its API has no one to type a plan id. The classifier family `web_local` recognizes such a call and classifies it `policy.edit`, and the shipped rule `G-WEB-AGENT` (in `modules/tool-declared.yml`) warns on it, so the harness asks the user first. A call is recognized when it is a `curl`, `wget`, `http`, `https` or `xh` line, or a `WebFetch` tool call (recognized by its path alone), to a loopback address on the configured web port or the port of the running server, and either the method is not `GET` or `HEAD` (or a body flag is present) or the path is under `/api/v1/exceptions/`, `/api/v1/author`, `/api/v1/state`, `/api/v1/register` or `/api/v1/session`, or is `/api/v1/plans/<id>/apply`. A plain `GET` to the API classifies as `web.fetch`. The rule is overridable like any warn; an agent never drives the web API, and when it wants the user to make a change it points them to `polispec web`.

## The limiter

Each session may make 30 changes in any 60 seconds. The 31st answers 429 `rate_limited` with `Retry-After` in seconds. A change is any request that is not `GET` or `HEAD` and passes the read-only, CSRF and Origin checks; it counts whether or not the server accepts it. The browser keeps the same count and waits before it sends.

Four computations do not count against it, because they change nothing and a person runs them while typing: `POST /lint`, `POST /explain`, `POST /explain-text` and `POST /blast-radius`. They also stay open under `--read-only`, as do reads of every kind. `POST /session` is outside the limiter.

Other limits stand beside it. The author panel is limited to 10 turns a minute for the whole host (see below). The delegate runner limits each app on its own, and the web app passes its 429 on.

## The author panel

The panel drafts a rulebook or a description from an intent in plain words. It never writes: a draft is validated against the schema and the description lint, planned like any other change, and only a person who presses apply changes anything.

**Ports.** The panel talks to the `author` port. polispec asks first for a port declared by an installed rplugin extension (for example one that maps an adapter to an `rllm` service); when none is mapped it uses `harness-cli`, built in, which keeps one persistent Claude Code session (or a Codex run per turn) per panel tab. `polispec.author.adapter` names the built-in adapter (default `harness-cli`), `polispec author adapters` lists what is installed, and `polispec author draft <kind> --intent TEXT` is the same port on the command line. The kinds are `policy`, `module`, `package`, `environments`, `roster`, `global`, `spec` and `description`.

**Roster.** The harness, model and effort come from the project's roster role `spec-author`, and default to `claude`, `sonnet` and `medium`.

**Boundary.**

- The built-in session has only the read tools: Claude Code runs with `--tools Read,Grep,Glob`, in manual permission mode, with one `Read(...)` rule per allowed root; Codex runs with `--sandbox read-only`. It can write no file, run no command and use no MCP server, and polispec refuses to start Claude Code with any `--dangerously` flag.
- The roots it may read are the target project's repository, the global shelf, and the `schemas`, `modules` and `examples` directories of the polispec release.
- It runs in a scratch directory under `<state home>/author`, and its environment carries no `POLISPEC_` variable but `POLISPEC_ACTOR`. It is a governed session, so the guard judges it too.
- At most 3 sessions are open on the host. An idle session closes after 15 minutes. A turn times out after 180 seconds. A turn that dies before its first event is retried at most twice, with jitter. The host allows 10 turns a minute.
- The web server closes every author session when it stops.

**Kill switch.** Set the environment variable `POLISPEC_AUTHOR=off`, or the setting `polispec.author.enabled` to `off` (`polispec settings set polispec.author.enabled off`), and the author answers every request with 403 `disabled` and the reason `kill_switch`. The panel then shows why, from `GET /config` (`flags.author`). Under a sealed plane only the protected setting counts; the environment variable is ignored. The lock edition excludes the author altogether (see [The lock edition](#the-lock-edition)).

## Exceptions through the delegate runner

An exception is a persistent entry on the global shelf's `exceptions.yml` that lets one command through a guard ask. Adding, promoting and removing one are operator actions that type a phrase on a terminal. The web app does not weaken that: it relays the phrase through the delegate runner, the same runner applications use for `promote` and `deploy` (`polispec delegate`).

1. Start the runner (`polispec delegate serve`) and, on a terminal, grant the app `polispec-web` the verbs: `polispec delegate grant polispec-web --projects PROJECT[,PROJECT] --targets test --verbs exceptions-add,exceptions-promote,exceptions-remove`. The command requires `--projects` and `--targets`; the exceptions verbs do not consult them. The grant prints a token once; store it with `polispec web token set`.
2. In the Exceptions view, an add, promote or remove becomes `POST /api/v1/exceptions/add|promote|remove` with `{"args": [...]}`, the arguments of the matching `polispec exceptions` command. The server asks the runner to start the command and answers `{"run_id"}`.
3. The run asks for a confirmation phrase, which the view shows: `exceptions add <id>`, `exceptions promote <proposal ids>` or `exceptions remove <id>`. You type it exactly in the view, which posts it to `POST /api/v1/runs/<run_id>/phrase`; the runner compares it and the command goes on only if it matches. You can read the run's output with `GET /api/v1/runs/<run_id>` and stop it with `POST /api/v1/runs/<run_id>/cancel`. A phrase not typed within 10 minutes cancels the run and does nothing.

The runner enforces the grant: an app can run only the verbs, projects and flags it was given, a second run can be refused while one is active (409 `busy`), and the web app shows a `disabled` reason when the runner is down, the token is missing or the runner refuses it. The runner refuses the exceptions verbs in the lock edition and when the plane is sealed.

## Registering from the web

The Register view is the form for `polispec register`. `POST /api/v1/register` takes `path`, `kind` (`software`, `directory` or `system`; `directory` when omitted), and an optional `id` and `description`. With `"dry_run": true` it answers the preview (`ok`, `findings` from the description lint, the owner and the actor who would register it, the YAML of the entry, and the plan) and creates nothing durable. Without it, it creates a ledger plan that follows [Write safety](#write-safety): a new entry is `onboarding`, which tightens, so it applies on one click. A path inside a ledgered repository, a repeated id, a path already registered and a missing path are refused as `polispec register` refuses them. Setting an entry `live` later is a status plan and needs its id typed. The `polispec-register` skill interviews the person and fills the form's fields; see [Registering software, directories and the system scope](schema.md#registering-software-directories-and-the-system-scope).

## The lock edition

`specs/editions.yml` lists what differs between the standard edition and the lock edition. For this feature:

- **`web`** is excluded. `polispec web` refuses to start with `edition_excluded` and exit 2, including `url`, `token` and `unit`.
- **`author`** is excluded. No drafting takes place; `GET /config` reports it.
- **`exceptions.delegate_promote`** is excluded. `polispec delegate grant` refuses the exceptions verbs and the runner refuses a request for them.
- **`register.path`** is restricted. A governed path entry is added only through the protected ledger the sealed plane names; `polispec register` refuses with `edition_restricted`, and the web register route answers 403 with that reason.
- **`manifest.index_publish`** is excluded: the machine-wide index is not published.

`polispec editions` prints the table and `polispec editions --check` reports drift.

## Local storage

There is no database. Everything the web app shows is read from files polispec already keeps, and everything it changes goes through a plan.

**In the browser** (nothing the server needs, and losing it costs nothing):

- `sessionStorage` holds the last copy of each view (so a view shows instantly, marked as cached, while it refreshes), and the unsaved draft of each rulebook in the manager.
- `localStorage` holds the theme you chose, and preferences: the heatmap window, the feed filters and its announce toggle, whether the author panel is open, and the last epoch you looked at.
- The session cookie is `HttpOnly`, so the page cannot read it.

**On disk, under `<state home>/web`** (the state home is `$XDG_STATE_HOME/polispec`, or `POLISPEC_STATE_HOME`):

| File | Holds |
| --- | --- |
| `launch.secret` | the secret that signs one-time codes, mode 0600 |
| `server.json` | pid, port, bind and start time of the running server |
| `server.log`, `server.log.1` | the access and error log, rotated at 4 MiB |
| `delegate.token` | the delegate token stored by `polispec web token set`, mode 0600 |
| `layout.json` | the positions of the map cards you dragged (JSON, at most 2000 entries) |
| `proposals/` | the ledger files behind pending ledger status plans |

Author sessions keep their scratch directories and their lock files under `<state home>/author`. The change records, the sessions record and the judgment stream are polispec's own records, written by the commands and the hooks, and the web app only reads them.

## The API

The JSON API is under `/api/v1`. [`web/public/openapi.yml`](../web/public/openapi.yml) is its contract, and the running server also serves it at `/openapi.yml`. In short:

| Group | Routes |
| --- | --- |
| Session and config | `POST/GET/DELETE /session`, `GET /config` |
| Read | `GET /map`, `/catalog`, `/rulebooks/{kind}/{id}/source`, `/composition`, `/history`, `/pipeline`, `/heatmap`, `/sessions`, `/changes`, `/judgments`, `/judgments/stream`, `/manifest/index`, `/manifest/{id}`, `/badge/{id}.svg`, `/exceptions`, `/exceptions/proposals`, `/state/layout` |
| Compute | `POST /lint`, `/explain`, `/explain-text`, `/blast-radius` |
| Change | `POST /plans`, `GET /plans/{id}`, `POST /plans/{id}/apply`, `POST /register`, `PUT /state/layout` |
| Delegate | `POST /exceptions/{verb}`, `GET /runs/{id}`, `POST /runs/{id}/phrase`, `POST /runs/{id}/cancel` |
| Author | `POST /author/sessions`, `DELETE /author/sessions/{sid}`, `POST /author/sessions/{sid}/turns`, `POST /author/sessions/{sid}/stop`, `GET /author/sessions/{sid}/stream` |

`GET /config` reports the version, the edition, the epoch, the theme, the operator's name, the owner, and the flags `author`, `feed`, `description` and `delegate` with the reason a feature is off. `GET /map` and `GET /rulebooks/.../source` answer with an `ETag` and honor `If-None-Match`.

The API is for the app's own page. An agent does not call it (see [G-WEB-AGENT](#g-web-agent)), and a script that does so on a person's behalf takes the same one-time link, the same cookie and the same CSRF header the page does.
