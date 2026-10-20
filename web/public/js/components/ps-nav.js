import "./ps-tooltip.js";
import { app } from "../core/store.js";
import { get, endpoints } from "../core/api.js";
import { currentRoute } from "../core/router.js";
import { formatDuration } from "../core/format.js";

const NS = "http://www.w3.org/2000/svg";
const EXPIRY_NOTE_MS = 10 * 60 * 1000;

export const NAV_GROUPS = [
  {
    label: "Observe",
    items: [
      { name: "Map", route: "map", icon: "map" },
      { name: "Pipeline", route: "pipeline", icon: "rails" },
      { name: "Sessions", route: "sessions", icon: "terminal" },
      { name: "Feed", route: "feed", icon: "signal" },
      { name: "Timeline", route: "timeline", icon: "list-clock" },
      { name: "Heatmap", route: "heatmap", icon: "grid" },
    ],
  },
  {
    label: "Understand",
    items: [
      { name: "Playground", route: "playground", icon: "beaker" },
      { name: "Explainer", route: "explain", icon: "question" },
      { name: "History", route: "history", icon: "rewind" },
    ],
  },
  {
    label: "Change",
    items: [
      { name: "Manager", route: "manager", icon: "edit" },
      { name: "Gallery", route: "gallery", icon: "cards" },
      { name: "Exceptions", route: "exceptions", icon: "flag" },
      { name: "Register", route: "register", icon: "plus-folder" },
    ],
  },
  {
    label: "Publish",
    items: [{ name: "Manifest", route: "manifest", icon: "manifest" }],
  },
];

const counts = new Map();
let expiresAt = null;
let expiryLoaded = false;

function icon(name) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "ps-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

async function loadExpiry() {
  if (expiryLoaded) return;
  expiryLoaded = true;
  try {
    const session = await get(endpoints.session, { retry: false });
    const stamp = session && session.expires_at ? Date.parse(session.expires_at) : NaN;
    expiresAt = Number.isFinite(stamp) ? stamp : null;
  } catch (error) {
    expiresAt = null;
  }
  document.dispatchEvent(new CustomEvent("ps-nav-footer"));
}

class PsNav extends HTMLElement {
  connectedCallback() {
    if (this.nav) {
      this.bind();
      this.sync();
      return;
    }
    this.nav = document.createElement("nav");
    this.nav.setAttribute("aria-label", "Primary");
    this.links = [];
    for (const group of NAV_GROUPS) {
      const section = document.createElement("div");
      section.className = "ps-group";
      const label = document.createElement("div");
      label.className = "ps-group-label text-2xs";
      label.textContent = group.label;
      label.setAttribute("aria-hidden", "true");
      section.append(label);
      for (const item of group.items) {
        const link = document.createElement("a");
        link.className = "ps-item";
        link.href = `#/${item.route}`;
        link.dataset.route = item.route;
        link.tabIndex = -1;
        link.setAttribute("aria-label", item.name);
        const text = document.createElement("span");
        text.className = "ps-label";
        text.textContent = item.name;
        const count = document.createElement("span");
        count.className = "ps-count num text-xs";
        count.hidden = true;
        const tip = document.createElement("ps-tooltip");
        tip.setAttribute("text", item.name);
        link.append(icon(item.icon), text, count, tip);
        link.addEventListener("keydown", (event) => this.onKey(event, link));
        link.addEventListener("focus", () => this.rove(link));
        section.append(link);
        this.links.push({ item, link, count, tip });
      }
      this.nav.append(section);
    }
    this.footer = document.createElement("div");
    this.footer.className = "ps-footer text-2xs";
    this.version = document.createElement("span");
    this.version.className = "ps-version mono";
    this.expiry = document.createElement("span");
    this.expiry.className = "ps-expiry";
    this.footer.append(this.version, this.expiry);
    this.append(this.nav, this.footer);
    this.bind();
    this.sync();
  }

  disconnectedCallback() {
    this.unbind();
  }

  bind() {
    this.unbind();
    this.onRoute = () => this.sync();
    this.onCount = (event) => {
      const detail = event.detail || {};
      counts.set(detail.route, detail.count);
      this.sync();
    };
    this.unsubscribe = app.subscribe(() => this.sync());
    this.ticker = setInterval(() => this.syncFooter(), 30000);
    document.addEventListener("ps-route-change", this.onRoute);
    document.addEventListener("ps-nav-count", this.onCount);
    document.addEventListener("ps-nav-footer", this.onRoute);
  }

  unbind() {
    if (this.unsubscribe) this.unsubscribe();
    this.unsubscribe = null;
    clearInterval(this.ticker);
    if (this.onRoute) {
      document.removeEventListener("ps-route-change", this.onRoute);
      document.removeEventListener("ps-nav-footer", this.onRoute);
    }
    if (this.onCount) document.removeEventListener("ps-nav-count", this.onCount);
  }

  setCount(route, value) {
    counts.set(route, value);
    this.sync();
  }

  sync() {
    const route = currentRoute();
    const name = route ? route.name : "";
    let tabbable = null;
    for (const entry of this.links) {
      const current = entry.item.route === name;
      if (current) entry.link.setAttribute("aria-current", "page");
      else entry.link.removeAttribute("aria-current");
      const value = counts.get(entry.item.route);
      const shown = value !== undefined && value !== null && value !== 0;
      entry.count.hidden = !shown;
      entry.count.textContent = shown ? String(value) : "";
      entry.link.setAttribute("aria-label", shown ? `${entry.item.name}, ${value}` : entry.item.name);
      if (current) tabbable = entry.link;
    }
    if (!tabbable && !this.links.some((entry) => entry.link.tabIndex === 0)) tabbable = this.links[0].link;
    if (tabbable) this.rove(tabbable);
    const state = app.get();
    if (state.session === "active" && !expiryLoaded) loadExpiry();
    this.syncFooter();
  }

  syncFooter() {
    const config = app.get().config;
    this.version.textContent = config && config.version ? `polispec ${config.version}` : "polispec";
    const left = expiresAt === null ? null : expiresAt - Date.now();
    this.expiry.textContent = left !== null && left > 0 && left < EXPIRY_NOTE_MS ? `Session ends in ${formatDuration(left)}` : "";
  }

  rove(target) {
    for (const entry of this.links) entry.link.tabIndex = entry.link === target ? 0 : -1;
  }

  onKey(event, link) {
    const order = this.links.map((entry) => entry.link);
    const index = order.indexOf(link);
    let next = null;
    if (event.key === "ArrowDown") next = order[(index + 1) % order.length];
    else if (event.key === "ArrowUp") next = order[(index - 1 + order.length) % order.length];
    else if (event.key === "Home") next = order[0];
    else if (event.key === "End") next = order[order.length - 1];
    if (!next) return;
    event.preventDefault();
    this.rove(next);
    next.focus();
  }
}

customElements.define("ps-nav", PsNav);
