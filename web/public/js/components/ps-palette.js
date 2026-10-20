import "./ps-dialog.js";
import "./ps-text-field.js";
import "./ps-skeleton.js";
import "./ps-kbd.js";
import { NAV_GROUPS } from "./ps-nav.js";
import { trapTab } from "./ps-side-panel.js";
import { CHOICES, LABELS, setChoice } from "../core/theme.js";
import { get, endpoints } from "../core/api.js";
import { app } from "../core/store.js";
import { getPref, setPref } from "../core/cache.js";
import { announce, toast } from "../core/announce.js";
import { navigate } from "../core/router.js";
import * as feed from "../core/sse.js";

const NS = "http://www.w3.org/2000/svg";
const MAX_OPTIONS = 50;
const RECENT_LIMIT = 8;
const GROUPS = ["Go to", "Projects", "Rulebooks", "Actions", "Theme"];
const JUDGMENT_ID = /^[A-Za-z0-9][A-Za-z0-9_-]{5,}$/;
let sequence = 0;

function icon(name) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "ps-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

function score(query, entry) {
  if (!query) return 3;
  const q = query.toLowerCase();
  const label = entry.label.toLowerCase();
  if (label.startsWith(q)) return 0;
  const words = `${label} ${(entry.keywords || "").toLowerCase()}`.split(/[\s/:._-]+/);
  if (words.some((word) => word.startsWith(q))) return 1;
  const haystack = `${label} ${(entry.keywords || "").toLowerCase()}`;
  let position = 0;
  for (const char of q) {
    position = haystack.indexOf(char, position);
    if (position === -1) return -1;
    position += 1;
  }
  return 2;
}

function readRecent() {
  const value = getPref("palette-recent", []);
  return Array.isArray(value) ? value : [];
}

function remember(id) {
  const next = [id, ...readRecent().filter((entry) => entry !== id)].slice(0, RECENT_LIMIT);
  setPref("palette-recent", next);
}

function listFrom(data, keys) {
  if (Array.isArray(data)) return data;
  for (const key of keys) if (data && Array.isArray(data[key])) return data[key];
  return [];
}

class PsPalette extends HTMLElement {
  connectedCallback() {
    if (this.dialog) return;
    sequence += 1;
    this.uid = `ps-palette-${sequence}`;
    this.dialog = document.createElement("ps-dialog");
    this.dialog.setAttribute("heading", "Search or run a command");
    this.dialog.setAttribute("size", "md");
    this.field = document.createElement("ps-text-field");
    this.field.setAttribute("label", "Search or run a command");
    this.field.setAttribute("hide-label", "");
    this.field.setAttribute("size", "md");
    this.field.setAttribute("icon", "search");
    this.field.setAttribute("placeholder", "Search or run a command");
    this.list = document.createElement("div");
    this.list.className = "ps-list";
    this.list.id = `${this.uid}-list`;
    this.list.setAttribute("role", "listbox");
    this.list.setAttribute("aria-label", "Commands");
    this.status = document.createElement("div");
    this.status.className = "visually-hidden";
    this.status.setAttribute("role", "status");
    this.dialog.append(this.field, this.list, this.status);
    this.append(this.dialog);
    this.input = this.field.input;
    this.input.setAttribute("role", "combobox");
    this.input.setAttribute("aria-autocomplete", "list");
    this.input.setAttribute("aria-expanded", "true");
    this.input.setAttribute("aria-controls", this.list.id);
    this.input.setAttribute("aria-haspopup", "listbox");
    this.input.autocomplete = "off";
    this.input.setAttribute("spellcheck", "false");
    this.items = [];
    this.active = -1;
    this.data = { projects: { state: "idle", rows: [] }, rulebooks: { state: "idle", rows: [] } };
    this.input.addEventListener("input", () => {
      this.active = 0;
      this.render();
    });
    this.input.addEventListener("keydown", (event) => this.onKey(event));
    this.dialog.addEventListener("keydown", (event) => trapTab(this.dialog.dialog, event));
    this.list.addEventListener("mousedown", (event) => event.preventDefault());
    this.list.addEventListener("click", (event) => {
      const row = event.target.closest("[role=option]");
      if (row) this.run(this.items[Number(row.dataset.index)]);
    });
    this.list.addEventListener("pointermove", (event) => {
      const row = event.target.closest("[role=option]");
      if (!row) return;
      const index = Number(row.dataset.index);
      if (index !== this.active) this.setActive(index, false);
    });
    this.dialog.addEventListener("ps-close", (event) => {
      if (event.target !== this.dialog) return;
      const pending = this.pending;
      this.pending = null;
      if (pending) setTimeout(pending, 0);
    });
    this.onOpen = (event) => this.open(event.detail && event.detail.opener);
    document.addEventListener("ps-open-palette", this.onOpen);
  }

