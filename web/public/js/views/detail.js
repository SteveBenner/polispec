import "../components/ps-chip.js";
import "../components/ps-digest.js";
import "../components/ps-button.js";
import "../components/ps-banner.js";
import "../components/ps-select.js";
import "../components/ps-text-field.js";
import "../components/ps-tabs.js";
import "../components/ps-env-lanes.js";
import "../components/ps-data-table.js";
import "../components/ps-state.js";
import "../components/ps-skeleton.js";
import { endpoints, get, post } from "../core/api.js";
import { isSingleKeyEnabled, register } from "../core/keys.js";
import { navigate } from "../core/router.js";
import { announce } from "../core/announce.js";
import { middleTruncate, shortDigest } from "../core/format.js";

const NS = "http://www.w3.org/2000/svg";
const ENVS = ["dev", "test", "prod"];
const DESCRIPTION_MIN_WIDTH = 960;
const EXPLAIN_DEBOUNCE = 400;
const KINDS = ["project", "path", "module", "package", "global", "exceptions"];

function node(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text !== undefined) el.textContent = text;
  return el;
}

function icon(name) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "ps-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

function tag(label) {
  const chip = document.createElement("ps-chip");
  chip.setAttribute("label", label);
  return chip;
}

function verdictCell(env, verdict) {
  const cell = node("span", "ps-vcell");
  if (!verdict) {
    cell.setAttribute("role", "img");
    cell.setAttribute("aria-label", `${env}: not applicable`);
    cell.dataset.empty = "";
    cell.textContent = "-";
    return cell;
  }
  cell.setAttribute("role", "img");
  cell.setAttribute("aria-label", `${env}: ${verdict}`);
  cell.dataset.verdict = verdict;
  cell.append(icon(verdict));
  return cell;
}

function paramsTable(params) {
  const keys = Object.keys(params || {});
  const table = node("dl", "ps-params");
  if (!keys.length) {
    table.append(node("dd", "ps-params-empty", "No parameters"));
    return table;
  }
  for (const key of keys) {
    table.append(node("dt", "mono", key), node("dd", "mono", String(params[key])));
  }
  return table;
}

function stamp(value) {
  return String(value || "").replace("T", " ").replace(/:\d\dZ$/, "").replace("Z", "");
}

