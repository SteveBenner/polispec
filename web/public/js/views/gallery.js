import "../components/ps-card.js";
import "../components/ps-chip.js";
import "../components/ps-state.js";
import "../components/ps-skeleton.js";
import "../components/ps-segmented.js";
import "../components/ps-select.js";
import "../components/ps-text-field.js";
import "../components/ps-toggle.js";
import "../components/ps-drawer.js";
import "../components/ps-button.js";
import "../components/ps-icon-button.js";
import { get, endpoints } from "../core/api.js";
import { announce } from "../core/announce.js";
import { writeView, getPref, setPref } from "../core/cache.js";
import { formatCount } from "../core/format.js";
import { openPlan } from "../components/ps-plan-sheet.js";
import * as router from "../core/router.js";

const KIND_LABEL = { package: "Package", module: "Module", example: "Example" };
const FILTERS = [
  { value: "all", label: "All" },
  { value: "package", label: "Packages" },
  { value: "module", label: "Modules" },
  { value: "example", label: "Examples" },
];
const SHELF = "global/shelf";

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

function usedBy(item) {
  if (Array.isArray(item.used_by)) return item.used_by;
  if (Array.isArray(item.projects)) return item.projects;
  return [];
}

function usedCount(item) {
  if (Number.isFinite(item.used_by_count)) return item.used_by_count;
  return usedBy(item).length;
}

function collect(catalog) {
  const out = [];
  const groups = [
    ["package", catalog && catalog.packages],
    ["module", catalog && catalog.modules],
    ["example", catalog && catalog.examples],
  ];
  for (const [kind, list] of groups) {
    for (const item of Array.isArray(list) ? list : []) {
      if (!item || !item.name) continue;
      out.push({ ...item, kind, params: normalizeParams(item), used: usedBy(item), usedN: usedCount(item) });
    }
  }
  return out;
}

function targets(catalog) {
  const list = [];
  const source = catalog && catalog.rulebooks;
  for (const entry of Array.isArray(source) ? source : []) {
    if (entry && entry.kind === "project" && entry.id) list.push({ value: `project/${entry.id}`, label: entry.id });
  }
  list.push({ value: SHELF, label: "The shelf (global)" });
  return list;
}

function newDraftId() {
  return "gl_" + Math.random().toString(16).slice(2, 10);
}

class Gallery {
  constructor(container, signal) {
    this.signal = signal;
    this.items = [];
    this.catalog = null;
    this.filter = String(getPref("gallery-kind", "all"));
    if (!FILTERS.some((entry) => entry.value === this.filter)) this.filter = "all";
    this.query = "";
    this.build(container);
  }

  build(container) {
    const section = el("section", "view gallery");
    const header = el("header", "view-header");
    const heading = el("h1", "", "Gallery");
    heading.tabIndex = -1;
    const controls = el("div", "gl-controls");
    this.segmented = document.createElement("ps-segmented");
    this.segmented.setAttribute("label", "Kind");
    this.segmented.options = FILTERS;
    this.segmented.setAttribute("value", this.filter);
    this.search = document.createElement("ps-text-field");
    this.search.setAttribute("label", "Search the gallery");
    this.search.setAttribute("hide-label", "");
    this.search.setAttribute("placeholder", "Search");
    this.search.setAttribute("icon", "search");
    this.search.setAttribute("clearable", "");
    controls.append(this.segmented, this.search);
    header.append(heading, controls);
    this.body = el("div", "gl-body");
    this.grid = el("div", "gl-grid");
    this.grid.setAttribute("aria-label", "Gallery items");
    this.status = el("p", "visually-hidden");
    this.status.setAttribute("role", "status");
    this.body.append(this.grid, this.status);
    section.append(header, this.body);
    container.replaceChildren(section);
    this.section = section;
    this.segmented.addEventListener("ps-change", (event) => {
      this.filter = event.detail.value;
      setPref("gallery-kind", this.filter);
      this.draw();
    });
    this.search.addEventListener("ps-input", (event) => {
      this.query = String(event.detail.value || "").trim().toLowerCase();
      this.draw();
    });
  }

  skeletons() {
    this.grid.replaceChildren();
    for (let index = 0; index < 6; index += 1) {
      const card = el("div", "gl-skeleton");
      card.setAttribute("aria-hidden", "true");
      card.append(document.createElement("ps-skeleton"));
      card.firstChild.setAttribute("lines", "4");
      this.grid.append(card);
    }
    this.grid.setAttribute("aria-busy", "true");
  }

