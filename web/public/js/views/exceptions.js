import "../components/ps-data-table.js";
import "../components/ps-tabs.js";
import "../components/ps-dialog.js";
import "../components/ps-confirm.js";
import "../components/ps-command.js";
import "../components/ps-chip.js";
import "../components/ps-state.js";
import "../components/ps-banner.js";
import "../components/ps-button.js";
import "../components/ps-segmented.js";
import "../components/ps-text-field.js";
import "../components/ps-skeleton.js";
import { get, post, endpoints } from "../core/api.js";
import { app } from "../core/store.js";
import { announce, toast } from "../core/announce.js";
import { relTime, middleTruncate, formatCount } from "../core/format.js";
import * as router from "../core/router.js";

const POLL_MS = 700;
const WAIT_LIMIT_MS = 600000;
const WIDE = 1440;
const END_STATES = ["succeeded", "failed", "cancelled", "timed_out"];
const VERBS = {
  add: { title: "Add exception", action: "Add exception", grant: "exceptions-add" },
  promote: { title: "Promote proposal", action: "Promote proposal", grant: "exceptions-promote" },
  remove: { title: "Remove exception", action: "Remove exception", grant: "exceptions-remove" },
};

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function button(text, options = {}) {
  const node = document.createElement("ps-button");
  if (options.variant) node.setAttribute("variant", options.variant);
  if (options.size) node.setAttribute("size", options.size);
  node.text = text;
  return node;
}

function chip(label, title) {
  const node = document.createElement("ps-chip");
  node.setAttribute("kind", "tag");
  node.setAttribute("label", label);
  if (title) node.title = title;
  return node;
}

function quote(text) {
  return `'${String(text).replace(/'/g, "'\\''")}'`;
}

function scopeOf(entry) {
  const scope = entry.scope;
  if (scope && scope.global) return { label: "Global", title: "Every project" };
  if (scope && scope.project) {
    const parts = String(scope.project).split("/").filter(Boolean);
    return { label: parts[parts.length - 1] || String(scope.project), title: String(scope.project) };
  }
  if (typeof scope === "string") return { label: scope, title: scope };
  return { label: "Global", title: "Every project" };
}

function globOf(entry) {
  return entry.command || (entry.tool ? `${entry.tool} (any call)` : "");
}

function timeCell(value) {
  if (!value) return el("span", "ex-faint", "Never");
  const { text, title } = relTime(value);
  const node = document.createElement("time");
  node.textContent = text;
  node.title = title;
  node.setAttribute("datetime", title);
  return node;
}

function delegateState(verb) {
  const config = app.get().config;
  const flags = (config && config.flags) || {};
  const node = flags.delegate && typeof flags.delegate === "object" ? flags.delegate : {};
  const granted = Array.isArray(node.granted_verbs) ? node.granted_verbs : [];
  const up = node.runner_up === true;
  const ok = up && granted.includes(VERBS[verb].grant);
  let why = "";
  if (!up) why = "The delegate runner is not running on this host.";
  else if (!granted.includes(VERBS[verb].grant)) why = `The polispec-web app has no grant for ${VERBS[verb].grant}.`;
  return { ok, why };
}

function operatorCommand(verb, spec) {
  if (verb === "add") {
    const parts = ["polispec exceptions add"];
    if (spec.command) parts.push("--command", quote(spec.command));
    parts.push("--tool", spec.tool || "Bash", "--kind", spec.kind || "control");
    if (spec.rule) parts.push("--rule", spec.rule);
    parts.push("--global");
    if (spec.note) parts.push("--note", quote(spec.note));
    return parts.join(" ");
  }
  if (verb === "promote") return `polispec exceptions promote ${spec.id} --global`;
  return `polispec exceptions remove ${spec.id}`;
}

function argsFor(verb, spec) {
  if (verb === "add") {
    const args = [];
    if (spec.command) args.push("--command", spec.command);
    args.push("--tool", spec.tool || "Bash", "--kind", spec.kind || "control");
    if (spec.rule) args.push("--rule", spec.rule);
    args.push("--global");
    if (spec.note) args.push("--note", spec.note);
    return args;
  }
  if (verb === "promote") return [spec.id, "--global"];
  return [spec.id];
}

