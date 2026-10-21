import "../components/ps-segmented.js";
import "../components/ps-select.js";
import "../components/ps-icon-button.js";
import "../components/ps-button.js";
import "../components/ps-banner.js";
import "../components/ps-dialog.js";
import "../components/ps-state.js";
import "../components/ps-command.js";
import "../components/ps-skeleton.js";
import "../components/ps-map.js";
import "../components/ps-map-tree.js";
import { endpoints, get, put } from "../core/api.js";
import { loadView, readView, getPref, setPref } from "../core/cache.js";
import { currentRoute, navigate } from "../core/router.js";
import { toast } from "../core/announce.js";
import { readOnly } from "../core/store.js";
import { buildModel } from "../map/layout.js";

const WINDOWS = [
  { value: "1h", label: "Window: 1 hour" },
  { value: "24h", label: "Window: 24 hours" },
  { value: "7d", label: "Window: 7 days" },
];
const INSPECT_DEBOUNCE = 300;
const SAVE_DEBOUNCE = 500;
const LIST_BELOW = 768;

function node(tag, className, text) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  if (text !== undefined) el.textContent = text;
  return el;
}

function setHash(mode) {
  const narrow = window.innerWidth < LIST_BELOW;
  let hash = "#/map";
  if (mode === "list") hash = "#/map/list";
  else if (narrow) hash = "#/map/map";
  if (window.location.hash !== hash) window.history.pushState(null, "", hash);
}

function describeError(error) {
  return { heading: "The map did not load", body: (error && error.message) || "The server did not answer.", errorId: error && error.requestId ? error.requestId : "" };
}

