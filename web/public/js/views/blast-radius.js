import { post, endpoints } from "../core/api.js";
import { formatCount } from "../core/format.js";
import * as router from "../core/router.js";

const NS = "http://www.w3.org/2000/svg";
const STRICTER = ["allow_to_warn", "allow_to_deny", "warn_to_deny"];
const LOOSER = ["warn_to_allow", "deny_to_allow", "deny_to_warn"];

function icon(name) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "ps-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

function sum(map, keys) {
  if (!map || typeof map !== "object") return 0;
  return keys.reduce((total, key) => total + (Number(map[key]) || 0), 0);
}

function flipText(project) {
  const value = project.largest_flip;
  if (typeof value === "string") return value;
  if (value && typeof value === "object") {
    const direction = (value.direction || `${value.from || ""} to ${value.to || ""}`).replace(/_to_/g, " to ").replace(/_/g, " ");
    let text = direction.trim();
    if (value.action) text += ` on ${value.action}`;
    if (value.env) text += ` in ${value.env}`;
    return text;
  }
  const flips = project.flips;
  if (flips && typeof flips === "object") {
    let best = null;
    for (const [key, count] of Object.entries(flips)) {
      if (Number(count) > 0 && (!best || Number(count) > Number(best[1]))) best = [key, count];
    }
    if (best) return best[0].replace(/_to_/g, " to ").replace(/_/g, " ");
  }
  return "";
}

export function normalize(data) {
  const payload = data && typeof data === "object" ? data : {};
  const list = Array.isArray(payload.projects) ? payload.projects : Array.isArray(payload.rows) ? payload.rows : [];
  const rows = list.map((item) => {
    const stricter = item.stricter != null ? Number(item.stricter) : sum(item.flips, STRICTER);
    const looser = item.looser != null ? Number(item.looser) : sum(item.flips, LOOSER);
    const replayed = Number(item.replayed != null ? item.replayed : item.rows) || 0;
    const unchanged = item.unchanged != null ? Number(item.unchanged) : Math.max(0, replayed - stricter - looser);
    return { project: String(item.project || item.id || ""), replayed, stricter, looser, unchanged, largest: flipText(item) };
  });
  rows.sort((a, b) => b.stricter + b.looser - (a.stricter + a.looser) || a.project.localeCompare(b.project));
  const total = rows.reduce(
    (memo, row) => ({
      replayed: memo.replayed + row.replayed,
      stricter: memo.stricter + row.stricter,
      looser: memo.looser + row.looser,
      unchanged: memo.unchanged + row.unchanged,
    }),
    { replayed: 0, stricter: 0, looser: 0, unchanged: 0 },
  );
  const replayed = payload.rows_replayed != null ? Number(payload.rows_replayed) : total.replayed;
  return { id: payload.id || payload.blast_id || "", days: Number(payload.days) || 14, replayed, rows, total, flips: total.stricter + total.looser };
}

export function aggregate(journal) {
  const byProject = new Map();
  for (const row of journal || []) {
    const key = row.project || "project";
    const entry = byProject.get(key) || { project: key, replayed: 0, stricter: 0, looser: 0, unchanged: 0, counts: new Map() };
    entry.replayed += 1;
    if (row.change === "tighten") entry.stricter += 1;
    else if (row.change === "loosen") entry.looser += 1;
    else entry.unchanged += 1;
    if (row.change === "tighten" || row.change === "loosen") {
      const label = `${row.before} to ${row.after}${row.probe ? " on " + row.probe : ""}`;
      entry.counts.set(label, (entry.counts.get(label) || 0) + 1);
    }
    byProject.set(key, entry);
  }
  const projects = [...byProject.values()].map((entry) => {
    let best = "";
    let max = 0;
    for (const [label, count] of entry.counts) {
      if (count > max) {
        max = count;
        best = label;
      }
    }
    return { project: entry.project, replayed: entry.replayed, stricter: entry.stricter, looser: entry.looser, unchanged: entry.unchanged, largest_flip: best };
  });
  return normalize({ projects });
}

function countCell(value, glyph) {
  const span = document.createElement("span");
  span.className = "blast-count";
  if (glyph && value > 0) span.append(icon(glyph));
  const text = document.createElement("span");
  text.className = "num";
  text.textContent = formatCount(value);
  span.append(text);
  return span;
}

