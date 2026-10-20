import "./ps-icon-button.js";
import "./ps-button.js";
import "./ps-banner.js";
import "./ps-dialog.js";
import "./ps-drawer.js";
import "./ps-toggle.js";
import "./ps-kbd.js";
import "./ps-tooltip.js";
import "./ps-state.js";
import "./ps-command.js";
import "./ps-digest.js";
import "./ps-chip.js";
import "./ps-conn-status.js";
import "./ps-text-field.js";
import "./ps-skeleton.js";
import "./ps-nav.js";
import "./ps-topbar.js";
import "./ps-side-panel.js";
import "./ps-plan-tray.js";
import "./ps-palette.js";
import "./ps-toaster.js";
import "./ps-session-gate.js";
import { trapTab } from "./ps-side-panel.js";
import "./ps-theme-switcher.js";
import { guard } from "./ps-view-boundary.js";
import { app, readOnly, READ_ONLY_REASON } from "../core/store.js";
import { get, endpoints } from "../core/api.js";
import { currentRoute } from "../core/router.js";
import * as keys from "../core/keys.js";
import { getPref, setPref } from "../core/cache.js";

const DOCK_WIDE = "(min-width: 1440px)";
const DOCK_MANAGER = "(min-width: 1024px)";
const SHEET = "(max-width: 767px)";

function element(tag, className) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  return node;
}

function keyParts(shortcut) {
  return shortcut.mod ? [`Mod ${shortcut.keys.toUpperCase()}`] : shortcut.keys.split(" ");
}

class PsAppShell extends HTMLElement {
  connectedCallback() {
    if (this.stage) return;
    const view = this.querySelector("main#view") || element("main");
    if (!view.id) view.id = "view";
    this.view = view;
    this.topbar = document.createElement("ps-topbar");
    this.navColumn = element("aside", "ps-nav-column");
    this.nav = document.createElement("ps-nav");
    this.navColumn.append(this.nav);
    this.stage = element("div", "ps-stage");
    this.banner = document.createElement("ps-banner");
    this.banner.setAttribute("severity", "warn");
    this.banner.setAttribute("text", "polispec web is not responding. Views may be out of date.");
    this.banner.setAttribute("action", "Retry");
    this.banner.setAttribute("data-banner", "offline");
    this.banner.hidden = true;
    this.banner.addEventListener("ps-action", () => {
      get(endpoints.config, { retry: false }).catch(() => null);
    });
    this.roBanner = document.createElement("ps-banner");
    this.roBanner.setAttribute("severity", "info");
    this.roBanner.setAttribute("text", READ_ONLY_REASON);
    this.roBanner.setAttribute("data-banner", "read-only");
    this.roBanner.hidden = true;
    this.tray = document.createElement("ps-plan-tray");
    this.stage.append(this.banner, this.roBanner, view, this.tray);
    this.panel = document.createElement("ps-side-panel");
    this.panel.setAttribute("heading", "Author panel");
    this.palette = document.createElement("ps-palette");
    this.toaster = document.createElement("ps-toaster");
    this.drawer = this.buildDrawer();
    this.shortcuts = this.buildShortcuts();
    this.replaceChildren(this.topbar, this.navColumn, this.stage, this.panel, this.drawer, this.palette, this.shortcuts, this.toaster);
    this.wire();
    this.syncRoute();
    this.syncOffline();
    this.syncPanelMode();
    this.restorePanel();
  }

  disconnectedCallback() {
    if (this.unsubscribe) this.unsubscribe();
    if (this.releaseGuard) this.releaseGuard();
    for (const [query, handler] of this.queries || []) query.removeEventListener("change", handler);
    document.removeEventListener("ps-route-change", this.onRoute);
    document.removeEventListener("ps-open-shortcuts", this.onShortcuts);
    document.removeEventListener("ps-open-author", this.onAuthor);
  }