  showError(error) {
    this.grid.removeAttribute("aria-busy");
    const state = document.createElement("ps-state");
    state.setAttribute("kind", "error");
    state.setAttribute("heading", "The gallery did not load");
    state.setAttribute("body", (error && error.message) || "The request failed.");
    if (error && error.errorId) state.setAttribute("error-id", error.errorId);
    state.addEventListener("ps-retry", (event) => {
      event.stopPropagation();
      this.load();
    });
    this.grid.replaceChildren(state);
    this.grid.setAttribute("data-empty", "");
  }

  async load() {
    this.skeletons();
    this.grid.removeAttribute("data-empty");
    try {
      const catalog = await get(endpoints.catalog, { signal: this.signal });
      if (this.signal.aborted) return;
      this.catalog = catalog;
      this.items = collect(catalog);
      this.draw();
    } catch (error) {
      if (this.signal.aborted || (error && error.name === "AbortError")) return;
      this.showError(error);
    }
  }

  visible() {
    return this.items.filter((item) => {
      if (this.filter !== "all" && item.kind !== this.filter) return false;
      if (!this.query) return true;
      const hay = `${item.name} ${item.summary || ""} ${item.description || ""}`.toLowerCase();
      return hay.includes(this.query);
    });
  }

  draw() {
    this.grid.removeAttribute("aria-busy");
    const list = this.visible();
    this.grid.replaceChildren();
    if (!list.length) {
      this.grid.setAttribute("data-empty", "");
      const state = document.createElement("ps-state");
      if (this.items.length) {
        state.setAttribute("kind", "empty_filtered");
        state.setAttribute("heading", "No items match");
        state.setAttribute("action", "Clear filters");
        state.addEventListener("ps-action", () => this.clearFilters());
      } else {
        state.setAttribute("kind", "empty_first_run");
        state.setAttribute("heading", "The gallery is empty");
        state.setAttribute("body", "No packages, shelf modules, or examples were found on this host.");
        state.setAttribute("glyph", "cards");
      }
      this.grid.append(state);
      this.status.textContent = "No items";
      return;
    }
    this.grid.removeAttribute("data-empty");
    for (const item of list) this.grid.append(this.card(item));
    this.status.textContent = `${list.length} ${list.length === 1 ? "item" : "items"}`;
  }

  clearFilters() {
    this.filter = "all";
    this.query = "";
    this.segmented.value = "all";
    this.search.value = "";
    setPref("gallery-kind", "all");
    this.draw();
    announce("Filters cleared");
  }

  card(item) {
    const card = document.createElement("ps-card");
    card.setAttribute("interactive", "");
    card.setAttribute("aria-label", `${item.name}, ${KIND_LABEL[item.kind]}. Open details.`);
    const wrap = el("div", "gl-card");
    const top = el("div", "gl-top");
    const name = el("span", "gl-name", item.name);
    name.title = item.name;
    const tag = document.createElement("ps-chip");
    tag.setAttribute("kind", "tag");
    tag.setAttribute("label", KIND_LABEL[item.kind]);
    top.append(name, tag);
    const summary = el("div", "gl-summary", item.summary || "");
    summary.title = item.summary || "";
    const description = el("div", "gl-desc", item.description || "");
    const foot = el("div", "gl-foot");
    const params = el("span", "num", `${formatCount(item.params.length)} ${item.params.length === 1 ? "param" : "params"}`);
    const used = el("span", "num", `Used by ${formatCount(item.usedN)}`);
    foot.append(params, used);
    wrap.append(top, summary, description, foot);
    card.append(wrap);
    card.addEventListener("click", () => this.openDrawer(item, card));
    return card;
  }

  openDrawer(item, opener) {
    const drawer = document.createElement("ps-drawer");
    drawer.setAttribute("heading", item.name);
    drawer.className = "gl-drawer";
    const body = el("div", "gl-drawer-body");
    const kindLine = el("div", "gl-kind");
    const tag = document.createElement("ps-chip");
    tag.setAttribute("kind", "tag");
    tag.setAttribute("label", KIND_LABEL[item.kind]);
    kindLine.append(tag);
    if (item.summary) kindLine.append(el("span", "gl-drawer-summary", item.summary));
    body.append(kindLine);
    body.append(el("p", "gl-drawer-desc", item.description || "This item has no description."));
    const using = el("div", "gl-using");
    using.append(el("h3", "gl-h3", `Used by ${formatCount(item.usedN)}`));
    if (item.used.length) {
      const chips = el("div", "gl-chips");
      for (const id of item.used) {
        const chip = document.createElement("ps-chip");
        chip.setAttribute("kind", "tag");
        chip.setAttribute("label", String(id));
        chips.append(chip);
      }
      using.append(chips);
    } else {
      using.append(el("p", "gl-quiet", "No project uses it yet."));
    }
    body.append(using);
    const fields = [];
    if (item.params.length) {
      const form = el("div", "gl-form");
      form.append(el("h3", "gl-h3", "Parameters"));
      for (const param of item.params) form.append(this.field(param, fields));
      body.append(form);
    }
    const target = document.createElement("ps-select");
    target.setAttribute("label", "Target");
    const options = targets(this.catalog);
    target.options = options;
    target.setAttribute("value", options[0].value);
    const targetWrap = el("div", "gl-target");
    targetWrap.append(target);
    body.append(targetWrap);
    const actions = el("div", "gl-actions");
    const preview = button("Preview on map", { size: "md" });
    const plan = button("Plan", { variant: "primary", size: "md" });
    actions.append(preview, plan);
    body.append(actions);
    drawer.append(body);
    this.section.append(drawer);
    drawer.addEventListener("ps-close", () => drawer.remove());
    preview.addEventListener("click", () => {
      const request = this.request(item, target.value, fields, true);
      if (!request) return;
      const draft = newDraftId();
      writeView(`gallery-draft:${draft}`, { payload: request });
      drawer.close();
      router.navigate(`map?preview=${encodeURIComponent(draft)}`);
    });
    plan.addEventListener("click", () => {
      const request = this.request(item, target.value, fields, true);
      if (!request) return;
      drawer.close();
      openPlan(request, opener);
    });
    drawer.show(opener);
  }