export function renderTable(host, model, { caption = "Blast radius by project" } = {}) {
  host.replaceChildren();
  const table = document.createElement("ps-data-table");
  table.setAttribute("compact", "");
  table.setAttribute("caption", caption);
  table.classList.add("blast-table");
  host.append(table);
  table.columns = [
    { key: "project", label: "Project", mono: true, width: "160px" },
    { key: "replayed", label: "Replayed", align: "end", width: "88px", render: (row) => formatCount(row.replayed) },
    { key: "stricter", label: "Stricter", align: "end", width: "88px", render: (row) => countCell(row.stricter, "deny") },
    { key: "looser", label: "Looser", align: "end", width: "88px", render: (row) => countCell(row.looser, "warn") },
    { key: "unchanged", label: "Unchanged", align: "end", width: "96px", render: (row) => formatCount(row.unchanged) },
    { key: "largest", label: "Largest flip", width: "240px" },
  ];
  table.keyBy = "project";
  table.emptyState = { kind: "empty_first_run", heading: "No judgments in the last 14 days to replay." };
  table.rows = model.rows;
  const foot = document.createElement("tfoot");
  const tr = document.createElement("tr");
  const cells = [
    ["Total", ""],
    [formatCount(model.total.replayed), "num"],
    [formatCount(model.total.stricter), "num"],
    [formatCount(model.total.looser), "num"],
    [formatCount(model.total.unchanged), "num"],
    ["", ""],
  ];
  for (const [text, klass] of cells) {
    const td = document.createElement("td");
    if (klass) td.className = klass;
    td.textContent = text;
    tr.append(td);
  }
  foot.append(tr);
  if (model.rows.length && table.table) table.table.append(foot);
  return table;
}

export function headerLine(model) {
  if (!model.rows.length && !model.replayed) return "No judgments in the last 14 days to replay.";
  let text = `Last ${model.days} days: ${formatCount(model.replayed)} judgment rows replayed against the draft.`;
  if (!model.flips) text += " Nothing would flip.";
  return text;
}

export function summaryLine(model) {
  const projects = model.rows.filter((row) => row.stricter + row.looser > 0).length;
  return `Blast radius, last ${model.days} days: ${formatCount(model.flips)} rows flip in ${formatCount(projects)} projects.`;
}

export async function loadBlastRadius(request, signal) {
  const data = await post(endpoints.blastRadius, { target: request.target, change: request.change }, { signal });
  return normalize(data);
}

export function mountBlastRadius(host, request, options = {}) {
  host.classList.add("blast");
  let controller = null;
  let latest = null;

  const header = document.createElement("div");
  header.className = "blast-head";
  const line = document.createElement("p");
  line.className = "text-sm";
  line.setAttribute("role", "status");
  const mapButton = document.createElement("ps-button");
  mapButton.setAttribute("variant", "ghost");
  mapButton.setAttribute("size", "xs");
  mapButton.text = "Show on map";
  mapButton.hidden = true;
  mapButton.addEventListener("click", () => router.navigate("map?blast=" + encodeURIComponent((latest && latest.id) || "draft")));
  header.append(line, mapButton);
  const body = document.createElement("div");
  body.className = "blast-body";
  host.replaceChildren(header, body);

  function loading() {
    line.textContent = "Replaying 14 days of judgments";
    mapButton.hidden = true;
    body.replaceChildren();
    const table = document.createElement("ps-data-table");
    table.setAttribute("compact", "");
    table.setAttribute("state", "loading");
    table.setAttribute("caption", "Blast radius by project");
    body.append(table);
    table.columns = [
      { key: "project", label: "Project", mono: true },
      { key: "replayed", label: "Replayed", align: "end" },
      { key: "stricter", label: "Stricter", align: "end" },
      { key: "looser", label: "Looser", align: "end" },
      { key: "unchanged", label: "Unchanged", align: "end" },
      { key: "largest", label: "Largest flip" },
    ];
    if (options.onSummary) options.onSummary("Calculating blast radius", null);
  }

  function failed(error) {
    line.textContent = "";
    mapButton.hidden = true;
    body.replaceChildren();
    const state = document.createElement("ps-state");
    state.setAttribute("kind", "error");
    state.setAttribute("heading", "Blast radius did not load");
    state.setAttribute("body", error && error.message ? error.message : "The replay failed.");
    if (error && error.errorId) state.setAttribute("error-id", error.errorId);
    state.addEventListener("ps-retry", () => refresh(request));
    body.append(state);
  }

  function loaded(model) {
    latest = model;
    line.textContent = headerLine(model);
    mapButton.hidden = false;
    if (!model.rows.length) {
      body.replaceChildren();
      const state = document.createElement("ps-state");
      state.setAttribute("kind", "empty_first_run");
      state.setAttribute("heading", "No judgments in the last 14 days to replay.");
      body.append(state);
    } else {
      renderTable(body, model);
    }
    if (options.onSummary) options.onSummary(summaryLine(model), model);
  }

  async function refresh(next) {
    request = next || request;
    if (controller) controller.abort();
    controller = new AbortController();
    const mine = controller;
    loading();
    try {
      const model = await loadBlastRadius(request, mine.signal);
      if (mine.signal.aborted) return;
      loaded(model);
    } catch (error) {
      if (mine.signal.aborted || (error && error.name === "AbortError")) return;
      failed(error);
      if (options.onSummary) options.onSummary("Blast radius is unavailable", null);
    }
  }

  refresh(request);
  return {
    refresh,
    destroy() {
      if (controller) controller.abort();
    },
  };
}
