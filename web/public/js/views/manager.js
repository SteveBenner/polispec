import "../components/ps-tabs.js";
import "../components/ps-button.js";
import "../components/ps-icon-button.js";
import "../components/ps-select.js";
import "../components/ps-combobox.js";
import "../components/ps-text-field.js";
import "../components/ps-toggle.js";
import "../components/ps-segmented.js";
import "../components/ps-dialog.js";
import "../components/ps-chip.js";
import "../components/ps-banner.js";
import "../components/ps-state.js";
import "../components/ps-skeleton.js";
import "../components/ps-data-table.js";
import "../components/ps-author-panel.js";
import { openPlan, renderDiffBlock } from "../components/ps-plan-sheet.js";
import { rulebookList, loadCatalog, setAuthorTarget, takePendingDraft } from "../components/ps-author-panel.js";
import {
  createYamlEditor,
  parseOutline,
  itemAtLine,
  moveItem,
  setGroup,
  composePoint,
  includeSnippet,
  unifiedDiff,
  merge3,
} from "../editor/codemirror.js";
import { requestFull, post, endpoints } from "../core/api.js";
import { flag } from "../core/store.js";
import { announce } from "../core/announce.js";
import * as router from "../core/router.js";
import { summaryLine } from "./blast-radius.js";

const NS = "http://www.w3.org/2000/svg";
const DRAFT_PREFIX = "polispec.web.draft:";
const LINT_DELAY = 350;
const PERSIST_DELAY = 300;
const BLAST_DELAY = 3000;
const LINT_MIN_GAP = 3000;
const SCOPES = [
  { key: "local", label: "Project-local" },
  { key: "global", label: "Global shelf" },
  { key: "project", label: "Projects" },
  { key: "path", label: "Paths" },
];
const DESCRIPTION_LIMITS = "Needs 2 to 8 sentences and 20 to 400 words.";
const SEVERITY_ICON = { error: "deny", warning: "warn", info: "info" };

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

function button(text, options = {}) {
  const node = document.createElement("ps-button");
  node.setAttribute("size", options.size || "sm");
  if (options.variant) node.setAttribute("variant", options.variant);
  if (options.icon) node.setAttribute("icon", options.icon);
  if (options.write) node.setAttribute("write", "");
  node.text = text;
  return node;
}

function scopeOf(kind) {
  if (kind === "local" || kind === "project-local") return "local";
  if (kind === "global" || kind === "shelf") return "global";
  if (kind === "path" || kind === "paths") return "path";
  return "project";
}

function isGlobal(kind) {
  return scopeOf(kind) === "global";
}

function normalizeSeverity(value) {
  const text = String(value || "error").toLowerCase();
  if (text === "warn" || text === "warning") return "warning";
  if (text === "info" || text === "notice") return "info";
  return "error";
}

function readDraft(kind, id) {
  try {
    const raw = window.sessionStorage.getItem(DRAFT_PREFIX + kind + "/" + id);
    return raw ? JSON.parse(raw) : null;
  } catch (error) {
    return null;
  }
}

function writeDraft(kind, id, payload) {
  try {
    const key = DRAFT_PREFIX + kind + "/" + id;
    if (payload) window.sessionStorage.setItem(key, JSON.stringify(payload));
    else window.sessionStorage.removeItem(key);
  } catch (error) {
    return;
  }
}

