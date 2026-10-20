import "../components/ps-data-table.js";
import "../components/ps-tabs.js";
import "../components/ps-select.js";
import "../components/ps-chip.js";
import "../components/ps-state.js";
import "../components/ps-command.js";
import "../components/ps-env-lanes.js";
import "../components/ps-digest.js";
import "../components/ps-button.js";
import "../components/ps-icon-button.js";
import "../components/ps-skeleton.js";
import { get, endpoints } from "../core/api.js";
import { announce } from "../core/announce.js";
import { shortDigest, middleTruncate, formatCount } from "../core/format.js";
import { createYamlEditor } from "../editor/codemirror.js";
import { openPlan } from "../components/ps-plan-sheet.js";
import * as router from "../core/router.js";

const ENVS = ["dev", "test", "prod"];

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

function chip(kind, value, label) {
  const node = document.createElement("ps-chip");
  node.setAttribute("kind", kind);
  if (value) node.setAttribute("value", value);
  if (label) node.setAttribute("label", label);
  return node;
}

function digest(value) {
  const node = document.createElement("ps-digest");
  node.setAttribute("kind", "policy digest");
  node.setAttribute("value", String(value));
  node.setAttribute("length", "8");
  return node;
}

function ownerText(owner) {
  if (!owner) return null;
  if (typeof owner === "string") return owner;
  return owner.name ? `${owner.name}${owner.uid != null ? ` (uid ${owner.uid})` : ""}` : null;
}

function ownerNode(owner) {
  const text = ownerText(owner);
  if (!text || text === "unknown") return el("span", "mf-faint", "unknown");
  return document.createTextNode(text);
}

function kvList(rows) {
  const list = el("dl", "mf-kv");
  for (const [label, value] of rows) {
    list.append(el("dt", "", label));
    const dd = el("dd");
    if (value instanceof Node) dd.append(value);
    else dd.textContent = value == null || value === "" ? "None" : String(value);
    list.append(dd);
  }
  return list;
}

function section(title, body) {
  const wrap = el("section", "mf-section");
  wrap.append(el("h3", "mf-h3", title), body);
  return wrap;
}

function paneHead(title, tagLabel, extra) {
  const head = el("div", "mf-pane-head");
  head.append(el("h2", "mf-h2", title), chip("tag", "", tagLabel));
  if (extra) {
    extra.classList.add("mf-head-extra");
    head.append(extra);
  }
  return head;
}

function emptyState(heading, body, glyph) {
  const state = document.createElement("ps-state");
  state.setAttribute("kind", "empty_first_run");
  state.setAttribute("heading", heading);
  if (body) state.setAttribute("body", body);
  state.setAttribute("glyph", glyph || "info");
  return state;
}

function indexTable(entries, openable) {
  const table = document.createElement("ps-data-table");
  table.setAttribute("caption", "Entries");
  table.setAttribute("compact", "");
  if (openable) table.setAttribute("openable", "");
  table.keyBy = "id";
  table.columns = [
    { key: "id", label: "Entry", width: "200px", mono: true, sortable: true, render: (row) => row.id },
    { key: "kind", label: "Kind", width: "88px", render: (row) => chip("tag", "", row.kind || "project") },
    { key: "owner", label: "Owner", width: "140px", render: (row) => ownerNode(row.owner) },
    { key: "status", label: "Status", width: "128px", render: (row) => chip("status", row.status || "live") },
    { key: "description", label: "Description", render: (row) => row.description || row.summary || "" },
  ];
  table.emptyState = { kind: "empty_first_run", heading: "No entries in this index." };
  table.rows = entries;
  return table;
}

class Manifest {
  constructor(container, params, signal) {
    this.container = container;
    this.signal = signal;
    this.id = params[0] || "";
    this.tab = this.id ? (params[1] === "badges" ? "badges" : "app") : "index";
    if (params[1] && params[1] !== "badges") this.tab = "app";
    this.index = null;
    this.data = null;
    this.editor = null;
    signal.addEventListener("abort", () => this.dispose(), { once: true });
    this.build();
  }