function lastLine(text) {
  const lines = String(text || "").split("\n").map((line) => line.trim()).filter(Boolean);
  return lines.length ? lines[lines.length - 1] : "";
}

function changeIdOf(run) {
  if (run.change_id) return run.change_id;
  const match = /chg_[0-9a-f]+/.exec(String(run.data || ""));
  return match ? match[0] : "";
}

class PhraseFlow {
  constructor({ verb, spec, summary, onDone, onClose, opener, signal, host }) {
    this.verb = verb;
    this.spec = spec;
    this.onDone = onDone;
    this.onClose = onClose;
    this.opener = opener;
    this.signal = signal;
    this.runId = "";
    this.offset = 0;
    this.output = "";
    this.state = "idle";
    this.timer = 0;
    this.waitStart = 0;
    this.gen = 0;
    this.dialog = document.createElement("ps-dialog");
    this.dialog.setAttribute("heading", VERBS[verb].title);
    this.summaryHost = el("div", "ex-summary");
    this.summaryHost.append(summary);
    this.stage = el("div", "ex-stage");
    this.stage.setAttribute("aria-live", "polite");
    this.body = el("div", "ex-flow");
    this.body.append(this.summaryHost, this.stage);
    const footer = el("div", "ex-flow-footer");
    footer.setAttribute("data-dialog-footer", "");
    this.cancel = button("Close", { size: "md" });
    this.go = button(VERBS[verb].action, { variant: verb === "remove" ? "danger" : "primary", size: "md" });
    footer.append(this.cancel, this.go);
    this.dialog.append(this.body, footer);
    host.append(this.dialog);
    this.cancel.addEventListener("click", () => this.dialog.close());
    this.go.addEventListener("click", () => this.start());
    this.dialog.addEventListener("ps-close", () => this.dispose());
    if (signal) signal.addEventListener("abort", () => this.dispose(), { once: true });
    this.mode = delegateState(verb);
    this.renderIdle();
  }

  show() {
    this.dialog.show(this.opener);
  }

  dispose() {
    if (this.onClose && this.dialog.isConnected) {
      const done = this.state === "confirmed";
      const close = this.onClose;
      this.onClose = null;
      close(done);
    }
    clearInterval(this.timer);
    this.timer = 0;
    this.gen += 1;
    if (this.dialog.isConnected) {
      if (this.dialog.open) this.dialog.close();
      this.dialog.remove();
    }
  }

  setBusy(on) {
    this.dialog.toggleAttribute("busy", on);
    this.go.toggleAttribute("busy", on);
    this.cancel.toggleAttribute("disabled", on && this.state === "requesting");
  }

  renderIdle() {
    this.state = "idle";
    this.stage.replaceChildren();
    if (!this.mode.ok) {
      const banner = document.createElement("ps-banner");
      banner.setAttribute("severity", "info");
      banner.setAttribute("text", `${this.mode.why} Run the command in a terminal instead.`);
      const command = document.createElement("ps-command");
      command.setAttribute("command", operatorCommand(this.verb, this.spec));
      command.setAttribute("why", "It asks for the confirmation phrase there.");
      const grant = document.createElement("ps-command");
      grant.setAttribute("command", `polispec delegate grant polispec-web --verbs ${VERBS[this.verb].grant}`);
      grant.setAttribute("operator", "");
      grant.setAttribute("why", "To run this from the page next time.");
      this.stage.append(banner, command, grant);
      this.go.hidden = true;
      return;
    }
    this.go.hidden = false;
    this.go.text = VERBS[this.verb].action;
    this.stage.append(el("p", "ex-note", "Continue to ask polispec for the phrase. Nothing changes until you type it."));
  }

  async start() {
    if (!this.mode.ok || this.state === "requesting" || this.state === "applying") return;
    this.gen += 1;
    const gen = this.gen;
    this.state = "requesting";
    this.output = "";
    this.offset = 0;
    this.runId = "";
    this.setBusy(true);
    this.go.hidden = true;
    this.stage.replaceChildren(el("p", "ex-note", "Requesting the phrase from the delegate runner."));
    announce("Requesting the phrase");
    try {
      const data = await post(endpoints.exceptionVerb(this.verb), { args: argsFor(this.verb, this.spec) });
      if (gen !== this.gen) return;
      this.runId = data && (data.run_id || data.id);
      if (!this.runId) throw Object.assign(new Error("The runner did not return a run id."), { code: "no_run" });
      this.waitStart = Date.now();
      this.poll(gen);
      this.timer = setInterval(() => this.poll(gen), POLL_MS);
    } catch (error) {
      if (gen !== this.gen) return;
      this.fail(error, "refused");
    }
  }

