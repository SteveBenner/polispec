import "./ps-dialog.js";
import "./ps-tabs.js";
import "./ps-chip.js";
import "./ps-digest.js";
import "./ps-command.js";
import "./ps-confirm.js";
import "./ps-banner.js";
import "./ps-button.js";
import "./ps-state.js";
import "./ps-data-table.js";
import "./ps-skeleton.js";
import { post, endpoints } from "../core/api.js";
import { app } from "../core/store.js";
import { announce } from "../core/announce.js";
import { formatCount } from "../core/format.js";
import * as sse from "../core/sse.js";
import * as router from "../core/router.js";
import { aggregate, renderTable, headerLine } from "../views/blast-radius.js";

const NS = "http://www.w3.org/2000/svg";

const CLASSES = [
  { key: "next_call", label: "Next call", icon: "next-call", means: "on their next tool call" },
  { key: "new_session", label: "New session", icon: "new-session", means: "only in sessions started after apply" },
  { key: "reload", label: "After /reload-plugins", icon: "reload", means: "after /reload-plugins in each" },
  { key: "trust", label: "After trust review", icon: "trust", means: "after the person reviews the hook" },
];

const TYPED_KINDS = ["move", "reorder", "regroup", "status"];
const ACTIONS = { add: "Added", added: "Added", create: "Added", replace: "Modified", modify: "Modified", modified: "Modified", conflict: "Modified", remove: "Removed", removed: "Removed", delete: "Removed", unchanged: "Unchanged" };

function icon(name) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "ps-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function sessionsOf(entry) {
  if (entry == null) return { affected: false, count: 0, ids: null };
  if (typeof entry === "number") return { affected: entry > 0, count: entry, ids: null };
  if (typeof entry === "boolean") return { affected: entry, count: 0, ids: null };
  const list = Array.isArray(entry.sessions) ? entry.sessions : Array.isArray(entry.ids) ? entry.ids : null;
  const count = list ? list.length : Number(entry.sessions != null ? entry.sessions : entry.count != null ? entry.count : entry.reached) || 0;
  const affected = entry.affected === false ? false : entry.affected === true ? true : count > 0;
  return { affected, count, ids: list };
}

export function normalizePlan(data) {
  const payload = data && typeof data === "object" ? data : {};
  const list = Array.isArray(payload.plans) && payload.plans.length ? payload.plans : null;
  const base = list ? { ...payload, ...list[list.length - 1] } : payload;
  const sequence = list ? list.map((item) => item.plan_id || item.id) : [base.plan_id || base.id];
  const effects = base.effects || payload.effects || {};
  const normalizedEffects = {};
  for (const item of CLASSES) normalizedEffects[item.key] = sessionsOf(effects[item.key]);
  const counts = CLASSES.map((item) => normalizedEffects[item.key].count);
  const active = Number(base.active_sessions != null ? base.active_sessions : effects.total != null ? effects.total : Math.max(0, ...counts));
  return {
    id: base.plan_id || base.id || "",
    sequence,
    target: base.target || "",
    classification: base.classification || "neutral",
    global: base.global === true || base.target === "global" || /^global\b/.test(String(base.target || "")),
    needsConfirm: base.needs_confirm === true,
    operatorOnly: Boolean(base.operator_only || payload.operator_only),
    command: base.operator_command || base.command || payload.operator_command || "",
    files: Array.isArray(base.files) ? base.files : [],
    ledger: base.ledger || null,
    probes: Array.isArray(base.probes) ? base.probes : [],
    journal: Array.isArray(base.journal) ? base.journal : [],
    policyDiff: Array.isArray(base.policy_diff) ? base.policy_diff : [],
    reasons: Array.isArray(base.reasons) ? base.reasons : [],
    effects: normalizedEffects,
    active,
    repo: base.repo || payload.repo || "",
  };
}

export function needsTyped(plan, request) {
  const kind = request && request.change && request.change.kind;
  const target = String(plan.target || (request && request.target && (request.target.kind || request.target)) || "");
  if (plan.needsConfirm || plan.global) return true;
  if (["loosening", "mixed", "global"].includes(plan.classification)) return true;
  if (TYPED_KINDS.includes(kind)) return true;
  if (/^ledger/.test(target)) return true;
  return false;
}

