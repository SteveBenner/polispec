import "../components/ps-scrubber.js";
import "../components/ps-select.js";
import "../components/ps-chip.js";
import "../components/ps-state.js";
import "../components/ps-skeleton.js";
import { requestFull, get, endpoints } from "../core/api.js";
import { announce } from "../core/announce.js";
import { loadCatalog, rulebookList } from "../components/ps-author-panel.js";
import { diffHunks } from "../editor/codemirror.js";
import * as router from "../core/router.js";

const NS = "http://www.w3.org/2000/svg";
const GROUPS = [
  { key: "module", label: "Modules" },
  { key: "rule", label: "Rules" },
  { key: "gate", label: "Gates" },
  { key: "freeze", label: "Freezes" },
];
const CHANGE_LABEL = { added: "Added", removed: "Removed", changed: "Changed" };
const SCRUB_DELAY = 300;

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

function classChip(value, label) {
  const node = document.createElement("ps-chip");
  node.setAttribute("kind", "classification");
  node.setAttribute("value", value);
  if (label) node.setAttribute("label", label);
  return node;
}

function normalizeClass(value) {
  if (value === "tighten" || value === "tightening") return "tightening";
  if (value === "loosen" || value === "loosening") return "loosening";
  return "neutral";
}

function pairRows(before, after) {
  const a = before == null ? [] : String(before).split("\n");
  const b = after == null ? [] : String(after).split("\n");
  const left = [];
  const right = [];
  const hunks = diffHunks(a, b);
  let ia = 0;
  let ib = 0;
  const same = (count) => {
    for (let k = 0; k < count; k += 1) {
      left.push({ sign: " ", text: a[ia + k] });
      right.push({ sign: " ", text: b[ib + k] });
    }
    ia += count;
    ib += count;
  };
  for (const hunk of hunks) {
    same(hunk.aStart - ia);
    const del = hunk.aEnd - hunk.aStart;
    const add = hunk.bEnd - hunk.bStart;
    const rows = Math.max(del, add);
    for (let k = 0; k < rows; k += 1) {
      left.push(k < del ? { sign: "-", text: a[hunk.aStart + k] } : { sign: "", text: "" });
      right.push(k < add ? { sign: "+", text: b[hunk.bStart + k] } : { sign: "", text: "" });
    }
    ia = hunk.aEnd;
    ib = hunk.bEnd;
  }
  same(a.length - ia);
  return { left, right };
}

function pane(rows, label) {
  const wrap = el("div", "hs-pane");
  wrap.setAttribute("role", "group");
  wrap.setAttribute("aria-label", label);
  for (const row of rows) {
    const line = el("div", "hs-line mono");
    line.dataset.kind = row.sign === "-" ? "del" : row.sign === "+" ? "add" : row.sign === "" ? "pad" : "ctx";
    line.append(el("span", "hs-sign", row.sign), el("span", "hs-text", row.text));
    wrap.append(line);
  }
  return wrap;
}

function changeRow(change, index) {
  const wrap = el("div", "hs-change");
  const kindKey = change.change || "changed";
  const row = el("button", "ps-native hs-row");
  row.type = "button";
  const detailId = `hs-detail-${index}`;
  row.setAttribute("aria-expanded", "false");
  row.setAttribute("aria-controls", detailId);
  const expandable = change.before != null || change.after != null;
  row.append(icon("chevron-right"));
  const tag = el("span", "hs-kind", CHANGE_LABEL[kindKey] || kindKey);
  tag.dataset.change = kindKey;
  row.append(tag, el("span", "mono hs-id", change.id || ""));
  const cls = normalizeClass(change.classification);
  row.append(classChip(cls));
  row.append(el("span", "hs-summary", change.summary || ""));
  wrap.append(row);
  const detail = el("div", "hs-detail");
  detail.id = detailId;
  detail.hidden = true;
  wrap.append(detail);
  if (!expandable) {
    row.disabled = true;
    row.querySelector(".ps-icon").style.visibility = "hidden";
    return wrap;
  }
  row.addEventListener("click", () => {
    const open = row.getAttribute("aria-expanded") !== "true";
    row.setAttribute("aria-expanded", open ? "true" : "false");
    detail.hidden = !open;
    if (open && !detail.firstChild) {
      const { left, right } = pairRows(change.before, change.after);
      const pair = el("div", "hs-pair");
      pair.append(pane(left, "Before"), pane(right, "After"));
      detail.append(pair);
    }
  });
  return wrap;
}

