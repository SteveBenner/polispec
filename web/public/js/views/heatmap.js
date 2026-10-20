import "../components/ps-data-table.js";
import "../components/ps-segmented.js";
import "../components/ps-combobox.js";
import "../components/ps-chip.js";
import "../components/ps-tooltip.js";
import "../components/ps-state.js";
import "../components/ps-banner.js";
import "../components/ps-skeleton.js";
import { endpoints } from "../core/api.js";
import { loadView, getPref, setPref } from "../core/cache.js";
import { toast } from "../core/announce.js";
import { formatCount, formatDuration } from "../core/format.js";
import { navigate } from "../core/router.js";

const NS = "http://www.w3.org/2000/svg";
const WINDOWS = [
  { value: "7d", label: "7 days" },
  { value: "14d", label: "14 days" },
  { value: "30d", label: "30 days" },
];
const ENVS = ["dev", "test", "prod"];
const CELL = 40;
const HEAD = 200;
const RENDER_ALL = 120;
const OVERSCAN = 20;
const SKELETON_ROWS = 10;
const SKELETON_COLS = 12;

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

function windowLabel(value) {
  return (WINDOWS.find((entry) => entry.value === value) || WINDOWS[1]).label;
}

function rowHeight() {
  return parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--row-compact")) || 24;
}

export function bucketBounds(values) {
  const sorted = values.slice().sort((a, b) => a - b);
  const n = sorted.length;
  const out = [];
  for (let step = 1; step <= 5; step += 1) {
    if (!n) out.push(step);
    else out.push(sorted[Math.min(n - 1, Math.ceil((n * step) / 5) - 1)]);
  }
  return out;
}

export function bucketOf(value, bounds) {
  for (let index = 0; index < bounds.length; index += 1) if (value <= bounds[index]) return index + 1;
  return bounds.length;
}

function boundLabel(bounds, index) {
  const low = index === 0 ? 1 : bounds[index - 1] + 1;
  const high = bounds[index];
  if (low > high) return "none";
  if (low === high) return formatCount(high);
  return `${formatCount(low)}-${formatCount(high)}`;
}

function swatch(heat) {
  const node = el("i", "hm-swatch");
  if (heat === "dead") node.classList.add("hm-dead");
  else node.dataset.heat = String(heat);
  return node;
}

function legend(bounds, hasData) {
  const wrap = el("div", "hm-legend");
  wrap.setAttribute("role", "group");
  wrap.setAttribute("aria-label", "Heat legend");
  wrap.append(el("span", "hm-legend-title", "Hits per rule"));
  const keys = el("span", "hm-keys");
  for (let index = 0; index < 5; index += 1) {
    const key = el("span", "hm-key");
    key.append(swatch(index + 1), el("span", "num", hasData ? boundLabel(bounds, index) : "none"));
    keys.append(key);
  }
  const dead = el("span", "hm-key hm-key-dead");
  dead.append(swatch("dead"), el("span", "", "Never fired"));
  keys.append(dead);
  wrap.append(keys);
  return wrap;
}