function diffStats(text) {
  let added = 0;
  let removed = 0;
  for (const line of String(text || "").split("\n")) {
    if (line.startsWith("+") && !line.startsWith("+++")) added += 1;
    else if (line.startsWith("-") && !line.startsWith("---")) removed += 1;
  }
  return { added, removed };
}

export function renderDiffBlock(path, text) {
  const block = el("div", "plan-diff-file");
  block.append(el("div", "plan-diff-path mono", path));
  let oldNo = 0;
  let newNo = 0;
  for (const raw of String(text || "").split("\n")) {
    if (raw === "" ) continue;
    const row = el("div", "plan-diff-row");
    const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(raw);
    let sign = " ";
    let kind = "ctx";
    let content = raw;
    let left = "";
    let right = "";
    if (hunk) {
      oldNo = Number(hunk[1]);
      newNo = Number(hunk[2]);
      kind = "hunk";
      sign = "";
    } else if (raw.startsWith("+++") || raw.startsWith("---") || raw.startsWith("diff ") || raw.startsWith("index ")) {
      kind = "meta";
      sign = "";
    } else if (raw.startsWith("+")) {
      kind = "add";
      sign = "+";
      content = raw.slice(1);
      right = String(newNo);
      newNo += 1;
    } else if (raw.startsWith("-")) {
      kind = "del";
      sign = "-";
      content = raw.slice(1);
      left = String(oldNo);
      oldNo += 1;
    } else {
      content = raw.startsWith(" ") ? raw.slice(1) : raw;
      left = String(oldNo);
      right = String(newNo);
      oldNo += 1;
      newNo += 1;
    }
    row.dataset.kind = kind;
    row.append(el("span", "plan-diff-no num", left), el("span", "plan-diff-no num", right), el("span", "plan-diff-sign", sign), el("span", "plan-diff-text mono", content));
    block.append(row);
  }
  return block;
}

function findingsList(findings) {
  const wrap = el("div", "plan-findings");
  const state = document.createElement("ps-state");
  state.setAttribute("kind", "error");
  state.setAttribute("heading", "The change did not validate");
  state.setAttribute("body", "Fix these findings, then plan again.");
  wrap.append(state);
  const list = el("ul", "plan-finding-list");
  for (const finding of findings || []) {
    const item = el("li", "plan-finding");
    if (finding.code) item.append(el("span", "mono", String(finding.code)));
    const where = finding.line ? `Line ${finding.line}${finding.col ? ":" + finding.col : ""}` : finding.pointer || "";
    if (where) item.append(el("span", "num", where));
    item.append(el("span", "", finding.message || String(finding)));
    list.append(item);
  }
  wrap.append(list);
  return wrap;
}

function verdictChip(value) {
  const chip = document.createElement("ps-chip");
  if (["allow", "warn", "deny"].includes(value)) {
    chip.setAttribute("kind", "verdict");
    chip.setAttribute("value", value);
  } else {
    chip.setAttribute("kind", "tag");
    chip.setAttribute("label", String(value == null ? "none" : value));
  }
  chip.setAttribute("size", "table");
  return chip;
}

function changeWord(change) {
  if (change === "tighten") return "Stricter";
  if (change === "loosen") return "Looser";
  return "Same";
}

function plainTable(columns, rows, caption) {
  const table = document.createElement("ps-data-table");
  table.setAttribute("compact", "");
  table.setAttribute("caption", caption);
  return { table, columns, rows };
}

function attachTable(host, spec, empty) {
  host.append(spec.table);
  spec.table.columns = spec.columns;
  spec.table.emptyState = { kind: "empty_first_run", heading: empty };
  spec.table.rows = spec.rows;
}