  dispose() {
    if (this.editor) {
      this.editor.destroy();
      this.editor = null;
    }
  }

  build() {
    const section = el("section", "view manifest");
    const header = el("header", "view-header");
    const heading = el("h1", "", "Manifest");
    heading.tabIndex = -1;
    this.picker = document.createElement("ps-select");
    this.picker.setAttribute("label", "Entry");
    this.picker.setAttribute("searchable", "");
    this.picker.options = this.id ? [{ value: this.id, label: this.id }] : [];
    if (this.id) this.picker.setAttribute("value", this.id);
    header.append(heading, this.picker);
    this.body = el("div", "mf-body");
    section.append(header, this.body);
    this.container.replaceChildren(section);
    this.section = section;
    this.picker.addEventListener("ps-change", (event) => {
      const next = event.detail.value;
      if (!next) return;
      router.navigate(`manifest/${encodeURIComponent(next)}${this.tab === "badges" ? "/badges" : ""}`);
    });
  }

  showLoading() {
    const wrap = el("div", "mf-loading");
    wrap.setAttribute("aria-busy", "true");
    const skeleton = document.createElement("ps-skeleton");
    skeleton.setAttribute("lines", "6");
    wrap.append(skeleton);
    this.body.replaceChildren(wrap);
  }

  showError(error, retry) {
    const state = document.createElement("ps-state");
    state.setAttribute("kind", "error");
    state.setAttribute("heading", "The manifest did not load");
    state.setAttribute("body", (error && error.message) || "The request failed.");
    if (error && error.errorId) state.setAttribute("error-id", error.errorId);
    state.addEventListener("ps-retry", (event) => {
      event.stopPropagation();
      retry();
    });
    this.body.replaceChildren(state);
  }

  async load() {
    this.showLoading();
    try {
      const jobs = [get(endpoints.manifestIndex, { signal: this.signal })];
      if (this.id) jobs.push(get(endpoints.manifest(this.id), { signal: this.signal }));
      const [index, data] = await Promise.all(jobs);
      if (this.signal.aborted) return;
      this.index = index || {};
      this.data = data || null;
      const entries = Array.isArray(this.index.entries) ? this.index.entries : [];
      const options = entries.map((entry) => ({ value: entry.id, label: entry.id }));
      if (this.id && !options.some((option) => option.value === this.id)) options.push({ value: this.id, label: this.id });
      this.picker.options = options;
      if (this.id) this.picker.value = this.id;
      this.draw();
    } catch (error) {
      if (this.signal.aborted || (error && error.name === "AbortError")) return;
      this.showError(error, () => this.load());
    }
  }

  draw() {
    const tabs = document.createElement("ps-tabs");
    tabs.setAttribute("label", "Manifest views");
    tabs.setAttribute("selected", this.tab);
    const app = el("div", "mf-panel");
    app.dataset.tab = "app";
    app.dataset.label = "App";
    const host = el("div", "mf-panel");
    host.dataset.tab = "index";
    host.dataset.label = "Host index";
    const badges = el("div", "mf-panel");
    badges.dataset.tab = "badges";
    badges.dataset.label = "Badges";
    tabs.append(app, host, badges);
    tabs.addEventListener("ps-tab-change", (event) => {
      const next = event.detail.id;
      if (next === "index") router.navigate("manifest");
      else if (!this.id) {
        this.tab = next;
        this.fill(app, host, badges);
      } else router.navigate(`manifest/${encodeURIComponent(this.id)}${next === "badges" ? "/badges" : ""}`);
    });
    this.body.replaceChildren(tabs);
    this.fill(app, host, badges);
    announce("Manifest loaded");
  }

  fill(app, host, badges) {
    for (const panel of [app, host, badges]) panel.replaceChildren();
    if (this.tab === "index") host.append(this.hostIndex());
    else if (!this.id) {
      const pick = (this.tab === "badges" ? badges : app);
      pick.append(emptyState("Pick an entry", "Choose a project or path entry above to see its manifest.", "manifest"));
    } else if (this.tab === "badges") badges.append(this.badgesTab());
    else app.append(this.appTab());
  }