  disconnectedCallback() {
    document.removeEventListener("ps-open-palette", this.onOpen);
  }

  open(opener) {
    if (this.dialog.open) return;
    this.input.value = "";
    this.active = 0;
    this.pending = null;
    this.loadData();
    this.render();
    this.dialog.show(opener || document.activeElement);
    this.input.focus();
  }

  async loadData() {
    const jobs = [
      ["projects", endpoints.map, ["projects", "entries"]],
      ["rulebooks", endpoints.catalog, ["rulebooks", "entries"]],
    ];
    for (const [name, path, keys] of jobs) {
      const slot = this.data[name];
      if (slot.state === "loading") continue;
      slot.state = "loading";
      this.render();
      try {
        const data = await get(path);
        slot.rows = listFrom(data, keys);
        slot.state = "ready";
      } catch (error) {
        slot.rows = [];
        slot.state = "error";
      }
      if (this.dialog.open) this.render();
    }
  }

  commands() {
    const entries = [];
    for (const group of NAV_GROUPS) {
      for (const item of group.items) {
        entries.push({
          id: `go:${item.route}`,
          group: "Go to",
          label: `Go to ${item.name}`,
          keywords: item.route,
          icon: item.icon,
          hint: `g ${this.goKey(item.route)}`.trim(),
          run: () => navigate(item.route),
        });
      }
    }
    for (const row of this.data.projects.rows) {
      const id = typeof row === "string" ? row : row.id;
      if (!id) continue;
      entries.push({
        id: `project:${id}`,
        group: "Projects",
        label: `Open project ${id}`,
        keywords: `${id} detail`,
        icon: "layers",
        hint: "Project",
        run: () => navigate(`detail/${id}`),
      });
    }
    for (const row of this.data.rulebooks.rows) {
      const id = typeof row === "string" ? row : row.id;
      const kind = typeof row === "string" ? "" : row.kind || "";
      if (!id) continue;
      const path = kind ? `${kind}/${id}` : id;
      entries.push({
        id: `rulebook:${path}`,
        group: "Rulebooks",
        label: `Open rulebook ${path} in manager`,
        keywords: `${path} edit`,
        icon: "edit",
        hint: "Manager",
        run: () => navigate(`manager/${path}`),
      });
      entries.push({
        id: `history:${path}`,
        group: "Rulebooks",
        label: `Open history of ${path}`,
        keywords: `${path} rewind`,
        icon: "rewind",
        hint: "History",
        run: () => navigate(`history/${path}`),
      });
    }
    const config = app.get().config || {};
    entries.push({
      id: "action:copy-epoch",
      group: "Actions",
      label: "Copy the epoch",
      keywords: "epoch digest clipboard",
      icon: "copy",
      hint: "Copy",
      run: () => this.copy(config.epoch, "No epoch is known yet."),
    });
    entries.push({
      id: "action:copy-plan",
      group: "Actions",
      label: "Copy the last plan id",
      keywords: "plan clipboard",
      icon: "copy",
      hint: "Copy",
      run: () => this.copy(app.get().lastPlanId, "No plan has been made yet."),
    });
    const running = ["live", "connecting", "reconnecting"].includes(feed.getState());
    entries.push({
      id: "action:feed",
      group: "Actions",
      label: running ? "Pause the feed" : "Resume the feed",
      keywords: "feed stream pause resume",
      icon: running ? "pause" : "play",
      hint: "Feed",
      run: () => (running ? feed.stop() : feed.start()),
    });
    entries.push({
      id: "action:author",
      group: "Actions",
      label: "Open the author panel",
      keywords: "author draft panel",
      icon: "panel-right",
      hint: "Panel",
      run: () => document.dispatchEvent(new CustomEvent("ps-open-author")),
    });
    entries.push({
      id: "action:shortcuts",
      group: "Actions",
      label: "Open keyboard shortcuts",
      keywords: "keys help",
      icon: "info",
      hint: "?",
      run: () => document.dispatchEvent(new CustomEvent("ps-open-shortcuts")),
    });
    for (const choice of CHOICES) {
      entries.push({
        id: `theme:${choice}`,
        group: "Theme",
        label: `Theme: ${LABELS[choice]}`,
        keywords: `theme ${choice}`,
        glyph: choice,
        hint: "Theme",
        run: () => {
          setChoice(choice);
          announce(`Theme: ${LABELS[choice]}`);
        },
      });
    }
    return entries;
  }

