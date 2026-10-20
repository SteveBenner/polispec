import "../components/ps-data-table.js";
import "../components/ps-chip.js";
import "../components/ps-digest.js";
import "../components/ps-command.js";
import "../components/ps-drawer.js";
import "../components/ps-state.js";
import { endpoints } from "../core/api.js";
import { loadView } from "../core/cache.js";
import { middleTruncate } from "../core/format.js";

const NS = "http://www.w3.org/2000/svg";
const DAY = new Intl.DateTimeFormat("en-GB", { weekday: "long", day: "numeric", month: "long", year: "numeric" });
const SINCE = "30d";
const EFFECT_SCOPE = { host: "host", project: "project" };
const EFFECT_LABEL = { next_call: "Next call", new_session: "New session", reload: "After /reload-plugins", trust: "After trust review" };

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

function bare(epoch) {
  return String(epoch || "").replace(/^ep_/, "");
}

function count(value) {
  if (Array.isArray(value)) return value.length;
  return Number(value) || 0;
}

function list(value) {
  return Array.isArray(value) ? value : [];
}

function pad(number) {
  return String(number).padStart(2, "0");
}

function clock(ts) {
  const date = new Date(ts);
  if (Number.isNaN(date.getTime())) return "";
  return `${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function dayKey(ts) {
  const date = new Date(ts);
  if (Number.isNaN(date.getTime())) return "unknown";
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function dayLabel(ts) {
  const date = new Date(ts);
  if (Number.isNaN(date.getTime())) return "Unknown day";
  return DAY.format(date).replace(",", "");
}

export function subjectText(subject) {
  if (subject == null) return "";
  if (typeof subject === "string") return subject;
  if (subject.plan_id) return subject.plan_id;
  if (Array.isArray(subject.entry_ids) && subject.entry_ids.length) return subject.entry_ids.join(" ");
  if (subject.project && subject.env && subject.tag) return `${subject.project} ${subject.env} ${subject.tag}`;
  if (subject.tag) return subject.tag;
  if (subject.target) return subject.target;
  if (subject.key) return subject.key;
  if (subject.id) return subject.id;
  if (subject.harness) return `${subject.harness} ${subject.scope || ""}`.trim();
  return Object.values(subject).filter((value) => typeof value === "string").join(" ");
}

function effectChips(change) {
  const wrap = el("span", "tl-effects");
  for (const effect of list(change.effects)) {
    const chip = document.createElement("ps-chip");
    chip.setAttribute("kind", "effect");
    chip.setAttribute("value", effect.class);
    const label = EFFECT_LABEL[effect.class] || effect.class;
    chip.title = effect.scope ? `${label}, scope ${EFFECT_SCOPE[effect.scope] || effect.scope}` : label;
    wrap.append(chip);
  }
  return wrap;
}

function epochCell(change) {
  const wrap = el("span", "tl-epoch");
  const before = document.createElement("ps-digest");
  before.setAttribute("value", bare(change.epoch_before));
  before.setAttribute("kind", "epoch before");
  before.setAttribute("length", "8");
  const after = document.createElement("ps-digest");
  after.setAttribute("value", bare(change.epoch_after));
  after.setAttribute("kind", "epoch after");
  after.setAttribute("length", "8");
  const arrow = el("span", "tl-arrow", "→");
  arrow.setAttribute("aria-label", "to");
  wrap.append(before, arrow, after);
  return wrap;
}

function crossedText(change) {
  const crossed = count(change.crossed);
  const total = crossed + count(change.pending) + count(change.flagged);
  return `${crossed} of ${total}`;
}

function sessionList(title, items, kind) {
  const section = el("section", "tl-sessions");
  section.dataset.kind = kind;
  section.append(el("h3", "tl-sessions-title", `${title} (${items.length})`));
  if (!items.length) {
    section.append(el("p", "tl-none", "None."));
    return section;
  }
  const ul = el("ul", "tl-session-list");
  for (const entry of items) {
    const li = el("li", "tl-session");
    const id = el("span", "mono", middleTruncate(entry.id, 16));
    id.title = entry.id;
    li.append(id);
    if (entry.harness) li.append(el("span", "tl-harness", entry.harness));
    for (const badge of list(entry.badges)) {
      const chip = document.createElement("ps-chip");
      chip.setAttribute("kind", "session");
      chip.setAttribute("value", badge);
      li.append(chip);
    }
    ul.append(li);
  }
  section.append(ul);
  return section;
}

function drawerContent(change) {
  const wrap = el("div", "tl-drawer");
  const fields = el("dl", "tl-kv");
  const add = (label, value) => {
    const dt = el("dt", "", label);
    const dd = el("dd");
    if (value instanceof Node) dd.append(value);
    else {
      dd.textContent = value == null || value === "" ? "none" : String(value);
      dd.className = "mono";
    }
    fields.append(dt, dd);
  };
  add("Change", change.id);
  add("Time", change.ts);
  add("Kind", change.kind);
  add("Actor", change.actor);
  const subject = change.subject;
  if (subject && typeof subject === "object") {
    for (const [key, value] of Object.entries(subject)) add(`Subject ${key}`, Array.isArray(value) ? value.join(", ") : value);
  } else add("Subject", subject);
  add("Epoch before", bare(change.epoch_before));
  add("Epoch after", bare(change.epoch_after));
  const effects = el("span", "tl-effects");
  for (const effect of list(change.effects)) {
    const chip = document.createElement("ps-chip");
    chip.setAttribute("kind", "effect");
    chip.setAttribute("value", effect.class);
    effects.append(chip);
    if (effect.scope) effects.append(el("span", "tl-scope", effect.scope));
  }
  add("Effects", list(change.effects).length ? effects : "none");
  const lists = el("div", "tl-lists");
  lists.append(sessionList("Crossed", list(change.crossed), "crossed"), sessionList("Pending", list(change.pending), "pending"), sessionList("Flagged", list(change.flagged), "flagged"));
  const command = document.createElement("ps-command");
  command.setAttribute("command", `polispec changes await ${change.id}`);
  wrap.append(fields, lists, command);
  return wrap;
}

export async function render(container, params, signal) {
  const section = el("section", "view timeline");
  const header = el("header", "view-header");
  const heading = el("h1", "", "Timeline");
  heading.tabIndex = -1;
  const chipHost = el("span", "tl-chips");
  header.append(heading, chipHost);

  const table = document.createElement("ps-data-table");
  table.setAttribute("caption", "Recorded changes");
  table.setAttribute("state", "loading");
  table.keyBy = "id";
  table.classList.add("tl-table");
  table.errorState = { heading: "Changes did not load" };
  table.emptyState = {
    kind: "empty_first_run",
    heading: "No changes recorded.",
    body: "Changes appear here after a plan applies, a promotion, or a settings change.",
    glyph: "list-clock",
  };
  const drawer = document.createElement("ps-drawer");
  section.append(header, table, drawer);
  container.replaceChildren(section);

  const byId = new Map();

  function openChange(id, opener) {
    const change = byId.get(id);
    if (!change) return;
    drawer.setAttribute("heading", `Change ${middleTruncate(change.id, 20)}`);
    drawer.body.replaceChildren(drawerContent(change));
    drawer.show(opener);
  }

  table.columns = [
    {
      key: "time",
      label: "Time",
      width: "64px",
      render: (row) => {
        if (row.type === "day") {
          const label = el("span", "tl-day", row.label);
          label.setAttribute("role", "presentation");
          return label;
        }
        const button = el("button", "ps-native ps-open tl-open mono", clock(row.change.ts));
        button.type = "button";
        button.dataset.change = row.change.id;
        button.title = row.change.ts;
        button.setAttribute("aria-label", `Open change ${row.change.id} at ${clock(row.change.ts)}`);
        return button;
      },
    },
    { key: "kind", label: "Kind", width: "120px", render: (row) => (row.type === "day" ? "" : chipTag(row.change.kind)) },
    { key: "actor", label: "Actor", width: "120px", render: (row) => (row.type === "day" ? "" : row.change.actor || "") },
    {
      key: "subject",
      label: "Subject",
      mono: true,
      render: (row) => {
        if (row.type === "day") return "";
        const span = el("span", "mono", subjectText(row.change.subject));
        span.title = span.textContent;
        return span;
      },
    },
    { key: "effects", label: "Effects", width: "240px", render: (row) => (row.type === "day" ? "" : effectChips(row.change)) },
    { key: "crossed", label: "Crossed", width: "88px", align: "end", render: (row) => (row.type === "day" ? "" : crossedText(row.change)) },
    { key: "epoch", label: "Epoch", width: "176px", render: (row) => (row.type === "day" ? "" : epochCell(row.change)) },
  ];

  table.addEventListener("click", (event) => {
    const button = event.target.closest("[data-change]");
    if (button) openChange(button.dataset.change, button);
  });

  function chipTag(text) {
    const chip = document.createElement("ps-chip");
    chip.setAttribute("kind", "tag");
    chip.setAttribute("label", text || "");
    return chip;
  }

  function adopt(data) {
    const changes = list(data && data.changes)
      .slice()
      .sort((a, b) => Date.parse(b.ts) - Date.parse(a.ts));
    byId.clear();
    const rows = [];
    let current = null;
    for (const change of changes) {
      byId.set(change.id, change);
      const key = dayKey(change.ts);
      if (key !== current) {
        current = key;
        rows.push({ id: `day:${key}`, type: "day", label: dayLabel(change.ts) });
      }
      rows.push({ id: change.id, type: "change", change });
    }
    table.rows = rows;
    table.setAttribute("state", "ready");
  }

  let loaded = false;
  async function load() {
    table.setAttribute("state", "loading");
    try {
      await loadView({
        key: "timeline",
        path: endpoints.changes({ since: SINCE }),
        chipHost,
        signal,
        render: (data) => {
          loaded = true;
          adopt(data);
        },
      });
    } catch (error) {
      if (signal.aborted || loaded) return;
      table.errorState = {
        heading: "Changes did not load",
        body: error.message || "The request failed.",
        "error-id": error.errorId || "",
      };
      table.setAttribute("state", "error");
    }
  }

  table.addEventListener("ps-retry", (event) => {
    event.stopPropagation();
    load();
  });

  await load();
}