class PsPlanSheet extends HTMLElement {
  connectedCallback() {
    if (this.dialog) return;
    this.dialog = document.createElement("ps-dialog");
    this.dialog.setAttribute("size", "lg");
    this.dialog.setAttribute("heading", "Plan");
    this.dialog.className = "ps-plan-dialog";
    this.footerHost = el("div", "plan-footer");
    this.footerHost.setAttribute("data-dialog-footer", "");
    this.dialog.append(this.footerHost);
    this.append(this.dialog);
    this.meta = el("div", "plan-meta");
    const header = this.dialog.titleEl.parentElement;
    header.insertBefore(this.meta, this.dialog.closeButton);
    this.bodyHost = this.dialog.body;
    this.footerBox = this.dialog.footer;
    this.s = { status: "idle", request: null, plan: null, typed: false, error: null, result: null, findings: null, retryAt: 0 };
    this.dialog.addEventListener("ps-close", () => this.onClosed());
    this.dialog.addEventListener("keydown", (event) => this.onKey(event));
    this.onSse = (type, record) => {
      if (type === "judgment") this.noteJudgment(record);
    };
  }

  disconnectedCallback() {
    this.teardown();
  }

  teardown() {
    clearInterval(this.countdown);
    clearInterval(this.cellsTimer);
    if (this.controller) this.controller.abort();
    if (this.unsubscribe) this.unsubscribe();
    this.unsubscribe = null;
  }

  onClosed() {
    this.teardown();
    this.dispatchEvent(new CustomEvent("ps-plan-closed", { bubbles: true, detail: { status: this.s.status } }));
  }

  get busy() {
    return this.s.status === "applying";
  }

  async open(request, opener) {
    this.s = { status: "loading", request, plan: null, typed: false, error: null, result: null, findings: null, retryAt: 0 };
    this.teardown();
    this.meta.replaceChildren();
    this.dialog.removeAttribute("busy");
    this.renderLoading();
    if (!this.dialog.open) this.dialog.show(opener);
    await this.load();
  }

  async load() {
    if (this.controller) this.controller.abort();
    this.controller = new AbortController();
    const mine = this.controller;
    this.s.status = "loading";
    this.s.error = null;
    this.s.findings = null;
    this.renderLoading();
    try {
      const data = await post(endpoints.plans, { target: this.s.request.target, change: this.s.request.change }, { signal: mine.signal });
      if (mine.signal.aborted) return;
      this.setPlan(data);
    } catch (error) {
      if (mine.signal.aborted || (error && error.name === "AbortError")) return;
      this.failLoad(error);
    }
  }

  setPlan(data) {
    const plan = normalizePlan(data);
    this.s.plan = plan;
    this.s.typed = needsTyped(plan, this.s.request);
    this.s.status = "ready";
    app.set({ lastPlanId: plan.id });
    announce(`Plan ready. ${plan.classification}.`);
    this.renderMeta();
    this.renderReady();
    if (this.dialog.open) this.focusStart();
  }

  focusStart() {
    if (this.s.typed && !this.s.plan.operatorOnly) {
      const confirm = this.footerHost.querySelector("ps-confirm");
      if (confirm) {
        confirm.focus();
        return;
      }
    }
    this.dialog.closeButton.focus();
  }

  failLoad(error) {
    if (error && error.kind === "invalid") {
      this.s.status = "invalid";
      this.s.findings = error.findings || [{ message: error.message }];
      this.s.plan = null;
      this.meta.replaceChildren();
      this.bodyHost.replaceChildren(findingsList(this.s.findings));
      this.renderFooter();
      return;
    }
    this.s.status = "error";
    this.s.error = error;
    this.bodyHost.replaceChildren();
    if (error && error.kind === "conflict") {
      const handled = !document.dispatchEvent(new CustomEvent("ps-plan-conflict", { cancelable: true, detail: { request: this.s.request } }));
      if (handled) {
        this.dialog.close();
        return;
      }
      const banner = document.createElement("ps-banner");
      banner.setAttribute("severity", "danger");
      banner.setAttribute("text", "The rulebook changed on main since this draft was opened.");
      this.bodyHost.append(banner);
    } else {
      const state = document.createElement("ps-state");
      state.setAttribute("kind", "error");
      state.setAttribute("heading", "The plan could not be made");
      state.setAttribute("body", error && error.message ? error.message : "The request failed.");
      if (error && error.errorId) state.setAttribute("error-id", error.errorId);
      state.addEventListener("ps-retry", () => this.load());
      this.bodyHost.append(state);
    }
    this.renderFooter();
  }