  goKey(route) {
    const keys = { map: "m", pipeline: "p", sessions: "s", feed: "f", timeline: "t", heatmap: "h", playground: "y", explain: "x", history: "i", manager: "c", gallery: "a", exceptions: "e", register: "r", manifest: "n" };
    return keys[route] || "";
  }

  copy(value, missing) {
    if (!value) {
      toast(missing, { kind: "info" });
      return;
    }
    navigator.clipboard.writeText(String(value)).then(
      () => document.dispatchEvent(new CustomEvent("ps-copied", { detail: { text: String(value), message: "Copied" } })),
      () => document.dispatchEvent(new CustomEvent("ps-copy-failed", { detail: { text: String(value), message: "Select and copy the value." } }))
    );
  }

  matches() {
    const query = this.input.value.trim();
    const recent = readRecent();
    const scored = [];
    this.commands().forEach((entry, order) => {
      const rank = score(query, entry);
      if (rank < 0) return;
      const recency = recent.indexOf(entry.id);
      scored.push({ entry, rank, recency: recency === -1 ? RECENT_LIMIT : recency, order });
    });
    const best = scored.reduce((low, row) => Math.min(low, row.rank), 3);
    const kept = query && best <= 1 ? scored.filter((row) => row.rank <= 1) : scored;
    const byGroup = new Map(GROUPS.map((group) => [group, []]));
    for (const row of kept) byGroup.get(row.entry.group).push(row);
    const out = [];
    for (const group of GROUPS) {
      const rows = byGroup.get(group);
      rows.sort((a, b) => a.rank - b.rank || a.recency - b.recency || a.order - b.order);
      for (const row of rows) out.push(row.entry);
    }
    if (query && JUDGMENT_ID.test(query)) {
      out.push({
        id: `explain:${query}`,
        group: "Actions",
        label: `Explain judgment ${query}`,
        keywords: "",
        icon: "question",
        hint: "Explainer",
        run: () => navigate(`explain/${query}`),
      });
    }
    return { query, rows: out };
  }

  groupId(group) {
    return `${this.uid}-group-${group.replace(/\s+/g, "-").toLowerCase()}`;
  }

  buildOption(entry, index) {
    const row = document.createElement("div");
    row.className = "ps-option";
    row.id = `${this.uid}-option-${index}`;
    row.setAttribute("role", "option");
    row.dataset.index = String(index);
    row.setAttribute("aria-describedby", this.groupId(entry.group));
    row.title = entry.label;
    const lead = entry.glyph ? this.themeGlyph(entry.glyph) : icon(entry.icon);
    const label = document.createElement("span");
    label.className = "ps-label";
    label.textContent = entry.label;
    const hint = document.createElement("span");
    hint.className = "ps-hint";
    if (/^g [a-z]$/.test(entry.hint || "")) {
      const kbd = document.createElement("ps-kbd");
      kbd.textContent = entry.hint;
      hint.append(kbd);
    } else {
      hint.textContent = entry.hint || "";
    }
    row.append(lead, label, hint);
    return row;
  }