  async poll(gen) {
    if (gen !== this.gen || this.busyPoll) return;
    this.busyPoll = true;
    try {
      const run = await get(endpoints.run(this.runId, { offset: this.offset }));
      if (gen !== this.gen) return;
      if (Number.isFinite(run.offset)) this.offset = run.offset;
      if (run.data) this.output += run.data;
      this.handle(run);
    } catch (error) {
      if (gen !== this.gen) return;
      clearInterval(this.timer);
      this.timer = 0;
      this.fail(error, "refused");
    } finally {
      this.busyPoll = false;
    }
  }

  handle(run) {
    const state = run.state;
    if (state === "waiting_phrase" && this.state !== "waiting" && this.state !== "applying") {
      clearInterval(this.timer);
      this.timer = 0;
      this.renderWaiting(run);
      return;
    }
    if (END_STATES.includes(state)) {
      clearInterval(this.timer);
      this.timer = 0;
      if (state === "succeeded") this.renderConfirmed(run);
      else this.renderEnded(run, state);
      return;
    }
    if (this.state === "requesting" && Date.now() - this.waitStart > WAIT_LIMIT_MS) {
      clearInterval(this.timer);
      this.timer = 0;
      this.renderTimedOut("The runner did not ask for a phrase in time.");
    }
  }

  renderWaiting(run) {
    this.state = "waiting";
    this.setBusy(false);
    this.stage.replaceChildren();
    const prompt = run.prompt || {};
    if (prompt.text) this.stage.append(el("pre", "ex-prompt mono", prompt.text));
    const confirm = document.createElement("ps-confirm");
    confirm.setAttribute("mode", "phrase");
    confirm.setAttribute("expected", prompt.phrase || "");
    confirm.setAttribute("action", VERBS[this.verb].action);
    confirm.setAttribute("busy-label", "Confirming");
    this.confirm = confirm;
    confirm.addEventListener("ps-confirm", (event) => this.submit(event.detail.value));
    this.stage.append(confirm, el("p", "ex-note", "The phrase is the one polispec would ask for in a terminal. Type it exactly."));
    announce("Waiting for you to type the phrase");
    confirm.focus();
    this.waitTimer = setTimeout(() => {
      if (this.state === "waiting") this.renderTimedOut("No phrase was typed within 10 minutes. Nothing was done.");
    }, WAIT_LIMIT_MS);
  }

  async submit(text) {
    if (this.state !== "waiting") return;
    clearTimeout(this.waitTimer);
    this.state = "applying";
    this.setBusy(true);
    this.confirm.setAttribute("busy", "");
    this.confirm.removeAttribute("error");
    const gen = this.gen;
    try {
      const result = await post(endpoints.runPhrase(this.runId), { text });
      if (gen !== this.gen) return;
      if (result && result.ok === false) {
        this.state = "waiting";
        this.setBusy(false);
        this.confirm.removeAttribute("busy");
        this.confirm.setAttribute("error", `${result.code || "refused"}: ${result.message || "The runner did not accept the phrase."}`);
        return;
      }
      this.timer = setInterval(() => this.poll(gen), POLL_MS);
      this.poll(gen);
    } catch (error) {
      if (gen !== this.gen) return;
      this.state = "waiting";
      this.setBusy(false);
      this.confirm.removeAttribute("busy");
      const code = error.code || error.kind || "refused";
      this.confirm.setAttribute("error", `${code}: ${error.message || "The request failed."}`);
    }
  }

