import "../components/ps-data-table.js";
import "../components/ps-select.js";
import "../components/ps-chip.js";
import "../components/ps-digest.js";
import "../components/ps-command.js";
import "../components/ps-state.js";
import "../components/ps-tooltip.js";
import { endpoints } from "../core/api.js";
import { loadView } from "../core/cache.js";
import { shortDigest } from "../core/format.js";

const NS = "http://www.w3.org/2000/svg";
const FILTERS = [
  { value: "all", label: "All projects" },
  { value: "unpromoted", label: "Unpromoted" },
  { value: "frozen", label: "Frozen" },
  { value: "failing", label: "Failing gates" },
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

function repoOf(project) {
  return project.repo || project.id;
}

function digestOf(ref) {
  return ref && ref.policy_digest ? ref.policy_digest : "";
}

function aheadOf(project, env) {
  const refs = project.refs || {};
  if (env === "main") return digestOf(refs.main) !== digestOf(refs.test);
  if (env === "test") return digestOf(refs.test) !== digestOf(refs.stable);
  return false;
}

function isUnpromoted(project) {
  return aheadOf(project, "main") || aheadOf(project, "test");
}

function matches(project, filter) {
  if (filter === "unpromoted") return isUnpromoted(project);
  if (filter === "frozen") return Number(project.freezes && project.freezes.active) > 0;
  if (filter === "failing") return Boolean(project.gate) && project.gate.status === "failing";
  return true;
}

function envCell(project, env) {
  const wrap = el("div", "pl-env");
  wrap.dataset.env = env;
  const ref = project.refs && project.refs[env];
  if (!ref) {
    const missing = el("span", "pl-missing", "Refs unavailable");
    if (project.refs_error) missing.title = project.refs_error;
    wrap.append(missing);
    wrap.title = project.refs_error || "Refs unavailable";
    return wrap;
  }
  const top = el("div", "pl-line");
  top.append(el("span", "mono pl-sha", shortDigest(ref.sha || "", 8)));
  if (ref.policy_digest) {
    const digest = document.createElement("ps-digest");
    digest.setAttribute("value", ref.policy_digest);
    digest.setAttribute("kind", "policy digest");
    digest.setAttribute("length", "8");
    top.append(digest);
  }
  const bottom = el("div", "pl-line");
  const ahead = aheadOf(project, env);
  const tag = el("span", ahead ? "pl-tag pl-ahead" : "pl-tag pl-step");
  if (ahead) tag.append(icon("warn"));
  tag.append(document.createTextNode(ahead ? "policy ahead" : "in step"));
  bottom.append(tag);
  wrap.append(top, bottom);
  return wrap;
}

function countCell(kind, label, glyph, value) {
  const span = el("span", "pl-count");
  span.dataset.kind = kind;
  span.append(icon(glyph));
  span.append(el("span", "num", String(value || 0)));
  span.append(el("span", "visually-hidden", ` ${label}`));
  return span;
}

function doctorCell(project) {
  const wrap = el("div", "pl-doctor");
  const doctor = project.doctor || {};
  wrap.append(countCell("error", "errors", "deny", doctor.error), countCell("warning", "warnings", "warn", doctor.warning), countCell("info", "info", "info", doctor.info));
  return wrap;
}

function freezeCell(project) {
  const active = Number(project.freezes && project.freezes.active) || 0;
  const wrap = el("span", "pl-freeze");
  wrap.append(el("span", "num", String(active)));
  if (active > 0) {
    const lock = icon("lock");
    wrap.append(lock);
    wrap.append(el("span", "visually-hidden", " active"));
  }
  return wrap;
}

function gateChip(project) {
  const gate = project.gate || {};
  const chip = document.createElement("ps-chip");
  chip.setAttribute("kind", "verdict");
  const failing = gate.status === "failing";
  chip.setAttribute("value", failing ? "deny" : "allow");
  chip.setAttribute("label", failing ? "Failing" : "Passing");
  return chip;
}

function command(text, options = {}) {
  const node = document.createElement("ps-command");
  node.setAttribute("command", text);
  if (options.operator) node.setAttribute("operator", "");
  if (options.why) node.setAttribute("why", options.why);
  return node;
}

function detailRow(project) {
  const repo = repoOf(project);
  const wrap = el("div", "pl-detail");
  const commands = el("div", "pl-commands");
  const left = el("div", "pl-half");
  left.append(command(`polispec promote ${repo} --to test`, { why: "The gate decides." }));
  const right = el("div", "pl-half");
  right.append(
    command(`polispec promote ${repo} --to stable`, { operator: true, why: "Only the operator promotes to stable." }),
    command(`polispec deploy ${repo} stable`, { operator: true })
  );
  commands.append(left, right);
  const lists = el("div", "pl-lists");
  const findings = el("section", "pl-list");
  findings.append(el("h3", "pl-list-title", "Doctor findings"));
  const items = (project.doctor && project.doctor.findings) || [];
  if (!items.length) findings.append(el("p", "pl-none", "No findings."));
  else {
    const list = el("ul", "pl-rows");
    for (const finding of items) {
      const row = el("li", "pl-row");
      const glyph = finding.severity === "error" ? "deny" : finding.severity === "warning" ? "warn" : "info";
      row.append(icon(glyph), el("span", "mono", finding.code || ""), el("span", "pl-message", finding.message || ""));
      row.dataset.severity = finding.severity || "info";
      list.append(row);
    }
    findings.append(list);
  }
  const gate = el("section", "pl-list");
  gate.append(el("h3", "pl-list-title", "Gate to test"));
  const requirements = (project.gate && project.gate.requirements) || [];
  if (!requirements.length) gate.append(el("p", "pl-none", "No gate requirements recorded."));
  else {
    const list = el("ul", "pl-rows");
    for (const requirement of requirements) {
      const row = el("li", "pl-row");
      row.dataset.met = requirement.met ? "true" : "false";
      row.append(icon(requirement.met ? "allow" : "deny"), el("span", "pl-message", requirement.label || requirement.id || ""));
      row.append(el("span", "visually-hidden", requirement.met ? " met" : " not met"));
      list.append(row);
    }
    gate.append(list);
  }
  lists.append(findings, gate);
  wrap.append(commands, lists);
  return wrap;
}

function columns() {
  return [
    { key: "id", label: "Project", width: "160px", mono: true, sortable: true },
    { key: "main", label: "dev main", width: "144px", render: (p) => envCell(p, "main") },
    { key: "test", label: "test", width: "144px", render: (p) => envCell(p, "test") },
    { key: "stable", label: "prod stable", width: "144px", render: (p) => envCell(p, "stable") },
    { key: "drift", label: "Drift", width: "96px", align: "end", render: (p) => String((p.drift && p.drift.packages) || 0) },
    { key: "doctor", label: "Doctor", width: "120px", render: doctorCell },
    { key: "freezes", label: "Freezes", width: "88px", align: "end", render: freezeCell },
    { key: "gate", label: "Gate to test", width: "120px", render: gateChip },
  ];
}

export async function render(container, params, signal) {
  const section = el("section", "view pipeline");
  const header = el("header", "view-header");
  const heading = el("h1", "", "Pipeline");
  heading.tabIndex = -1;
  const chipHost = el("span", "pl-chips");
  const select = document.createElement("ps-select");
  select.setAttribute("label", "Show");
  select.setAttribute("value", "all");
  select.options = FILTERS;
  header.append(heading, chipHost, select);

  const table = document.createElement("ps-data-table");
  table.setAttribute("caption", "Promotion pipeline by project");
  table.setAttribute("expandable", "");
  table.setAttribute("state", "loading");
  table.keyBy = "id";
  table.columns = columns();
  table.renderDetail = detailRow;
  table.errorState = { heading: "The pipeline did not load" };
  section.append(header, table);
  container.replaceChildren(section);

  let projects = [];
  let loaded = false;

  function draw() {
    const filter = select.value || "all";
    const shown = projects.filter((project) => matches(project, filter));
    if (!projects.length) {
      table.emptyState = {
        kind: "empty_first_run",
        heading: "No live projects yet.",
        body: "Projects in onboarding have no pipeline.",
        glyph: "rails",
      };
    } else {
      table.emptyState = { kind: "empty_filtered", action: "Clear filters" };
    }
    table.rows = shown;
    table.setAttribute("state", "ready");
  }

  select.addEventListener("ps-change", draw);
  table.addEventListener("ps-action", () => {
    select.value = "all";
    draw();
  });

  async function load() {
    table.setAttribute("state", "loading");
    try {
      await loadView({
        key: "pipeline",
        path: endpoints.pipeline,
        chipHost,
        signal,
        render: (data) => {
          projects = (data && data.projects) || [];
          loaded = true;
          draw();
        },
      });
    } catch (error) {
      if (signal && signal.aborted) return;
      if (loaded) return;
      table.errorState = {
        heading: "The pipeline did not load",
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