export async function render(container, params, signal) {
  const kind = (params && params[0]) || "";
  const id = (params && params[1]) || "";

  const section = el("section", "view history");
  const header = el("header", "view-header");
  const heading = el("h1", "", id ? `History of ${id}` : "History");
  heading.tabIndex = -1;
  const switcher = document.createElement("ps-select");
  switcher.setAttribute("label", "Rulebook");
  switcher.setAttribute("searchable", "");
  switcher.options = [];
  header.append(heading, switcher);
  const body = el("div", "hs-body");
  section.append(header, body);
  container.replaceChildren(section);

  try {
    const catalog = await loadCatalog();
    if (signal.aborted) return;
    const list = rulebookList(catalog);
    const options = list.map((item) => ({ value: `${item.kind}/${item.id}`, label: `${item.kind}: ${item.id}` }));
    if (kind && id && !options.some((o) => o.value === `${kind}/${id}`)) options.push({ value: `${kind}/${id}`, label: `${kind}: ${id}` });
    switcher.options = options;
    if (kind && id) switcher.value = `${kind}/${id}`;
  } catch (error) {
    if (signal.aborted) return;
  }
  switcher.addEventListener("ps-change", (event) => {
    const [k, ...rest] = String(event.detail.value).split("/");
    router.navigate(`history/${encodeURIComponent(k)}/${encodeURIComponent(rest.join("/"))}`);
  });

  if (!kind || !id) {
    const state = document.createElement("ps-state");
    state.setAttribute("kind", "empty_first_run");
    state.setAttribute("heading", "Pick a rulebook to see its history.");
    state.setAttribute("glyph", "rewind");
    body.append(state);
    return;
  }

  const scrubber = document.createElement("ps-scrubber");
  scrubber.setAttribute("label", `Versions of ${id}`);
  const summary = el("div", "hs-summary-row");
  const diff = el("div", "hs-diff");
  diff.setAttribute("aria-live", "polite");
  body.append(scrubber, summary, diff);

  let commits = [];
  let diffController = null;
  let scrubTimer = 0;
  signal.addEventListener("abort", () => clearTimeout(scrubTimer), { once: true });

  function message(text, kindName) {
    const state = document.createElement("ps-state");
    state.setAttribute("kind", kindName || "empty_cleared");
    state.setAttribute("heading", text);
    state.setAttribute("glyph", "info");
    return state;
  }

  function skeletons() {
    const wrap = el("div", "hs-skeleton");
    for (let k = 0; k < 5; k += 1) wrap.append(document.createElement("ps-skeleton"));
    return wrap;
  }

  function drawErrorIn(host, error, retry) {
    const state = document.createElement("ps-state");
    state.setAttribute("kind", "error");
    state.setAttribute("heading", "The history did not load");
    state.setAttribute("body", error.message || "The request failed.");
    if (error.errorId) state.setAttribute("error-id", error.errorId);
    state.addEventListener("ps-retry", (event) => {
      event.stopPropagation();
      retry();
    });
    host.replaceChildren(state);
  }

  function drawSummary(changes) {
    summary.textContent = "";
    const counts = { tightening: 0, loosening: 0, neutral: 0 };
    for (const change of changes) counts[normalizeClass(change.classification)] += 1;
    summary.append(
      classChip("tightening", `Tightens ${counts.tightening}`),
      classChip("loosening", `Loosens ${counts.loosening}`),
      classChip("neutral", `Neutral ${counts.neutral}`)
    );
    return counts;
  }

  function drawDiff(changes) {
    diff.textContent = "";
    if (!changes.length) {
      diff.append(message("These two versions have the same policy."));
      return;
    }
    let index = 0;
    for (const group of GROUPS) {
      const items = changes.filter((change) => (change.kind || change.group) === group.key);
      if (!items.length) continue;
      const block = el("section", "hs-group");
      const title = el("h2", "hs-group-head");
      title.append(document.createTextNode(group.label + " "), el("span", "num", String(items.length)));
      block.append(title);
      for (const change of items) {
        block.append(changeRow(change, index));
        index += 1;
      }
      diff.append(block);
    }
  }

  async function loadDiff() {
    const { a, b } = scrubber.range;
    const from = commits[a];
    const to = commits[b];
    if (!from || !to) return;
    if (from.sha === to.sha) {
      summary.textContent = "";
      diff.replaceChildren(message("Pick two different versions to compare."));
      return;
    }
    if (diffController) diffController.abort();
    const controller = new AbortController();
    diffController = controller;
    const forward = () => controller.abort();
    signal.addEventListener("abort", forward, { once: true });
    summary.textContent = "";
    diff.replaceChildren(skeletons());
    try {
      const result = await requestFull("GET", endpoints.history(kind, id, { from: from.sha, to: to.sha }), { signal: controller.signal });
      if (controller.signal.aborted) return;
      const changes = (result.data && result.data.changes) || [];
      const counts = drawSummary(changes);
      drawDiff(changes);
      announce(`${changes.length} changes. ${counts.tightening} tighten, ${counts.loosening} loosen, ${counts.neutral} neutral.`);
    } catch (error) {
      if (controller.signal.aborted) return;
      drawErrorIn(diff, error, loadDiff);
    } finally {
      signal.removeEventListener("abort", forward);
    }
  }

  scrubber.addEventListener("ps-scrub", () => {
    clearTimeout(scrubTimer);
    scrubTimer = setTimeout(loadDiff, SCRUB_DELAY);
  });
  scrubber.addEventListener("ps-apply", () => {
    clearTimeout(scrubTimer);
    loadDiff();
  });

  async function loadHistory() {
    scrubber.hidden = false;
    diff.replaceChildren(skeletons());
    try {
      const data = await get(endpoints.history(kind, id), { signal });
      if (signal.aborted) return;
      const list = ((data && data.commits) || []).slice();
      list.sort((x, y) => Date.parse(x.date) - Date.parse(y.date));
      commits = list;
      scrubber.commits = list.map((commit) => ({
        ref: commit.sha,
        tag: (commit.tags && commit.tags[0]) || commit.tag || "",
        date: commit.date ? String(commit.date).slice(0, 10) : "",
      }));
      if (list.length < 2) {
        summary.textContent = "";
        diff.replaceChildren(message(list.length ? "Only one version so far." : "No history for this rulebook yet."));
        return;
      }
      await loadDiff();
    } catch (error) {
      if (signal.aborted) return;
      drawErrorIn(diff, error, loadHistory);
    }
  }

  await loadHistory();
}
