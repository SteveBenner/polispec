import "../components/ps-data-table.js";
import "../components/ps-select.js";
import "../components/ps-segmented.js";
import "../components/ps-chip.js";
import "../components/ps-digest.js";
import "../components/ps-command.js";
import "../components/ps-state.js";
import { endpoints, get } from "../core/api.js";
import { loadView } from "../core/cache.js";
import { announce } from "../core/announce.js";
import { app } from "../core/store.js";
import { middleTruncate, relTimeElement } from "../core/format.js";
import * as feed from "../core/sse.js";

const WINDOWS = [
  { value: "1h", label: "1 hour" },
  { value: "6h", label: "6 hours" },
  { value: "24h", label: "24 hours" },
];
const STATUSES = [
  { value: "all", label: "All" },
  { value: "current", label: "Current" },
  { value: "pending", label: "Pending" },
  { value: "reload_needed", label: "Needs reload" },
  { value: "stale_briefing", label: "Stale" },
  { value: "untrusted_hook", label: "Untrusted" },
];
const REFRESH_MS = 30000;
const TICK_MS = 30000;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function dash() {
  const node = el("span", "ss-dash", "-");
  node.setAttribute("aria-label", "none");
  return node;
}

function bare(epoch) {
  return String(epoch || "").replace(/^ep_/, "");
}

function capital(text) {
  const value = String(text || "");
  return value.charAt(0).toUpperCase() + value.slice(1);
}