  renderLoading() {
    const box = el("div", "plan-loading");
    box.setAttribute("aria-busy", "true");
    const grid = el("div", "plan-banner");
    for (let i = 0; i < 4; i += 1) {
      const cell = el("div", "plan-cell");
      const skeleton = document.createElement("ps-skeleton");
      skeleton.setAttribute("lines", "3");
      cell.append(skeleton);
      grid.append(cell);
    }
    const lines = document.createElement("ps-skeleton");
    lines.setAttribute("lines", "6");
    box.append(grid, lines);
    this.bodyHost.replaceChildren(box);
    this.renderFooter();
  }

  renderMeta() {
    const plan = this.s.plan;
    this.meta.replaceChildren();
    if (!plan) return;
    const digest = document.createElement("ps-digest");
    digest.setAttribute("kind", "plan id");
    digest.setAttribute("value", plan.id);
    digest.setAttribute("length", String(plan.id.length));
    this.meta.append(digest);
    const chip = document.createElement("ps-chip");
    chip.setAttribute("kind", "classification");
    chip.setAttribute("value", plan.classification);
    this.meta.append(chip);
    if (plan.global && plan.classification !== "global") {
      const global = document.createElement("ps-chip");
      global.setAttribute("kind", "classification");
      global.setAttribute("value", "global");
      this.meta.append(global);
    }
    if (plan.operatorOnly) {
      const operator = document.createElement("ps-chip");
      operator.setAttribute("kind", "tag");
      operator.setAttribute("label", "Operator only");
      this.meta.append(operator);
    }
  }

  cells(plan, crossed) {
    const grid = el("div", "plan-banner");
    grid.setAttribute("role", "list");
    grid.setAttribute("aria-label", "Effect of this plan on active sessions");
    for (const item of CLASSES) {
      const effect = plan.effects[item.key];
      const cell = el("div", "plan-cell");
      cell.setAttribute("role", "listitem");
      cell.dataset.effect = item.key;
      const top = el("div", "plan-cell-top");
      top.append(icon(item.icon), el("span", "text-xs", item.label));
      const number = el("div", "plan-cell-num num", formatCount(effect.count));
      if (!effect.affected) number.dataset.dim = "true";
      let means;
      if (!effect.affected) means = "Not affected";
      else if (crossed) means = `Crossed ${formatCount(Math.min(crossed[item.key] || 0, effect.count))} of ${formatCount(effect.count)}`;
      else means = item.means;
      const line = el("div", "plan-cell-means text-2xs", means);
      cell.append(top, number, line);
      grid.append(cell);
    }
    return grid;
  }

  reachLine(plan) {
    const reached = plan.effects.next_call.count;
    return el("p", "plan-reach text-xs", `Reaches ${formatCount(reached)} of ${formatCount(plan.active)} active sessions on their next call.`);
  }

  renderReady() {
    const plan = this.s.plan;
    this.bodyHost.replaceChildren();
    this.bodyHost.append(this.cells(plan), this.reachLine(plan));
    if (plan.reasons.length) {
      const reasons = el("ul", "plan-reasons text-xs");
      for (const reason of plan.reasons.slice(0, 6)) reasons.append(el("li", "", reason));
      this.bodyHost.append(reasons);
    }
    this.tabs = this.buildTabs(plan);
    this.bodyHost.append(this.tabs);
    this.renderFooter();
  }

  buildTabs(plan) {
    const tabs = document.createElement("ps-tabs");
    tabs.setAttribute("label", "Plan details");
    const panels = [
      ["diff", "Policy diff", undefined, (host) => this.diffPanel(host, plan)],
      ["files", "Files", plan.files.length, (host) => this.filesPanel(host, plan)],
      ["probes", "Probes", plan.probes.length, (host) => this.probesPanel(host, plan)],
      ["journal", "Journal replay", undefined, (host) => this.journalPanel(host, plan)],
      ["ledger", "Ledger effect", undefined, (host) => this.ledgerPanel(host, plan)],
    ];
    const fillers = [];
    for (const [id, label, count, fill] of panels) {
      const panel = el("div", "plan-panel");
      panel.dataset.tab = id;
      panel.dataset.label = label;
      if (count !== undefined) panel.dataset.count = String(count);
      tabs.append(panel);
      fillers.push([panel, fill]);
    }
    this.diffPanelHost = fillers[0][0];
    this.pendingFill = fillers;
    queueMicrotask(() => {
      for (const [panel, fill] of fillers) fill(panel);
    });
    return tabs;
  }

