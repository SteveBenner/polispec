import { announce } from "./announce.js";

const routes = new Map();
const staticViews = new Map();
let container = null;
let controller = null;
let notFound = { title: "Not found", module: "views/not-found.js" };
let defaultRoute = "map";
let firstRender = true;
let current = null;

export function defineRoutes(table, options = {}) {
  routes.clear();
  for (const [name, route] of Object.entries(table)) routes.set(name, route);
  if (options.notFound) notFound = options.notFound;
  if (options.defaultRoute) defaultRoute = options.defaultRoute;
}

export function parseHash(hash) {
  const text = String(hash || "").replace(/^#/, "");
  const [pathPart, queryPart] = text.split("?");
  const segments = pathPart
    .split("/")
    .filter((segment) => segment !== "")
    .map((segment) => {
      try {
        return decodeURIComponent(segment);
      } catch (error) {
        return segment;
      }
    });
  const query = {};
  for (const [key, value] of new URLSearchParams(queryPart || "")) query[key] = value;
  return { name: segments[0] || "", params: segments.slice(1), query };
}

export function navigate(path) {
  const target = "#/" + String(path).replace(/^#?\/?/, "");
  if (window.location.hash === target) {
    mount();
    return;
  }
  window.location.hash = target;
}

export function currentRoute() {
  return current;
}

function stashStatic() {
  for (const child of Array.from(container.children)) {
    if (child.id && child.id.startsWith("/")) staticViews.set(child.id.slice(1), child);
  }
}

function renderFallback(title, message) {
  const section = document.createElement("section");
  const heading = document.createElement("h1");
  heading.textContent = title;
  heading.tabIndex = -1;
  const body = document.createElement("p");
  body.textContent = message;
  section.append(heading, body);
  container.replaceChildren(section);
}

async function renderRoute(route, params, signal, name) {
  if (route.static) {
    const element = staticViews.get(name);
    if (!element) throw new Error("No static view for " + name);
    container.replaceChildren(element);
    return;
  }
  const module = await import(new URL("../" + route.module, import.meta.url).href);
  if (signal.aborted) return;
  container.replaceChildren();
  await module.render(container, params, signal);
}

function focusHeading() {
  const heading = container.querySelector("h1");
  if (!heading) return;
  if (!heading.hasAttribute("tabindex")) heading.setAttribute("tabindex", "-1");
  heading.focus({ preventScroll: false });
}

async function mount() {
  const parsed = parseHash(window.location.hash);
  if (window.location.hash.startsWith("#k=")) return;
  if (controller) controller.abort();
  controller = new AbortController();
  const signal = controller.signal;
  const name = parsed.name || defaultRoute;
  let route = routes.get(name);
  const known = Boolean(route);
  if (!known) route = notFound;
  current = { name: known ? name : "not-found", params: parsed.params, query: parsed.query, title: route.title };
  container.setAttribute("aria-busy", "true");
  try {
    await renderRoute(route, parsed.params, signal, name);
  } catch (error) {
    if (signal.aborted) return;
    renderFallback(route.title, known ? "This view could not be loaded." : "There is no view at this address.");
    document.dispatchEvent(new CustomEvent("ps-route-error", { detail: { name, error } }));
  }
  if (signal.aborted) return;
  container.removeAttribute("aria-busy");
  document.title = route.title + " | polispec";
  if (!firstRender) focusHeading();
  firstRender = false;
  announce(route.title + " loaded");
  document.dispatchEvent(new CustomEvent("ps-route-change", { detail: current }));
}

export function start(target) {
  container = target;
  stashStatic();
  window.addEventListener("hashchange", mount);
  return mount();
}

export function stop() {
  window.removeEventListener("hashchange", mount);
  if (controller) controller.abort();
  controller = null;
  firstRender = true;
}
