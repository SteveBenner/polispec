import "../components/ps-data-table.js";
import "../components/ps-combobox.js";
import "../components/ps-segmented.js";
import "../components/ps-toggle.js";
import "../components/ps-conn-status.js";
import "../components/ps-banner.js";
import "../components/ps-button.js";
import "../components/ps-chip.js";
import "../components/ps-state.js";
import { endpoints, get } from "../core/api.js";
import { announce } from "../core/announce.js";
import { getPref, setPref } from "../core/cache.js";
import { flag } from "../core/store.js";
import { middleTruncate } from "../core/format.js";
import * as feed from "../core/sse.js";

const LIMIT = 1000;
const FLUSH_MS = 250;
const ANNOUNCE_GAP_MS = 2000;
const VERDICTS = [
  { value: "all", label: "All" },
  { value: "allow", label: "Allow" },
  { value: "warn", label: "Warn" },
  { value: "deny", label: "Deny" },
];
const CONN = { live: "live", connecting: "reconnecting", reconnecting: "reconnecting", paused: "paused", closed: "offline", disabled: "off" };

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

export function normalize(record) {
  if (!record || typeof record !== "object" || !record.id) return null;
  const action = record.action || {};
  const target = (Array.isArray(record.targets) && record.targets[0]) || {};
  const outcome = record.outcome || {};
  return {
    id: record.id,
    ts: record.ts || "",
    session: record.session || action.session_id || "",
    harness: record.harness || action.harness || "",
    project: record.project != null ? record.project : target.project || "",
    env: record.env != null ? record.env : target.env || "",
    tool: record.tool != null ? record.tool : action.tool || "",
    verdict: record.verdict || outcome.verdict || target.verdict || "allow",
    rule: record.rule_id != null ? record.rule_id : record.rule != null ? record.rule : outcome.rule_id || target.rule_id || "",
  };
}

function pad(number) {
  return String(number).padStart(2, "0");
}