  renderConfirmed(run) {
    this.state = "confirmed";
    this.setBusy(false);
    this.stage.replaceChildren();
    const id = changeIdOf(run);
    const done = el("p", "ex-done");
    done.append(document.createTextNode("Confirmed. "));
    if (id) {
      done.append(document.createTextNode("Change record "));
      done.append(el("span", "mono", id));
      done.append(document.createTextNode("."));
    }
    this.stage.append(done);
    this.go.hidden = true;
    this.cancel.text = "Close";
    toast(id ? `Change record ${id}` : "The change was recorded", { kind: "success", title: `${VERBS[this.verb].title} confirmed` });
    announce("Confirmed");
    if (this.onDone) this.onDone(id);
  }

  renderEnded(run, state) {
    const message = lastLine(run.data || this.output) || "The runner ended the run.";
    if (state === "timed_out" || /no phrase was typed/i.test(this.output)) {
      this.renderTimedOut(message);
      return;
    }
    this.fail({ code: state === "cancelled" ? "cancelled" : "refused", message, exit_code: run.exit_code }, "refused");
  }

  renderTimedOut(message) {
    clearInterval(this.timer);
    clearTimeout(this.waitTimer);
    this.timer = 0;
    this.gen += 1;
    this.state = "timed_out";
    this.setBusy(false);
    this.stage.replaceChildren();
    const banner = document.createElement("ps-banner");
    banner.setAttribute("severity", "warn");
    banner.setAttribute("text", message);
    banner.setAttribute("action", "Retry");
    banner.addEventListener("ps-action", () => this.start());
    this.stage.append(banner);
    announce("The request timed out", { assertive: true });
  }

  fail(error, kind) {
    clearInterval(this.timer);
    clearTimeout(this.waitTimer);
    this.timer = 0;
    this.gen += 1;
    this.state = kind;
    this.setBusy(false);
    this.stage.replaceChildren();
    const code = (error && (error.code || error.kind)) || "refused";
    const text = (error && error.message) || "The runner refused the request.";
    const banner = document.createElement("ps-banner");
    banner.setAttribute("severity", "danger");
    banner.setAttribute("text", `${code}: ${text}`);
    banner.setAttribute("action", "Retry");
    banner.addEventListener("ps-action", () => this.start());
    this.stage.append(banner);
    if (error && error.errorId) this.stage.append(el("p", "ex-note mono", `Error id ${error.errorId}`));
    this.mode = delegateState(this.verb);
    const command = document.createElement("ps-command");
    command.setAttribute("command", operatorCommand(this.verb, this.spec));
    command.setAttribute("why", "Or run it in a terminal.");
    this.stage.append(command);
    announce(`${code}: ${text}`, { assertive: true });
  }
}

function kvList(rows) {
  const list = el("dl", "ex-kv");
  for (const [label, value] of rows) {
    list.append(el("dt", "", label));
    const dd = el("dd");
    if (value instanceof Node) dd.append(value);
    else dd.textContent = value == null || value === "" ? "None" : String(value);
    list.append(dd);
  }
  return list;
}

class Exceptions {
  constructor(container, params, signal) {
    this.container = container;
    this.signal = signal;
    this.selectedId = params[0] || "";
    this.exceptions = [];
    this.proposals = [];
    this.tab = "exceptions";
    this.build();
  }

  build() {
    const section = el("section", "view exceptions");
    const header = el("header", "view-header");
    const heading = el("h1", "", "Exceptions");
    heading.tabIndex = -1;
    this.addButton = button("Add exception", { size: "md" });
    this.addButton.addEventListener("click", () => this.openAdd());
    header.append(heading, this.addButton);
    this.body = el("div", "ex-body");
    section.append(header, this.body);
    this.container.replaceChildren(section);
    this.section = section;
  }

  loading() {
    this.body.replaceChildren();
    const table = document.createElement("ps-data-table");
    table.setAttribute("caption", "Exceptions");
    table.setAttribute("state", "loading");
    table.columns = [{ key: "id", label: "Exception" }];
    this.body.append(table);
  }