function stamp(value) {
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function digestNode(value, kind, length = 8) {
  const node = document.createElement("ps-digest");
  node.setAttribute("value", bare(value));
  node.setAttribute("kind", kind);
  node.setAttribute("length", String(length));
  return node;
}

function statusCell(session) {
  const wrap = el("span", "ss-status");
  for (const badge of session.badges || []) {
    const chip = document.createElement("ps-chip");
    chip.setAttribute("kind", "session");
    chip.setAttribute("value", badge);
    wrap.append(chip);
  }
  return wrap;
}

function projectsCell(session) {
  const list = session.projects || [];
  const current = list.filter((entry) => entry.in_step).length;
  return `${current} of ${list.length}`;
}

function detailRow(session) {
  const wrap = el("div", "ss-detail");
  const list = session.projects || [];
  if (list.length) {
    const table = el("table", "ss-projects");
    const caption = el("caption", "visually-hidden", `Projects seen by session ${session.id}`);
    const head = el("thead");
    const headRow = el("tr");
    for (const label of ["Project", "Policy digest seen", "Current digest", "In step"]) {
      const th = el("th", "", label);
      th.scope = "col";
      headRow.append(th);
    }
    head.append(headRow);
    const body = el("tbody");
    for (const entry of list) {
      const row = el("tr");
      const name = el("th", "mono", entry.id);
      name.scope = "row";
      const seen = el("td");
      seen.append(digestNode(entry.policy_digest_seen || "", "policy digest seen"));
      const now = el("td");
      now.append(digestNode(entry.current_digest || "", "current policy digest"));
      const step = el("td");
      const chip = document.createElement("ps-chip");
      chip.setAttribute("kind", "session");
      chip.setAttribute("value", entry.in_step ? "current" : "pending");
      chip.setAttribute("label", entry.in_step ? "In step" : "Behind");
      step.append(chip);
      row.append(name, seen, now, step);
      body.append(row);
    }
    table.append(caption, head, body);
    wrap.append(table);
  } else {
    wrap.append(el("p", "ss-none", "No project has been seen by this session yet."));
  }
  if ((session.badges || []).includes("reload_needed")) {
    const command = document.createElement("ps-command");
    command.setAttribute("command", "/reload-plugins");
    command.setAttribute("who", "Run in that Claude Code session.");
    wrap.append(command);
  }
  return wrap;
}

function columns() {
  return [
    {
      key: "id",
      label: "Session",
      width: "128px",
      mono: true,
      sortable: true,
      render: (s) => {
        const span = el("span", "mono", middleTruncate(s.id, 12));
        span.title = s.id;
        return span;
      },
    },
    { key: "harness", label: "Harness", width: "96px", sortable: true },
    { key: "agent_type", label: "Agent", width: "120px", render: (s) => s.agent_type || dash() },
    { key: "started", label: "Started", width: "96px", sortable: true, sortValue: (s) => stamp(s.started), render: (s) => relTimeElement(s.started) },
    { key: "last_call", label: "Last call", width: "96px", sortable: true, sortValue: (s) => stamp(s.last_call), render: (s) => relTimeElement(s.last_call) },
    { key: "runtime_version", label: "Runtime", width: "88px", mono: true, render: (s) => s.runtime_version || dash() },
    { key: "epoch", label: "Epoch", width: "96px", render: (s) => (s.epoch ? digestNode(s.epoch, "epoch") : "") },
    { key: "projects", label: "Projects", width: "96px", align: "end", render: projectsCell },
    { key: "badges", label: "Status", render: statusCell },
  ];
}

export async function render(container, params, signal) {
  const section = el("section", "view sessions");
  const header = el("header", "view-header");
  const heading = el("h1", "", "Sessions");
  heading.tabIndex = -1;
  const chipHost = el("span", "ss-chips");
  const controls = el("div", "ss-controls");
  const windowSelect = document.createElement("ps-select");
  windowSelect.setAttribute("label", "Window");
  windowSelect.setAttribute("value", "1h");
  windowSelect.options = WINDOWS;
  const segmented = document.createElement("ps-segmented");
  segmented.setAttribute("label", "Session status");
  segmented.setAttribute("value", "all");
  segmented.options = STATUSES;
  segmented.classList.add("ss-seg");
  const statusSelect = document.createElement("ps-select");
  statusSelect.setAttribute("label", "Status");
  statusSelect.setAttribute("value", "all");
  statusSelect.options = STATUSES;
  statusSelect.classList.add("ss-statuspick");
  const harnessSelect = document.createElement("ps-select");
  harnessSelect.setAttribute("label", "Harness");
  harnessSelect.setAttribute("value", "all");
  harnessSelect.options = [{ value: "all", label: "All harnesses" }];
  controls.append(windowSelect, segmented, statusSelect, harnessSelect);
  header.append(heading, chipHost, controls);

  const summary = el("p", "ss-summary");
  summary.setAttribute("data-summary", "");
  const table = document.createElement("ps-data-table");
  table.setAttribute("caption", "Active agent sessions");
  table.setAttribute("expandable", "");
  table.setAttribute("state", "loading");
  table.keyBy = "id";
  table.columns = columns();
  table.renderDetail = detailRow;
  table.errorState = { heading: "Sessions did not load" };
  section.append(header, summary, table);
  container.replaceChildren(section);

  let sessions = [];
  let currentEpoch = (app.get().config && app.get().config.epoch) || "";
  let windowValue = "1h";
  let statusValue = "all";
  let harnessValue = "all";
  let loaded = false;
  let redrawQueued = false;
  const untrusted = new Set();

  function windowLabel() {
    return (WINDOWS.find((entry) => entry.value === windowValue) || WINDOWS[0]).label;
  }

  function syncHarness() {
    const names = [...new Set(sessions.map((s) => s.harness).filter(Boolean))].sort();
    const options = [{ value: "all", label: "All harnesses" }, ...names.map((name) => ({ value: name, label: capital(name) }))];
    harnessSelect.options = options;
    if (!options.some((option) => option.value === harnessValue)) harnessValue = "all";
    harnessSelect.value = harnessValue;
  }

  function updateSummary() {
    const total = sessions.length;
    const crossed = sessions.filter((s) => (s.badges || []).includes("current")).length;
    const pending = sessions.filter((s) => (s.badges || []).includes("pending")).length;
    const reload = sessions.filter((s) => (s.badges || []).includes("reload_needed")).length;
    const epoch = bare(currentEpoch).slice(0, 8);
    summary.textContent = `${total} active ${total === 1 ? "session" : "sessions"}. ${crossed} crossed over to epoch ${epoch || "unknown"}, ${pending} pending, ${reload} need /reload-plugins.`;
  }

  function visible() {
    return sessions
      .filter((s) => statusValue === "all" || (s.badges || []).includes(statusValue))
      .filter((s) => harnessValue === "all" || s.harness === harnessValue)
      .sort((a, b) => stamp(b.started) - stamp(a.started));
  }

  function keepFocus(work) {
    const active = document.activeElement;
    let probe = null;
    if (active && table.contains(active) && table.displayed) {
      const tr = active.closest("tr[data-index]");
      if (tr) {
        const row = table.displayed[Number(tr.dataset.index)];
        const focusables = [...tr.querySelectorAll("button, a[href]")];
        if (row) probe = { id: row.id, nth: focusables.indexOf(active) };
      }
    }
    work();
    if (probe && probe.nth >= 0 && table.displayed) {
      const index = table.displayed.findIndex((row) => row.id === probe.id);
      if (index >= 0) {
        const tr = table.tbody.querySelector(`tr[data-index="${index}"]`);
        const target = tr ? [...tr.querySelectorAll("button, a[href]")][probe.nth] : null;
        if (target) target.focus({ preventScroll: true });
      }
    }
  }

  function draw() {
    updateSummary();
    const rows = visible();
    keepFocus(() => {
      if (!sessions.length) {
        table.emptyState = { kind: "empty_cleared", heading: `No agent sessions in the last ${windowLabel()}.` };
      } else {
        table.emptyState = { kind: "empty_filtered", action: "Clear filters" };
      }
      table.rows = rows;
      table.setAttribute("state", "ready");
    });
  }

  function queueDraw() {
    if (redrawQueued) return;
    redrawQueued = true;
    window.requestAnimationFrame(() => {
      redrawQueued = false;
      if (!signal.aborted) draw();
    });
  }

  function noteUntrusted(list) {
    for (const session of list) {
      const flagged = (session.badges || []).includes("untrusted_hook");
      if (flagged && !untrusted.has(session.id)) {
        untrusted.add(session.id);
        if (loaded) announce(`${capital(session.harness)} session ${middleTruncate(session.id, 12)} has an untrusted hook`);
      } else if (!flagged) {
        untrusted.delete(session.id);
      }
    }
  }

  function adopt(data) {
    sessions = (data && data.sessions) || [];
    if (data && data.epoch) currentEpoch = data.epoch;
    noteUntrusted(sessions);
    syncHarness();
    loaded = true;
    draw();
  }

  function onJudgment(record) {
    if (!record || typeof record !== "object") return;
    const action = record.action || {};
    const id = record.session || action.session_id;
    if (!id) return;
    const ts = record.ts || new Date().toISOString();
    const epoch = record.epoch || "";
    const flags = Array.isArray(record.session_badges) ? record.session_badges : null;
    let session = sessions.find((s) => s.id === id);
    if (!session) {
      session = {
        id,
        harness: record.harness || action.harness || "",
        agent_type: action.agent_type || record.agent_type || "",
        started: ts,
        last_call: ts,
        runtime_version: "",
        epoch,
        badges: [epoch && currentEpoch && epoch === currentEpoch ? "current" : "pending"],
        projects: [],
      };
      sessions = [session, ...sessions];
    } else {
      session.last_call = ts;
      if (epoch) {
        session.epoch = epoch;
        if (epoch === currentEpoch && !(session.badges || []).includes("current")) {
          session.badges = [...(session.badges || []).filter((b) => b !== "pending"), "current"];
        }
      }
    }
    if (flags) {
      session.badges = [...new Set([...(session.badges || []), ...flags])];
    }
    noteUntrusted([session]);
    syncHarness();
    queueDraw();
  }

  const unsubscribe = feed.subscribe((type, payload) => {
    if (type === "judgment") onJudgment(payload);
  });

  async function refresh() {
    try {
      const data = await get(endpoints.sessions({ window: windowValue }), { signal });
      if (!signal.aborted) adopt(data);
    } catch (error) {
      return;
    }
  }

  async function load() {
    table.setAttribute("state", "loading");
    try {
      await loadView({
        key: "sessions:" + windowValue,
        path: endpoints.sessions({ window: windowValue }),
        chipHost,
        signal,
        render: (data) => adopt(data),
      });
    } catch (error) {
      if (signal.aborted || loaded) return;
      table.errorState = {
        heading: "Sessions did not load",
        body: error.message || "The request failed.",
        "error-id": error.errorId || "",
      };
      table.setAttribute("state", "error");
    }
  }

  windowSelect.addEventListener("ps-change", (event) => {
    event.stopPropagation();
    windowValue = event.detail.value;
    loaded = false;
    load();
  });
  segmented.addEventListener("ps-change", (event) => {
    statusValue = event.detail.value;
    statusSelect.value = statusValue;
    draw();
  });
  statusSelect.addEventListener("ps-change", (event) => {
    event.stopPropagation();
    statusValue = event.detail.value;
    segmented.value = statusValue;
    draw();
  });
  harnessSelect.addEventListener("ps-change", (event) => {
    event.stopPropagation();
    harnessValue = event.detail.value;
    draw();
  });
  table.addEventListener("ps-action", () => {
    statusValue = "all";
    harnessValue = "all";
    segmented.value = "all";
    statusSelect.value = "all";
    harnessSelect.value = "all";
    draw();
  });
  table.addEventListener("ps-retry", (event) => {
    event.stopPropagation();
    load();
  });

  const refreshTimer = window.setInterval(() => {
    if (!document.hidden) refresh();
  }, REFRESH_MS);
  const tickTimer = window.setInterval(() => {
    if (!document.hidden && loaded) draw();
  }, TICK_MS);
  signal.addEventListener("abort", () => {
    unsubscribe();
    window.clearInterval(refreshTimer);
    window.clearInterval(tickTimer);
  });

  await load();
}
