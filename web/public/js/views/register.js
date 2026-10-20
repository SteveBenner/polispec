import "../components/ps-text-field.js";
import "../components/ps-textarea.js";
import "../components/ps-segmented.js";
import "../components/ps-select.js";
import "../components/ps-toggle.js";
import "../components/ps-button.js";
import "../components/ps-icon-button.js";
import "../components/ps-chip.js";
import "../components/ps-state.js";
import "../components/ps-banner.js";
import "../components/ps-command.js";
import { get, post, endpoints } from "../core/api.js";
import { app, descriptionAllowed } from "../core/store.js";
import { announce } from "../core/announce.js";
import { createYamlEditor } from "../editor/codemirror.js";
import { planSheet } from "../components/ps-plan-sheet.js";
import * as router from "../core/router.js";

const ID_PATTERN = /^[a-z0-9][a-z0-9-]{0,40}$/;
const KINDS = [
  { value: "software", label: "Software" },
  { value: "directory", label: "Directory" },
  { value: "system", label: "System" },
];
const STARTERS = [
  { value: "none", label: "None" },
  { value: "gallery", label: "From the gallery" },
  { value: "author", label: "Ask the author" },
];
const ID_DELAY = 600;
const LINT_DELAY = 600;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function button(text, options = {}) {
  const node = document.createElement("ps-button");
  if (options.variant) node.setAttribute("variant", options.variant);
  if (options.size) node.setAttribute("size", options.size);
  node.text = text;
  return node;
}