  diffPanel(host, plan) {
    host.replaceChildren();
    if (this.s.findings) {
      host.append(findingsList(this.s.findings));
      return;
    }
    const diffs = plan.files.filter((file) => file.diff);
    if (!diffs.length && !plan.policyDiff.length) {
      host.append(el("p", "text-sm plan-quiet", "No policy text changes in this plan."));
      return;
    }
    const wrap = el("div", "plan-diff");
    wrap.setAttribute("role", "region");
    wrap.setAttribute("aria-label", "Unified diff");
    wrap.tabIndex = 0;
    for (const file of diffs) wrap.append(renderDiffBlock(file.path, file.diff));
    host.append(wrap);
    if (plan.policyDiff.length) {
      const list = el("ul", "plan-structural text-xs");
      for (const entry of plan.policyDiff) {
        const digest = entry.digest || {};
        list.append(el("li", "", `${entry.project || "policy"}: ${digest.before || "none"} to ${digest.after || "none"}`));
      }
      host.append(list);
    }
  }

  filesPanel(host, plan) {
    const rows = plan.files.map((file) => {
      const stats = diffStats(file.diff);
      return { path: file.path, change: ACTIONS[file.action] || file.action || "Modified", added: stats.added, removed: stats.removed };
    });
    const spec = plainTable(
      [
        { key: "path", label: "Path", mono: true },
        { key: "change", label: "Change", width: "96px" },
        { key: "lines", label: "Lines", align: "end", width: "112px", render: (row) => `+${row.added} -${row.removed}` },
      ],
      rows,
      "Files changed",
    );
    attachTable(host, spec, "No files change.");
  }

  probesPanel(host, plan) {
    const rows = plan.probes.map((probe) => ({ probe: probe.probe, project: probe.project, env: probe.env || "", before: probe.before, after: probe.after, change: probe.change }));
    const spec = plainTable(
      [
        { key: "probe", label: "Probe", mono: true },
        { key: "env", label: "Env", width: "72px" },
        { key: "before", label: "Before", width: "104px", render: (row) => verdictChip(row.before) },
        { key: "after", label: "After", width: "104px", render: (row) => verdictChip(row.after) },
        { key: "change", label: "Change", width: "88px", render: (row) => changeWord(row.change) },
      ],
      rows,
      "Probes whose verdict is checked",
    );
    attachTable(host, spec, "No probes were judged.");
  }

  journalPanel(host, plan) {
    const model = aggregate(plan.journal);
    const changed = plan.journal.filter((row) => row.change !== "same").length;
    host.append(el("p", "text-sm plan-quiet", plan.journal.length ? `${formatCount(plan.journal.length)} replayed, ${formatCount(changed)} changed.` : headerLine({ rows: [], replayed: 0, flips: 0, days: 14 })));
    if (model.rows.length) {
      const holder = el("div", "plan-journal");
      host.append(holder);
      renderTable(holder, model, { caption: "Journal replay by project" });
    }
  }

  ledgerPanel(host, plan) {
    if (!plan.ledger) {
      host.append(el("p", "text-sm plan-quiet", "This plan leaves the ledger untouched."));
      return;
    }
    const before = plan.ledger.before && typeof plan.ledger.before === "object" ? plan.ledger.before : {};
    const after = plan.ledger.after && typeof plan.ledger.after === "object" ? plan.ledger.after : {};
    const keys = [...new Set([...Object.keys(before), ...Object.keys(after)])];
    const list = el("dl", "plan-kv");
    const head = el("div", "plan-kv-head text-xs");
    head.append(el("span", "", "Key"), el("span", "", "Before"), el("span", "", "After"));
    list.append(head);
    const show = (value) => (value === undefined ? "none" : typeof value === "object" ? JSON.stringify(value) : String(value));
    for (const key of keys) {
      const row = el("div", "plan-kv-row");
      row.append(el("dt", "mono text-xs", key), el("dd", "mono text-xs", show(before[key])), el("dd", "mono text-xs", show(after[key])));
      if (show(before[key]) !== show(after[key])) row.dataset.changed = "true";
      list.append(row);
    }
    host.append(list);
  }