function clock(ts) {
  const date = new Date(ts);
  if (Number.isNaN(date.getTime())) return "";
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

function tagChip(text) {
  const chip = document.createElement("ps-chip");
  chip.setAttribute("kind", "tag");
  chip.setAttribute("label", text || "");
  return chip;
}

function verdictChip(value) {
  const chip = document.createElement("ps-chip");
  chip.setAttribute("kind", "verdict");
  chip.setAttribute("value", ["allow", "warn", "deny"].includes(value) ? value : "allow");
  return chip;
}

function monoSpan(text, limit) {
  const span = el("span", "mono", limit ? middleTruncate(text, limit) : text);
  span.title = text;
  return span;
}

export async function render(container, params, signal) {
  const saved = getPref("feed.filters", {}) || {};
  const filters = {
    session: Array.isArray(saved.session) ? saved.session : [],
    project: Array.isArray(saved.project) ? saved.project : [],
    rule: Array.isArray(saved.rule) ? saved.rule : [],
    verdict: ["all", "allow", "warn", "deny"].includes(saved.verdict) ? saved.verdict : "all",
  };

  const section = el("section", "view feed");
  const header = el("header", "view-header");
  const heading = el("h1", "", "Feed");
  heading.tabIndex = -1;
  header.append(heading);

  const toolbar = el("div", "fd-toolbar");
  toolbar.setAttribute("role", "group");
  toolbar.setAttribute("aria-label", "Feed controls");
  function combo(label, key) {
    const node = document.createElement("ps-combobox");
    node.setAttribute("label", label);
    node.setAttribute("multiple", "");
    node.setAttribute("placeholder", label);
    node.setAttribute("hide-label", "");
    node.setAttribute("size", "sm");
    node.classList.add("fd-filter");
    node.dataset.key = key;
    return node;
  }
  const sessionBox = combo("Session", "session");
  const projectBox = combo("Project", "project");
  const ruleBox = combo("Rule", "rule");
  const verdictSeg = document.createElement("ps-segmented");
  verdictSeg.setAttribute("label", "Verdict");
  verdictSeg.setAttribute("value", filters.verdict);
  verdictSeg.options = VERDICTS;
  const pauseToggle = document.createElement("ps-toggle");
  pauseToggle.setAttribute("label", "Hold");
  const announceToggle = document.createElement("ps-toggle");
  announceToggle.setAttribute("label", "Announce denies");
  if (getPref("feed.announce", false) === true) announceToggle.setAttribute("checked", "");
  const conn = document.createElement("ps-conn-status");
  conn.setAttribute("size", "sm");
  conn.setAttribute("state", CONN[feed.getState()] || "offline");
  toolbar.append(sessionBox, projectBox, ruleBox, verdictSeg, pauseToggle, announceToggle, conn);

  const banner = document.createElement("ps-banner");
  banner.hidden = true;
  const region = el("div", "fd-region");
  const table = document.createElement("ps-data-table");
  table.setAttribute("caption", "Live judgments, newest first");
  table.setAttribute("compact", "");
  table.setAttribute("state", "ready");
  table.keyBy = "id";
  table.classList.add("fd-table");
  const pill = el("div", "fd-pill");
  pill.hidden = true;
  const pillButton = document.createElement("ps-button");
  pillButton.setAttribute("variant", "primary");
  pillButton.setAttribute("size", "sm");
  pillButton.setAttribute("icon", "chevron-down");
  pillButton.text = "0 new judgments";
  pill.append(pillButton);
  const disabledHost = el("div", "fd-disabled");
  disabledHost.hidden = true;
  region.append(table, pill);
  section.append(header, toolbar, banner, region, disabledHost);
  container.replaceChildren(section);

  table.columns = [
    {
      key: "ts",
      label: "Time",
      width: "72px",
      render: (row) => {
        if (row.tail) return el("span", "fd-tail", "Older judgments are not kept here. Open Timeline or Heatmap for history.");
        const link = el("a", "ps-open fd-link mono", clock(row.ts));
        link.href = `#/explain?judgment=${encodeURIComponent(row.id)}`;
        link.title = row.ts;
        link.setAttribute("aria-label", `Explain judgment ${row.id} at ${clock(row.ts)}`);
        return link;
      },
    },
    { key: "session", label: "Session", width: "112px", render: (row) => (row.tail ? "" : monoSpan(row.session, 12)) },
    { key: "project", label: "Project", width: "120px", render: (row) => (row.tail ? "" : monoSpan(row.project)) },
    { key: "env", label: "Env", width: "48px", render: (row) => (row.tail ? "" : tagChip(row.env || (row.project ? "" : "global"))) },
    { key: "tool", label: "Tool", mono: true, render: (row) => (row.tail ? "" : monoSpan(row.tool)) },
    { key: "verdict", label: "Verdict", width: "80px", render: (row) => (row.tail ? "" : verdictChip(row.verdict)) },
    { key: "rule", label: "Rule", width: "160px", render: (row) => (row.tail ? "" : monoSpan(row.rule)) },
  ];

  let all = [];
  const seen = new Set();
  let truncated = false;
  let snapshot = null;
  let atTop = true;
  let flushTimer = 0;
  let lastTs = "";
  let previousState = feed.getState();
  let lastAnnounce = 0;
  let excess = 0;
  let announceTimer = 0;
  let tick = 0;
  let reconnectAt = 0;
  let reconnectKey = "";
  const known = { session: new Set(), project: new Set(), rule: new Set() };

  function remember(record) {
    for (const key of ["session", "project", "rule"]) {
      if (record[key]) known[key].add(record[key]);
    }
  }

  function add(record, fresh) {
    if (!record || seen.has(record.id)) return false;
    seen.add(record.id);
    all.unshift(record);
    if (all.length > LIMIT) {
      const dropped = all.splice(LIMIT);
      for (const gone of dropped) seen.delete(gone.id);
      truncated = true;
    }
    if (record.ts && record.ts > lastTs) lastTs = record.ts;
    remember(record);
    if (fresh && record.verdict === "deny") noteDeny(record);
    return true;
  }

  function matchesFilters(record, includeVerdict) {
    if (filters.session.length && !filters.session.includes(record.session)) return false;
    if (filters.project.length && !filters.project.includes(record.project)) return false;
    if (filters.rule.length && !filters.rule.includes(record.rule)) return false;
    if (includeVerdict && filters.verdict !== "all" && record.verdict !== filters.verdict) return false;
    return true;
  }

  function noteDeny(record) {
    if (!announceToggle.checked || !matchesFilters(record, false)) return;
    const now = Date.now();
    if (!announceTimer && now - lastAnnounce >= ANNOUNCE_GAP_MS) {
      lastAnnounce = now;
      announce(`Deny: ${record.tool} in ${record.project} ${record.env} by ${record.rule}`);
      return;
    }
    excess += 1;
    if (!announceTimer) {
      announceTimer = window.setTimeout(() => {
        announceTimer = 0;
        const count = excess;
        excess = 0;
        if (count > 0) {
          lastAnnounce = Date.now();
          announce(`${count} more ${count === 1 ? "deny" : "denies"}`);
        }
      }, Math.max(0, lastAnnounce + ANNOUNCE_GAP_MS - now));
    }
  }

  function frozen() {
    return pauseToggle.checked || !atTop;
  }

  function syncFreeze() {
    if (frozen()) {
      if (!snapshot) snapshot = all.slice();
    } else if (snapshot) {
      snapshot = null;
    }
  }

  function queuedCount() {
    if (!snapshot) return 0;
    const head = snapshot[0];
    const index = head ? all.findIndex((record) => record.id === head.id) : all.length;
    const fresh = index < 0 ? all : all.slice(0, index);
    return fresh.filter((record) => matchesFilters(record, true)).length;
  }

  function updateOptions() {
    for (const [box, key] of [[sessionBox, "session"], [projectBox, "project"], [ruleBox, "rule"]]) {
      const values = [...new Set([...known[key], ...filters[key]])].sort();
      const before = box.options.map((option) => option.value).join("\n");
      if (before !== values.join("\n")) box.options = values.map((value) => ({ value, label: value }));
    }
  }

  function emptyConfig(feedState, hasRecords) {
    if (hasRecords) return { kind: "empty_filtered", action: "Clear filters" };
    if (feedState === "connecting" || feedState === "reconnecting") {
      return { kind: "empty_first_run", heading: "Connecting to the judgment stream", glyph: "signal" };
    }
    return { kind: "empty_cleared", heading: "Waiting for the next judgment." };
  }

  function draw() {
    syncFreeze();
    updateOptions();
    const source = snapshot || all;
    const rows = source.filter((record) => matchesFilters(record, true));
    if (truncated && rows.length) rows.push({ id: "__tail", tail: true });
    table.emptyState = emptyConfig(feed.getState(), source.length > 0);
    table.rows = rows;
    const queued = queuedCount();
    pill.hidden = queued === 0 || !frozen();
    pillButton.text = `${queued} new judgments`;
    syncStatus();
  }

  function queueDraw() {
    if (flushTimer) return;
    flushTimer = window.setTimeout(() => {
      flushTimer = 0;
      if (!signal.aborted) draw();
    }, FLUSH_MS);
  }

  function savePrefs() {
    setPref("feed.filters", { session: filters.session, project: filters.project, rule: filters.rule, verdict: filters.verdict });
  }

  function syncStatus() {
    const state = feed.getState();
    conn.setAttribute("state", CONN[state] || "offline");
    const status = feed.status();
    banner.hidden = true;
    disabledHost.hidden = true;
    region.hidden = false;
    if (state === "disabled" || !flag("feed").enabled) {
      region.hidden = true;
      disabledHost.hidden = false;
      const node = document.createElement("ps-state");
      node.setAttribute("kind", "disabled");
      node.setAttribute("feature", "Live feed");
      node.setAttribute("body", flag("feed").reason || "The server turned the judgment feed off.");
      disabledHost.replaceChildren(node);
      conn.removeAttribute("seconds");
      return;
    }
    if (state === "reconnecting") {
      const key = `${status.attempts}:${status.nextDelay}`;
      if (key !== reconnectKey) {
        reconnectKey = key;
        reconnectAt = Date.now() + (status.nextDelay || 0);
      }
      const seconds = Math.max(0, Math.ceil((reconnectAt - Date.now()) / 1000));
      conn.setAttribute("seconds", String(seconds));
      banner.hidden = false;
      banner.setAttribute("severity", "warn");
      banner.setAttribute("text", `Reconnecting in ${seconds} s. Judgments made meanwhile are fetched when the stream returns.`);
      banner.removeAttribute("action");
    } else if (state === "closed") {
      conn.removeAttribute("seconds");
      banner.hidden = false;
      banner.setAttribute("severity", "danger");
      banner.setAttribute("text", "The judgment stream is closed.");
      banner.setAttribute("action", "Retry");
    } else {
      conn.removeAttribute("seconds");
      reconnectKey = "";
    }
  }

  async function fillGap() {
    if (!lastTs) return;
    try {
      const data = await get(endpoints.judgments({ since: lastTs, limit: 200 }), { signal });
      const records = (Array.isArray(data) ? data : (data && data.judgments) || []).map(normalize).filter(Boolean);
      records.sort((a, b) => (a.ts < b.ts ? -1 : a.ts > b.ts ? 1 : 0));
      let changed = false;
      for (const record of records) if (add(record, false)) changed = true;
      if (changed) {
        all.sort((a, b) => (a.ts < b.ts ? 1 : a.ts > b.ts ? -1 : 0));
        queueDraw();
      }
    } catch (error) {
      return;
    }
  }

  const initial = feed.getEvents().map(normalize).filter(Boolean);
  for (const record of initial) add(record, false);
  if (feed.getEvents().length >= LIMIT) truncated = true;

  const unsubscribe = feed.subscribe((type, payload) => {
    if (type === "judgment") {
      const record = normalize(payload);
      if (record && add(record, true)) queueDraw();
    } else if (type === "state") {
      if (previousState === "reconnecting" && payload === "live") fillGap();
      previousState = payload;
      syncStatus();
      queueDraw();
    }
  });

  tick = window.setInterval(() => {
    if (feed.getState() === "reconnecting") syncStatus();
  }, 500);
  signal.addEventListener("abort", () => {
    unsubscribe();
    window.clearInterval(tick);
    window.clearTimeout(flushTimer);
    window.clearTimeout(announceTimer);
  });

  function thawToTop() {
    pauseToggle.checked = false;
    pauseToggle.setAttribute("label", "Hold");
    atTop = true;
    table.scroller.scrollTop = 0;
    draw();
  }

  table.scroller.addEventListener("scroll", () => {
    const top = table.scroller.scrollTop <= 2;
    if (top === atTop) return;
    atTop = top;
    draw();
  });
  pillButton.addEventListener("click", thawToTop);
  pauseToggle.addEventListener("ps-change", () => {
    pauseToggle.setAttribute("label", pauseToggle.checked ? "Resume" : "Hold");
    draw();
  });
  announceToggle.addEventListener("ps-change", () => {
    setPref("feed.announce", announceToggle.checked);
    if (!announceToggle.checked) {
      window.clearTimeout(announceTimer);
      announceTimer = 0;
      excess = 0;
    }
  });
  for (const box of [sessionBox, projectBox, ruleBox]) {
    box.value = filters[box.dataset.key];
    box.addEventListener("ps-change", (event) => {
      filters[box.dataset.key] = event.detail.value.slice();
      savePrefs();
      draw();
    });
  }
  verdictSeg.addEventListener("ps-change", (event) => {
    filters.verdict = event.detail.value;
    savePrefs();
    draw();
  });
  table.addEventListener("ps-action", () => {
    filters.session = [];
    filters.project = [];
    filters.rule = [];
    filters.verdict = "all";
    for (const box of [sessionBox, projectBox, ruleBox]) box.value = [];
    verdictSeg.value = "all";
    savePrefs();
    draw();
  });
  banner.addEventListener("ps-action", () => feed.start());

  draw();
}
