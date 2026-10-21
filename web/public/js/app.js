import "./components/ps-app-shell.js";
import "./components/ps-author-panel.js";
import "./core/theme.js";
import { app } from "./core/store.js";
import { get, endpoints } from "./core/api.js";
import { bootSession, watchLinks } from "./core/session.js";
import * as feed from "./core/sse.js";
import * as router from "./core/router.js";
import * as keys from "./core/keys.js";

const VIEWS = {
  map: "Map",
  pipeline: "Pipeline",
  sessions: "Sessions",
  feed: "Feed",
  timeline: "Timeline",
  heatmap: "Heatmap",
  playground: "Playground",
  explain: "Explainer",
  history: "History",
  manager: "Manager",
  gallery: "Gallery",
  exceptions: "Exceptions",
  register: "Register",
  manifest: "Manifest",
  detail: "Detail",
};

const GO_KEYS = {
  m: "map",
  p: "pipeline",
  s: "sessions",
  f: "feed",
  t: "timeline",
  h: "heatmap",
  y: "playground",
  x: "explain",
  i: "history",
  e: "exceptions",
  r: "register",
  n: "manifest",
  c: "manager",
  a: "gallery",
};

const GATES = {
  exchanging: {
    title: "Opening polispec web",
    body: "Checking the one-time link.",
  },
  link_used_or_expired: {
    title: "This link has already been used or has expired",
    body: "Each link works once. Get a new one in a terminal.",
    command: "polispec web url",
  },
  no_session: {
    title: "No session",
    body: "Run polispec web url in a terminal and open the link it prints.",
    command: "polispec web url",
  },
  session_ended: {
    title: "Session ended",
    body: "",
    command: "polispec web url",
  },
  server_unreachable: {
    title: "polispec web is not running",
    body: "Start it again in a terminal. Cached views are shown when you reopen the link.",
    command: "polispec web --open",
    retry: true,
  },
};

const view = document.getElementById("view");
const shell = document.querySelector("ps-app-shell");
let gateHost = null;
let routerStarted = false;

function routeTable() {
  const table = { specimen: { title: "Token specimen", static: true } };
  for (const [name, title] of Object.entries(VIEWS)) table[name] = { title, module: "views/" + name + ".js" };
  return table;
}

function buildGate(state, cause) {
  const spec = GATES[state];
  const section = document.createElement(window.customElements.get("ps-session-gate") ? "ps-session-gate" : "section");
  section.setAttribute("state", state);
  section.setAttribute("data-gate", state);
  if (window.customElements.get("ps-session-gate")) return section;
  section.setAttribute("role", "alert");
  const heading = document.createElement("h1");
  heading.textContent = spec.title;
  heading.tabIndex = -1;
  const body = document.createElement("p");
  body.textContent = state === "session_ended" && cause ? "Session ended: " + cause : spec.body;
  section.append(heading, body);
  if (spec.command) {
    const command = document.createElement("code");
    command.textContent = spec.command;
    section.append(command);
  }
  if (spec.retry) {
    const retry = document.createElement("button");
    retry.type = "button";
    retry.textContent = "Retry";
    retry.addEventListener("click", boot);
    section.append(retry);
  }
  return section;
}

function showGate(state, cause) {
  hideGate();
  gateHost = document.createElement("div");
  gateHost.id = "gate";
  gateHost.append(buildGate(state, cause));
  shell.hidden = true;
  document.body.insertBefore(gateHost, shell);
  const heading = gateHost.querySelector("h1");
  if (heading) heading.focus();
}

function hideGate() {
  if (gateHost) gateHost.remove();
  gateHost = null;
  shell.hidden = false;
}

function syncBanner(offline) {
  document.documentElement.toggleAttribute("data-offline", offline);
}

function onState(state) {
  syncBanner(state.offline);
  if (state.session === "active") {
    hideGate();
    if (!routerStarted) {
      routerStarted = true;
      router.start(view);
    }
    feed.start();
    return;
  }
  if (GATES[state.session]) {
    feed.stop();
    showGate(state.session, state.cause);
  }
}

function registerShortcuts() {
  for (const [key, name] of Object.entries(GO_KEYS)) {
    keys.register({
      keys: "g " + key,
      description: "Go to " + VIEWS[name],
      group: "Navigation",
      handler: () => router.navigate(name),
    });
  }
  keys.register({
    keys: "?",
    description: "Show keyboard shortcuts",
    group: "General",
    handler: () => document.dispatchEvent(new CustomEvent("ps-open-shortcuts")),
  });
  keys.register({
    keys: "k",
    mod: true,
    description: "Open the command palette",
    group: "General",
    handler: () => document.dispatchEvent(new CustomEvent("ps-open-palette")),
  });
}

function boot() {
  return bootSession();
}

router.defineRoutes(routeTable(), { notFound: { title: "Not found", module: "views/not-found.js" }, defaultRoute: "map" });
registerShortcuts();
keys.start();
app.subscribe(onState);
watchLinks();
boot();