  async load() {
    this.loading();
    try {
      const [list, inbox] = await Promise.all([get(endpoints.exceptions, { signal: this.signal }), get(endpoints.proposals, { signal: this.signal })]);
      if (this.signal.aborted) return;
      this.exceptions = Array.isArray(list && list.exceptions) ? list.exceptions : [];
      this.proposals = Array.isArray(inbox && inbox.proposals) ? inbox.proposals : [];
      document.dispatchEvent(new CustomEvent("ps-nav-count", { detail: { route: "exceptions", count: this.proposals.length } }));
      this.draw();
    } catch (error) {
      if (this.signal.aborted || (error && error.name === "AbortError")) return;
      const state = document.createElement("ps-state");
      state.setAttribute("kind", "error");
      state.setAttribute("heading", "Exceptions did not load");
      state.setAttribute("body", (error && error.message) || "The request failed.");
      if (error && error.errorId) state.setAttribute("error-id", error.errorId);
      state.addEventListener("ps-retry", (event) => {
        event.stopPropagation();
        this.load();
      });
      this.body.replaceChildren(state);
    }
  }

  wide() {
    return window.innerWidth >= WIDE;
  }

  draw() {
    this.body.replaceChildren();
    const detail = this.selectedId ? this.exceptions.find((entry) => entry.id === this.selectedId) : null;
    if (this.selectedId && !this.wide()) {
      this.body.append(this.detailPane(detail));
      return;
    }
    const split = el("div", "ex-split");
    split.toggleAttribute("data-detail", Boolean(this.selectedId));
    split.append(this.tabs());
    if (this.selectedId) split.append(this.detailPane(detail));
    this.body.append(split);
  }

  tabs() {
    const tabs = document.createElement("ps-tabs");
    tabs.setAttribute("label", "Exceptions and proposals");
    tabs.setAttribute("selected", this.tab);
    const one = el("div");
    one.dataset.tab = "exceptions";
    one.dataset.label = "Exceptions";
    one.dataset.count = String(this.exceptions.length);
    one.append(this.exceptionsTable());
    const two = el("div");
    two.dataset.tab = "proposals";
    two.dataset.label = "Proposals inbox";
    two.dataset.count = String(this.proposals.length);
    two.append(this.proposalsTable());
    tabs.append(one, two);
    tabs.addEventListener("ps-tab-change", (event) => {
      this.tab = event.detail.id;
    });
    return tabs;
  }

  exceptionsTable() {
    const table = document.createElement("ps-data-table");
    table.setAttribute("caption", "Exceptions");
    table.setAttribute("openable", "");
    table.keyBy = "id";
    table.columns = [
      { key: "id", label: "Exception", width: "148px", mono: true, sortable: true, render: (row) => row.id },
      { key: "scope", label: "Scope", width: "120px", render: (row) => chip(scopeOf(row).label, scopeOf(row).title) },
      { key: "command", label: "Command glob", mono: true, render: (row) => middleTruncate(globOf(row), 64) },
      { key: "added_by", label: "Added by", width: "120px", render: (row) => row.added_by || "unknown" },
      { key: "first_use", label: "First use", width: "96px", render: (row) => timeCell(row.first_use) },
      { key: "last_use", label: "Last use", width: "96px", render: (row) => timeCell(row.last_use) },
      { key: "hits", label: "Hits", width: "72px", align: "end", sortable: true, render: (row) => formatCount(row.hits || 0) },
      { key: "sessions", label: "Sessions", width: "72px", align: "end", sortable: true, sortValue: (row) => this.sessionCount(row), render: (row) => formatCount(this.sessionCount(row)) },
    ];
    table.emptyState = { kind: "empty_cleared", heading: "No exceptions. Every call is judged by the composed rules." };
    table.rows = this.exceptions;
    table.addEventListener("ps-row-open", (event) => {
      router.navigate(`exceptions/${encodeURIComponent(event.detail.row.id)}`);
    });
    return table;
  }

  sessionCount(row) {
    if (Array.isArray(row.sessions)) return row.sessions.length;
    return Number(row.sessions) || 0;
  }