  generated() {
    return (this.data && (this.data.generated || this.data)) || {};
  }

  appTab() {
    const generated = this.generated();
    const authored = this.data ? this.data.authored : null;
    const wrap = el("div", "mf-split");
    wrap.append(this.generatedPane(generated), this.authoredPane(generated, authored));
    return wrap;
  }

  generatedPane(g) {
    const pane = el("section", "mf-pane");
    pane.setAttribute("aria-label", "Generated manifest");
    let action = null;
    if (g.status === "onboarding") {
      action = button("Make live", { size: "xs" });
      action.addEventListener("click", () => {
        openPlan({ target: { kind: "ledger", id: "ledger" }, change: { kind: "status", id: g.id || this.id, status: "live" } }, action);
      });
    }
    pane.append(paneHead("Generated", g.schema || "polispec.manifest/v1", action));
    pane.append(
      section(
        "Identity",
        kvList([
          ["Id", el("span", "mono", g.id || this.id)],
          ["Kind", g.kind || "project"],
          ["Owner", ownerNode(g.owner)],
          ["Status", g.status ? chip("status", g.status) : "None"],
          ["Edition", g.edition || ""],
          ["Enforce mode", g.enforce || g.enforce_mode || ""],
        ])
      )
    );
    const lanes = {};
    const environments = g.environments || {};
    for (const env of ENVS) {
      const item = environments[env];
      if (!item) continue;
      lanes[env] = {
        primary: item.policy_digest ? shortDigest(item.policy_digest, 8) : item.ref || "",
        secondary: item.last_promotion ? String(item.last_promotion).slice(0, 10) : "Not promoted",
      };
    }
    const envs = document.createElement("ps-env-lanes");
    envs.lanes = lanes;
    pane.append(section("Environments", Object.keys(lanes).length ? envs : el("p", "mf-quiet", "No environments are recorded for this entry.")));
    pane.append(section("Layer chain", this.layerChain(g.layers || g.layer_chain || [])));
    pane.append(section("Roster roles", this.roster(g.roster || [])));
    pane.append(section("Doctor findings", this.doctor(g.doctor || {})));
    return pane;
  }

  layerChain(layers) {
    if (!layers.length) return el("p", "mf-quiet", "No layers are composed for this entry.");
    const list = el("ol", "mf-layers");
    layers.forEach((layer, index) => {
      const item = el("li", "mf-layer");
      const head = el("div", "mf-layer-head");
      head.append(el("span", "num mf-step", String(index + 1)), el("span", "mf-layer-name", layer.name || layer.id || ""), chip("tag", "", layer.kind || "layer"));
      item.append(head);
      const modules = Array.isArray(layer.modules) ? layer.modules : [];
      const packages = Array.isArray(layer.packages) ? layer.packages : [];
      if (modules.length || packages.length) {
        const chips = el("div", "mf-chips");
        for (const module of modules) {
          const name = typeof module === "string" ? module : module.name;
          chips.append(chip("tag", "", name));
        }
        for (const pkg of packages) chips.append(chip("tag", "", `package ${typeof pkg === "string" ? pkg : pkg.name}`));
        item.append(chips);
      }
      list.append(item);
    });
    return list;
  }

  roster(rows) {
    const table = document.createElement("ps-data-table");
    table.setAttribute("caption", "Roster roles");
    table.setAttribute("compact", "");
    table.columns = [
      { key: "role", label: "Role", width: "112px", mono: true, render: (row) => row.role },
      { key: "harness", label: "Harness", width: "72px", render: (row) => row.harness || "" },
      { key: "model", label: "Model", width: "80px", render: (row) => row.model || "" },
      { key: "effort", label: "Effort", width: "72px", render: (row) => row.effort || "" },
    ];
    table.emptyState = { kind: "empty_first_run", heading: "No roster roles.", body: "The project has no roster file." };
    table.rows = rows;
    return table;
  }