export async function render(container, params, signal) {
  const kind = params[0] || "";
  const id = params[1] || kind;
  const section = node("section", "view detail");
  const header = node("header", "view-header");
  const title = node("h1", "", id || "Detail");
  title.tabIndex = -1;
  header.append(title);
  const body = node("div", "ps-detail-region");
  section.append(header, body);
  if (signal && signal.aborted) return;
  container.replaceChildren(section);

  const loading = node("div", "ps-detail-loading");
  loading.setAttribute("aria-busy", "true");
  const lanes = node("div", "ps-detail-lane-skeleton");
  for (let i = 0; i < 3; i += 1) {
    const sk = document.createElement("ps-skeleton");
    sk.setAttribute("height", "88px");
    lanes.append(sk);
  }
  const chain = node("div", "ps-detail-chain-skeleton");
  for (let i = 0; i < 5; i += 1) {
    const sk = document.createElement("ps-skeleton");
    sk.setAttribute("height", "var(--row)");
    chain.append(sk);
  }
  const table = document.createElement("ps-data-table");
  table.setAttribute("caption", "Rules");
  table.setAttribute("state", "loading");
  table.columns = [{ key: "id", label: "Rule" }];
  const loadBody = node("div", "ps-detail-body");
  loadBody.append(chain, table);
  loading.append(lanes, loadBody);
  body.append(loading);

  let comp;
  try {
    comp = await get(endpoints.composition(kind, id), { signal });
  } catch (error) {
    if ((signal && signal.aborted) || !section.isConnected) return;
    body.textContent = "";
    const state = document.createElement("ps-state");
    state.setAttribute("kind", "error");
    state.setAttribute("heading", "The rulebook did not compose");
    state.setAttribute("body", error.message || "The server did not answer.");
    if (error.requestId) state.setAttribute("error-id", error.requestId);
    state.addEventListener("ps-retry", () => render(container, params, signal));
    body.append(state);
    if (error.findings && error.findings.length) {
      const findings = document.createElement("ps-data-table");
      findings.setAttribute("caption", "Validator findings");
      findings.setAttribute("show-caption", "");
      findings.setAttribute("compact", "");
      findings.columns = [
        { key: "code", label: "Code", width: "180px", mono: true },
        { key: "path", label: "Path", width: "220px", mono: true },
        { key: "message", label: "Message" },
      ];
      findings.rows = error.findings;
      body.append(findings);
    }
    return;
  }
  if ((signal && signal.aborted) || !section.isConnected) return;
  build(comp);

  function build(comp) {
    title.textContent = comp.name || id;
    const status = document.createElement("ps-chip");
    status.setAttribute("kind", "status");
    status.setAttribute("value", comp.status || "live");
    const kindTag = tag(comp.kind || kind);
    kindTag.setAttribute("kind", "tag");
    const digest = document.createElement("ps-digest");
    digest.setAttribute("value", shortDigest(comp.digest || "", 64));
    digest.setAttribute("kind", "policy digest");
    digest.setAttribute("length", "8");
    const actions = node("div", "ps-detail-actions");
    const edit = document.createElement("ps-button");
    edit.setAttribute("variant", "secondary");
    edit.text = "Edit in manager";
    edit.addEventListener("click", () => navigate(`manager/${encodeURIComponent(kind)}/${encodeURIComponent(id)}`));
    const history = document.createElement("ps-button");
    history.setAttribute("variant", "ghost");
    history.text = "History";
    history.addEventListener("click", () => navigate(`history/${encodeURIComponent(kind)}/${encodeURIComponent(id)}`));
    actions.append(edit, history);
    const titleGroup = node("div", "ps-detail-title");
    header.textContent = "";
    titleGroup.append(title, status, kindTag, digest);
    header.append(titleGroup, actions);

    body.textContent = "";
    if (!comp.description) {
      const banner = document.createElement("ps-banner");
      banner.setAttribute("severity", "warn");
      banner.setAttribute("text", "No description. Add one in the manager.");
      banner.className = "ps-detail-banner";
      body.append(banner);
    }

    const layers = comp.layers || [];
    const rules = comp.rules || [];
    const own = layers.length ? layers[layers.length - 1] : null;
    const ownRules = comp.own_rules !== undefined ? comp.own_rules : own ? own.rule_count : 0;
    const hasOwnLayer = own && (own.id === "project" || own.id.startsWith("child"));
    const state = { layer: ownRules === 0 && hasOwnLayer ? own.id : "all", open: new Set(), action: null, text: "", token: 0 };

    const winner = node("div", "ps-winner");
    const row1 = node("div", "ps-winner-inputs");
    const actionSelect = document.createElement("ps-select");
    actionSelect.setAttribute("label", "Action class");
    actionSelect.setAttribute("hide-label", "");
    actionSelect.setAttribute("searchable", "");
    actionSelect.setAttribute("placeholder", "Action class");
    actionSelect.options = (comp.action_classes || []).map((value) => ({ value, label: value }));
    const textField = document.createElement("ps-text-field");
    textField.setAttribute("label", "Tool call or command");
    textField.setAttribute("hide-label", "");
    textField.setAttribute("placeholder", "Tool call or command");
    textField.setAttribute("mono", "");
    const clear = document.createElement("ps-button");
    clear.setAttribute("variant", "ghost");
    clear.text = "Clear";
    row1.append(actionSelect, textField, clear);
    const laneHost = node("div", "ps-winner-lanes");
    const envLanes = document.createElement("ps-env-lanes");
    laneHost.append(envLanes);
    winner.append(row1, laneHost);

    const region = node("div", "ps-detail-body");
    const chainEl = node("aside", "ps-layer-chain");
    chainEl.setAttribute("aria-label", "Layer chain");
    const main = node("div", "ps-detail-main");
    const layerSelect = document.createElement("ps-select");
    layerSelect.setAttribute("label", "Layer");
    layerSelect.className = "ps-layer-select";
    layerSelect.setAttribute("hide-label", "");
    layerSelect.options = [{ value: "all", label: "Layer: All layers" }, ...layers.map((layer) => ({ value: layer.id, label: "Layer: " + layer.name }))];
    layerSelect.setAttribute("value", state.layer);

    const tabs = document.createElement("ps-tabs");
    tabs.setAttribute("label", "Rulebook content");
    const rulesPanel = node("div");
    rulesPanel.dataset.tab = "rules";
    rulesPanel.dataset.label = "Rules";
    const modulesPanel = node("div");
    modulesPanel.dataset.tab = "modules";
    modulesPanel.dataset.label = "Modules";
    const gatesPanel = node("div");
    gatesPanel.dataset.tab = "gates";
    gatesPanel.dataset.label = "Gates";
    const freezesPanel = node("div");
    freezesPanel.dataset.tab = "freezes";
    freezesPanel.dataset.label = "Freezes";

    const modules = [];
    for (const layer of layers) for (const mod of layer.modules || []) modules.push({ ...mod, layer: layer.id, layerName: layer.name });
    const gates = comp.gates || [];
    const freezes = comp.freezes || [];
    modulesPanel.dataset.count = String(modules.length);
    gatesPanel.dataset.count = String(gates.length);
    freezesPanel.dataset.count = String(freezes.length);

    const rulesTable = document.createElement("ps-data-table");
    rulesTable.classList.add("ps-rules-table");
    rulesTable.setAttribute("caption", "Rules");
    rulesTable.setAttribute("expandable", "");
    rulesTable.keyBy = "id";
    rulesPanel.append(rulesTable);

    const modulesTable = document.createElement("ps-data-table");
    modulesTable.setAttribute("caption", "Modules");
    modulesTable.setAttribute("expandable", "");
    modulesTable.keyBy = (row) => row.layer + ":" + row.name;
    modulesPanel.append(modulesTable);

    const gatesTable = document.createElement("ps-data-table");
    gatesTable.setAttribute("caption", "Gates");
    gatesPanel.append(gatesTable);

    const freezesTable = document.createElement("ps-data-table");
    freezesTable.setAttribute("caption", "Freezes");
    freezesPanel.append(freezesTable);

    tabs.append(rulesPanel, modulesPanel, gatesPanel, freezesPanel);
    main.append(layerSelect, tabs);
    region.append(chainEl, main);
    body.append(winner, region);

    const layerName = (layerId) => {
      const layer = layers.find((item) => item.id === layerId);
      return layer ? layer.name : layerId;
    };

    const ruleColumns = (wide) => {
      const columns = [
        { key: "id", label: "Rule", width: "180px", mono: true, render: (row) => dim(row, row.id) },
        { key: "layer", label: "Layer", width: "112px", render: (row) => tag(layerName(row.layer)) },
        ...ENVS.map((env) => ({ key: "v_" + env, label: env, width: "44px", render: (row) => verdictCell(env, row.verdicts[env]) })),
        { key: "applies_to", label: "Applies to", render: (row) => dim(row, (row.applies_to || []).join(", ")) },
        {
          key: "overrides",
          label: "Overrides",
          width: "160px",
          mono: true,
          render: (row) => {
            if (row.overridden_by) {
              const wrap = node("span", "ps-override");
              wrap.append(tag("overridden by " + row.overridden_by));
              return wrap;
            }
            return (row.overrides || []).join(", ");
          },
        },
      ];
      if (wide) columns.push({ key: "description", label: "Description", render: (row) => dim(row, row.description || "") });
      return columns;
    };

    function dim(row, text) {
      const span = node("span", row.overridden_by ? "ps-overridden" : "", text);
      return span;
    }

    let wide = false;
    rulesTable.columns = ruleColumns(false);
    rulesTable.renderDetail = (row) => {
      const wrap = node("div", "ps-rule-detail");
      wrap.append(node("p", "text-md", row.description || "No description."));
      wrap.append(node("div", "ps-rule-source mono", row.source || ""));
      const pre = node("pre", "ps-rule-yaml");
      pre.textContent = row.yaml || "";
      pre.tabIndex = 0;
      wrap.append(pre);
      return wrap;
    };

    modulesTable.columns = [
      { key: "name", label: "Module", mono: true, width: "220px" },
      { key: "layer", label: "Layer", width: "140px", render: (row) => tag(row.layerName) },
      { key: "kind", label: "Kind", width: "100px" },
      { key: "params", label: "Params", width: "80px", align: "end", render: (row) => String(Object.keys(row.params || {}).length) },
      { key: "rules", label: "Rules contributed", width: "140px", align: "end", render: (row) => String(row.rules || 0) },
    ];
    modulesTable.renderDetail = (row) => paramsTable(row.params);
    modulesTable.rows = modules;
    modulesTable.emptyState = { kind: "empty_first_run", heading: "No module instances" };

    const gateChip = (status) => {
      const chip = document.createElement("ps-chip");
      if (status === "passing") {
        chip.setAttribute("kind", "verdict");
        chip.setAttribute("value", "allow");
        chip.setAttribute("label", "Passing");
      } else if (status === "failing") {
        chip.setAttribute("kind", "verdict");
        chip.setAttribute("value", "deny");
        chip.setAttribute("label", "Failing");
      } else {
        chip.setAttribute("label", "Not evaluated");
      }
      return chip;
    };
    gatesTable.columns = [
      { key: "id", label: "Gate", mono: true, width: "200px" },
      { key: "transition", label: "Transition", width: "160px" },
      { key: "requirement", label: "Requirement" },
      { key: "status", label: "Status", width: "140px", render: (row) => gateChip(row.status) },
    ];
    gatesTable.rows = gates;
    gatesTable.emptyState = { kind: "empty_first_run", heading: "No gates apply to this rulebook" };

    freezesTable.columns = [
      { key: "id", label: "Freeze", mono: true, width: "200px" },
      { key: "env", label: "Env", width: "80px" },
      { key: "window", label: "Window", mono: true, width: "320px", render: (row) => `${stamp(row.start)} to ${stamp(row.end)}` },
      { key: "reason", label: "Reason" },
      {
        key: "active",
        label: "Active",
        width: "100px",
        render: (row) => {
          const chip = document.createElement("ps-chip");
          if (row.active) {
            chip.setAttribute("kind", "verdict");
            chip.setAttribute("value", "warn");
            chip.setAttribute("label", "Active");
          } else {
            chip.setAttribute("label", "Inactive");
          }
          return chip;
        },
      },
    ];
    freezesTable.rows = freezes;
    freezesTable.emptyState = { kind: "empty_first_run", heading: "No freezes are set" };

    const visibleRules = () => (state.layer === "all" ? rules : rules.filter((rule) => rule.layer === state.layer));

    const inheritedCount = () => rules.filter((rule) => rule.layer !== (own && own.id)).length;

    const refreshRules = () => {
      const list = visibleRules();
      rulesTable.rows = list;
      rulesPanel.dataset.count = String(list.length);
      tabs.render();
      if (!list.length) {
        const ownSelected = own && state.layer === own.id;
        if (ownSelected && ownRules === 0) {
          const names = layers.filter((layer) => layer.id !== own.id && layer.rule_count > 0).map((layer) => layer.name);
          rulesTable.emptyState = {
            kind: "empty_first_run",
            heading: "This rulebook adds no rules of its own",
            body: `It inherits ${inheritedCount()} rules from ${names.length ? names.join(", ") : "no layers"}.`,
            action: "Show inherited rules",
          };
        } else {
          rulesTable.emptyState = { kind: "empty_first_run", heading: "This layer adds no rules" };
        }
        rulesTable.renderBody();
      }
    };

    rulesTable.addEventListener("ps-action", (event) => {
      event.stopPropagation();
      setLayer("all");
    });

    function renderChain() {
      chainEl.textContent = "";
      const list = node("ul", "ps-layer-list");
      const make = (layerId, label, ruleCount, moduleCount, layer) => {
        const item = node("li", "ps-layer-item");
        const row = node("div", "ps-layer-row");
        const expandable = Boolean(layer && layer.modules && layer.modules.length);
        const toggle = document.createElement("button");
        toggle.type = "button";
        toggle.className = "ps-layer-toggle";
        if (expandable) {
          const open = state.open.has(layerId);
          toggle.setAttribute("aria-expanded", open ? "true" : "false");
          toggle.setAttribute("aria-label", (open ? "Collapse " : "Expand ") + label);
          toggle.append(icon(open ? "chevron-down" : "chevron-right"));
          toggle.addEventListener("click", () => {
            if (state.open.has(layerId)) state.open.delete(layerId);
            else state.open.add(layerId);
            renderChain();
            const again = chainEl.querySelector(`[data-layer-toggle="${layerId}"]`);
            if (again) again.focus();
          });
          toggle.dataset.layerToggle = layerId;
        } else {
          toggle.disabled = true;
          toggle.tabIndex = -1;
          toggle.setAttribute("aria-hidden", "true");
          toggle.dataset.leaf = "";
        }
        const pick = document.createElement("button");
        pick.type = "button";
        pick.className = "ps-layer-pick";
        pick.setAttribute("aria-pressed", state.layer === layerId ? "true" : "false");
        pick.dataset.layer = layerId;
        const name = node("span", "ps-layer-name", label);
        pick.append(name);
        if (ruleCount !== null) {
          const counts = node("span", "ps-layer-counts");
          counts.append(node("span", "num", String(ruleCount)), node("span", "num", String(moduleCount)));
          counts.title = `${ruleCount} rules, ${moduleCount} modules`;
          counts.setAttribute("aria-label", `${ruleCount} rules, ${moduleCount} modules`);
          pick.append(counts);
        }
        pick.addEventListener("click", () => setLayer(layerId));
        row.append(toggle, pick);
        item.append(row);
        if (expandable && state.open.has(layerId)) {
          const mods = node("ul", "ps-layer-mods");
          for (const mod of layer.modules) {
            const key = layerId + ":" + mod.name;
            const mItem = node("li", "ps-mod-item");
            const mRow = document.createElement("button");
            mRow.type = "button";
            mRow.className = "ps-mod-row mono";
            const modOpen = state.open.has(key);
            mRow.setAttribute("aria-expanded", modOpen ? "true" : "false");
            mRow.dataset.modKey = key;
            mRow.append(icon(modOpen ? "chevron-down" : "chevron-right"), node("span", "ps-mod-name", mod.name));
            mRow.addEventListener("click", () => {
              if (state.open.has(key)) state.open.delete(key);
              else state.open.add(key);
              renderChain();
              const again = chainEl.querySelector(`[data-mod-key="${CSS.escape(key)}"]`);
              if (again) again.focus();
            });
            mItem.append(mRow);
            if (modOpen) mItem.append(paramsTable(mod.params));
            mods.append(mItem);
          }
          item.append(mods);
        }
        return item;
      };
      list.append(make("all", "All layers", null, null, null));
      for (const layer of layers) list.append(make(layer.id, layer.name, layer.rule_count ?? 0, layer.module_count ?? (layer.modules || []).length, layer));
      chainEl.append(list);
    }

    function setLayer(layerId) {
      state.layer = layerId;
      layerSelect.value = layerId;
      renderChain();
      const pressed = chainEl.querySelector(`[data-layer="${CSS.escape(layerId)}"]`);
      if (document.activeElement === document.body && pressed) pressed.focus();
      refreshRules();
      tabs.select("rules", false);
    }

    layerSelect.addEventListener("ps-change", (event) => {
      state.layer = event.detail.value;
      renderChain();
      refreshRules();
    });

    function selectRule(ruleId) {
      if (!rules.some((rule) => rule.id === ruleId)) return;
      if (state.layer !== "all") {
        state.layer = "all";
        layerSelect.value = "all";
        renderChain();
        refreshRules();
      }
      tabs.select("rules", false);
      const list = rulesTable.displayed || rulesTable.rows;
      const index = list.findIndex((rule) => rule.id === ruleId);
      if (index >= 0) rulesTable.selectRow(index, true);
    }

    function laneData(entry) {
      if (!entry) return { verdict: null, primary: "No rule matches", secondary: "", rule: null, layer: null };
      const noRule = !entry.rule || entry.rule === "NO-RULE";
      return {
        verdict: entry.verdict,
        primary: noRule ? "No rule matches" : entry.rule,
        secondary: entry.overrides ? "overrides " + entry.overrides : "",
        rule: noRule ? null : entry.rule,
        layer: noRule ? null : entry.layer,
      };
    }

    function paintLanes(data) {
      const map = {};
      for (const env of ENVS) map[env] = data ? laneData(data[env]) : { verdict: null, primary: "Pick an action class to see the winning rule", secondary: "" };
      envLanes.lanes = map;
      laneHost.querySelector(".ps-lane-error")?.remove();
      envLanes.hidden = false;
      for (const env of ENVS) {
        const lane = envLanes.querySelector(`.ps-lane[data-env="${env}"]`);
        if (!lane) continue;
        lane.tabIndex = -1;
        const primary = lane.querySelector(".ps-lane-primary");
        const info = map[env];
        if (!data) {
          primary.classList.remove("mono");
          primary.classList.add("ps-lane-hint");
          continue;
        }
        if (info.rule) {
          const link = document.createElement("a");
          link.href = "#";
          link.className = "ps-rule-link";
          link.textContent = middleTruncate(info.rule, 28);
          link.title = info.rule;
          link.addEventListener("click", (event) => {
            event.preventDefault();
            selectRule(info.rule);
          });
          primary.textContent = "";
          primary.append(link);
          primary.title = "";
          if (info.layer) {
            const chip = tag(layerName(info.layer));
            chip.className = "ps-lane-layer";
            primary.after(chip);
          }
        } else {
          primary.classList.remove("mono");
          primary.classList.add("ps-lane-hint");
        }
      }
    }

    function paintBusy() {
      envLanes.lanes = Object.fromEntries(ENVS.map((env) => [env, { verdict: null, primary: "", secondary: "Judging" }]));
      laneHost.querySelector(".ps-lane-error")?.remove();
      envLanes.hidden = false;
    }

    function paintError(retry) {
      envLanes.hidden = true;
      laneHost.querySelector(".ps-lane-error")?.remove();
      const box = node("div", "ps-lane-error");
      box.setAttribute("role", "alert");
      box.append(icon("deny"), node("span", "", "Could not judge this action"));
      const button = document.createElement("ps-button");
      button.setAttribute("size", "xs");
      button.text = "Retry";
      button.addEventListener("click", retry);
      box.append(button);
      laneHost.append(box);
    }

    async function judge() {
      state.token += 1;
      const token = state.token;
      const text = state.text.trim();
      if (!text && !state.action) {
        paintLanes(null);
        return;
      }
      paintBusy();
      try {
        let winners;
        if (text) {
          const result = await post(endpoints.explain, { tool: "Bash", input: { command: text }, all_envs: true, target: { kind, id } }, { signal });
          winners = result.envs;
        } else {
          const result = await get(endpoints.composition(kind, id, { action: state.action }), { signal });
          winners = result.winners;
        }
        if (token !== state.token || (signal && signal.aborted)) return;
        paintLanes(winners || {});
        const summary = ENVS.map((env) => `${env} ${winners && winners[env] ? winners[env].verdict : "no rule"}`).join(", ");
        announce("Winners: " + summary);
      } catch (error) {
        if (signal && signal.aborted) return;
        if (token !== state.token) return;
        paintError(judge);
      }
    }

    let explainTimer = 0;
    actionSelect.addEventListener("ps-change", (event) => {
      state.action = event.detail.value;
      judge();
    });
    textField.addEventListener("ps-input", (event) => {
      state.text = event.detail.value;
      clearTimeout(explainTimer);
      explainTimer = setTimeout(judge, EXPLAIN_DEBOUNCE);
    });
    clear.addEventListener("click", () => {
      state.action = null;
      state.text = "";
      actionSelect.value = null;
      textField.value = "";
      clearTimeout(explainTimer);
      judge();
    });

    const onKey = (event) => {
      if (!event.altKey || event.ctrlKey || event.metaKey) return;
      const index = ["1", "2", "3"].indexOf(event.key);
      if (index < 0) return;
      const lane = envLanes.querySelector(`.ps-lane[data-env="${ENVS[index]}"]`);
      if (!lane) return;
      event.preventDefault();
      lane.focus();
    };
    document.addEventListener("keydown", onKey);
    const unregister = register({
      keys: "/",
      description: "Focus the tool call field",
      group: "Detail",
      handler: () => {
        if (isSingleKeyEnabled()) textField.focus();
      },
    });

    const observer = new ResizeObserver(() => {
      const next = rulesPanel.clientWidth >= DESCRIPTION_MIN_WIDTH;
      if (next !== wide) {
        wide = next;
        rulesTable.columns = ruleColumns(wide);
      }
    });
    observer.observe(rulesPanel);

    signal.addEventListener("abort", () => {
      document.removeEventListener("keydown", onKey);
      unregister();
      observer.disconnect();
      clearTimeout(explainTimer);
    });

    renderChain();
    refreshRules();
    paintLanes(comp.winners || null);
  }
}