  buildDrawer() {
    const drawer = document.createElement("ps-drawer");
    drawer.setAttribute("edge", "start");
    drawer.setAttribute("heading", "Navigation");
    const nav = document.createElement("ps-nav");
    const footer = element("div", "ps-drawer-footer");
    footer.append(document.createElement("ps-conn-status"));
    this.drawerStatus = footer.firstElementChild;
    this.drawerAuthor = document.createElement("ps-icon-button");
    this.drawerAuthor.setAttribute("icon", "panel-right");
    this.drawerAuthor.setAttribute("label", "Author panel");
    this.drawerAuthor.setAttribute("size", "md");
    this.drawerAuthor.setAttribute("icon-size", "lg");
    this.drawerAuthor.setAttribute("pressed", "false");
    this.drawerAuthor.addEventListener("click", () => {
      this.drawer.close();
      this.toggleAuthor(this.topbar.menuButton);
    });
    footer.append(this.drawerAuthor, document.createElement("ps-theme-switcher"));
    drawer.append(nav, footer);
    return drawer;
  }

  buildShortcuts() {
    const dialog = document.createElement("ps-dialog");
    dialog.id = "shortcuts";
    dialog.setAttribute("heading", "Keyboard shortcuts");
    dialog.setAttribute("size", "md");
    this.shortcutBody = element("div", "ps-shortcuts");
    this.shortcutToggle = document.createElement("ps-toggle");
    this.shortcutToggle.setAttribute("label", "Single-key shortcuts");
    this.shortcutToggle.toggleAttribute("checked", keys.isSingleKeyEnabled());
    this.shortcutToggle.addEventListener("ps-change", (event) => {
      keys.setSingleKeyEnabled(event.detail.checked);
    });
    dialog.append(this.shortcutToggle, this.shortcutBody);
    dialog.addEventListener("keydown", (event) => trapTab(dialog.dialog, event));
    return dialog;
  }

  fillShortcuts() {
    const groups = new Map();
    for (const shortcut of keys.list()) {
      if (!groups.has(shortcut.group)) groups.set(shortcut.group, []);
      groups.get(shortcut.group).push(shortcut);
    }
    const tables = [];
    for (const [group, entries] of groups) {
      const table = document.createElement("table");
      table.className = "ps-shortcut-table";
      const caption = document.createElement("caption");
      caption.textContent = group;
      const head = document.createElement("thead");
      head.className = "visually-hidden";
      const headRow = document.createElement("tr");
      for (const name of ["Shortcut", "Action"]) {
        const th = document.createElement("th");
        th.scope = "col";
        th.textContent = name;
        headRow.append(th);
      }
      head.append(headRow);
      const body = document.createElement("tbody");
      for (const entry of entries) {
        const row = document.createElement("tr");
        const keysCell = document.createElement("th");
        keysCell.scope = "row";
        keysCell.className = "ps-keys";
        keyParts(entry).forEach((part, index) => {
          if (index > 0) keysCell.append(document.createTextNode(entry.mod ? " " : " then "));
          const kbd = document.createElement("ps-kbd");
          kbd.textContent = part;
          keysCell.append(kbd);
        });
        const action = document.createElement("td");
        action.textContent = entry.description;
        row.append(keysCell, action);
        body.append(row);
      }
      table.append(caption, head, body);
      tables.push(table);
    }
    this.shortcutBody.replaceChildren(...tables);
    this.shortcutToggle.toggleAttribute("checked", keys.isSingleKeyEnabled());
  }