  reasonText() {
    const plan = this.s.plan;
    if (!plan) return this.s.status === "loading" ? "Planning." : "";
    if (plan.operatorOnly) return "Operator-only action. Run the command in a terminal.";
    if (this.s.typed) return plan.classification === "loosening" || plan.classification === "mixed" ? `${plan.classification === "mixed" ? "Mixed" : "Loosening"} plan. Type the plan id to apply.` : "This kind of change needs the plan id typed. Type the plan id to apply.";
    return `${plan.classification === "tightening" ? "Tightening" : "Neutral"} plan. Applies on one click.`;
  }

  renderFooter() {
    const host = this.footerHost;
    host.replaceChildren();
    clearInterval(this.countdown);
    const status = this.s.status;
    const plan = this.s.plan;
    const notice = el("div", "plan-notice");
    host.append(notice);
    const reason = el("p", "plan-reason text-sm", this.reasonText());
    const action = el("div", "plan-action");
    host.append(reason, action);

    if (status === "loading") {
      this.addApply(action, { disabled: true, reason: "Planning" });
      return;
    }
    if (status === "invalid" || (status === "error" && !plan)) {
      const again = document.createElement("ps-button");
      again.setAttribute("variant", "primary");
      again.setAttribute("size", "md");
      again.text = "Plan again";
      again.addEventListener("click", () => this.load());
      action.append(again);
      this.addApply(action, { disabled: true, reason: status === "invalid" ? "Fix the findings first" : "No plan to apply" });
      return;
    }
    if (!plan) return;
    if (plan.operatorOnly) {
      const command = document.createElement("ps-command");
      command.setAttribute("operator", "");
      command.setAttribute("command", plan.command || `polispec apply ${plan.target}`);
      command.className = "plan-operator";
      action.append(command);
      return;
    }
    if (status === "stale") {
      const banner = document.createElement("ps-banner");
      banner.setAttribute("severity", "danger");
      banner.setAttribute("text", "This plan is out of date. Something changed after it was made.");
      banner.setAttribute("action", "Plan again");
      banner.addEventListener("ps-action", () => this.load());
      notice.append(banner);
      this.addApply(action, { disabled: true, reason: "Plan again first" });
      return;
    }
    if (status === "rate") {
      this.rateFooter(notice, action);
      return;
    }
    if (status === "invalid-apply") {
      this.addApply(action, { disabled: true, reason: "Fix the findings first" });
      return;
    }
    if (status === "error") {
      const box = el("div", "plan-inline-error");
      const error = this.s.error;
      box.setAttribute("role", "alert");
      box.append(el("span", "text-sm", error && error.message ? error.message : "The apply failed."));
      if (error && error.errorId) {
        const id = document.createElement("ps-digest");
        id.setAttribute("kind", "error id");
        id.setAttribute("value", error.errorId);
        id.setAttribute("length", String(error.errorId.length));
        box.append(id);
      }
      const retry = document.createElement("ps-button");
      retry.setAttribute("size", "xs");
      retry.text = "Retry";
      retry.addEventListener("click", () => {
        this.s.status = "ready";
        this.renderFooter();
      });
      box.append(retry);
      notice.append(box);
    }
    this.addApplyControl(action);
  }

  addApply(action, { disabled, reason }) {
    const button = document.createElement("ps-button");
    button.setAttribute("variant", "primary");
    button.setAttribute("size", "md");
    button.text = "Apply plan";
    if (disabled) {
      button.setAttribute("disabled", "");
      if (reason) button.setAttribute("reason", reason);
    }
    action.append(button);
    return button;
  }

  addApplyControl(action) {
    const plan = this.s.plan;
    const busy = this.busy;
    if (this.s.typed) {
      const confirm = document.createElement("ps-confirm");
      confirm.setAttribute("expected", plan.id);
      confirm.setAttribute("action", "Apply plan");
      confirm.setAttribute("busy-label", "Applying");
      if (busy) confirm.setAttribute("busy", "");
      if (this.s.confirmError) confirm.setAttribute("error", this.s.confirmError);
      confirm.addEventListener("ps-confirm", (event) => this.apply(event.detail.value));
      action.append(confirm);
      if (busy) queueMicrotask(() => confirm.input && (confirm.input.readOnly = true));
      return;
    }
    const button = document.createElement("ps-button");
    button.setAttribute("variant", "primary");
    button.setAttribute("size", "md");
    button.setAttribute("busy-label", "Applying");
    button.text = "Apply plan";
    if (busy) button.setAttribute("busy", "");
    button.addEventListener("click", () => this.apply(""));
    action.append(button);
    this.applyButton = button;
  }