export async function render(container, params, signal) {
  const route = currentRoute();
  const query = route ? route.query : {};
  const narrow = window.innerWidth < LIST_BELOW;
  let mode = params[0] === "list" ? "list" : params[0] === "map" ? "map" : narrow ? "list" : "map";
  let windowKey = getPref("map.window", "24h");
  if (!WINDOWS.some((item) => item.value === windowKey)) windowKey = "24h";
  const blastId = query.blast || "";
  const previewId = query.preview || "";

  const section = node("section", "view map");
  const header = node("header", "view-header");
  const heading = node("h1", "", "Map");
  heading.tabIndex = -1;
  const toolbar = node("div", "ps-map-toolbar");
  toolbar.setAttribute("role", "toolbar");
  toolbar.setAttribute("aria-label", "Map controls");

  const modeControl = document.createElement("ps-segmented");
  modeControl.setAttribute("label", "Map view");
  modeControl.setAttribute("value", mode);
  modeControl.options = [
    { value: "map", label: "Map" },
    { value: "list", label: "List" },
  ];
  const windowSelect = document.createElement("ps-select");
  windowSelect.setAttribute("label", "Window");
  windowSelect.setAttribute("hide-label", "");
  windowSelect.setAttribute("value", windowKey);
  windowSelect.options = WINDOWS;
  const zoomOut = document.createElement("ps-icon-button");
  zoomOut.setAttribute("icon", "zoom-out");
  zoomOut.setAttribute("label", "Zoom out");
  const zoomIn = document.createElement("ps-icon-button");
  zoomIn.setAttribute("icon", "zoom-in");
  zoomIn.setAttribute("label", "Zoom in");
  const fit = document.createElement("ps-icon-button");
  fit.setAttribute("icon", "fit");
  fit.setAttribute("label", "Fit to width");
  const reset = document.createElement("ps-button");
  reset.setAttribute("variant", "ghost");
  reset.text = "Reset layout";
  reset.setAttribute("write", "");
  reset.setAttribute("disabled", "");
  reset.setAttribute("reason", "No card has a saved position");
  const zoomGroup = node("div", "ps-map-zoom");
  zoomGroup.append(zoomOut, zoomIn, fit);
  toolbar.append(modeControl, windowSelect, zoomGroup, reset);
  header.append(heading, toolbar);

  const inspector = node("div", "ps-map-inspector text-xs");
  inspector.setAttribute("aria-live", "polite");
  inspector.textContent = "Loading map";

  const banner = document.createElement("ps-banner");
  banner.className = "ps-map-banner";
  banner.hidden = true;

  const stage = node("div", "ps-map-stage");
  section.append(header, inspector, banner, stage);

  const dialog = document.createElement("ps-dialog");
  dialog.setAttribute("size", "sm");
  dialog.setAttribute("heading", "Reset layout");
  const dialogText = node("p", "", "");
  const cancel = document.createElement("ps-button");
  cancel.setAttribute("data-dialog-footer", "");
  cancel.setAttribute("variant", "secondary");
  cancel.text = "Cancel";
  const confirm = document.createElement("ps-button");
  confirm.setAttribute("data-dialog-footer", "");
  confirm.setAttribute("variant", "primary");
  confirm.text = "Reset layout";
  dialog.append(dialogText, cancel, confirm);
  section.append(dialog);

  if (signal && signal.aborted) return;
  container.replaceChildren(section);

  const state = {
    payload: null,
    model: null,
    positions: {},
    map: null,
    tree: null,
    inspectTimer: 0,
    saveTimer: 0,
    pendingSave: false,
    blast: null,
    preview: null,
    loadToken: 0,
  };

  const setInspector = (text) => {
    clearTimeout(state.inspectTimer);
    state.inspectTimer = setTimeout(() => {
      inspector.textContent = text || "";
    }, INSPECT_DEBOUNCE);
  };

  const setInspectorNow = (text) => {
    clearTimeout(state.inspectTimer);
    inspector.textContent = text || "";
  };

  const syncControls = () => {
    const mapMode = mode === "map";
    zoomGroup.hidden = !mapMode;
    for (const button of [zoomOut, zoomIn, fit]) {
      if (mapMode && state.payload) button.removeAttribute("disabled");
      else button.setAttribute("disabled", "");
    }
    reset.hidden = !mapMode;
    const saved = Object.keys(state.positions).length;
    if (saved > 0 && mapMode) {
      reset.removeAttribute("disabled");
      reset.removeAttribute("reason");
    } else {
      reset.setAttribute("disabled", "");
      reset.setAttribute("reason", mapMode ? "No card has a saved position" : "Saved positions apply to the map view");
    }
  };

  const setLoadingControls = (loading) => {
    for (const el of [modeControl, windowSelect]) {
      if (loading) el.setAttribute("disabled", "");
      else el.removeAttribute("disabled");
    }
    if (loading) {
      for (const button of [zoomOut, zoomIn, fit, reset]) button.setAttribute("disabled", "");
    } else {
      syncControls();
    }
  };

  const flushSave = async () => {
    clearTimeout(state.saveTimer);
    state.saveTimer = 0;
    if (!state.pendingSave) return;
    state.pendingSave = false;
    if (readOnly()) return;
    try {
      await put(endpoints.state("layout"), { positions: state.positions });
    } catch (error) {
      toast("The map layout could not be saved.", { kind: "error" });
    }
  };

  const scheduleSave = () => {
    state.pendingSave = true;
    clearTimeout(state.saveTimer);
    state.saveTimer = setTimeout(flushSave, SAVE_DEBOUNCE);
  };

  const mountStage = () => {
    stage.textContent = "";
    state.map = null;
    state.tree = null;
    if (mode === "map") {
      const map = document.createElement("ps-map");
      map.addEventListener("ps-map-inspect", (event) => {
        event.stopPropagation();
        if (event.detail.text) setInspector(event.detail.text);
        else setInspectorNow("");
      });
      map.addEventListener("ps-map-positions", (event) => {
        state.positions = event.detail.positions;
        syncControls();
        scheduleSave();
      });
      map.addEventListener("ps-retry", () => load(true));
      map.addEventListener("ps-action", () => navigate("register"));
      stage.append(map);
      state.map = map;
      map.setPositions(state.positions);
    } else {
      const tree = document.createElement("ps-map-tree");
      tree.addEventListener("ps-tree-inspect", (event) => setInspector(event.detail.text));
      stage.append(tree);
      state.tree = tree;
    }
  };

  const showStageError = (error) => {
    const info = describeError(error);
    setInspectorNow("The map did not load");
    if (state.map) {
      state.map.showError(info);
      return;
    }
    stage.textContent = "";
    const err = document.createElement("ps-state");
    err.setAttribute("kind", "error");
    err.setAttribute("heading", info.heading);
    err.setAttribute("body", info.body);
    if (info.errorId) err.setAttribute("error-id", info.errorId);
    err.addEventListener("ps-retry", () => {
      mountStage();
      load(true);
    });
    stage.append(err);
  };

  const applyBlast = () => {
    banner.hidden = true;
    state.blast = null;
    if (!blastId) return;
    const cached = readView("blast:" + blastId);
    const payload = cached && cached.payload;
    banner.hidden = false;
    banner.setAttribute("action", "Close overlay");
    banner.onclick = null;
    banner.addEventListener("ps-action", () => {
      window.history.pushState(null, "", mode === "list" ? "#/map/list" : "#/map");
      route.query = {};
      banner.hidden = true;
      state.blast = null;
      if (state.map) state.map.setBlast(null);
    });
    if (!payload || !Array.isArray(payload.projects)) {
      banner.setAttribute("severity", "warn");
      banner.setAttribute("text", `No blast radius is stored for ${blastId}. Open the manager draft and show the blast radius again.`);
      return;
    }
    const rows = payload.projects.reduce((sum, project) => sum + (project.stricter || 0) + (project.looser || 0), 0);
    const flipped = payload.projects.filter((project) => (project.stricter || 0) + (project.looser || 0) > 0).length;
    banner.setAttribute("severity", "info");
    banner.setAttribute("icon", "tightening");
    banner.setAttribute("text", `Blast radius of ${blastId}: ${rows} rows flip in ${flipped} projects.`);
    state.blast = payload;
  };

  const closePreview = () => {
    window.history.pushState(null, "", mode === "list" ? "#/map/list" : "#/map");
    route.query = {};
    banner.hidden = true;
    state.preview = null;
    if (state.map) state.map.setPreview(null);
  };

  const applyPreview = () => {
    state.preview = null;
    if (blastId || !previewId) return;
    const cached = readView("gallery-draft:" + previewId);
    const payload = cached && cached.payload;
    const change = payload && payload.change && payload.change.compose;
    const target = payload && payload.target;
    banner.hidden = false;
    banner.setAttribute("action", "Close preview");
    banner.addEventListener("ps-action", closePreview);
    if (!change || !target || !target.kind) {
      banner.setAttribute("severity", "info");
      banner.removeAttribute("icon");
      banner.setAttribute("text", "That preview is no longer stored. Open the gallery and choose Preview on map again.");
      return;
    }
    const itemKind = Object.keys(change).find((key) => key !== "with") || "item";
    const name = change[itemKind];
    const where = target.kind === "project" ? `project ${target.id}` : "the shelf";
    banner.setAttribute("severity", "info");
    banner.setAttribute("icon", "tightening");
    banner.setAttribute("text", `Preview: ${itemKind} ${name} on ${where}. Nothing is planned or applied.`);
    state.preview = { kind: target.kind, id: target.id };
  };

  const renderPayload = (payload) => {
    state.payload = payload;
    state.model = buildModel(payload);
    if (state.map) {
      state.map.setPositions(state.positions);
      state.map.setData(payload);
      if (state.blast) state.map.setBlast(state.blast);
      if (state.preview) state.map.setPreview(state.preview);
    } else if (state.tree) {
      state.tree.setData(state.model);
      if (state.model.count === 0) {
        const empty = document.createElement("ps-state");
        empty.setAttribute("kind", "empty_first_run");
        empty.setAttribute("heading", "No projects are governed yet");
        empty.setAttribute("body", "Put a git repository under polispec in a terminal.");
        empty.setAttribute("action", "Register a path");
        const command = document.createElement("ps-command");
        command.setAttribute("command", "polispec apply environment-control --repo <path> --variant service");
        empty.append(command);
        empty.addEventListener("ps-action", () => navigate("register"));
        stage.append(empty);
      }
      setInspectorNow("");
    }
    syncControls();
    if (state.map && !inspector.textContent) setInspectorNow("");
  };

  async function load(force) {
    const token = (state.loadToken += 1);
    if (state.map) state.map.showLoading();
    else if (state.tree) {
      const sk = document.createElement("ps-skeleton");
      sk.setAttribute("lines", "6");
      stage.append(sk);
    }
    setInspectorNow("Loading map");
    setLoadingControls(true);
    const path = endpoints.map + "?window=" + encodeURIComponent(windowKey);
    try {
      await loadView({
        key: "map:" + windowKey,
        path,
        chipHost: toolbar,
        signal,
        render: (payload) => {
          if (token !== state.loadToken) return;
          const hadSkeleton = state.tree && stage.querySelector("ps-skeleton");
          if (hadSkeleton) stage.querySelector("ps-skeleton").remove();
          renderPayload(payload);
        },
      });
      if (token === state.loadToken) setLoadingControls(false);
    } catch (error) {
      if (signal && signal.aborted) return;
      if (token !== state.loadToken) return;
      setLoadingControls(false);
      state.payload = null;
      showStageError(error);
      syncControls();
    }
  }

  modeControl.addEventListener("ps-change", (event) => {
    const next = event.detail.value;
    if (next === mode) return;
    mode = next;
    setHash(mode);
    mountStage();
    if (state.payload) renderPayload(state.payload);
    else load(false);
    syncControls();
  });

  windowSelect.addEventListener("ps-change", (event) => {
    windowKey = event.detail.value;
    setPref("map.window", windowKey);
    load(false);
  });

  zoomIn.addEventListener("click", () => state.map && state.map.zoomBy(1));
  zoomOut.addEventListener("click", () => state.map && state.map.zoomBy(-1));
  fit.addEventListener("click", () => state.map && state.map.userFit());

  reset.addEventListener("click", () => {
    const count = Object.keys(state.positions).length;
    if (!count) return;
    dialogText.textContent = `Reset the map layout? Saved positions for ${count} ${count === 1 ? "card" : "cards"} are cleared.`;
    dialog.show(reset);
  });
  cancel.addEventListener("click", () => dialog.close());
  confirm.addEventListener("click", () => {
    state.positions = {};
    if (state.map) state.map.clearPositions();
    state.pendingSave = true;
    flushSave();
    syncControls();
    dialog.close();
  });

  signal.addEventListener("abort", () => {
    clearTimeout(state.inspectTimer);
    flushSave();
  });

  applyBlast();
  applyPreview();
  mountStage();
  try {
    const saved = await get(endpoints.state("layout"), { signal });
    if (saved && saved.positions && typeof saved.positions === "object") state.positions = saved.positions;
  } catch (error) {
    if (signal && signal.aborted) return;
    state.positions = {};
  }
  if ((signal && signal.aborted) || !section.isConnected) return;
  if (state.map) state.map.setPositions(state.positions);
  await load(false);
}