  doctor(doctor) {
    const wrap = el("div", "mf-doctor");
    const counts = el("div", "mf-counts");
    for (const [key, label] of [["error", "Errors"], ["warning", "Warnings"], ["info", "Info"]]) {
      const count = el("span", "mf-count");
      count.dataset.severity = key;
      count.append(el("span", "num", formatCount(doctor[key] || 0)), document.createTextNode(` ${label}`));
      counts.append(count);
    }
    wrap.append(counts);
    const findings = Array.isArray(doctor.findings) ? doctor.findings : [];
    if (findings.length) {
      const table = document.createElement("ps-data-table");
      table.setAttribute("caption", "Doctor findings");
      table.setAttribute("compact", "");
      table.columns = [
        { key: "severity", label: "Severity", width: "88px", render: (row) => row.severity || "info" },
        { key: "code", label: "Code", width: "200px", mono: true, render: (row) => middleTruncate(row.code || "", 28) },
        { key: "message", label: "Message", render: (row) => row.message || "" },
      ];
      table.rows = findings;
      wrap.append(table);
    }
    return wrap;
  }

  authoredPane(g, authored) {
    const pane = el("section", "mf-pane");
    pane.setAttribute("aria-label", "Authored app file");
    const valid = authored && authored.valid !== false && !(authored.findings || []).some((f) => f.severity === "error");
    const verdict = authored ? chip("verdict", valid ? "allow" : "deny", valid ? "Valid" : "Invalid") : null;
    pane.append(paneHead("Authored", "polispec.app/v1", verdict));
    pane.append(el("p", "mf-quiet", "It grants nothing and is never read by the guard."));
    if (!authored || authored.text == null) {
      const root = (this.data && this.data.root) || g.root || (authored && authored.root) || "the entry root";
      const state = emptyState(`No polispec.app.yml at ${root}.`, "Add one beside the code. Start from this snippet.", "info");
      const snippet = document.createElement("ps-command");
      snippet.setAttribute("command", this.starter(g));
      state.append(snippet);
      pane.append(state);
      return pane;
    }
    const host = el("div", "mf-editor");
    pane.append(host);
    this.editor = createYamlEditor(host, { doc: authored.text, readOnly: true, ariaLabel: "polispec.app.yml, read only" });
    const findings = Array.isArray(authored.findings) ? authored.findings : [];
    if (findings.length) {
      const table = document.createElement("ps-data-table");
      table.setAttribute("caption", "Validation findings");
      table.setAttribute("compact", "");
      table.columns = [
        { key: "severity", label: "Severity", width: "88px", render: (row) => row.severity || "error" },
        { key: "code", label: "Code", width: "180px", mono: true, render: (row) => middleTruncate(row.code || "", 24) },
        { key: "message", label: "Message", render: (row) => row.message || "" },
      ];
      table.rows = findings;
      pane.append(table);
    } else {
      pane.append(el("p", "mf-quiet", "No validation findings."));
    }
    return pane;
  }

  starter(g) {
    return [
      "schema: polispec.app/v1",
      `name: ${g.id || this.id}`,
      "description: One or two sentences on what it does and who it serves.",
      "serves: real_users",
      "owners: []",
      "wants: []",
      "contact: you@example.com",
    ].join("\n");
  }