export async function render(container, params, signal) {
  const section = el("section", "view heatmap");
  const header = el("header", "view-header");
  const heading = el("h1", "", "Heatmap");
  heading.tabIndex = -1;
  const chipHost = el("span", "hm-chips");
  const controls = el("div", "hm-controls");
  let windowValue = getPref("heatmap.window", "14d");
  if (!WINDOWS.some((entry) => entry.value === windowValue)) windowValue = "14d";
  const segmented = document.createElement("ps-segmented");
  segmented.setAttribute("label", "Window");
  segmented.setAttribute("value", windowValue);
  segmented.options = WINDOWS;
  const picker = document.createElement("ps-combobox");
  picker.setAttribute("label", "Projects");
  picker.setAttribute("placeholder", "Projects");
  picker.setAttribute("hide-label", "");
  picker.setAttribute("multiple", "");
  picker.setAttribute("size", "sm");
  picker.classList.add("hm-picker");
  controls.append(segmented, picker);
  header.append(heading, chipHost, controls);

  const legendHost = el("div", "hm-legend-host");
  const body = el("div", "hm-body");
  const deadSection = el("section", "hm-deadrules");
  const deadHeading = el("h2", "hm-dead-title");
  const deadNote = document.createElement("ps-banner");
  deadNote.setAttribute("severity", "info");
  deadNote.hidden = true;
  const deadTable = document.createElement("ps-data-table");
  deadTable.setAttribute("caption", "Rules that never fired");
  deadTable.setAttribute("state", "loading");
  deadTable.keyBy = "rule_id";
  deadTable.errorState = { heading: "Rules that never fired did not load" };
  deadSection.append(deadHeading, deadNote, deadTable);
  const tip = document.createElement("ps-tooltip");
  tip.classList.add("hm-tip");
  section.append(header, legendHost, body, deadSection, tip);
  container.replaceChildren(section);

  let data = null;
  let selected = [];
  let loaded = false;
  let skeletonTimer = 0;
  let scroller = null;
  let tbody = null;
  let model = null;
  let active = { row: 0, col: 0 };
  let scrollQueued = false;

  deadTable.columns = [
    {
      key: "rule_id",
      label: "Rule",
      width: "260px",
      mono: true,
      render: (row) => {
        const wrap = el("span", "hm-deadcell");
        wrap.append(swatch("dead"), el("span", "mono", row.rule_id));
        return wrap;
      },
    },
    {
      key: "layer",
      label: "Layer",
      width: "140px",
      render: (row) => {
        const chip = document.createElement("ps-chip");
        chip.setAttribute("kind", "tag");
        chip.setAttribute("label", row.layer || "");
        return chip;
      },
    },
    { key: "projects", label: "Projects it applies to", width: "180px", align: "end", render: (row) => formatCount(row.projects || 0) },
    { key: "last_fired", label: "Last fired", width: "140px", render: (row) => (row.last_fired ? String(row.last_fired).slice(0, 10) : "never recorded") },
    {
      key: "added",
      label: "Age",
      render: (row) => {
        const stamp = Date.parse(row.added);
        return Number.isFinite(stamp) ? formatDuration(Date.now() - stamp) : "unknown";
      },
    },
  ];

  function visibleProjects() {
    const all = (data && data.projects) || [];
    return selected.length ? all.filter((project) => selected.includes(project.id)) : all;
  }

  function buildModel() {
    const projects = visibleProjects();
    const columns = [];
    for (const project of projects) for (const env of project.envs || ENVS) columns.push({ project: project.id, env, key: `${project.id}/${env}` });
    const noRule = (data && data.no_rule) || {};
    let rules = ((data && data.rules) || []).map((rule) => {
      let total = 0;
      for (const column of columns) total += Number((rule.hits || {})[column.key]) || 0;
      return { rule, total };
    });
    if (selected.length) rules = rules.filter((entry) => entry.total > 0);
    rules.sort((a, b) => b.total - a.total || String(a.rule.rule_id).localeCompare(String(b.rule.rule_id)));
    const counts = [];
    for (const entry of rules) for (const column of columns) {
      const value = Number((entry.rule.hits || {})[column.key]) || 0;
      if (value > 0) counts.push(value);
    }
    for (const column of columns) {
      const value = Number((noRule[column.key] || {}).count) || 0;
      if (value > 0) counts.push(value);
    }
    return { projects, columns, rules, noRule, bounds: bucketBounds(counts), hasData: counts.length > 0 };
  }

  function tipText(td) {
    const rule = td.dataset.rule;
    const [project, env] = td.dataset.key.split("/");
    const count = formatCount(Number(td.dataset.count) || 0);
    return `${rule} in ${project} ${env}: ${count} hits in ${windowLabel(windowValue)}`;
  }

  function cell(ruleId, column, count, heatBounds, isNoRule, extra) {
    const td = el("td");
    td.dataset.cell = "";
    td.dataset.rule = ruleId;
    td.dataset.key = column.key;
    td.dataset.count = String(count);
    td.tabIndex = -1;
    if (count > 0) {
      td.dataset.heat = String(bucketOf(count, heatBounds));
      if (isNoRule) {
        const button = el("button", "ps-native hm-open");
        button.type = "button";
        button.dataset.project = column.project;
        button.dataset.env = column.env;
        button.dataset.action = (extra && extra.top_action) || "";
        button.setAttribute("aria-label", `${formatCount(count)} NO-RULE hits in ${column.project} ${column.env}. Open a draft rule in the manager`);
        button.append(el("span", "num", formatCount(count)));
        td.append(button);
      } else {
        td.append(el("span", "num", formatCount(count)));
      }
    }
    return td;
  }

  function rowFor(entry, index) {
    const tr = el("tr");
    tr.dataset.row = String(index);
    const th = el("th", "hm-rowhead");
    th.scope = "row";
    const name = el("span", "mono hm-rule", entry.rule.rule_id);
    name.title = entry.rule.rule_id;
    const inner = el("div", "hm-rowin");
    inner.append(name);
    if (entry.rule.layer) inner.append(el("span", "hm-layer", entry.rule.layer));
    th.append(inner);
    tr.append(th);
    for (const column of model.columns) tr.append(cell(entry.rule.rule_id, column, Number((entry.rule.hits || {})[column.key]) || 0, model.bounds, false));
    return tr;
  }

  function noRuleRow() {
    const tr = el("tr", "hm-norule");
    tr.dataset.row = "-1";
    const th = el("th", "hm-rowhead");
    th.scope = "row";
    const inner = el("div", "hm-rowin");
    inner.append(icon("warn"), el("span", "mono hm-rule", "NO-RULE"));
    th.append(inner);
    tr.append(th);
    for (const column of model.columns) {
      const info = model.noRule[column.key] || {};
      tr.append(cell("NO-RULE", column, Number(info.count) || 0, model.bounds, true, info));
    }
    return tr;
  }

  function spacer(height) {
    const tr = el("tr", "hm-spacer");
    tr.setAttribute("aria-hidden", "true");
    tr.style.height = `${height}px`;
    const td = el("td");
    td.colSpan = model.columns.length + 1;
    tr.append(td);
    return tr;
  }

  function drawBody() {
    if (!tbody) return;
    const rowH = rowHeight();
    const list = model.rules;
    const scrollTop = scroller.scrollTop;
    const viewHeight = Math.max(scroller.clientHeight, 480);
    tbody.textContent = "";
    tbody.append(noRuleRow());
    let start = 0;
    let end = list.length;
    if (list.length > RENDER_ALL) {
      const top = Math.max(0, scrollTop - rowH * 3);
      const visible = Math.ceil(viewHeight / rowH);
      start = Math.max(0, Math.floor(top / rowH) - OVERSCAN);
      end = Math.min(list.length, Math.floor(top / rowH) + visible + OVERSCAN);
      tbody.append(spacer(start * rowH));
    }
    for (let index = start; index < end; index += 1) tbody.append(rowFor(list[index], index));
    if (list.length > RENDER_ALL) tbody.append(spacer((list.length - end) * rowH));
  }

  function drawGrid() {
    const wrap = el("div", "hm-scroll");
    wrap.setAttribute("role", "region");
    wrap.setAttribute("aria-label", `Rule hits by project and environment, last ${windowLabel(windowValue)}. Focus the region and press Enter to move between cells with the arrow keys.`);
    wrap.tabIndex = 0;
    const table = el("table", "hm-grid");
    table.style.width = `${HEAD + CELL * model.columns.length}px`;
    const caption = el("caption", "visually-hidden", `Rule hits in the last ${windowLabel(windowValue)}`);
    const headGroup = el("colgroup");
    const headCol = el("col");
    headCol.style.width = `${HEAD}px`;
    headGroup.append(headCol);
    const groups = [headGroup];
    for (const project of model.projects) {
      const group = el("colgroup");
      for (let index = 0; index < (project.envs || ENVS).length; index += 1) {
        const col = el("col");
        col.style.width = `${CELL}px`;
        group.append(col);
      }
      groups.push(group);
    }
    const thead = el("thead");
    const first = el("tr");
    const corner = el("th", "hm-corner");
    corner.rowSpan = 2;
    corner.scope = "col";
    corner.textContent = "Rule";
    first.append(corner);
    const second = el("tr");
    for (const project of model.projects) {
      const envs = project.envs || ENVS;
      const group = el("th", "hm-group");
      group.colSpan = envs.length;
      group.scope = "colgroup";
      group.append(el("span", "mono", project.id));
      group.title = project.id;
      first.append(group);
      for (const env of envs) {
        const sub = el("th", "hm-env", env);
        sub.scope = "col";
        second.append(sub);
      }
    }
    thead.append(first, second);
    tbody = el("tbody");
    table.append(caption, ...groups, thead, tbody);
    wrap.append(table);
    body.replaceChildren(wrap);
    scroller = wrap;
    drawBody();
    wrap.addEventListener("scroll", () => {
      tip.hide();
      if (model.rules.length <= RENDER_ALL || scrollQueued) return;
      scrollQueued = true;
      window.requestAnimationFrame(() => {
        scrollQueued = false;
        drawBody();
      });
    });
  }

  function cellAt(rowIndex, colIndex) {
    return tbody.querySelector(`tr[data-row="${rowIndex}"] td[data-cell]:nth-of-type(${colIndex + 1})`);
  }

  function focusCell(rowIndex, colIndex) {
    const rowMax = model.rules.length - 1;
    const colMax = model.columns.length - 1;
    const row = Math.max(-1, Math.min(rowMax, rowIndex));
    const col = Math.max(0, Math.min(colMax, colIndex));
    active = { row, col };
    let target = cellAt(row, col);
    if (!target && row >= 0) {
      const rowH = rowHeight();
      scroller.scrollTop = Math.max(0, row * rowH - scroller.clientHeight / 2);
      drawBody();
      target = cellAt(row, col);
    }
    if (!target) return;
    target.focus({ preventScroll: false });
    target.scrollIntoView({ block: "nearest", inline: "nearest" });
  }

  function onKey(event) {
    const td = event.target.closest && event.target.closest("td[data-cell]");
    const keys = ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown"];
    if (!td) {
      if (event.target === scroller && event.key === "Enter") {
        event.preventDefault();
        focusCell(active.row, active.col);
      }
      return;
    }
    if (!keys.includes(event.key)) {
      if (event.key === "Escape") {
        event.preventDefault();
        scroller.focus();
      }
      return;
    }
    event.preventDefault();
    const row = Number(td.parentElement.dataset.row);
    const col = [...td.parentElement.querySelectorAll("td[data-cell]")].indexOf(td);
    const page = Math.max(1, Math.floor(scroller.clientHeight / rowHeight()) - 3);
    if (event.key === "ArrowUp") focusCell(row - 1, col);
    else if (event.key === "ArrowDown") focusCell(row + 1, col);
    else if (event.key === "ArrowLeft") focusCell(row, col - 1);
    else if (event.key === "ArrowRight") focusCell(row, col + 1);
    else if (event.key === "Home") focusCell(row, 0);
    else if (event.key === "End") focusCell(row, model.columns.length - 1);
    else if (event.key === "PageUp") focusCell(row - page, col);
    else focusCell(row + page, col);
  }

  function drawSkeleton() {
    const wrap = el("div", "hm-scroll hm-skeleton");
    wrap.setAttribute("aria-busy", "true");
    const table = el("table", "hm-grid");
    table.style.width = `${HEAD + CELL * SKELETON_COLS}px`;
    const caption = el("caption", "visually-hidden", "Heatmap loading");
    const tb = el("tbody");
    for (let row = 0; row < SKELETON_ROWS; row += 1) {
      const tr = el("tr");
      const th = el("th", "hm-rowhead");
      const block = document.createElement("ps-skeleton");
      block.setAttribute("width", `${60 + ((row * 7) % 5) * 7}%`);
      th.append(block);
      tr.append(th);
      for (let col = 0; col < SKELETON_COLS; col += 1) {
        const td = el("td");
        const small = document.createElement("ps-skeleton");
        small.setAttribute("width", "60%");
        td.append(small);
        tr.append(td);
      }
      tb.append(tr);
    }
    table.append(caption, tb);
    wrap.append(table);
    body.replaceChildren(wrap);
    scroller = null;
    tbody = null;
  }

  function drawDead() {
    deadHeading.textContent = `Never fired in ${windowLabel(windowValue)}`;
    const dead = (data && data.dead) || [];
    deadTable.emptyState = { kind: "empty_cleared", heading: "Every rule fired in this window." };
    deadTable.rows = dead;
    deadTable.setAttribute("state", "ready");
    const empty = !model.hasData;
    deadNote.hidden = !empty;
    if (empty) deadNote.setAttribute("text", "No judgments were recorded in this window, so every rule counts as never fired.");
  }

  function draw() {
    window.clearTimeout(skeletonTimer);
    model = buildModel();
    legendHost.replaceChildren(legend(model.bounds, model.hasData));
    const options = ((data && data.projects) || []).map((project) => ({ value: project.id, label: project.id }));
    if (picker.options.map((o) => o.value).join("\n") !== options.map((o) => o.value).join("\n")) picker.options = options;
    if (!model.hasData) {
      const state = document.createElement("ps-state");
      state.setAttribute("kind", "empty_first_run");
      state.setAttribute("heading", `No judgments in the last ${windowLabel(windowValue)}.`);
      state.setAttribute("body", "Judgments appear here once agents make calls in a live project.");
      state.setAttribute("glyph", "grid");
      body.replaceChildren(state);
      scroller = null;
      tbody = null;
    } else {
      drawGrid();
    }
    drawDead();
  }

  function showError(error) {
    const state = document.createElement("ps-state");
    state.setAttribute("kind", "error");
    state.setAttribute("heading", "The heatmap did not load");
    state.setAttribute("body", error.message || "The request failed.");
    if (error.errorId) state.setAttribute("error-id", error.errorId);
    state.addEventListener("ps-retry", (event) => {
      event.stopPropagation();
      load();
    });
    body.replaceChildren(state);
    legendHost.replaceChildren();
    deadTable.setAttribute("state", "ready");
    deadTable.rows = [];
    deadTable.emptyState = { kind: "empty_first_run", heading: "Not available while the heatmap is unavailable." };
    scroller = null;
    tbody = null;
  }

  async function load() {
    loaded = false;
    deadTable.setAttribute("state", "loading");
    window.clearTimeout(skeletonTimer);
    skeletonTimer = window.setTimeout(() => {
      if (!loaded) drawSkeleton();
    }, 200);
    try {
      await loadView({
        key: "heatmap:" + windowValue,
        path: endpoints.heatmap({ window: windowValue }),
        chipHost,
        signal,
        render: (payload) => {
          data = payload;
          loaded = true;
          draw();
        },
      });
    } catch (error) {
      window.clearTimeout(skeletonTimer);
      if (signal.aborted || loaded) return;
      showError(error);
    }
  }

  segmented.addEventListener("ps-change", (event) => {
    event.stopPropagation();
    windowValue = event.detail.value;
    setPref("heatmap.window", windowValue);
    load();
  });
  picker.addEventListener("ps-change", (event) => {
    event.stopPropagation();
    selected = event.detail.value.slice();
    if (data) draw();
  });

  body.addEventListener("click", (event) => {
    const button = event.target.closest(".hm-open");
    if (!button) return;
    const params = new URLSearchParams({ draft: "no-rule", env: button.dataset.env });
    if (button.dataset.action) params.set("action", button.dataset.action);
    navigate(`manager/project/${encodeURIComponent(button.dataset.project)}?${params.toString()}`);
    toast("Draft rule opened in the manager");
  });
  body.addEventListener("keydown", onKey);
  body.addEventListener("pointerover", (event) => {
    const td = event.target.closest && event.target.closest("td[data-cell]");
    if (!td) return;
    tip.target = td;
    tip.text = tipText(td);
    tip.schedule(400);
  });
  body.addEventListener("pointerout", (event) => {
    const td = event.target.closest && event.target.closest("td[data-cell]");
    if (td) tip.scheduleHide();
  });
  body.addEventListener("focusin", (event) => {
    const td = event.target.closest && event.target.closest("td[data-cell]");
    if (!td) return;
    tip.target = td;
    tip.text = tipText(td);
    tip.schedule(0);
  });
  body.addEventListener("focusout", (event) => {
    if (event.target.closest && event.target.closest("td[data-cell]")) tip.scheduleHide();
  });
  signal.addEventListener("abort", () => window.clearTimeout(skeletonTimer));

  await load();
}