  render() {
    const { query, rows } = this.matches();
    const shown = rows.slice(0, MAX_OPTIONS);
    this.items = [];
    const nodes = [];
    for (const group of GROUPS) {
      const entries = shown.filter((entry) => entry.group === group);
      const key = group === "Projects" ? "projects" : group === "Rulebooks" ? "rulebooks" : null;
      const slot = key ? this.data[key] : null;
      const loading = Boolean(slot) && slot.state === "loading" && !query;
      const failed = Boolean(slot) && slot.state === "error" && !query;
      if (!entries.length && !loading && !failed) continue;
      const header = document.createElement("div");
      header.className = "ps-group";
      header.setAttribute("role", "presentation");
      header.id = this.groupId(group);
      header.textContent = group;
      nodes.push(header);
      if (loading) {
        const note = document.createElement("div");
        note.className = "ps-note";
        note.setAttribute("role", "presentation");
        const text = document.createElement("span");
        text.textContent = `Loading ${key}`;
        const skeleton = document.createElement("ps-skeleton");
        skeleton.setAttribute("lines", "2");
        note.append(text, skeleton);
        nodes.push(note);
      }
      for (const entry of entries) {
        nodes.push(this.buildOption(entry, this.items.length));
        this.items.push(entry);
      }
      if (failed) {
        const retry = {
          id: `retry:${key}`,
          group,
          label: `${group} did not load. Retry`,
          icon: "reset",
          hint: "Retry",
          run: () => {
            this.data[key].state = "idle";
            this.loadData();
          },
        };
        nodes.push(this.buildOption(retry, this.items.length));
        this.items.push(retry);
      }
    }
    if (!this.items.length) {
      const empty = document.createElement("div");
      empty.className = "ps-empty";
      empty.setAttribute("role", "presentation");
      const title = document.createElement("div");
      title.className = "ps-title";
      title.textContent = `No command matches "${query}"`;
      const hint = document.createElement("div");
      hint.className = "ps-body";
      hint.textContent = "Try a view name, a project id, or a rule id.";
      empty.append(title, hint);
      nodes.push(empty);
    }
    if (rows.length > MAX_OPTIONS) {
      const more = document.createElement("div");
      more.className = "ps-note";
      more.setAttribute("role", "presentation");
      more.textContent = `Showing ${MAX_OPTIONS} of ${rows.length}. Keep typing to narrow.`;
      nodes.push(more);
    }
    this.list.replaceChildren(...nodes);
    if (this.active >= this.items.length) this.active = this.items.length - 1;
    if (this.active < 0 && this.items.length) this.active = 0;
    this.setActive(this.active, true);
    const total = this.items.length;
    this.status.textContent = total ? `${total} ${total === 1 ? "result" : "results"}` : "No results";
  }

  themeGlyph(choice) {
    const svg = document.createElementNS(NS, "svg");
    svg.setAttribute("class", "ps-icon");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("aria-hidden", "true");
    const use = document.createElementNS(NS, "use");
    use.setAttribute("href", `icons/icons.svg#t-${choice}`);
    svg.append(use);
    return svg;
  }

  setActive(index, scroll) {
    const rows = this.list.querySelectorAll("[role=option]");
    for (const row of rows) row.removeAttribute("aria-selected");
    this.active = index;
    const row = rows[index];
    if (!row) {
      this.input.removeAttribute("aria-activedescendant");
      return;
    }
    row.setAttribute("aria-selected", "true");
    this.input.setAttribute("aria-activedescendant", row.id);
    if (scroll) row.scrollIntoView({ block: "nearest" });
  }

  onKey(event) {
    const total = this.items.length;
    if (event.key === "ArrowDown") {
      event.preventDefault();
      if (total) this.setActive((this.active + 1) % total, true);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      if (total) this.setActive((this.active - 1 + total) % total, true);
    } else if (event.key === "Enter") {
      event.preventDefault();
      if (this.items[this.active]) this.run(this.items[this.active]);
    }
  }

  run(entry) {
    if (!entry) return;
    if (entry.id.startsWith("retry:")) {
      entry.run();
      return;
    }
    remember(entry.id);
    this.pending = entry.run;
    this.dialog.close();
  }
}

customElements.define("ps-palette", PsPalette);