  proposalsTable() {
    const table = document.createElement("ps-data-table");
    table.setAttribute("caption", "Proposals inbox");
    table.setAttribute("compact", "");
    table.keyBy = "id";
    table.columns = [
      { key: "id", label: "Proposal", width: "148px", mono: true, render: (row) => row.id },
      { key: "proposed_by", label: "Proposed by", width: "120px", render: (row) => row.proposed_by || "unknown" },
      { key: "command", label: "Command glob", mono: true, render: (row) => middleTruncate(globOf(row), 64) },
      { key: "reason", label: "Reason", render: (row) => row.reason || row.rule || "" },
      { key: "age", label: "Age", width: "96px", render: (row) => timeCell(row.ts || row.proposed_at) },
      {
        key: "action",
        label: "Action",
        width: "96px",
        render: (row) => {
          const promote = button("Promote", { size: "xs" });
          promote.setAttribute("aria-label", `Promote proposal ${row.id}`);
          promote.addEventListener("click", () => this.openPromote(row, promote));
          return promote;
        },
      },
    ];
    table.emptyState = { kind: "empty_cleared", heading: "No proposals waiting." };
    table.rows = this.proposals;
    return table;
  }

  detailPane(entry) {
    const pane = el("aside", "ex-detail");
    pane.setAttribute("aria-label", "Exception detail");
    const top = el("div", "ex-detail-head");
    const back = button("All exceptions", { size: "xs", variant: "ghost" });
    back.addEventListener("click", () => router.navigate("exceptions"));
    top.append(back);
    pane.append(top);
    if (!entry) {
      const state = document.createElement("ps-state");
      state.setAttribute("kind", "empty_filtered");
      state.setAttribute("heading", `No exception ${this.selectedId}`);
      state.setAttribute("body", "It may have been removed.");
      pane.append(state);
      return pane;
    }
    const heading = el("h2", "ex-detail-title mono", entry.id);
    pane.append(heading);
    const scope = scopeOf(entry);
    const glob = el("code", "ex-glob mono", globOf(entry));
    const remove = button("Remove", { variant: "danger", size: "md" });
    remove.addEventListener("click", () => this.openRemove(entry, remove));
    pane.append(
      kvList([
        ["Scope", chip(scope.label, scope.title)],
        ["Command glob", glob],
        ["Added by", entry.added_by || "unknown"],
        ["Added at", entry.added || ""],
        ["First use", entry.first_use ? timeCell(entry.first_use) : "Never"],
        ["Last use", entry.last_use ? timeCell(entry.last_use) : "Never"],
        ["Hits", formatCount(entry.hits || 0)],
      ])
    );
    const sessions = Array.isArray(entry.sessions) ? entry.sessions : [];
    pane.append(el("h3", "ex-h3", `Sessions that used it (${sessions.length})`));
    const table = document.createElement("ps-data-table");
    table.setAttribute("caption", `Sessions that used ${entry.id}`);
    table.setAttribute("compact", "");
    table.columns = [
      { key: "id", label: "Session", mono: true, render: (row) => middleTruncate(row.id, 20) },
      { key: "harness", label: "Harness", width: "88px", render: (row) => row.harness || "" },
      { key: "last_use", label: "Last use", width: "96px", render: (row) => timeCell(row.last_use) },
      { key: "hits", label: "Hits", width: "64px", align: "end", render: (row) => formatCount(row.hits || 0) },
    ];
    table.emptyState = { kind: "empty_cleared", heading: "No session has used it." };
    table.rows = sessions;
    pane.append(table);
    const actions = el("div", "ex-actions");
    actions.append(remove);
    pane.append(actions);
    return pane;
  }

  flow(config) {
    const flow = new PhraseFlow({
      ...config,
      signal: this.signal,
      host: this.section,
      onDone: () => this.load(),
      onClose: (done) => {
        if (done && config.verb === "remove" && this.selectedId) router.navigate("exceptions");
      },
    });
    flow.show();
    return flow;
  }

  openPromote(row, opener) {
    const summary = el("div", "ex-summary-body");
    summary.append(el("p", "ex-lead", "This lets the exception below lift the ask that proposal records, for every project."));
    summary.append(kvList([["Proposal", row.id], ["Command glob", el("code", "mono", globOf(row))], ["Proposed by", row.proposed_by || "unknown"], ["Reason", row.reason || row.rule || ""]]));
    this.flow({ verb: "promote", spec: { id: row.id }, summary, opener });
  }