function icon(name) {
  const NS = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "ps-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

function lintCounts(text) {
  const value = String(text || "").trim();
  if (!value) return { sentences: 0, words: 0 };
  return {
    sentences: value.split(/[.!?]+(?:\s+|$)/).filter((part) => part.trim()).length,
    words: value.split(/\s+/).filter(Boolean).length,
  };
}

function normalizeParams(item) {
  const raw = item && item.params;
  const list = Array.isArray(raw) ? raw : raw && typeof raw === "object" ? Object.entries(raw).map(([name, spec]) => (spec && typeof spec === "object" ? { name, ...spec } : { name, type: spec })) : [];
  return list.map((param) => {
    const values = param.enum || param.values || null;
    let type = String(param.type || "string").toLowerCase();
    if (values && values.length) type = "enum";
    else if (type === "bool") type = "boolean";
    else if (type === "array") type = "list";
    else if (!["boolean", "list"].includes(type)) type = "string";
    return { name: param.name, type, required: Boolean(param.required), values, description: param.description || param.summary || "", fallback: param.default };
  });
}

function configOwner() {
  const config = app.get().config || {};
  if (config.owner && typeof config.owner === "object") return { uid: config.owner.uid, name: config.owner.name };
  return { uid: null, name: config.operator || "unknown" };
}

function ownerLabel(owner) {
  return owner.uid != null ? `${owner.name} (uid ${owner.uid})` : String(owner.name);
}

function homePath() {
  const config = app.get().config || {};
  return config.home || "~";
}

class Register {
  constructor(container, signal) {
    this.signal = signal;
    this.container = container;
    this.owner = configOwner();
    this.registeredBy = "web";
    this.kind = "directory";
    this.entries = null;
    this.lastCheck = null;
    this.starter = "none";
    this.starterFields = [];
    this.picked = null;
    this.timers = { id: 0, lint: 0 };
    this.catalog = null;
    this.editor = null;
    this.done = null;
    signal.addEventListener("abort", () => this.dispose(), { once: true });
    this.build();
  }

  dispose() {
    clearTimeout(this.timers.id);
    clearTimeout(this.timers.lint);
    if (this.editor) {
      this.editor.destroy();
      this.editor = null;
    }
    if (this.onApplied) document.removeEventListener("ps-plan-applied", this.onApplied);
    this.restoreSheet();
  }

  build() {
    const section = el("section", "view register");
    const header = el("header", "view-header");
    const heading = el("h1", "", "Register");
    heading.tabIndex = -1;
    header.append(heading);
    const split = el("div", "rg-split");
    this.form = el("div", "rg-form");
    this.preview = el("aside", "rg-preview");
    this.preview.setAttribute("aria-label", "Ledger entry preview");
    split.append(this.form, this.preview);
    section.append(header, split);
    this.container.replaceChildren(section);
    this.section = section;
    this.buildForm();
    if (this.descField.area) this.descField.area.rows = 4;
    this.buildPreview();
    this.refreshPreview();
    this.onApplied = (event) => {
      const request = event.detail && event.detail.request;
      if (request && request.change && request.change.kind === "register") this.showDone(request.change.register.id);
    };
    document.addEventListener("ps-plan-applied", this.onApplied);
    get(endpoints.map, { signal: this.signal })
      .then((map) => {
        if (this.signal.aborted) return;
        this.entries = Array.isArray(map && map.entries) ? map.entries : [];
        if (this.idField.value.trim()) this.checkId();
      })
      .catch(() => {
        this.entries = null;
      });
    get(endpoints.catalog, { signal: this.signal })
      .then((catalog) => {
        if (this.signal.aborted) return;
        this.catalog = catalog || {};
        this.fillGallery();
      })
      .catch(() => {
        this.catalog = {};
      });
  }

  group(title, lead) {
    const wrap = el("section", "rg-section");
    wrap.append(el("h2", "rg-h2", title));
    if (lead) wrap.append(el("p", "rg-lead", lead));
    return wrap;
  }

  buildForm() {
    const pathSection = this.group("Path and kind", "Say where the thing lives and what it is.");
    this.pathField = document.createElement("ps-text-field");
    this.pathField.setAttribute("label", "Path");
    this.pathField.setAttribute("mono", "");
    this.pathField.setAttribute("placeholder", "/home/you/notes");
    this.pathField.setAttribute("help", "A directory, installed software, or your home directory for system scope.");
    this.kindControl = document.createElement("ps-segmented");
    this.kindControl.setAttribute("label", "Kind");
    this.kindControl.options = KINDS;
    this.kindControl.setAttribute("value", this.kind);
    pathSection.append(this.pathField, this.kindControl);

    const identity = this.group("Identity");
    this.idField = document.createElement("ps-text-field");
    this.idField.setAttribute("label", "Id");
    this.idField.setAttribute("mono", "");
    this.idField.setAttribute("maxlength", "41");
    this.idField.setAttribute("placeholder", "my-notes");
    this.avail = el("div", "rg-avail");
    this.avail.setAttribute("role", "status");
    this.ownerField = document.createElement("ps-text-field");
    this.ownerField.setAttribute("label", "Owner");
    this.ownerField.setAttribute("readonly", "");
    this.ownerField.setAttribute("value", ownerLabel(this.owner));
    this.byField = document.createElement("ps-text-field");
    this.byField.setAttribute("label", "Registered by");
    this.byField.setAttribute("readonly", "");
    this.byField.setAttribute("value", this.registeredBy);
    identity.append(this.idField, this.avail, this.ownerField, this.byField);

    const description = this.group("Description", "Two sentences: what the thing is, and what must never happen to it.");
    this.descField = document.createElement("ps-textarea");
    this.descField.setAttribute("label", "Description");
    this.descLine = el("div", "rg-lint");
    this.descLine.setAttribute("role", "status");
    this.descFindings = el("ul", "rg-findings");
    description.append(this.descField, this.descLine, this.descFindings);
    const allowed = descriptionAllowed();
    if (!allowed.enabled) {
      this.descField.setAttribute("disabled", "");
      this.descField.setAttribute("reason", allowed.reason || "Descriptions are turned off on this host");
      description.append(el("p", "rg-lead", allowed.reason || "Descriptions are turned off on this host."));
    }

    const policy = this.group("Starter policy", "Optional. Pick a module or example from the gallery, or ask the author to draft one.");
    this.starterControl = document.createElement("ps-segmented");
    this.starterControl.setAttribute("label", "Starter policy");
    this.starterControl.options = STARTERS;
    this.starterControl.setAttribute("value", this.starter);
    this.starterBody = el("div", "rg-starter");
    policy.append(this.starterControl, this.starterBody);

    const review = this.group("Review", "Check runs a dry run. Register opens the plan.");
    this.findings = el("div", "rg-check");
    this.findings.setAttribute("aria-live", "polite");
    const actions = el("div", "rg-actions");
    this.checkButton = button("Check", { size: "md" });
    this.checkButton.setAttribute("busy-label", "Checking");
    this.registerButton = button("Register", { variant: "primary", size: "md" });
    actions.append(this.checkButton, this.registerButton);
    review.append(this.findings, actions);

    this.formBody = el("div", "rg-form-body");
    this.formBody.append(pathSection, identity, description, policy, review);
    this.form.append(this.formBody);

    this.pathField.addEventListener("ps-input", () => {
      this.invalidate();
      this.pathField.removeAttribute("error");
      this.refreshPreview();
    });
    this.kindControl.addEventListener("ps-change", (event) => {
      this.kind = event.detail.value;
      if (this.kind === "system") {
        this.pathField.value = homePath();
        this.pathField.setAttribute("readonly", "");
      } else {
        this.pathField.removeAttribute("readonly");
        if (this.pathField.value === homePath()) this.pathField.value = "";
      }
      this.invalidate();
      this.refreshPreview();
    });
    this.idField.addEventListener("ps-input", () => {
      this.invalidate();
      this.idField.removeAttribute("error");
      this.avail.replaceChildren();
      clearTimeout(this.timers.id);
      this.timers.id = setTimeout(() => this.checkId(), ID_DELAY);
      this.refreshPreview();
    });
    this.descField.addEventListener("ps-input", () => {
      this.invalidate();
      this.refreshPreview();
      this.lintDescription();
    });
    this.starterControl.addEventListener("ps-change", (event) => {
      this.starter = event.detail.value;
      this.invalidate();
      this.drawStarter();
    });
    this.checkButton.addEventListener("click", () => this.check());
    this.registerButton.addEventListener("click", () => this.register());
  }

  buildPreview() {
    const head = el("div", "rg-preview-head");
    head.append(el("h2", "rg-h2", "Ledger entry preview"));
    this.editorHost = el("div", "rg-editor");
    this.previewLine = el("div", "rg-lint");
    this.previewLine.setAttribute("role", "status");
    this.preview.append(head, this.editorHost, this.previewLine);
    this.editor = createYamlEditor(this.editorHost, { doc: "", readOnly: true, ariaLabel: "Ledger entry preview, read only" });
  }

  values() {
    return {
      path: this.pathField.value.trim(),
      kind: this.kindControl.value || this.kind,
      id: this.idField.value.trim(),
      description: this.descField.value.trim(),
    };
  }

  body() {
    const body = this.values();
    const starter = this.starterRequest();
    if (starter) body.starter = starter;
    return body;
  }

  localYaml() {
    const v = this.values();
    const id = v.id || "your-id";
    const owner = this.owner.uid != null ? `{uid: ${this.owner.uid}, name: ${JSON.stringify(String(this.owner.name))}}` : `{name: ${JSON.stringify(String(this.owner.name))}}`;
    const lines = ["paths:", `  - id: ${id}`, `    kind: ${v.kind}`, `    path: ${JSON.stringify(v.path || "/your/path")}`, "    status: onboarding", `    owner: ${owner}`, `    registered_by: ${JSON.stringify(this.registeredBy)}`];
    if (v.description) lines.push(`    description: ${JSON.stringify(v.description)}`);
    lines.push(`    policy: paths/${id}.yml`);
    return lines.join("\n") + "\n";
  }

  inputsKey() {
    return JSON.stringify(this.body());
  }

  invalidate() {
    this.lastCheck = null;
  }

  refreshPreview() {
    const text = this.lastCheck && this.lastCheck.key === this.inputsKey() && this.lastCheck.yaml ? this.lastCheck.yaml : this.localYaml();
    if (this.editor) this.editor.setValue(text);
    const counts = lintCounts(this.descField.value);
    this.previewLine.textContent = `${counts.sentences} ${counts.sentences === 1 ? "sentence" : "sentences"}, ${counts.words} ${counts.words === 1 ? "word" : "words"}`;
    this.descLine.textContent = this.previewLine.textContent;
  }

  checkId() {
    const id = this.idField.value.trim();
    this.avail.replaceChildren();
    if (!id) return;
    if (!ID_PATTERN.test(id)) {
      this.idField.setAttribute("error", "Use lowercase letters, digits, and hyphens, up to 41 characters, starting with a letter or digit.");
      return;
    }
    this.idField.removeAttribute("error");
    if (!this.entries) return;
    const taken = this.entries.find((entry) => entry.id === id);
    const line = el("span", taken ? "rg-taken" : "rg-ok");
    line.append(icon(taken ? "deny" : "allow"), document.createTextNode(taken ? `Taken by ${taken.kind || "an entry"} ${taken.id}` : "Available"));
    this.avail.append(line);
  }

  lintDescription() {
    clearTimeout(this.timers.lint);
    const run = async () => {
      const text = this.descField.value.trim();
      this.descFindings.replaceChildren();
      if (!text || !descriptionAllowed().enabled) return;
      try {
        const result = await post(endpoints.lint, { kind: "description", yaml: text }, { signal: this.signal });
        if (this.signal.aborted || text !== this.descField.value.trim()) return;
        if (result && result.description) {
          const { sentences, words } = result.description;
          this.descLine.textContent = `${sentences} ${sentences === 1 ? "sentence" : "sentences"}, ${words} ${words === 1 ? "word" : "words"}`;
          this.previewLine.textContent = this.descLine.textContent;
        }
        for (const finding of (result && result.findings) || []) {
          const item = el("li", "rg-finding");
          item.dataset.severity = finding.severity || "warning";
          item.append(el("span", "mono rg-code", finding.code || ""), document.createTextNode(finding.message || ""));
          this.descFindings.append(item);
        }
      } catch (error) {
        return;
      }
    };
    this.timers.lint = setTimeout(run, LINT_DELAY);
  }

  drawStarter() {
    this.starterBody.replaceChildren();
    this.starterFields = [];
    this.picked = null;
    if (this.starter === "gallery") {
      this.starterSelect = document.createElement("ps-select");
      this.starterSelect.setAttribute("label", "Module or example");
      this.starterSelect.setAttribute("searchable", "");
      this.starterForm = el("div", "rg-starter-form");
      this.starterBody.append(this.starterSelect, this.starterForm);
      this.fillGallery();
      this.starterSelect.addEventListener("ps-change", (event) => this.pickStarter(event.detail.value));
    } else if (this.starter === "author") {
      const note = el("p", "rg-lead", "The author drafts a starter policy from your description. It opens in the side panel.");
      const open = button("Open the author panel", { size: "md" });
      open.addEventListener("click", () => {
        document.dispatchEvent(new CustomEvent("ps-open-author", { detail: { intent: `Draft a starter policy for ${this.idField.value.trim() || "this entry"}. ${this.descField.value.trim()}`.trim() } }));
      });
      this.starterBody.append(note, open);
    }
  }

  shelf() {
    const catalog = this.catalog || {};
    const out = [];
    for (const [kind, list] of [["module", catalog.modules], ["example", catalog.examples]]) {
      for (const item of Array.isArray(list) ? list : []) if (item && item.name) out.push({ ...item, kind });
    }
    return out;
  }

  fillGallery() {
    if (this.starter !== "gallery" || !this.starterSelect) return;
    this.starterSelect.options = this.shelf().map((item) => ({ value: `${item.kind}:${item.name}`, label: `${item.name} (${item.kind})` }));
  }

  pickStarter(value) {
    this.picked = this.shelf().find((item) => `${item.kind}:${item.name}` === value) || null;
    this.starterForm.replaceChildren();
    this.starterFields = [];
    this.invalidate();
    if (!this.picked) return;
    if (this.picked.summary) this.starterForm.append(el("p", "rg-lead", this.picked.summary));
    for (const param of normalizeParams(this.picked)) this.starterForm.append(this.paramField(param));
  }

  paramField(param) {
    const wrap = el("div", "rg-field");
    const label = param.required ? `${param.name} (Required)` : param.name;
    const touch = () => this.invalidate();
    if (param.type === "enum") {
      const select = document.createElement("ps-select");
      select.setAttribute("label", label);
      select.options = param.values.map((value) => ({ value: String(value), label: String(value) }));
      if (param.fallback != null) select.setAttribute("value", String(param.fallback));
      select.addEventListener("ps-change", touch);
      wrap.append(select);
      this.starterFields.push({ param, read: () => select.value || "", mark: (text) => (text ? select.setAttribute("state", "error") : select.removeAttribute("state")) });
    } else if (param.type === "boolean") {
      wrap.append(el("span", "rg-field-label", label));
      const toggle = document.createElement("ps-toggle");
      toggle.setAttribute("label", param.description || param.name);
      if (param.fallback === true) toggle.setAttribute("checked", "");
      toggle.addEventListener("ps-change", touch);
      wrap.append(toggle);
      this.starterFields.push({ param, read: () => (toggle.checked || param.fallback === true ? toggle.checked : ""), mark: () => null });
    } else if (param.type === "list") {
      const input = document.createElement("ps-text-field");
      input.setAttribute("label", `${label} (comma separated)`);
      input.setAttribute("mono", "");
      input.addEventListener("ps-input", touch);
      wrap.append(input);
      this.starterFields.push({ param, read: () => input.value.split(",").map((part) => part.trim()).filter(Boolean), mark: (text) => (text ? input.setAttribute("error", text) : input.removeAttribute("error")) });
    } else {
      const input = document.createElement("ps-text-field");
      input.setAttribute("label", label);
      if (param.description) input.setAttribute("help", param.description);
      input.setAttribute("mono", "");
      if (param.fallback != null) input.setAttribute("value", String(param.fallback));
      input.addEventListener("ps-input", touch);
      wrap.append(input);
      this.starterFields.push({ param, read: () => input.value.trim(), mark: (text) => (text ? input.setAttribute("error", text) : input.removeAttribute("error")) });
    }
    return wrap;
  }

  starterRequest() {
    if (this.starter !== "gallery" || !this.picked) return null;
    const values = {};
    for (const field of this.starterFields) {
      const value = field.read();
      const empty = value === "" || (Array.isArray(value) && !value.length);
      if (!empty) values[field.param.name] = value;
    }
    const starter = { with: values };
    starter[this.picked.kind] = this.picked.name;
    return starter;
  }

  starterMissing() {
    if (this.starter !== "gallery" || !this.picked) return false;
    let missing = false;
    for (const field of this.starterFields) {
      const value = field.read();
      const empty = value === "" || (Array.isArray(value) && !value.length);
      if (field.param.required && empty) {
        field.mark("Required");
        missing = true;
      } else field.mark("");
    }
    return missing;
  }

  localProblems() {
    const v = this.values();
    let bad = false;
    this.pathField.removeAttribute("error");
    this.idField.removeAttribute("error");
    if (!v.path) {
      this.pathField.setAttribute("error", "Enter the path to register.");
      bad = true;
    }
    if (!v.id) {
      this.idField.setAttribute("error", "Enter an id.");
      bad = true;
    } else if (!ID_PATTERN.test(v.id)) {
      this.idField.setAttribute("error", "Use lowercase letters, digits, and hyphens, up to 41 characters, starting with a letter or digit.");
      bad = true;
    } else if (this.entries && this.entries.some((entry) => entry.id === v.id)) {
      this.idField.setAttribute("error", "That id is already in the ledger.");
      bad = true;
    }
    if (this.starterMissing()) bad = true;
    if (bad) {
      this.focusFirstError();
      announce("Fix the fields marked with errors", { assertive: true });
    }
    return bad;
  }

  focusFirstError() {
    const bad = this.formBody.querySelector("[error] input, [state=error] button");
    if (bad) bad.focus();
  }

  applyFindings(findings) {
    const rest = [];
    for (const finding of findings || []) {
      const code = finding.code || "";
      const text = finding.message || code;
      if (code === "inside_ledgered_repo" || code === "inside_project") {
        this.pathField.setAttribute("error", `This path is inside ${finding.repo || finding.project || "a repo"}, which polispec already governs. Its policy lives in that repo.`);
      } else if (code === "not_found" || code === "path_missing" || code === "path_not_found") {
        this.pathField.setAttribute("error", "That path does not exist.");
      } else if (code === "path_registered") {
        this.pathField.setAttribute("error", `This path is already registered as ${finding.id || "another entry"}.`);
      } else if (code === "system_path_invalid" || code === "system_path") {
        this.pathField.setAttribute("error", "The System kind registers the home directory only.");
      } else if (code === "id_taken" || code === "id_collision") {
        this.idField.setAttribute("error", finding.entry ? `Taken by ${finding.entry}` : "That id is already in the ledger.");
      } else if (code === "id_invalid" || code === "invalid_id") {
        this.idField.setAttribute("error", "Use lowercase letters, digits, and hyphens, up to 41 characters, starting with a letter or digit.");
      } else {
        rest.push(finding);
      }
    }
    return rest;
  }

  drawCheck(data, rest, error) {
    this.findings.replaceChildren();
    if (rest && rest.length) {
      const table = el("table", "rg-table");
      const head = el("thead");
      const row = el("tr");
      for (const label of ["Severity", "Code", "Message"]) row.append(el("th", "", label));
      head.append(row);
      const body = el("tbody");
      for (const finding of rest) {
        const tr = el("tr");
        tr.append(el("td", "", finding.severity || "error"), el("td", "mono", finding.code || ""), el("td", "", finding.message || ""));
        body.append(tr);
      }
      table.append(head, body);
      this.findings.append(table);
    }
    if (error) {
      const state = document.createElement("ps-state");
      state.setAttribute("kind", "error");
      state.setAttribute("heading", "The check did not complete");
      state.setAttribute("body", error.message || "The request failed.");
      if (error.errorId) state.setAttribute("error-id", error.errorId);
      state.addEventListener("ps-retry", (event) => {
        event.stopPropagation();
        this.check();
      });
      this.findings.append(state);
      return;
    }
    if (data) {
      const plan = data.plan || data;
      const line = el("div", "rg-plan");
      const chip = document.createElement("ps-chip");
      chip.setAttribute("kind", "classification");
      chip.setAttribute("value", plan.classification || "tightening");
      line.append(chip, el("span", "rg-plan-text", (plan.reasons && plan.reasons[0]) || "A new onboarding entry changes nothing until it is made live."));
      this.findings.append(line);
    }
  }

  async check() {
    if (this.localProblems()) return;
    this.checkButton.setAttribute("busy", "");
    const key = this.inputsKey();
    try {
      const data = await post(endpoints.register, { ...this.body(), dry_run: true }, { signal: this.signal });
      if (this.signal.aborted) return;
      this.checkButton.removeAttribute("busy");
      const rest = this.applyFindings(data && data.findings);
      const blocking = rest.some((finding) => finding.severity === "error") || (data && data.ok === false);
      this.lastCheck = { key, yaml: data && data.preview && (data.preview.yaml || data.preview) };
      if (data && data.owner) {
        this.owner = data.owner;
        this.ownerField.value = ownerLabel(this.owner);
      }
      if (data && data.registered_by) {
        this.registeredBy = data.registered_by;
        this.byField.value = this.registeredBy;
      }
      this.refreshPreview();
      this.drawCheck(blocking ? null : data, rest, null);
      announce(blocking ? "The check found problems" : "The check passed");
      if (this.pathField.hasAttribute("error") || this.idField.hasAttribute("error")) this.focusFirstError();
    } catch (error) {
      if (this.signal.aborted || (error && error.name === "AbortError")) return;
      this.checkButton.removeAttribute("busy");
      if (error && error.kind === "invalid") {
        const rest = this.applyFindings(error.findings || [{ code: error.code, message: error.message }]);
        this.drawCheck(null, rest, null);
        this.focusFirstError();
        announce("The check found problems", { assertive: true });
      } else {
        this.drawCheck(null, [], error);
      }
    }
  }

  restoreSheet() {
    const sheet = this.sheet;
    if (sheet && Object.prototype.hasOwnProperty.call(sheet, "load")) delete sheet.load;
    this.sheet = null;
  }

  register() {
    if (this.localProblems()) return;
    const body = this.body();
    const view = this;
    const sheet = planSheet();
    this.restoreSheet();
    this.sheet = sheet;
    sheet.load = async function load() {
      if (this.controller) this.controller.abort();
      this.controller = new AbortController();
      const mine = this.controller;
      this.s.status = "loading";
      this.s.error = null;
      this.s.findings = null;
      this.renderLoading();
      try {
        const data = await post(endpoints.register, body, { signal: mine.signal });
        if (mine.signal.aborted) return;
        const next = { ...(data && data.plan ? { ...data.plan } : { ...data }) };
        next.target = `register:${body.id}`;
        this.setPlan(next);
      } catch (error) {
        if (mine.signal.aborted || (error && error.name === "AbortError")) return;
        if (error && error.kind === "invalid" && error.findings) view.applyFindings(error.findings);
        this.failLoad(error);
      }
    };
    sheet.addEventListener("ps-plan-closed", () => view.restoreSheet(), { once: true });
    sheet.open({ target: { kind: "register", id: body.id }, change: { kind: "register", register: body } }, this.registerButton);
  }

  showDone(id) {
    this.done = id;
    this.formBody.replaceChildren();
    const state = document.createElement("ps-state");
    state.setAttribute("kind", "empty_cleared");
    state.setAttribute("heading", `Registered ${id}`);
    state.setAttribute("body", "The entry is onboarding: it is listed and judged by nothing yet. Make it live from its manifest when it is ready.");
    const open = button("Open manifest", { variant: "primary", size: "md" });
    open.addEventListener("click", () => router.navigate(`manifest/${encodeURIComponent(id)}`));
    const again = button("Register another", { size: "md" });
    again.addEventListener("click", () => router.navigate("register"));
    const actions = el("div", "rg-actions");
    actions.append(again, open);
    this.formBody.append(state, actions);
    announce(`Registered ${id}`);
  }
}

export async function render(container, params, signal) {
  new Register(container, signal);
}