  hostIndex() {
    const wrap = el("div", "mf-index");
    const publish = document.createElement("ps-command");
    publish.setAttribute("command", "polispec manifest index --publish");
    publish.setAttribute("why", "Publishes your index for other users.");
    wrap.append(publish);
    const index = this.index || {};
    const entries = Array.isArray(index.entries) ? index.entries : [];
    const head = el("div", "mf-index-head");
    head.append(el("h2", "mf-h2", index.user ? `Entries of ${index.user}` : "Your entries"));
    if (index.generated_at) head.append(el("span", "mf-quiet", `Generated ${String(index.generated_at).slice(0, 19).replace("T", " ")}`));
    wrap.append(head);
    const table = indexTable(entries, true);
    table.addEventListener("ps-row-open", (event) => router.navigate(`manifest/${encodeURIComponent(event.detail.row.id)}`));
    wrap.append(table);
    wrap.append(el("h2", "mf-h2", "Published by other users"));
    const published = Array.isArray(index.published) ? index.published : [];
    if (!published.length) {
      wrap.append(el("p", "mf-quiet", "No other users have published an index on this host."));
      return wrap;
    }
    published.forEach((entry, position) => {
      const group = el("div", "mf-group");
      const toggle = el("button", "ps-native mf-group-toggle");
      toggle.type = "button";
      const panelId = `mf-group-${position}`;
      toggle.setAttribute("aria-expanded", "false");
      toggle.setAttribute("aria-controls", panelId);
      toggle.append(el("span", "mf-group-name", entry.user || "unknown"), el("span", "mf-quiet", entry.host || ""), el("span", "num mf-group-count", formatCount((entry.entries || []).length)));
      const body = el("div", "mf-group-body");
      body.id = panelId;
      body.hidden = true;
      toggle.addEventListener("click", () => {
        const open = toggle.getAttribute("aria-expanded") !== "true";
        toggle.setAttribute("aria-expanded", open ? "true" : "false");
        body.hidden = !open;
        if (open && !body.firstChild) {
          if (entry.error) {
            const state = document.createElement("ps-state");
            state.setAttribute("kind", "error");
            state.setAttribute("heading", "This index is not valid");
            state.setAttribute("body", String(entry.error));
            body.append(state);
          } else body.append(indexTable(entry.entries || [], false));
        }
      });
      group.append(toggle, body);
      wrap.append(group);
    });
    return wrap;
  }

  badgesTab() {
    const g = this.generated();
    const wrap = el("div", "mf-badges");
    const preview = el("div", "mf-badge-preview");
    const img = document.createElement("img");
    img.src = `/api/v1/badge/${encodeURIComponent(this.id)}.svg`;
    img.alt = `polispec badge: ${g.status || "status unknown"}${g.enforce ? `, ${g.enforce}` : ""}`;
    img.height = 20;
    img.className = "mf-badge";
    preview.append(img);
    wrap.append(section("Badge", preview));
    const card = el("div", "mf-card");
    card.append(el("div", "mf-card-title mono", g.id || this.id));
    const meta = el("div", "mf-card-meta");
    if (g.status) meta.append(chip("status", g.status));
    meta.append(chip("tag", "", g.enforce || g.enforce_mode || "enforce unknown"));
    card.append(meta);
    card.append(el("div", "mf-card-line", g.description || "No description."));
    const lanes = el("div", "mf-card-envs");
    for (const env of ENVS) {
      const item = (g.environments || {})[env];
      const cell = el("div", "mf-card-env");
      cell.append(el("span", "mf-quiet", env), item && item.policy_digest ? digest(item.policy_digest) : el("span", "mf-faint", "none"));
      lanes.append(cell);
    }
    card.append(lanes);
    wrap.append(section("Card", card));
    const embed = el("div", "mf-embed");
    const markdown = "![polispec](.polispec/badge.svg)";
    const code = el("code", "mono mf-code", markdown);
    const copy = document.createElement("ps-icon-button");
    copy.setAttribute("icon", "copy");
    copy.setAttribute("label", "Copy markdown");
    copy.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(markdown);
        copy.setAttribute("icon", "check");
        announce("Markdown copied");
        setTimeout(() => copy.setAttribute("icon", "copy"), 1500);
      } catch (error) {
        announce("Select and copy the markdown");
      }
    });
    embed.append(code, copy);
    wrap.append(section("Embed in a README", embed));
    if (g.kind === "path") {
      wrap.append(section("Write to the repository", el("p", "mf-quiet", "Path entries have no repository, so the badge and manifest files are not written.")));
    } else {
      const write = document.createElement("ps-command");
      write.setAttribute("command", `polispec manifest ${this.id} --write`);
      write.setAttribute("why", "Writes polispec.manifest.json and .polispec/badge.svg and commits those two paths on main.");
      wrap.append(section("Write to the repository", write));
    }
    return wrap;
  }
}

export async function render(container, params, signal) {
  const view = new Manifest(container, params || [], signal);
  await view.load();
}