  rateFooter(notice, action) {
    const message = el("p", "plan-rate text-sm");
    message.setAttribute("role", "status");
    notice.append(message);
    const tick = () => {
      const left = Math.max(0, Math.ceil((this.s.retryAt - Date.now()) / 1000));
      message.textContent = `Too many changes in a minute. Try again in ${left} s.`;
      if (left <= 0) {
        clearInterval(this.countdown);
        this.s.status = "ready";
        this.renderFooter();
      }
    };
    tick();
    this.countdown = setInterval(tick, 1000);
    this.addApply(action, { disabled: true, reason: "Rate limit" });
  }

  onKey(event) {
    if (!(event.key === "Enter" && (event.metaKey || event.ctrlKey))) return;
    if (this.s.status !== "ready" || !this.s.plan || this.s.plan.operatorOnly) return;
    event.preventDefault();
    if (this.s.typed) {
      const confirm = this.footerHost.querySelector("ps-confirm");
      if (confirm) confirm.submit();
    } else {
      this.apply("");
    }
  }

  async apply(typed) {
    if (this.busy || this.s.status !== "ready") return;
    const plan = this.s.plan;
    if (this.s.typed && typed !== plan.id) return;
    this.s.status = "applying";
    this.s.confirmError = "";
    this.dialog.setAttribute("busy", "");
    this.renderFooter();
    this.controller = new AbortController();
    const mine = this.controller;
    try {
      let result = null;
      for (const id of plan.sequence) {
        const body = this.s.typed ? { confirm: id === plan.id ? typed : id } : {};
        result = await post(endpoints.apply(id), body, { signal: mine.signal });
      }
      this.dialog.removeAttribute("busy");
      this.succeed(result || {});
    } catch (error) {
      this.dialog.removeAttribute("busy");
      this.failApply(error);
    }
  }

  failApply(error) {
    this.s.error = error;
    if (error.kind === "conflict") {
      this.s.status = "stale";
      announce("This plan is out of date.", { assertive: true });
    } else if (error.kind === "rate_limited") {
      this.s.status = "rate";
      this.s.retryAt = Date.now() + (error.retryAfter == null ? 60 : error.retryAfter) * 1000;
    } else if (error.kind === "invalid" && error.code === "confirm_required") {
      this.s.status = "ready";
      this.s.confirmError = "The server did not accept that id. Type the plan id exactly.";
    } else if (error.kind === "invalid") {
      this.s.status = "invalid-apply";
      this.s.findings = error.findings || [{ message: error.message }];
      const panel = this.diffPanelHost;
      if (panel) this.diffPanel(panel, this.s.plan);
      if (this.tabs) this.tabs.select("diff", false);
    } else {
      this.s.status = "error";
    }
    this.renderFooter();
  }