  request(item, targetValue, fields, validate) {
    const values = {};
    let missing = false;
    for (const field of fields) {
      const value = field.read();
      const empty = value === "" || (Array.isArray(value) && !value.length);
      if (field.param.required && empty) {
        field.mark("Required");
        missing = true;
      } else {
        field.mark("");
        if (!empty) values[field.param.name] = value;
      }
    }
    if (validate && missing) {
      announce("Fill in the required fields first", { assertive: true });
      return null;
    }
    const [kind, ...rest] = String(targetValue).split("/");
    const compose = { with: values };
    compose[item.kind] = item.name;
    return { target: { kind, id: rest.join("/") }, change: { kind: "compose", compose } };
  }

  field(param, fields) {
    const wrap = el("div", "gl-field");
    const label = param.required ? `${param.name} (Required)` : param.name;
    if (param.type === "enum") {
      const select = document.createElement("ps-select");
      select.setAttribute("label", label);
      select.options = param.values.map((value) => ({ value: String(value), label: String(value) }));
      if (param.fallback != null) select.setAttribute("value", String(param.fallback));
      wrap.append(select);
      fields.push({ param, read: () => select.value || "", mark: (text) => (text ? select.setAttribute("state", "error") : select.removeAttribute("state")) });
    } else if (param.type === "boolean") {
      wrap.append(el("span", "gl-field-label", label));
      const toggle = document.createElement("ps-toggle");
      toggle.setAttribute("label", param.description || param.name);
      if (param.fallback === true) toggle.setAttribute("checked", "");
      wrap.append(toggle);
      fields.push({ param, read: () => (toggle.checked || param.fallback === true ? toggle.checked : ""), mark: () => null });
    } else if (param.type === "list") {
      const group = el("div", "gl-list-field");
      group.setAttribute("role", "group");
      group.setAttribute("aria-label", label);
      group.append(el("span", "gl-field-label", label));
      const rows = el("div", "gl-list-rows");
      const inputs = [];
      const add = () => {
        const row = el("div", "gl-list-row");
        const input = document.createElement("ps-text-field");
        input.setAttribute("label", `${param.name} item ${inputs.length + 1}`);
        input.setAttribute("hide-label", "");
        input.setAttribute("mono", "");
        const remove = document.createElement("ps-icon-button");
        remove.setAttribute("icon", "close");
        remove.setAttribute("label", `Remove ${param.name} item`);
        remove.addEventListener("click", () => {
          inputs.splice(inputs.indexOf(input), 1);
          row.remove();
        });
        row.append(input, remove);
        rows.append(row);
        inputs.push(input);
      };
      const adder = button("Add item", { size: "xs" });
      adder.addEventListener("click", add);
      add();
      group.append(rows, adder);
      wrap.append(group);
      fields.push({ param, read: () => inputs.map((input) => input.value.trim()).filter(Boolean), mark: () => null });
    } else {
      const input = document.createElement("ps-text-field");
      input.setAttribute("label", label);
      if (param.description) input.setAttribute("help", param.description);
      input.setAttribute("mono", "");
      if (param.fallback != null) input.setAttribute("value", String(param.fallback));
      wrap.append(input);
      fields.push({ param, read: () => input.value.trim(), mark: (text) => (text ? input.setAttribute("error", text) : input.removeAttribute("error")) });
    }
    return wrap;
  }
}

export async function render(container, params, signal) {
  const gallery = new Gallery(container, signal);
  await gallery.load();
}
