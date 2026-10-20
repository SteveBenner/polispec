import "../components/ps-segmented.js";
import "../components/ps-textarea.js";
import "../components/ps-text-field.js";
import "../components/ps-combobox.js";
import "../components/ps-button.js";
import "../components/ps-data-table.js";
import "../components/ps-chip.js";
import "../components/ps-state.js";
import { post, get, endpoints } from "../core/api.js";
import { announce } from "../core/announce.js";
import * as router from "../core/router.js";

const NS = "http://www.w3.org/2000/svg";
const ENVS = ["dev", "test", "prod"];
const MODES = [
  { value: "tool", label: "Tool call" },
  { value: "shell", label: "Shell line" },
  { value: "judgment", label: "Recorded judgment" },
];

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

function chip(kind, value, label) {
  const node = document.createElement("ps-chip");
  node.setAttribute("kind", kind);
  if (value) node.setAttribute("value", value);
  if (label) node.setAttribute("label", label);
  return node;
}

function ago(iso) {
  const ms = Date.now() - Date.parse(iso);
  if (!Number.isFinite(ms)) return "";
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return s + " s ago";
  const m = Math.round(s / 60);
  if (m < 60) return m + " min ago";
  const h = Math.round(m / 60);
  if (h < 48) return h + " h ago";
  return Math.round(h / 24) + " d ago";
}

function judgmentLabel(record) {
  const target = (record.targets && record.targets[0]) || {};
  const tool = record.action && record.action.tool;
  const verdict = (record.outcome && record.outcome.verdict) || target.verdict;
  return [record.id, tool, target.project, verdict, ago(record.ts)].filter(Boolean).join(" · ");
}

function parseToolJson(text) {
  let value;
  try {
    value = JSON.parse(text);
  } catch (error) {
    const found = /position (\d+)/.exec(error.message || "");
    const atEnd = /end of JSON/i.test(error.message || "");
    if (found || atEnd) {
      const position = found ? Number(found[1]) : text.length;
      const before = text.slice(0, position).split("\n");
      return { error: `Not valid JSON at line ${before.length}, column ${before[before.length - 1].length + 1}.` };
    }
    return { error: "Not valid JSON: " + (error.message || "parse failed") };
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) return { error: "Expected a JSON object with tool_name and tool_input." };
  const tool = value.tool_name || value.tool;
  if (!tool) return { error: "The payload needs a tool_name." };
  const input = value.tool_input || value.input || {};
  const body = { tool, input };
  if (value.cwd) body.cwd = value.cwd;
  return { body };
}

function cellStyleKey(entry, env) {
  return entry.id + "|" + env;
}