  succeed(result) {
    const plan = this.s.plan;
    this.s.status = "success";
    this.s.result = result;
    const before = result.epoch_before || (result.epoch && result.epoch.before) || "";
    const after = result.epoch_after || (result.epoch && result.epoch.after) || (typeof result.epoch === "string" ? result.epoch : "");
    this.s.epochAfter = after;
    this.seen = {};
    for (const item of CLASSES) this.seen[item.key] = new Set();
    this.bodyHost.replaceChildren();
    const ok = el("div", "plan-ok");
    ok.setAttribute("role", "status");
    ok.append(icon("allow"), el("span", "text-lg", "Applied."));
    this.bodyHost.append(ok);
    const commit = result.commit || "";
    if (commit) this.bodyHost.append(el("p", "text-sm", `Applied on main as ${String(commit).slice(0, 8)}.`));
    const list = el("dl", "plan-kv plan-result");
    const add = (key, node) => {
      const row = el("div", "plan-kv-row");
      row.append(el("dt", "text-xs", key));
      const dd = el("dd", "");
      dd.append(node);
      row.append(dd);
      list.append(row);
    };
    if (commit) {
      const digest = document.createElement("ps-digest");
      digest.setAttribute("kind", "commit");
      digest.setAttribute("value", commit);
      add("Commit", digest);
    }
    const record = result.change_id || result.change || result.record_id || "";
    if (record) add("Change record", el("span", "mono text-sm", String(record)));
    if (before || after) add("Epoch", el("span", "mono text-sm", `${before || "none"} → ${after || "none"}`));
    this.bodyHost.append(list);
    this.cellsHost = el("div", "plan-cells-host");
    this.bodyHost.append(this.cellsHost);
    this.renderCrossed();
    this.bodyHost.append(this.reachLine(plan));
    const follow = el("div", "plan-follow");
    const repo = plan.repo || (this.s.request.target && this.s.request.target.id) || this.projectOf(plan.target);
    if (/^(project|path)/.test(String(plan.target)) || (this.s.request.target && this.s.request.target.kind === "project")) {
      const promote = document.createElement("ps-command");
      promote.setAttribute("command", `polispec promote ${repo} --to test`);
      promote.setAttribute("why", "The gate decides whether it promotes.");
      follow.append(promote);
    }
    if (plan.effects.reload.affected) {
      const reload = document.createElement("ps-command");
      reload.setAttribute("command", "/reload-plugins");
      reload.setAttribute("why", "Run it in each session that should pick up the change.");
      follow.append(reload);
    }
    if (follow.childElementCount) this.bodyHost.append(follow);
    this.footerHost.replaceChildren();
    const actions = el("div", "plan-result-actions");
    const timeline = document.createElement("ps-button");
    timeline.setAttribute("size", "md");
    timeline.text = "Open timeline";
    timeline.addEventListener("click", () => {
      this.dialog.close();
      router.navigate("timeline" + (record ? "?change=" + encodeURIComponent(record) : ""));
    });
    const close = document.createElement("ps-button");
    close.setAttribute("variant", "primary");
    close.setAttribute("size", "md");
    close.text = "Close";
    close.addEventListener("click", () => this.dialog.close());
    actions.append(timeline, close);
    this.footerHost.append(actions);
    close.focus();
    announce("Applied.");
    this.unsubscribe = sse.subscribe(this.onSse);
    document.dispatchEvent(new CustomEvent("ps-plan-applied", { detail: { plan, result, request: this.s.request } }));
  }

  projectOf(target) {
    const match = /^(?:project|path):([^:]+)/.exec(String(target || ""));
    return match ? match[1] : "<repo>";
  }

  crossedCounts() {
    const out = {};
    const plan = this.s.plan;
    for (const item of CLASSES) {
      const effect = plan.effects[item.key];
      const seen = this.seen[item.key];
      if (effect.ids) {
        let count = 0;
        for (const id of effect.ids) if (this.seenAll && this.seenAll.has(id)) count += 1;
        out[item.key] = count;
      } else if (item.key === "next_call") {
        out[item.key] = seen.size;
      } else {
        out[item.key] = 0;
      }
    }
    return out;
  }

  renderCrossed() {
    if (!this.cellsHost) return;
    this.cellsHost.replaceChildren(this.cells(this.s.plan, this.crossedCounts()));
  }

  noteJudgment(record) {
    if (this.s.status !== "success" || !record || typeof record !== "object") return;
    const session = record.session || record.session_id;
    if (!session) return;
    if (this.s.epochAfter && record.epoch !== this.s.epochAfter) return;
    this.seenAll = this.seenAll || new Set();
    if (this.seenAll.has(session)) return;
    this.seenAll.add(session);
    this.seen.next_call.add(session);
    this.renderCrossed();
  }
}

if (!customElements.get("ps-plan-sheet")) customElements.define("ps-plan-sheet", PsPlanSheet);

let singleton = null;

export function planSheet() {
  if (!singleton || !singleton.isConnected) {
    singleton = document.createElement("ps-plan-sheet");
    document.body.append(singleton);
  }
  return singleton;
}

export function openPlan(request, opener) {
  return planSheet().open(request, opener);
}

document.addEventListener("ps-open-plan", (event) => {
  if (event.detail && event.detail.target) openPlan(event.detail, document.activeElement);
});