  wire() {
    this.queries = [];
    const watch = (text) => {
      const query = window.matchMedia(text);
      const handler = () => {
        this.syncPanelMode();
        if (!window.matchMedia("(max-width: 1023px)").matches) this.drawer.close();
      };
      query.addEventListener("change", handler);
      this.queries.push([query, handler]);
    };
    watch(DOCK_WIDE);
    watch(DOCK_MANAGER);
    watch(SHEET);
    watch("(max-width: 1023px)");
    this.topbar.addEventListener("ps-nav-open", () => {
      this.topbar.setMenuExpanded(true);
      this.syncDrawerStatus();
      this.drawer.show(this.topbar.menuButton);
    });
    this.drawer.addEventListener("ps-close", () => this.topbar.setMenuExpanded(false));
    this.topbar.addEventListener("ps-author-toggle", () => this.toggleAuthor(this.topbar.authorButton.button));
    this.panel.addEventListener("ps-panel-open", () => this.syncPanelState());
    this.panel.addEventListener("ps-panel-close", () => this.syncPanelState());
    this.onRoute = () => {
      this.syncRoute();
      this.drawer.close();
    };
    document.addEventListener("ps-route-change", this.onRoute);
    this.onShortcuts = () => {
      this.fillShortcuts();
      this.shortcuts.show(document.activeElement);
    };
    document.addEventListener("ps-open-shortcuts", this.onShortcuts);
    this.onAuthor = () => {
      if (!this.panel.isOpen()) this.toggleAuthor(document.activeElement);
    };
    document.addEventListener("ps-open-author", this.onAuthor);
    this.unsubscribe = app.subscribe(() => {
      this.syncOffline();
      this.syncPanelState();
    });
    this.releaseGuard = guard(this.view);
  }

  toggleAuthor(opener) {
    this.syncPanelMode();
    this.panel.toggle(opener);
    setPref("author-panel-open", this.panel.isOpen());
    this.syncPanelState();
  }

  restorePanel() {
    if (getPref("author-panel-open", false) && window.matchMedia(DOCK_WIDE).matches) {
      this.panel.setAttribute("mode", "docked");
      this.panel.show(null);
      this.panel.opener = null;
      this.syncPanelState();
    }
  }

  syncRoute() {
    const route = currentRoute();
    if (route) this.setAttribute("data-route", route.name);
    else this.removeAttribute("data-route");
    this.syncPanelMode();
  }

  syncOffline() {
    const offline = Boolean(app.get().offline);
    this.banner.hidden = !offline;
    document.documentElement.toggleAttribute("data-offline", offline);
    this.roBanner.hidden = !readOnly();
  }

  panelMode() {
    if (window.matchMedia(SHEET).matches) return "sheet";
    if (window.matchMedia(DOCK_WIDE).matches) return "docked";
    const route = currentRoute();
    if (route && route.name === "manager" && window.matchMedia(DOCK_MANAGER).matches) return "docked";
    return "overlay";
  }

  syncPanelMode() {
    if (!this.panel) return;
    const mode = this.panelMode();
    if (this.panel.getAttribute("mode") !== mode) this.panel.setAttribute("mode", mode);
    this.setAttribute("data-panel-mode", mode);
  }

  syncPanelState() {
    const open = this.panel.isOpen();
    this.topbar.setAuthorPressed(open);
    this.drawerAuthor.setAttribute("pressed", open ? "true" : "false");
    const blocked = this.topbar.authorButton.hasAttribute("disabled");
    this.drawerAuthor.toggleAttribute("disabled", blocked);
    if (blocked) this.drawerAuthor.setAttribute("reason", this.topbar.authorButton.getAttribute("reason") || "");
    else this.drawerAuthor.removeAttribute("reason");
    this.toggleAttribute("data-panel-open", open);
    this.syncDrawerStatus();
  }

  syncDrawerStatus() {
    const source = this.topbar.status;
    if (!source || !this.drawerStatus) return;
    const state = source.getAttribute("state");
    if (state) this.drawerStatus.setAttribute("state", state);
    const seconds = source.getAttribute("seconds");
    if (seconds) this.drawerStatus.setAttribute("seconds", seconds);
    else this.drawerStatus.removeAttribute("seconds");
  }
}

customElements.define("ps-app-shell", PsAppShell);