export async function render(container, params, signal) {
  const route = router.currentRoute();
  const preset = (params && params[0]) || (route && route.query && route.query.judgment) || "";

  const section = el("section", "view playground");
  const header = el("header", "view-header");
  const heading = el("h1", "", "Playground");
  heading.tabIndex = -1;
  header.append(heading);

  const input = el("div", "pg-input");
  const modeControl = document.createElement("ps-segmented");
  modeControl.setAttribute("label", "Input kind");
  modeControl.options = MODES;
  modeControl.setAttribute("value", preset ? "judgment" : "tool");

  const toolField = document.createElement("ps-textarea");
  toolField.setAttribute("label", "Hook payload (JSON)");
  toolField.setAttribute("mono", "");
  toolField.setAttribute("submit", "");
  toolField.setAttribute("reserve", "");
  toolField.setAttribute("placeholder", '{"tool_name":"Bash","tool_input":{"command":"git push origin stable"}}');
  toolField.validator = (text) => (text.trim() ? parseToolJson(text).error || "" : "");

  const shellField = document.createElement("ps-text-field");
  shellField.setAttribute("label", "Shell line");
  shellField.setAttribute("mono", "");
  shellField.setAttribute("placeholder", "git push origin stable");

  const judgmentField = document.createElement("ps-combobox");
  judgmentField.setAttribute("label", "Recorded judgment");
  judgmentField.setAttribute("placeholder", "Search jdg_ ids, tools, projects");
  judgmentField.options = [];

  const fieldHost = el("div", "pg-field");
  const judge = document.createElement("ps-button");
  judge.setAttribute("variant", "primary");
  judge.text = "Judge";
  const actions = el("div", "pg-actions");
  const note = el("p", "pg-note", "Read-only. Nothing is recorded.");
  const hint = el("span", "pg-hint mono", "Ctrl Enter");
  actions.append(judge, hint);
  input.append(modeControl, fieldHost, actions, note);

  const results = el("div", "pg-results");
  const matrixPane = el("div", "pg-pane pg-matrix");
  const recordLine = el("div", "pg-record");
  recordLine.hidden = true;
  const table = document.createElement("ps-data-table");
  table.setAttribute("caption", "Verdict by entry and environment");
  table.keyBy = "id";
  matrixPane.append(recordLine, table);
  const tracePane = el("div", "pg-pane pg-trace");
  tracePane.hidden = true;
  results.append(matrixPane, tracePane);

  section.append(header, input, results);
  container.replaceChildren(section);

  let mode = modeControl.getAttribute("value");
  let entries = [];
  let selected = null;
  let judgments = [];

  const idleState = {
    kind: "empty_first_run",
    heading: "Enter a tool call or pick a recorded judgment to see the verdict everywhere.",
    glyph: "question",
  };

  function showField() {
    const field = mode === "tool" ? toolField : mode === "shell" ? shellField : judgmentField;
    fieldHost.replaceChildren(field);
  }

  function currentText() {
    if (mode === "tool") return toolField.value;
    if (mode === "shell") return shellField.value;
    return "";
  }

  function winner(cell) {
    return (cell && cell.trace && cell.trace.find((step) => step.winner)) || null;
  }

  function ruleOf(cell) {
    if (!cell) return "";
    if (cell.rule !== undefined) return cell.rule || "";
    return (winner(cell) && winner(cell).rule) || "";
  }

  function cellButton(entry, env) {
    const cell = entry.envs && entry.envs[env];
    const wrap = el("div", "pg-cell");
    if (!cell) {
      wrap.append(el("span", "pg-none", "No result"));
      return wrap;
    }
    const button = el("button", "ps-native pg-cellbtn");
    button.type = "button";
    button.dataset.key = cellStyleKey(entry, env);
    const rule = ruleOf(cell);
    button.setAttribute("aria-label", `${entry.id} ${env}: ${cell.verdict} by ${rule || "no rule"}`);
    button.setAttribute("aria-pressed", selected && selected.key === button.dataset.key ? "true" : "false");
    button.append(chip("verdict", cell.verdict));
    button.addEventListener("click", () => select(entry, env));
    wrap.append(button);
    return wrap;
  }

  function columns() {
    return [
      { key: "id", label: "Entry", width: "200px", mono: true },
      ...ENVS.map((env) => ({ key: env, label: env, width: "120px", render: (entry) => cellButton(entry, env) })),
      {
        key: "rule",
        label: "Rule",
        mono: true,
        render: (entry) => {
          const rules = [];
          for (const env of ENVS) {
            const rule = ruleOf(entry.envs && entry.envs[env]);
            if (rule && !rules.includes(rule)) rules.push(rule);
          }
          return rules.join(", ") || "No rule";
        },
      },
    ];
  }

  table.columns = columns();
  table.emptyState = idleState;
  table.setAttribute("state", "ready");

  function syncPressed() {
    for (const button of table.querySelectorAll(".pg-cellbtn")) {
      button.setAttribute("aria-pressed", selected && button.dataset.key === selected.key ? "true" : "false");
    }
  }

  function select(entry, env) {
    selected = { key: cellStyleKey(entry, env), entry, env };
    syncPressed();
    drawTrace();
  }

  function drawTrace() {
    tracePane.textContent = "";
    if (!selected) {
      tracePane.hidden = true;
      return;
    }
    tracePane.hidden = false;
    const cell = selected.entry.envs[selected.env];
    const title = el("h2", "pg-trace-title");
    title.append(document.createTextNode(`Trace: `), el("span", "mono", selected.entry.id), document.createTextNode(` ${selected.env}`));
    tracePane.append(title);
    const steps = (cell && cell.trace) || [];
    const list = el("ol", "pg-steps");
    list.setAttribute("aria-label", `Rule trace for ${selected.entry.id} ${selected.env}`);
    steps.forEach((step, index) => {
      const row = el("li", "pg-step");
      if (step.winner) row.setAttribute("aria-current", "true");
      row.append(el("span", "num pg-num", String(index + 1)));
      row.append(chip("tag", "", step.layer || ""));
      row.append(el("span", "mono pg-rule", step.rule || ""));
      const matched = el("span", "pg-matched");
      matched.append(icon(step.matched ? "check" : "close"), document.createTextNode(step.matched ? "Matched" : "Skipped"));
      row.append(matched);
      if (step.verdict) row.append(chip("verdict", step.verdict));
      list.append(row);
    });
    if (!steps.length) list.append(el("li", "pg-step pg-none", "No rule steps were recorded for this cell."));
    const scroll = el("div", "pg-steps-scroll");
    scroll.tabIndex = 0;
    scroll.setAttribute("role", "region");
    scroll.setAttribute("aria-label", "Trace steps");
    scroll.append(list);
    tracePane.append(scroll);
    tracePane.append(el("p", "pg-reason", (cell && cell.reason) || "No explanation was returned for this cell."));
  }

  function drawRecord(record) {
    recordLine.textContent = "";
    if (!record) {
      recordLine.hidden = true;
      return;
    }
    recordLine.hidden = false;
    const entry = entries.find((item) => item.id === record.project);
    const cell = entry && entry.envs && entry.envs[record.env];
    const same = Boolean(cell) && cell.verdict === record.verdict && (ruleOf(cell) || null) === (record.rule || null);
    recordLine.dataset.match = same ? "true" : "false";
    recordLine.append(icon(same ? "check" : "warn"));
    recordLine.append(el("span", "", "Recorded:"), chip("verdict", record.verdict), el("span", "mono", record.rule || "no rule"));
    recordLine.append(el("span", "", `in ${record.project || "?"} ${record.env || ""}. Replay:`));
    if (cell) recordLine.append(chip("verdict", cell.verdict), el("span", "mono", ruleOf(cell) || "no rule"));
    recordLine.append(el("span", "pg-match", same ? "Same verdict and rule." : "The replay differs from the record."));
  }

  let running = null;
  async function run() {
    let body;
    if (mode === "tool") {
      const text = toolField.value;
      if (!text.trim()) {
        toolField.setError("Enter a JSON hook payload.");
        toolField.focus();
        return;
      }
      const parsed = parseToolJson(text);
      if (parsed.error) {
        toolField.setError(parsed.error);
        toolField.focus();
        return;
      }
      toolField.setError("");
      body = { ...parsed.body, all_envs: true };
    } else if (mode === "shell") {
      const text = shellField.value.trim();
      if (!text) {
        shellField.focus();
        return;
      }
      body = { tool: "Bash", input: { command: text }, all_envs: true };
    } else {
      const id = judgmentField.value;
      if (!id) {
        judgmentField.focus();
        return;
      }
      body = { judgment_id: id, all_envs: true };
    }
    if (running) running.abort();
    const controller = new AbortController();
    running = controller;
    const forward = () => controller.abort();
    signal.addEventListener("abort", forward, { once: true });
    selected = null;
    drawTrace();
    drawRecord(null);
    table.setAttribute("state", "loading");
    try {
      const data = await post(endpoints.explain, body, { signal: controller.signal });
      if (controller.signal.aborted) return;
      entries = (data && data.entries) || [];
      table.emptyState = { kind: "empty_cleared", heading: "No entries to judge against.", glyph: "info" };
      table.rows = entries;
      table.setAttribute("state", "ready");
      drawRecord(data && data.record);
      announce(`${entries.length} entries judged`);
    } catch (error) {
      if (controller.signal.aborted) return;
      table.errorState = {
        heading: "The judgment did not run",
        body: error.message || "The request failed.",
        "error-id": error.errorId || "",
      };
      table.setAttribute("state", "error");
    } finally {
      signal.removeEventListener("abort", forward);
      if (running === controller) running = null;
    }
  }

  table.addEventListener("ps-retry", (event) => {
    event.stopPropagation();
    run();
  });
  judge.addEventListener("click", run);
  toolField.addEventListener("ps-submit", run);
  section.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
      event.preventDefault();
      run();
    } else if (event.key === "Enter" && event.target === shellField.input) {
      event.preventDefault();
      run();
    }
  });
  modeControl.addEventListener("ps-change", (event) => {
    mode = event.detail.value;
    showField();
  });
  judgmentField.addEventListener("ps-change", () => {
    if (judgmentField.value) run();
  });

  showField();

  try {
    const data = await get(endpoints.judgments({ limit: 50 }), { signal });
    judgments = (data && data.judgments) || [];
  } catch (error) {
    if (signal.aborted) return;
    judgments = [];
  }
  const options = judgments.map((record) => ({ value: record.id, label: judgmentLabel(record) }));
  if (preset && !options.some((option) => option.value === preset)) options.unshift({ value: preset, label: preset });
  judgmentField.options = options;
  if (preset) {
    judgmentField.value = preset;
    await run();
  }
}