  openRemove(entry, opener) {
    const summary = el("div", "ex-summary-body");
    summary.append(el("p", "ex-lead", "The calls this exception lifted will ask again."));
    summary.append(kvList([["Exception", entry.id], ["Command glob", el("code", "mono", globOf(entry))], ["Scope", scopeOf(entry).label], ["Hits so far", formatCount(entry.hits || 0)]]));
    this.flow({ verb: "remove", spec: { id: entry.id }, summary, opener });
  }

  openAdd() {
    const dialog = document.createElement("ps-dialog");
    dialog.setAttribute("heading", "Add exception");
    const form = el("div", "ex-form");
    form.append(el("p", "ex-lead", "An exception lifts one ask for the commands its glob matches, for every project. A deny is never lifted."));
    const kind = document.createElement("ps-segmented");
    kind.setAttribute("label", "Kind");
    kind.options = [
      { value: "control", label: "Control ask" },
      { value: "rule", label: "Rule warn" },
    ];
    kind.setAttribute("value", "control");
    const tool = document.createElement("ps-text-field");
    tool.setAttribute("label", "Tool");
    tool.setAttribute("mono", "");
    tool.setAttribute("value", "Bash");
    const command = document.createElement("ps-text-field");
    command.setAttribute("label", "Command glob (Required for Bash)");
    command.setAttribute("mono", "");
    command.setAttribute("placeholder", "git status*");
    command.setAttribute("help", "Matched against the whitespace-normalised command. * crosses slashes.");
    const rule = document.createElement("ps-text-field");
    rule.setAttribute("label", "Rule id (Required for a rule warn)");
    rule.setAttribute("mono", "");
    rule.hidden = true;
    const note = document.createElement("ps-text-field");
    note.setAttribute("label", "Note");
    note.setAttribute("maxlength", "200");
    form.append(kind, tool, command, rule, note);
    for (const field of [tool, command, rule]) field.addEventListener("ps-input", () => field.removeAttribute("error"));
    const footer = el("div", "ex-flow-footer");
    footer.setAttribute("data-dialog-footer", "");
    const cancel = button("Cancel", { size: "md" });
    const next = button("Continue", { variant: "primary", size: "md" });
    footer.append(cancel, next);
    dialog.append(form, footer);
    this.section.append(dialog);
    kind.addEventListener("ps-change", () => {
      rule.hidden = kind.value !== "rule";
    });
    cancel.addEventListener("click", () => dialog.close());
    dialog.addEventListener("ps-close", () => dialog.remove());
    this.signal.addEventListener("abort", () => dialog.isConnected && dialog.remove(), { once: true });
    next.addEventListener("click", () => {
      const spec = { kind: kind.value, tool: tool.value.trim() || "Bash", command: command.value.trim(), rule: rule.value.trim(), note: note.value.trim() };
      let bad = false;
      command.removeAttribute("error");
      rule.removeAttribute("error");
      tool.removeAttribute("error");
      if (spec.tool === "Bash" && !spec.command) {
        command.setAttribute("error", "A command glob is required for Bash.");
        bad = true;
      } else if (spec.tool !== "Bash" && spec.command) {
        command.setAttribute("error", "Only Bash takes a command glob.");
        bad = true;
      }
      if (spec.kind === "rule" && (!spec.rule || spec.tool !== "Bash")) {
        rule.setAttribute("error", spec.tool !== "Bash" ? "A rule warn applies to Bash only." : "A rule id is required.");
        bad = true;
      }
      if (spec.kind === "control" && spec.rule) {
        rule.setAttribute("error", "A control ask takes no rule id.");
        bad = true;
      }
      if (bad) {
        announce("Fix the fields marked with errors", { assertive: true });
        return;
      }
      dialog.close();
      const summary = el("div", "ex-summary-body");
      summary.append(el("p", "ex-lead", "A new global exception will be written to the shelf."));
      summary.append(kvList([["Kind", spec.kind === "rule" ? "Rule warn" : "Control ask"], ["Tool", spec.tool], ["Command glob", spec.command ? el("code", "mono", spec.command) : "Any call"], ["Rule", spec.rule || "None"], ["Note", spec.note || "None"]]));
      this.flow({ verb: "add", spec, summary, opener: this.addButton });
    });
    dialog.show(this.addButton);
  }
}

export async function render(container, params, signal) {
  const view = new Exceptions(container, params || [], signal);
  await view.load();
}
