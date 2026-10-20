import "../components/ps-textarea.js";
import "../components/ps-button.js";
import "../components/ps-chip.js";
import "../components/ps-tabs.js";
import "../components/ps-command.js";
import "../components/ps-state.js";
import "../components/ps-skeleton.js";
import { createYamlEditor } from "../editor/codemirror.js";
import { post, endpoints } from "../core/api.js";
import { announce } from "../core/announce.js";
import { PENDING_KEY } from "../components/ps-author-panel.js";
import * as router from "../core/router.js";

const JUDGMENT_ID = /^jdg_[0-9a-f]+$/i;

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

function panelHeader(title, right) {
  const head = el("div", "ex-head");
  head.append(el("h2", "ex-title", title));
  if (right) head.append(right);
  return head;
}

function stashDraft(draft) {
  try {
    window.sessionStorage.setItem(PENDING_KEY, JSON.stringify({ target: draft.target, yaml: draft.yaml }));
  } catch (error) {
    return;
  }
}

export async function render(container, params, signal) {
  const route = router.currentRoute();
  const preset = (params && params[0]) || (route && route.query && route.query.judgment) || "";

  const section = el("section", "view explain");
  const header = el("header", "view-header");
  const heading = el("h1", "", "Explainer");
  heading.tabIndex = -1;
  header.append(heading);

  const input = el("div", "ex-input");
  const field = document.createElement("ps-textarea");
  field.setAttribute("label", "Paste a deny or warn message, or a judgment id");
  field.setAttribute("mono", "");
  field.setAttribute("submit", "");
  field.setAttribute("placeholder", "[POLISPEC G-GIT-PUSH-PROTECTED] ... or jdg_0123456789ab");
  const explain = document.createElement("ps-button");
  explain.setAttribute("variant", "primary");
  explain.text = "Explain";
  input.append(field, explain);

  const output = el("div", "ex-output");
  output.setAttribute("aria-live", "polite");
  section.append(header, input, output);
  container.replaceChildren(section);

  const idle = () => {
    output.replaceChildren(el("p", "ex-idle", "Paste the text an agent saw, for example a line starting with POLISPEC."));
  };
  idle();
  if (field.area) field.area.rows = 4;

  let editor = null;
  const dropEditor = () => {
    if (editor) {
      editor.destroy();
      editor = null;
    }
  };
  signal.addEventListener("abort", dropEditor, { once: true });

  function drawError(error) {
    dropEditor();
    const state = document.createElement("ps-state");
    state.setAttribute("kind", "error");
    state.setAttribute("heading", "The explanation did not load");
    state.setAttribute("body", error.message || "The request failed.");
    if (error.errorId) state.setAttribute("error-id", error.errorId);
    state.addEventListener("ps-retry", (event) => {
      event.stopPropagation();
      run();
    });
    output.replaceChildren(state);
  }

  function drawNoMatch(data) {
    dropEditor();
    const wrap = el("div", "ex-nomatch");
    wrap.append(el("p", "ex-nomatch-line", "No rule or judgment found in this text."));
    const tried = (data && data.tried) || [];
    if (tried.length) {
      wrap.append(el("p", "ex-tried-title", "Tokens it tried"));
      const list = el("ul", "ex-tried");
      for (const token of tried) list.append(el("li", "mono", token));
      wrap.append(list);
    }
    output.replaceChildren(wrap);
  }

  function rulePanel(data) {
    const panel = el("section", "ex-panel ex-rule");
    panel.setAttribute("aria-labelledby", "ex-rule-title");
    const head = panelHeader("Rule");
    head.firstChild.id = "ex-rule-title";
    panel.append(head);
    const body = el("div", "ex-body");
    const top = el("div", "ex-line");
    top.append(chip("verdict", data.verdict), el("span", "mono ex-ruleid", data.rule_id || ""));
    if (data.layer) top.append(chip("tag", "", data.layer));
    body.append(top);
    if (data.module) {
      const mod = el("p", "ex-meta");
      mod.append(document.createTextNode("Module "), el("span", "mono", data.module));
      body.append(mod);
    }
    body.append(el("p", "ex-prose", data.description || "This rule has no description."));
    const source = data.source;
    if (source && source.path) {
      const where = el("p", "ex-meta");
      where.append(document.createTextNode("Source "), el("span", "mono", source.path + (source.line ? ":" + source.line : "")));
      body.append(where);
    }
    panel.append(body);
    return panel;
  }

  function wayPanel(data) {
    const panel = el("section", "ex-panel ex-way");
    panel.setAttribute("aria-labelledby", "ex-way-title");
    const head = panelHeader("Way forward");
    head.firstChild.id = "ex-way-title";
    panel.append(head);
    const body = el("div", "ex-body");
    body.append(el("p", "ex-prose", data.way_forward || "No way forward was recorded for this rule."));
    const tabs = document.createElement("ps-tabs");
    tabs.setAttribute("label", "Drafts");
    const exceptionTab = el("div", "ex-tab");
    exceptionTab.dataset.tab = "exception";
    exceptionTab.dataset.label = "Draft exception";
    const onceTab = el("div", "ex-tab");
    onceTab.dataset.tab = "allow-once";
    onceTab.dataset.label = "Operator request";

    const draft = data.draft_exception;
    const host = el("div", "ex-editor");
    exceptionTab.append(host);
    const actions = el("div", "ex-actions");
    const open = document.createElement("ps-button");
    open.text = "Open in manager";
    if (!draft || !draft.target) open.setAttribute("disabled", "");
    open.addEventListener("click", () => {
      stashDraft(draft);
      router.navigate(`manager/${encodeURIComponent(draft.target.kind)}/${encodeURIComponent(draft.target.id)}`);
    });
    actions.append(open);
    exceptionTab.append(actions);

    const onceId = (data.allow_once && data.allow_once.id) || data.judgment_id || "";
    const command = document.createElement("ps-command");
    command.setAttribute("operator", "");
    command.setAttribute("who", "The operator runs this in a terminal.");
    command.setAttribute("command", `polispec allow-once ${onceId}`);
    onceTab.append(command);

    tabs.append(exceptionTab, onceTab);
    body.append(tabs);
    panel.append(body);
    requestAnimationFrame(() => {
      if (!host.isConnected) return;
      dropEditor();
      editor = createYamlEditor(host, {
        doc: (draft && draft.yaml) || "",
        readOnly: true,
        ariaLabel: "Draft exception YAML",
      });
    });
    return panel;
  }

  function drawResult(data) {
    dropEditor();
    if (!data || data.match === false) {
      drawNoMatch(data);
      return;
    }
    const grid = el("div", "ex-grid");
    grid.append(rulePanel(data), wayPanel(data));
    output.replaceChildren(grid);
    announce(`Explained ${data.rule_id || "judgment"}`);
  }

  let running = null;
  async function run() {
    const text = field.value.trim();
    if (!text) {
      idle();
      field.focus();
      return;
    }
    if (running) running.abort();
    const controller = new AbortController();
    running = controller;
    const forward = () => controller.abort();
    signal.addEventListener("abort", forward, { once: true });
    const loading = el("div", "ex-loading");
    loading.append(document.createElement("ps-skeleton"), document.createElement("ps-skeleton"));
    output.replaceChildren(loading);
    explain.setAttribute("busy", "");
    try {
      const body = JUDGMENT_ID.test(text) ? { judgment_id: text } : { text };
      const data = await post(endpoints.explainText, body, { signal: controller.signal });
      if (controller.signal.aborted) return;
      drawResult(data);
    } catch (error) {
      if (controller.signal.aborted) return;
      drawError(error);
    } finally {
      signal.removeEventListener("abort", forward);
      explain.removeAttribute("busy");
      if (running === controller) running = null;
    }
  }

  explain.addEventListener("click", run);
  field.addEventListener("ps-submit", run);

  if (preset) {
    field.value = preset;
    await run();
  }
}