export function descriptionOf(text) {
  const lines = String(text).split("\n");
  const index = lines.findIndex((line) => /^description:/.test(line));
  if (index < 0) return null;
  const first = lines[index].replace(/^description:\s*/, "");
  const parts = [];
  if (first && !/^[|>][-+]?\s*$/.test(first)) parts.push(first.replace(/^["']|["']$/g, ""));
  for (let i = index + 1; i < lines.length; i += 1) {
    if (lines[i] !== "" && !/^\s/.test(lines[i])) break;
    if (lines[i].trim()) parts.push(lines[i].trim());
  }
  const value = parts.join(" ").trim();
  const sentences = value.split(/[.!?]+(?:\s+|$)/).filter((part) => part.trim()).length;
  const words = value.split(/\s+/).filter(Boolean).length;
  return { sentences, words };
}

function descriptionLine() {
  return DESCRIPTION_LIMITS;
}

function normalizeParams(item) {
  const raw = item && item.params;
  const list = Array.isArray(raw) ? raw : raw && typeof raw === "object" ? Object.entries(raw).map(([name, spec]) => (spec && typeof spec === "object" ? { name, ...spec } : { name, type: spec })) : [];
  return list.map((param) => {
    const values = param.enum || param.values || null;
    let type = String(param.type || "string").toLowerCase();
    if (values && values.length) type = "enum";
    else if (type === "bool") type = "boolean";
    else if (type === "array") type = "list";
    else if (!["boolean", "list"].includes(type)) type = "string";
    return { name: param.name, type, required: Boolean(param.required), values, description: param.description || param.summary || "", fallback: param.default };
  });
}

class Manager {
  constructor(container, params, signal) {
    this.container = container;
    this.signal = signal;
    this.kind = params[0] || "";
    this.id = params[1] || "";
    this.base = "";
    this.draft = "";
    this.etag = "";
    this.digest = "";
    this.schema = "";
    this.structural = null;
    this.composeInfo = null;
    this.findings = [];
    this.lintStatus = "idle";
    this.lintText = null;
    this.catalog = null;
    this.rulebooks = [];
    this.outline = { items: [], lines: [] };
    this.cursor = { line: 1, col: 1, offset: 0 };
    this.timers = {};
    this.controllers = new Set();
    this.blast = null;
    this.blastExpanded = false;
    this.small = window.matchMedia("(max-width: 1023px)");
    this.selectedOutline = null;
  }

  get loaded() {
    return Boolean(this.editor);
  }

  get dirty() {
    return this.loaded && this.draft !== this.base;
  }

  start() {
    this.build();
    this.bindGlobal();
    this.signal.addEventListener("abort", () => this.teardown(), { once: true });
    return this.boot();
  }

  teardown() {
    for (const timer of Object.values(this.timers)) clearTimeout(timer);
    for (const controller of this.controllers) controller.abort();
    this.controllers.clear();
    if (this.editor) this.editor.destroy();
    this.editor = null;
    if (this.blast) this.blast.destroy();
    this.blast = null;
    this.unbind();
    document.dispatchEvent(new CustomEvent("ps-draft-change", { detail: null }));
    const tray = document.querySelector("ps-plan-tray");
    if (tray && tray.panel) tray.panel.replaceChildren();
    document.documentElement.removeAttribute("data-manager");
  }

  guard() {
    const controller = new AbortController();
    this.controllers.add(controller);
    return controller;
  }

  later(name, delay, fn) {
    clearTimeout(this.timers[name]);
    this.timers[name] = setTimeout(() => {
      if (!this.signal.aborted) fn();
    }, delay);
  }

  build() {
    const root = el("section", "mgr");
    this.root = root;
    const header = el("header", "view-header");
    this.title = el("h1", "", "Manager");
    this.title.tabIndex = -1;
    header.append(this.title);
    this.toolbar = this.buildToolbar();
    this.banners = el("div", "mgr-banners");
    this.body = el("div", "mgr-body");
    this.editorBox = el("div", "mgr-editor");
    this.editorHost = el("div", "mgr-editor-host");
    this.editorBox.append(this.editorHost);
    this.aside = el("aside", "mgr-panel");
    this.aside.setAttribute("aria-label", "Manager panel");
    this.body.append(this.editorBox, this.aside);
    root.append(header, this.toolbar, this.banners, this.body);
    this.container.append(root);
    this.buildTabs();
    this.setLoading(true);
    document.documentElement.setAttribute("data-manager", "");
  }

  buildToolbar() {
    const bar = el("div", "mgr-toolbar");
    bar.setAttribute("role", "toolbar");
    bar.setAttribute("aria-label", "Manager actions");
    this.picker = document.createElement("ps-select");
    this.picker.setAttribute("label", "Rulebook");
    this.picker.setAttribute("hide-label", "");
    this.picker.setAttribute("aria-label", "Rulebook");
    this.picker.setAttribute("searchable", "");
    this.picker.setAttribute("placeholder", "Pick a rulebook");
    this.picker.addEventListener("ps-change", (event) => {
      const value = String(event.detail.value);
      if (value.startsWith("__")) return;
      const [kind, ...rest] = value.split("/");
      router.navigate(`manager/${encodeURIComponent(kind)}/${encodeURIComponent(rest.join("/"))}`);
    });
    this.validation = el("button", "ps-native mgr-validation");
    this.validation.type = "button";
    this.validation.addEventListener("click", () => this.openTab("lint", true));
    this.composeButton = button("Compose");
    this.composeButton.addEventListener("click", () => this.openTab("compose", true));
    this.moveButton = button("Move", { write: true });
    this.moveButton.addEventListener("click", () => this.openMove());
    this.planButton = button("Plan", { variant: "primary", write: true });
    this.planButton.addEventListener("click", () => this.plan());
    this.authorButton = document.createElement("ps-icon-button");
    this.authorButton.setAttribute("icon", "panel-right");
    this.authorButton.setAttribute("label", "Author panel");
    this.authorButton.setAttribute("pressed", "false");
    this.authorButton.addEventListener("click", () => document.dispatchEvent(new CustomEvent("ps-open-author")));
    const left = el("div", "mgr-toolbar-left");
    left.append(this.picker, this.validation, this.composeButton, this.moveButton, this.planButton);
    bar.append(left, this.authorButton);
    this.setControls(false);
    return bar;
  }

  buildTabs() {
    this.tabs = document.createElement("ps-tabs");
    this.tabs.setAttribute("label", "Manager panel");
    this.tabs.setAttribute("selected", this.small.matches ? "editor" : "lint");
    const make = (id, label) => {
      const panel = el("div", `mgr-tab mgr-tab-${id}`);
      panel.dataset.tab = id;
      panel.dataset.label = label;
      this.tabs.append(panel);
      return panel;
    };
    this.editorPanel = make("editor", "Editor");
    this.lintPanel = make("lint", "Lint");
    this.outlinePanel = make("outline", "Outline");
    this.composePanel = make("compose", "Compose");
    this.authorPanel = make("author", "Author");
    this.buildLint();
    this.buildOutline();
    this.buildCompose();
    this.authorPanel.append(document.createElement("ps-author-panel"));
    this.aside.append(this.tabs);
    this.tabs.addEventListener("ps-tab-change", () => this.syncLayout());
    this.syncLayout();
  }

  openTab(id, focus) {
    this.tabs.select(id, focus);
    this.syncLayout();
  }

  syncLayout() {
    const small = this.small.matches;
    if (small && this.editorBox.parentElement !== this.editorPanel) {
      this.editorPanel.append(this.editorBox);
    } else if (!small && this.editorBox.parentElement !== this.body) {
      this.body.prepend(this.editorBox);
      if (this.tabs.value === "editor") this.tabs.select("lint", false);
    }
    this.root.toggleAttribute("data-small", small);
  }

  bindGlobal() {
    this.handlers = [];
    const on = (target, type, fn, options) => {
      target.addEventListener(type, fn, options);
      this.handlers.push(() => target.removeEventListener(type, fn, options));
    };
    on(this.small, "change", () => this.syncLayout());
    on(document, "keydown", (event) => this.onKey(event));
    on(document, "ps-review-plan", () => this.plan());
    on(document, "ps-blast-toggle", (event) => this.onBlastToggle(event.detail.expanded));
    on(document, "ps-plan-applied", (event) => this.onApplied(event.detail));
    on(document, "ps-plan-conflict", (event) => {
      if (!this.sameTarget(event.detail.request && event.detail.request.target)) return;
      event.preventDefault();
      this.showConflict();
    });
    on(document, "ps-author-draft", (event) => this.loadAuthorDraft(event.detail));
    on(document, "ps-panel-open", () => this.authorButton.setAttribute("pressed", "true"));
    on(document, "ps-panel-close", () => this.authorButton.setAttribute("pressed", "false"));
    this.handlers.push(
      router.addRouteGuard((next) => {
        if (!this.dirty || this.leaving) return false;
        if (next.startsWith(`#/manager/${this.kind}/${this.id}`)) return false;
        this.askLeave(next);
        return true;
      }),
    );
    on(
      document,
      "click",
      (event) => {
        const link = event.target.closest && event.target.closest("a[href^='#/']");
        if (!link || !this.dirty) return;
        const target = link.getAttribute("href");
        if (target.startsWith(`#/manager/${this.kind}/${this.id}`)) return;
        event.preventDefault();
        this.askLeave(target);
      },
      true,
    );
  }

  unbind() {
    for (const off of this.handlers || []) off();
    this.handlers = [];
  }

  sameTarget(target) {
    return !target || (target.kind === this.kind && target.id === this.id);
  }

  onKey(event) {
    const mod = event.metaKey || event.ctrlKey;
    if (!mod || event.defaultPrevented) return;
    const key = event.key.toLowerCase();
    if (key === "s" && !event.shiftKey) {
      event.preventDefault();
      this.plan();
    } else if (key === "l" && event.shiftKey) {
      event.preventDefault();
      this.openTab("lint", true);
    } else if (key === "o" && event.shiftKey) {
      event.preventDefault();
      this.openTab("outline", true);
    }
  }

  setControls(enabled) {
    for (const node of [this.picker, this.composeButton, this.moveButton, this.planButton]) {
      node.toggleAttribute("disabled", !enabled && node !== this.picker);
    }
    this.picker.toggleAttribute("disabled", false);
    this.validation.hidden = !enabled;
    this.tools = enabled;
  }

  setLoading(on) {
    if (!on) return;
    this.editorHost.replaceChildren();
    const widths = ["72%", "48%", "86%", "60%", "34%", "78%", "52%", "90%", "40%", "66%", "58%", "30%"];
    const wrap = el("div", "mgr-skeleton");
    wrap.setAttribute("aria-busy", "true");
    for (const width of widths) {
      const line = document.createElement("ps-skeleton");
      line.setAttribute("width", width);
      line.setAttribute("height", "14px");
      wrap.append(line);
    }
    this.editorHost.append(wrap);
    for (const panel of [this.lintPanel, this.outlinePanel]) {
      const holder = el("div", "mgr-skeleton");
      for (let i = 0; i < 4; i += 1) {
        const line = document.createElement("ps-skeleton");
        line.setAttribute("height", "16px");
        holder.append(line);
      }
      panel.querySelector(".mgr-loading")?.remove();
      holder.classList.add("mgr-loading");
      panel.prepend(holder);
    }
  }

  clearLoading() {
    this.root.querySelectorAll(".mgr-loading").forEach((node) => node.remove());
  }

  async boot() {
    try {
      this.catalog = await loadCatalog();
    } catch (error) {
      this.catalog = null;
    }
    if (this.signal.aborted) return;
    this.rulebooks = rulebookList(this.catalog);
    this.fillPicker();
    this.fillCompose();
    if (!this.kind || !this.id) {
      this.clearLoading();
      this.showEmpty();
      return;
    }
    await this.loadSource(true);
  }

  fillPicker() {
    const options = [];
    for (const scope of SCOPES) {
      const entries = this.rulebooks.filter((item) => scopeOf(item.kind) === scope.key);
      if (!entries.length) continue;
      options.push({ value: `__${scope.key}`, label: scope.label, disabled: true });
      for (const item of entries) options.push({ value: `${item.kind}/${item.id}`, label: `${scope.label}: ${item.id}` });
    }
    this.picker.options = options;
    if (this.kind && this.id) {
      const value = `${this.kind}/${this.id}`;
      if (!options.some((option) => option.value === value)) options.push({ value, label: `${SCOPES.find((s) => s.key === scopeOf(this.kind)).label}: ${this.id}` });
      this.picker.options = options;
      this.picker.value = value;
    }
  }

  showEmpty() {
    this.editorHost.replaceChildren();
    const state = document.createElement("ps-state");
    state.setAttribute("kind", "empty_first_run");
    state.setAttribute("heading", "Pick a rulebook to edit");
    state.setAttribute("body", "Choose one in the picker above. Your edits stay in this tab until you plan them.");
    this.editorHost.append(state);
    this.setControls(false);
    setTimeout(() => {
      if (!this.signal.aborted) this.picker.focus();
    }, 60);
    setAuthorTarget(null);
  }

  showError(error) {
    this.editorHost.replaceChildren();
    const state = document.createElement("ps-state");
    state.setAttribute("kind", "error");
    state.setAttribute("heading", "The rulebook did not load");
    state.setAttribute("body", error && error.message ? error.message : "The request failed.");
    if (error && error.errorId) state.setAttribute("error-id", error.errorId);
    state.addEventListener("ps-retry", () => {
      this.setLoading(true);
      this.loadSource(true);
    });
    this.editorHost.append(state);
    this.setControls(false);
    this.clearLoading();
  }

  async fetchSource() {
    const guard = this.guard();
    const result = await requestFull("GET", endpoints.source(this.kind, this.id), { signal: guard.signal });
    const data = result.data && typeof result.data === "object" ? result.data : { yaml: String(result.data || "") };
    return {
      text: String(data.yaml != null ? data.yaml : data.text != null ? data.text : data.source != null ? data.source : ""),
      etag: result.etag || data.etag || data.digest || "",
      digest: data.digest || "",
      schema: data.schema_id || data.schema || "",
      ahead: Number(data.ahead) > 0 ? Number(data.ahead) : 0,
      aheadFiles: Array.isArray(data.ahead_files) ? data.ahead_files.map((entry) => (entry && typeof entry === "object" ? entry.path || entry.file || "" : String(entry))).filter(Boolean) : [],
      trustRef: data.trust_ref || "",
    };
  }

  async loadSource(first) {
    let source;
    try {
      source = await this.fetchSource();
    } catch (error) {
      if (this.signal.aborted || (error && error.name === "AbortError")) return;
      this.showError(error);
      return;
    }
    if (this.signal.aborted) return;
    this.base = source.text;
    this.etag = source.etag;
    this.digest = source.digest;
    this.schema = source.schema;
    this.aheadBanner(source);
    const pending = first ? takePendingDraft() : null;
    const saved = first ? readDraft(this.kind, this.id) : null;
    let text = source.text;
    let restored = false;
    if (pending && pending.target && pending.target.kind === this.kind && pending.target.id === this.id) {
      text = pending.yaml;
    } else if (saved && typeof saved.text === "string" && saved.text !== source.text) {
      text = saved.text;
      restored = true;
    }
    this.draft = text;
    this.mountEditor(text);
    this.clearLoading();
    this.setControls(true);
    setAuthorTarget({ kind: this.kind, id: this.id });
    this.afterChange(true);
    if (restored) this.restoredBanner();
    if (pending && pending.yaml !== source.text) this.noteBanner("Draft from the author loaded into the editor.", "info");
  }

  aheadBanner(source) {
    this.clearBanner("ahead");
    if (!source || !(source.ahead > 0)) return;
    const count = source.ahead;
    const ref = String(source.trustRef || "").split("@")[0] || "the trust ref";
    const banner = this.noteBanner(`main is ${count} ${count === 1 ? "commit" : "commits"} ahead of ${ref}. A plan from here includes those changes.`, "info", "ahead");
    if (source.aheadFiles.length) {
      const list = el("ul", "mgr-ahead-files mono");
      for (const file of source.aheadFiles) list.append(el("li", "", file));
      banner.append(list);
    }
  }

  mountEditor(text) {
    if (this.editor) this.editor.destroy();
    this.editorHost.replaceChildren();
    this.editor = createYamlEditor(this.editorHost, {
      doc: text,
      ariaLabel: `YAML editor for ${this.kind} ${this.id}`,
      onChange: (value) => this.onEdited(value),
      onSelection: (cursor) => this.onCursor(cursor),
      onPlan: () => this.plan(),
      onEscapeTwice: () => this.picker.focus(),
    });
  }

  onEdited(value) {
    if (value === this.draft) return;
    this.draft = value;
    this.afterChange(false);
  }

  onCursor(cursor) {
    this.cursor = cursor;
    const item = itemAtLine(this.outline, cursor.line);
    const enabled = this.tools && Boolean(item);
    this.moveButton.toggleAttribute("disabled", !enabled);
    if (!enabled) this.moveButton.setAttribute("reason", "Place the cursor inside a rule or module to move it");
    else this.moveButton.removeAttribute("reason");
  }

  afterChange(immediate) {
    this.outline = parseOutline(this.draft);
    if (!this.dirty) {
      this.structural = null;
      this.composeInfo = null;
      this.clearBanner("order");
    }
    this.renderOutline();
    this.onCursor(this.cursor);
    this.syncPlanButton();
    if (this.lintStatus !== "idle") this.renderLint();
    this.later("persist", PERSIST_DELAY, () => this.persist());
    this.updateTray();
    if (immediate) this.runLint();
    else this.later("lint", Math.max(LINT_DELAY, LINT_MIN_GAP - (Date.now() - (this.lintSent || 0))), () => this.runLint());
    if (this.blastExpanded) this.later("blast", BLAST_DELAY, () => this.refreshBlast());
  }

  addsDescription() {
    return /^description:/m.test(this.draft) && !/^description:/m.test(this.base);
  }

  descriptionBlocked() {
    return !flag("description").enabled && this.addsDescription();
  }

  syncPlanButton() {
    const global = isGlobal(this.kind);
    this.planButton.text = global ? "Plan global" : "Plan";
    let reason = "";
    if (!this.dirty && !this.structural) reason = "There are no changes to plan";
    else if (this.descriptionBlocked()) reason = "Readers of this rulebook run a polispec older than 0.35.0";
    this.planButton.toggleAttribute("disabled", !this.tools || Boolean(reason));
    if (reason) this.planButton.setAttribute("reason", reason);
    else this.planButton.removeAttribute("reason");
    const blocked = this.descriptionBlocked();
    if (blocked) {
      this.noteBanner("Readers of this rulebook run a polispec older than 0.35.0; a description makes it invalid there.", "warn", "description");
    } else {
      this.clearBanner("description");
    }
  }

  noteBanner(text, severity, key) {
    const id = key || "note";
    this.clearBanner(id);
    const banner = document.createElement("ps-banner");
    banner.setAttribute("severity", severity);
    banner.setAttribute("text", text);
    banner.dataset.key = id;
    this.banners.append(banner);
    return banner;
  }

  clearBanner(key) {
    this.banners.querySelectorAll(`[data-key="${key}"]`).forEach((node) => node.remove());
  }

  restoredBanner() {
    const banner = this.noteBanner("Restored your unsaved draft from this tab.", "info", "restored");
    banner.setAttribute("action", "Discard draft");
    banner.addEventListener("ps-action", () => {
      this.editor.setValue(this.base);
      this.clearBanner("restored");
      writeDraft(this.kind, this.id, null);
    });
  }

  persist() {
    if (!this.loaded) return;
    if (this.dirty) writeDraft(this.kind, this.id, { text: this.draft, digest: this.digest });
    else writeDraft(this.kind, this.id, null);
  }

  changedCount() {
    const before = parseOutline(this.base);
    const after = this.outline;
    const index = (outline) => new Map(outline.items.map((item) => [item.type + ":" + item.id, outline.lines.slice(item.start, item.end + 1).join("\n")]));
    const a = index(before);
    const b = index(after);
    let changed = 0;
    for (const [key, text] of b) if (a.get(key) !== text) changed += 1;
    for (const key of a.keys()) if (!b.has(key)) changed += 1;
    if (!changed && this.dirty) {
      const x = this.base.split("\n");
      const y = this.draft.split("\n");
      for (let i = 0; i < Math.max(x.length, y.length); i += 1) if (x[i] !== y[i]) changed += 1;
    }
    return changed;
  }

  updateTray() {
    if (!this.dirty) {
      document.dispatchEvent(new CustomEvent("ps-draft-change", { detail: null }));
      return;
    }
    const detail = { rulebook: `${this.kind}/${this.id}`, changed: this.changedCount() };
    if (this.lastBlast) {
      detail.flips = this.lastBlast.flips;
      detail.projects = this.lastBlast.rows.filter((row) => row.stricter + row.looser > 0).length;
    }
    document.dispatchEvent(new CustomEvent("ps-draft-change", { detail }));
  }

  request(extra) {
    const kind = this.structural || "replace";
    const change = { kind, yaml: this.draft, base: { etag: this.etag, digest: this.digest } };
    if (this.composeInfo && kind === "compose") change.compose = this.composeInfo;
    return { target: { kind: this.kind, id: this.id }, change: { ...change, ...(extra || {}) } };
  }

  async plan(extra) {
    if (!this.tools || (!extra && this.planButton.hasAttribute("disabled"))) return;
    const unchanged = await this.checkSource();
    if (this.signal.aborted) return;
    if (!unchanged) {
      this.showConflict();
      return;
    }
    openPlan(this.request(extra), this.planButton);
  }

  async checkSource() {
    try {
      const guard = this.guard();
      const result = await requestFull("GET", endpoints.source(this.kind, this.id), { signal: guard.signal, etag: this.etag, retry: false });
      if (result.status === 304) return true;
      const data = result.data && typeof result.data === "object" ? result.data : {};
      const text = data.yaml != null ? data.yaml : data.text != null ? data.text : null;
      if (text !== null) return text === this.base;
      return !result.etag || result.etag === this.etag;
    } catch (error) {
      return true;
    }
  }

  onApplied(detail) {
    const target = detail.request && detail.request.target;
    if (!this.sameTarget(target)) return;
    this.structural = null;
    this.composeInfo = null;
    writeDraft(this.kind, this.id, null);
    this.clearBanner("conflict");
    this.clearBanner("order");
    this.fetchSource()
      .then((source) => {
        if (this.signal.aborted) return;
        this.base = source.text;
        this.etag = source.etag;
        this.digest = source.digest;
        this.aheadBanner(source);
        this.editor.setValue(source.text);
        this.draft = source.text;
        this.afterChange(true);
      })
      .catch(() => null);
  }

  loadAuthorDraft(detail) {
    if (!detail || !this.sameTarget(detail.target)) return;
    this.editor.setValue(detail.yaml);
    this.noteBanner("Draft from the author loaded into the editor.", "info");
    this.editor.focus();
  }

  askLeave(target) {
    const dialog = document.createElement("ps-dialog");
    dialog.setAttribute("size", "sm");
    dialog.setAttribute("heading", "Leave without planning?");
    dialog.setAttribute("dismissible", "");
    dialog.append(el("p", "text-md", "The draft stays in this tab."));
    const footer = el("div", "mgr-dialog-footer");
    footer.setAttribute("data-dialog-footer", "");
    const stay = button("Stay", { size: "md" });
    const leave = button("Leave", { size: "md", variant: "primary" });
    footer.append(stay, leave);
    dialog.append(footer);
    document.body.append(dialog);
    stay.addEventListener("click", () => dialog.close());
    leave.addEventListener("click", () => {
      this.persist();
      this.leaving = true;
      dialog.close();
      window.location.hash = target;
    });
    dialog.addEventListener("ps-close", () => dialog.remove());
    dialog.show();
  }

  showConflict() {
    const banner = this.noteBanner(`${this.kind}/${this.id} changed on main since you opened it.`, "danger", "conflict");
    banner.setAttribute("action", "Show changes");
    banner.addEventListener("ps-action", () => this.showChanges());
    const rebase = button("Rebase draft", { size: "xs" });
    rebase.addEventListener("click", () => this.rebase());
    banner.append(rebase);
    announce("The rulebook changed on main.", { assertive: true });
  }

  async showChanges() {
    let main;
    try {
      main = await this.fetchSource();
    } catch (error) {
      this.noteBanner(error.message || "Could not load main.", "danger", "conflict-error");
      return;
    }
    const dialog = document.createElement("ps-dialog");
    dialog.setAttribute("size", "lg");
    dialog.setAttribute("heading", "Changes on main");
    dialog.setAttribute("dismissible", "");
    const diff = unifiedDiff(this.base, main.text, `${this.kind}/${this.id}`);
    const wrap = el("div", "plan-diff");
    wrap.tabIndex = 0;
    wrap.setAttribute("role", "region");
    wrap.setAttribute("aria-label", "Read-only diff of main");
    if (diff) wrap.append(renderDiffBlock(`${this.kind}/${this.id}`, diff));
    else wrap.append(el("p", "text-sm mgr-quiet", "No text differences."));
    dialog.append(wrap);
    document.body.append(dialog);
    dialog.addEventListener("ps-close", () => dialog.remove());
    dialog.show();
  }

  async rebase() {
    let main;
    try {
      main = await this.fetchSource();
    } catch (error) {
      this.noteBanner(error.message || "Could not load main.", "danger", "conflict-error");
      return;
    }
    const merged = merge3(this.base, this.draft, main.text);
    if (merged !== null) {
      const mine = this.draft;
      this.base = main.text;
      this.etag = main.etag;
      this.digest = main.digest;
      this.aheadBanner(main);
      this.editor.setValue(merged);
      this.clearBanner("conflict");
      this.noteBanner(mine === merged ? "Draft rebased on main." : "Draft rebased on main. Review the merged text before planning.", "ok", "rebased");
      announce("Draft rebased on main");
      this.afterChange(true);
      return;
    }
    this.sideBySide(main);
  }

  sideBySide(main) {
    const dialog = document.createElement("ps-dialog");
    dialog.setAttribute("size", "lg");
    dialog.setAttribute("heading", "Both texts, side by side");
    const note = el("p", "text-sm mgr-quiet", "The draft and main both changed the same lines. Choose which text to keep.");
    const grid = el("div", "mgr-sidebyside");
    const left = el("div", "mgr-side");
    const right = el("div", "mgr-side");
    left.append(el("h3", "", "Your draft"));
    right.append(el("h3", "", "Main"));
    const leftHost = el("div", "mgr-side-editor");
    const rightHost = el("div", "mgr-side-editor");
    left.append(leftHost);
    right.append(rightHost);
    grid.append(left, right);
    dialog.append(note, grid);
    const footer = el("div", "mgr-dialog-footer");
    footer.setAttribute("data-dialog-footer", "");
    const useMain = button("Use main", { size: "md" });
    const keep = button("Keep my draft", { size: "md", variant: "primary" });
    footer.append(useMain, keep);
    dialog.append(footer);
    document.body.append(dialog);
    const a = createYamlEditor(leftHost, { doc: this.draft, readOnly: true, ariaLabel: "Your draft" });
    const b = createYamlEditor(rightHost, { doc: main.text, readOnly: true, ariaLabel: "Main" });
    const adopt = (text) => {
      this.base = main.text;
      this.etag = main.etag;
      this.digest = main.digest;
      this.editor.setValue(text);
      this.clearBanner("conflict");
      this.afterChange(true);
      dialog.close();
    };
    useMain.addEventListener("click", () => adopt(main.text));
    keep.addEventListener("click", () => adopt(this.draft));
    dialog.addEventListener("ps-close", () => {
      a.destroy();
      b.destroy();
      dialog.remove();
    });
    dialog.show();
  }

  async runLint() {
    if (!this.loaded) return;
    const text = this.draft;
    if (this.lintText === text && this.lintStatus === "ready") {
      this.renderLint();
      return;
    }
    if (this.lintController) this.lintController.abort();
    const controller = new AbortController();
    this.lintController = controller;
    this.lintStatus = this.lintStatus === "ready" ? "ready" : "loading";
    if (this.lintStatus === "loading") this.renderLint();
    this.lintSent = Date.now();
    try {
      const data = await post(endpoints.lint, { kind: this.kind, yaml: text }, { signal: controller.signal });
      if (controller.signal.aborted || this.signal.aborted) return;
      this.findings = (Array.isArray(data && data.findings) ? data.findings : Array.isArray(data) ? data : []).map((finding) => ({ ...finding, severity: normalizeSeverity(finding.severity || finding.level) }));
      if (data && data.schema_id) this.schema = data.schema_id;
      this.lintDescription = data && data.description ? data.description : null;
      this.lintText = text;
      this.lintStatus = "ready";
    } catch (error) {
      if (controller.signal.aborted || this.signal.aborted || (error && error.name === "AbortError")) return;
      this.lintStatus = "unavailable";
    }
    this.renderLint();
  }

  allFindings() {
    const list = this.findings.slice();
    if (this.descriptionBlocked()) {
      const lines = this.draft.split("\n");
      const line = Math.max(1, lines.findIndex((entry) => /^description:/.test(entry)) + 1);
      list.push({
        severity: "error",
        code: "description_not_allowed",
        message: "Readers of this rulebook run a polispec older than 0.35.0; a description makes it invalid there.",
        line,
        col: 1,
      });
    }
    return list;
  }

  buildLint() {
    this.lintBanner = document.createElement("ps-banner");
    this.lintBanner.setAttribute("severity", "warn");
    this.lintBanner.setAttribute("text", "Live lint is not responding. The plan still validates before anything applies.");
    this.lintBanner.hidden = true;
    this.lintTable = document.createElement("ps-data-table");
    this.lintTable.setAttribute("compact", "");
    this.lintTable.setAttribute("caption", "Lint findings");
    this.lintTable.setAttribute("openable", "");
    this.lintNote = el("p", "text-xs mgr-quiet mgr-desc");
    this.lintPanel.append(this.lintBanner, this.lintTable, this.lintNote);
    this.lintTable.columns = [
      {
        key: "severity",
        label: "Sev",
        width: "40px",
        render: (row) => {
          const holder = el("span", "mgr-sev");
          holder.append(icon(SEVERITY_ICON[row.severity] || "info"));
          holder.append(el("span", "visually-hidden", row.severity));
          return holder;
        },
      },
      { key: "pos", label: "Line:Col", align: "end", width: "72px", render: (row) => `${row.line || 1}:${row.col || 1}` },
      { key: "code", label: "Code", mono: true, width: "136px" },
      {
        key: "message",
        label: "Message",
        width: "200px",
        render: (row) => {
          const holder = el("span", "mgr-lint-msg");
          holder.append(el("span", "mgr-lint-text", row.message || ""));
          if (row.code) holder.append(el("span", "mono mgr-lint-code", row.code));
          return holder;
        },
      },
    ];
    this.lintTable.addEventListener("ps-row-open", (event) => {
      const row = event.detail.row;
      this.editor.goTo(row.line || 1, row.col || 1);
    });
  }

  renderLint() {
    if (!this.loaded) return;
    const findings = this.allFindings();
    const errors = findings.filter((finding) => finding.severity === "error").length;
    const warnings = findings.filter((finding) => finding.severity === "warning").length;
    this.validation.replaceChildren();
    const chip = document.createElement("ps-chip");
    chip.setAttribute("kind", "verdict");
    if (this.lintStatus === "unavailable") {
      chip.setAttribute("kind", "tag");
      chip.setAttribute("label", "Lint unavailable");
    } else if (errors) {
      chip.setAttribute("value", "deny");
      chip.setAttribute("label", `${errors} ${errors === 1 ? "error" : "errors"}`);
    } else if (warnings) {
      chip.setAttribute("value", "warn");
      chip.setAttribute("label", `${warnings} ${warnings === 1 ? "warning" : "warnings"}`);
    } else {
      chip.setAttribute("value", "allow");
      chip.setAttribute("label", this.lintStatus === "loading" ? "Checking" : "Valid");
    }
    this.validation.append(chip);
    this.validation.setAttribute("aria-label", `Validation: ${chip.getAttribute("label")}. Show lint findings`);
    this.lintBanner.hidden = this.lintStatus !== "unavailable";
    this.lintTable.hidden = this.lintStatus === "loading";
    this.lintTable.emptyState = {
      kind: "empty_cleared",
      heading: `No findings. ${this.schema || "The schema"} and the description lint pass.`,
    };
    this.lintTable.rows = findings.map((finding) => ({ ...finding, pos: `${finding.line || 1}:${finding.col || 1}` }));
    const stats = this.lintDescription || descriptionOf(this.draft);
    if (stats) this.lintNote.textContent = `${stats.sentences} sentences, ${stats.words} words. ${descriptionLine()}`;
    else this.lintNote.textContent = "";
    this.lintNote.hidden = !stats;
    this.editor.setDiagnostics(findings);
    this.syncPlanButton();
  }

  buildOutline() {
    this.outlineList = el("ul", "mgr-outline");
    this.outlineList.setAttribute("role", "listbox");
    this.outlineList.setAttribute("aria-label", "Rules and modules in this rulebook");
    this.outlineEmpty = el("p", "text-sm mgr-quiet", "This rulebook has no rules or module instances.");
    this.outlinePanel.append(this.outlineList, this.outlineEmpty);
    this.outlineList.addEventListener("keydown", (event) => this.onOutlineKey(event));
  }

  renderOutline() {
    if (!this.outlineList) return;
    const items = this.outline.items;
    this.outlineEmpty.hidden = items.length > 0;
    this.outlineList.replaceChildren();
    const groups = [...new Set(items.filter((item) => item.group).map((item) => item.group))];
    items.forEach((item) => {
      const row = el("li", "mgr-outline-row");
      row.setAttribute("role", "option");
      row.tabIndex = item.id === this.selectedOutline ? 0 : -1;
      row.setAttribute("aria-selected", item.id === this.selectedOutline ? "true" : "false");
      row.dataset.id = item.id;
      row.draggable = true;
      const grip = el("span", "mgr-grip");
      grip.append(icon("grip"));
      row.append(grip, el("span", "mono text-sm mgr-outline-id", item.id));
      const tag = el("span", "text-xs mgr-outline-tag", item.type === "module" ? "module" : item.group || "no group");
      row.append(tag);
      if (item.type === "rule") {
        const select = document.createElement("ps-select");
        select.setAttribute("size", "xs");
        select.setAttribute("label", "Move to group");
        select.setAttribute("hide-label", "");
        select.setAttribute("aria-label", `Move ${item.id} to group`);
        select.setAttribute("placeholder", "Group");
        select.options = [...groups.map((name) => ({ value: name, label: name })), { value: "__new", label: "New group" }];
        if (item.group) select.value = item.group;
        select.addEventListener("ps-change", (event) => this.regroup(item.id, String(event.detail.value)));
        row.append(select);
      }
      row.addEventListener("click", (event) => {
        if (event.target.closest("ps-select")) return;
        this.selectOutline(item.id, true);
      });
      row.addEventListener("dragstart", (event) => {
        event.dataTransfer.setData("text/plain", item.id);
        event.dataTransfer.effectAllowed = "move";
        row.dataset.dragging = "true";
      });
      row.addEventListener("dragend", () => delete row.dataset.dragging);
      row.addEventListener("dragover", (event) => {
        event.preventDefault();
        event.dataTransfer.dropEffect = "move";
      });
      row.addEventListener("drop", (event) => {
        event.preventDefault();
        const from = event.dataTransfer.getData("text/plain");
        const peers = items.filter((entry) => entry.type === item.type);
        const to = peers.findIndex((entry) => entry.id === item.id);
        if (from && from !== item.id) this.reorder(from, to);
      });
      this.outlineList.append(row);
    });
  }

  selectOutline(id, focus) {
    this.selectedOutline = id;
    this.outlineList.querySelectorAll("li").forEach((row) => {
      const on = row.dataset.id === id;
      row.setAttribute("aria-selected", on ? "true" : "false");
      row.tabIndex = on ? 0 : -1;
      if (on && focus) row.focus();
    });
    const item = this.outline.items.find((entry) => entry.id === id);
    if (item && this.editor) this.editor.goTo(item.start + 1, 1);
    if (focus) this.outlineList.querySelector(`[data-id="${CSS.escape(id)}"]`)?.focus();
  }

  onOutlineKey(event) {
    const row = event.target.closest && event.target.closest("li");
    if (!row || event.target.closest("ps-select")) return;
    const items = this.outline.items;
    const index = items.findIndex((item) => item.id === row.dataset.id);
    if (index < 0) return;
    if (event.altKey && (event.key === "ArrowUp" || event.key === "ArrowDown")) {
      event.preventDefault();
      const item = items[index];
      const peers = items.filter((entry) => entry.type === item.type);
      const at = peers.indexOf(item);
      const next = event.key === "ArrowUp" ? at - 1 : at + 1;
      if (next < 0 || next >= peers.length) return;
      this.reorder(item.id, next, true);
      return;
    }
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const next = Math.max(0, Math.min(items.length - 1, index + (event.key === "ArrowDown" ? 1 : -1)));
      this.selectOutline(items[next].id, true);
    }
  }

  reorder(id, toIndex, refocus) {
    const result = moveItem(this.draft, id, toIndex);
    if (!result || result.text === this.draft) return;
    this.structural = "reorder";
    this.editor.setValue(result.text);
    this.selectedOutline = id;
    this.afterChange(true);
    this.noteBanner("Order changed. Plan to apply it.", "info", "order");
    announce(`Moved ${id} to position ${result.index + 1} of ${result.total}`);
    this.renderOutline();
    if (refocus) this.outlineList.querySelector(`[data-id="${CSS.escape(id)}"]`)?.focus();
  }

  regroup(id, group) {
    if (group === "__new") {
      this.askGroup(id);
      return;
    }
    const name = group;
    const text = setGroup(this.draft, id, name);
    if (!text || text === this.draft) return;
    this.structural = "regroup";
    this.editor.setValue(text);
    this.afterChange(true);
    this.noteBanner("Order changed. Plan to apply it.", "info", "order");
    announce(`Moved ${id} to group ${name}`);
  }

  askGroup(id) {
    const dialog = document.createElement("ps-dialog");
    dialog.setAttribute("size", "sm");
    dialog.setAttribute("heading", "New group");
    dialog.setAttribute("dismissible", "");
    const field = document.createElement("ps-text-field");
    field.setAttribute("label", "Group name");
    field.setAttribute("mono", "");
    dialog.append(field);
    const footer = el("div", "mgr-dialog-footer");
    footer.setAttribute("data-dialog-footer", "");
    const cancel = button("Cancel", { size: "md" });
    const ok = button("Move to group", { size: "md", variant: "primary" });
    footer.append(cancel, ok);
    dialog.append(footer);
    document.body.append(dialog);
    cancel.addEventListener("click", () => dialog.close());
    ok.addEventListener("click", () => {
      const name = field.value.trim().replace(/[^A-Za-z0-9_.-]/g, "-");
      if (!name) return;
      dialog.close();
      this.regroup(id, name);
    });
    dialog.addEventListener("ps-close", () => {
      dialog.remove();
      this.renderOutline();
    });
    dialog.show();
  }

  buildCompose() {
    this.combo = document.createElement("ps-combobox");
    this.combo.setAttribute("label", "Find a module or package");
    this.combo.setAttribute("placeholder", "Search the shelf");
    this.composeSummary = el("p", "text-xs mgr-quiet");
    this.composeForm = el("div", "mgr-form");
    this.composeFooter = el("div", "mgr-compose-footer");
    this.insertButton = button("Insert into draft", { variant: "primary" });
    this.insertButton.setAttribute("disabled", "");
    this.insertButton.setAttribute("reason", "Pick a module first");
    this.composeFooter.append(this.insertButton);
    this.composePanel.append(this.combo, this.composeSummary, this.composeForm, this.composeFooter);
    this.combo.addEventListener("ps-change", (event) => {
      if (event.target === this.combo) this.pickModule(event.detail.value);
    });
    this.insertButton.addEventListener("click", () => this.insertModule());
    this.shelf = [];
  }

  fillCompose() {
    const catalog = this.catalog || {};
    const modules = (Array.isArray(catalog.modules) ? catalog.modules : []).map((item) => ({ ...item, kind: "module" }));
    const packages = (Array.isArray(catalog.packages) ? catalog.packages : []).map((item) => ({ ...item, kind: "package" }));
    this.shelf = modules.concat(packages);
    this.combo.options = this.shelf.map((item) => ({ value: `${item.kind}:${item.name}`, label: `${item.name} (${item.kind})` }));
  }

  pickModule(value) {
    this.picked = this.shelf.find((item) => `${item.kind}:${item.name}` === value) || null;
    this.composeForm.replaceChildren();
    this.fields = [];
    if (!this.picked) {
      this.composeSummary.textContent = "";
      this.insertButton.setAttribute("disabled", "");
      return;
    }
    this.composeSummary.textContent = this.picked.summary || "";
    for (const param of normalizeParams(this.picked)) this.composeForm.append(this.buildField(param));
    const package_ = this.picked.kind === "package";
    this.insertButton.toggleAttribute("disabled", package_);
    if (package_) this.insertButton.setAttribute("reason", "Packages are applied from the plan sheet, not inserted into a draft");
    else this.insertButton.removeAttribute("reason");
  }

  buildField(param) {
    const wrap = el("div", "mgr-field");
    const label = param.required ? `${param.name} (Required)` : param.name;
    if (param.type === "enum") {
      const select = document.createElement("ps-select");
      select.setAttribute("label", label);
      select.options = param.values.map((value) => ({ value: String(value), label: String(value) }));
      if (param.fallback != null) select.value = String(param.fallback);
      wrap.append(select);
      this.fields.push({ param, read: () => select.value, mark: (text) => (text ? select.setAttribute("state", "error") : select.removeAttribute("state")) });
    } else if (param.type === "boolean") {
      wrap.append(el("span", "mgr-field-label text-xs", label));
      const toggle = document.createElement("ps-toggle");
      toggle.setAttribute("label", param.description || param.name);
      if (param.fallback === true) toggle.setAttribute("checked", "");
      wrap.append(toggle);
      this.fields.push({ param, read: () => (toggle.checked || param.fallback === true ? toggle.checked : ""), mark: () => null });
    } else if (param.type === "list") {
      wrap.append(this.listField(param, label));
    } else {
      const field = document.createElement("ps-text-field");
      field.setAttribute("label", label);
      if (param.description) field.setAttribute("help", param.description);
      field.setAttribute("mono", "");
      if (param.fallback != null) field.setAttribute("value", String(param.fallback));
      wrap.append(field);
      this.fields.push({ param, read: () => field.value.trim(), mark: (text) => (text ? field.setAttribute("error", text) : field.removeAttribute("error")) });
    }
    return wrap;
  }

  listField(param, label) {
    const group = el("div", "mgr-list-field");
    group.setAttribute("role", "group");
    group.setAttribute("aria-label", label);
    group.append(el("span", "mgr-field-label text-xs", label));
    const rows = el("div", "mgr-list-rows");
    const inputs = [];
    const add = () => {
      const row = el("div", "mgr-list-row");
      const field = document.createElement("ps-text-field");
      field.setAttribute("label", `${param.name} item ${inputs.length + 1}`);
      field.setAttribute("hide-label", "");
      field.setAttribute("mono", "");
      const remove = document.createElement("ps-icon-button");
      remove.setAttribute("icon", "close");
      remove.setAttribute("label", `Remove ${param.name} item`);
      remove.addEventListener("click", () => {
        inputs.splice(inputs.indexOf(field), 1);
        row.remove();
      });
      row.append(field, remove);
      rows.append(row);
      inputs.push(field);
    };
    const adder = button("Add item", { size: "xs" });
    adder.addEventListener("click", add);
    add();
    group.append(rows, adder);
    this.fields.push({ param, read: () => inputs.map((field) => field.value.trim()).filter(Boolean), mark: () => null });
    return group;
  }

  insertModule() {
    if (!this.picked || this.picked.kind !== "module") return;
    const values = {};
    let missing = false;
    for (const field of this.fields) {
      const value = field.read();
      const empty = value === "" || (Array.isArray(value) && !value.length);
      if (field.param.required && empty) {
        field.mark("Required");
        missing = true;
      } else {
        field.mark("");
        if (!empty) values[field.param.name] = value;
      }
    }
    if (missing) {
      announce("Fill in the required fields first", { assertive: true });
      return;
    }
    const point = composePoint(this.draft, this.cursor.line);
    const snippet = includeSnippet(this.picked.name, values, point.existing);
    const insert = point.prefix + snippet;
    const at = Math.min(point.offset, this.draft.length);
    this.structural = this.structural || "compose";
    this.composeInfo = { module: this.picked.name, with: values };
    this.editor.insert(at, insert);
    announce(`Inserted ${this.picked.name} into the draft`);
  }

  openMove() {
    const item = itemAtLine(this.outline, this.cursor.line);
    if (!item || !this.tools) return;
    const lines = this.outline.lines.slice(item.start, item.end + 1).join("\n");
    const dialog = document.createElement("ps-dialog");
    dialog.setAttribute("heading", `Move ${item.id}`);
    dialog.setAttribute("dismissible", "");
    const from = document.createElement("ps-text-field");
    from.setAttribute("label", "From");
    from.setAttribute("readonly", "");
    from.setAttribute("mono", "");
    from.setAttribute("value", `${SCOPES.find((scope) => scope.key === scopeOf(this.kind)).label}: ${this.kind}/${this.id}`);
    const to = document.createElement("ps-segmented");
    to.setAttribute("label", "To");
    to.options = [
      { value: "local", label: "Project-local" },
      { value: "global", label: "Global shelf" },
      { value: "project", label: "Project" },
    ];
    to.value = "local";
    const target = document.createElement("ps-select");
    target.setAttribute("label", "Project");
    target.options = this.rulebooks.filter((entry) => scopeOf(entry.kind) === "project").map((entry) => ({ value: entry.id, label: entry.id }));
    target.hidden = true;
    const position = document.createElement("ps-select");
    position.setAttribute("label", "Position");
    const peers = this.outline.items.filter((entry) => entry.type === item.type && entry.id !== item.id);
    const options = [];
    for (const peer of peers) {
      options.push({ value: `before:${peer.id}`, label: `Before ${peer.id}` });
      options.push({ value: `after:${peer.id}`, label: `After ${peer.id}` });
    }
    options.push({ value: "end", label: "At the end" });
    position.options = options;
    position.value = "end";
    to.addEventListener("ps-change", () => {
      target.hidden = to.value !== "project";
    });
    const form = el("div", "mgr-form");
    form.append(from, to, target, position);
    dialog.append(form);
    const footer = el("div", "mgr-dialog-footer");
    footer.setAttribute("data-dialog-footer", "");
    const cancel = button("Cancel", { size: "md" });
    const go = button("Plan move", { size: "md", variant: "primary", write: true });
    footer.append(cancel, go);
    dialog.append(footer);
    document.body.append(dialog);
    cancel.addEventListener("click", () => dialog.close());
    go.addEventListener("click", async () => {
      const where = String(position.value || "end");
      const [mode, rule] = where.split(":");
      const move = {
        item: { type: item.type, id: item.id, yaml: lines },
        from: { kind: this.kind, id: this.id },
        to: { scope: to.value, project: to.value === "project" ? target.value : null, position: { where: mode, rule: rule || null } },
      };
      dialog.close();
      await this.plan({ kind: "move", ...move });
    });
    dialog.addEventListener("ps-close", () => dialog.remove());
    dialog.show();
  }

  onBlastToggle(expanded) {
    this.blastExpanded = Boolean(expanded);
    const tray = document.querySelector("ps-plan-tray");
    if (!tray || !tray.panel) return;
    if (!expanded) {
      if (this.blast) this.blast.destroy();
      this.blast = null;
      tray.panel.replaceChildren();
      return;
    }
    this.refreshBlast();
  }

  async refreshBlast() {
    const tray = document.querySelector("ps-plan-tray");
    if (!tray || !tray.panel || !this.dirty) return;
    if (this.blast) this.blast.destroy();
    const host = el("div", "mgr-blast");
    tray.panel.replaceChildren(host);
    const { mountBlastRadius } = await import("./blast-radius.js");
    this.blast = mountBlastRadius(host, this.request(), {
      onSummary: (text, modelData) => {
        if (modelData) {
          this.lastBlast = modelData;
          document.dispatchEvent(new CustomEvent("ps-draft-change", { detail: { summary: `Draft of ${this.kind}/${this.id}: ${this.changedCount()} rules changed. ${summaryLine(modelData)}` } }));
        } else {
          document.dispatchEvent(new CustomEvent("ps-draft-change", { detail: { summary: `Draft of ${this.kind}/${this.id}: ${this.changedCount()} rules changed. ${text}.` } }));
        }
      },
    });
  }
}

export async function render(container, params, signal) {
  const manager = new Manager(container, params, signal);
  await manager.start();
}

