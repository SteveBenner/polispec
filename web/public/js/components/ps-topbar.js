import "./ps-icon-button.js";
import "./ps-button.js";
import "./ps-digest.js";
import "./ps-kbd.js";
import "./ps-conn-status.js";
import "./ps-theme-switcher.js";
import { app, flag } from "../core/store.js";
import { getPref, setPref } from "../core/cache.js";
import { getState as feedState, status as feedStatus } from "../core/sse.js";
import { relTime } from "../core/format.js";

const FEED_STATES = {
  live: "live",
  connecting: "reconnecting",
  reconnecting: "reconnecting",
  paused: "paused",
  disabled: "off",
  closed: "offline",
};

function element(tag, className, attributes = {}) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, value);
  return node;
}

class PsTopbar extends HTMLElement {
  connectedCallback() {
    if (this.left) {
      this.bind();
      this.sync();
      return;
    }
    this.left = element("div", "ps-left");
    this.center = element("div", "ps-center");
    this.right = element("div", "ps-right");

    this.menuButton = element("ps-icon-button", "ps-menu", {
      icon: "menu",
      label: "Open navigation",
      size: "md",
      "icon-size": "lg",
      expanded: "false",
    });
    this.menuButton.addEventListener("click", () => {
      this.dispatchEvent(new CustomEvent("ps-nav-open", { bubbles: true }));
    });

    this.wordmark = element("a", "ps-wordmark", { href: "#/map" });
    this.wordmark.textContent = "polispec";

    this.epoch = element("span", "ps-epoch");
    const epochLabel = element("span", "ps-epoch-label text-2xs");
    epochLabel.textContent = "epoch";
    this.epochDigest = element("ps-digest", "", { kind: "epoch", value: "", length: "8" });
    this.epoch.append(epochLabel, this.epochDigest);
    this.epoch.hidden = true;

    this.left.append(this.menuButton, this.wordmark, this.epoch);

    this.centerWordmark = element("a", "ps-wordmark ps-wordmark-center", { href: "#/map" });
    this.centerWordmark.textContent = "polispec";

    this.trigger = element("ps-button", "ps-trigger", {
      variant: "field",
      size: "md",
      icon: "search",
    });
    this.trigger.text = "Search or run a command";
    this.hint = element("ps-kbd", "ps-hint");
    this.hint.textContent = "Mod K";
    this.trigger.addEventListener("click", () => this.openPalette());

    this.center.append(this.centerWordmark, this.trigger);

    this.searchButton = element("ps-icon-button", "ps-search", {
      icon: "search",
      label: "Search or run a command",
      size: "md",
      "icon-size": "lg",
    });
    this.searchButton.addEventListener("click", () => this.openPalette());

    this.status = element("ps-conn-status", "ps-status", { state: "offline" });

    this.authorButton = element("ps-icon-button", "ps-author", {
      icon: "panel-right",
      label: "Author panel",
      size: "md",
      "icon-size": "lg",
      pressed: "false",
    });
    this.authorButton.addEventListener("click", () => {
      this.dispatchEvent(new CustomEvent("ps-author-toggle", { bubbles: true }));
    });

    this.switcher = element("ps-theme-switcher", "ps-theme");

    this.right.append(this.status, this.authorButton, this.searchButton, this.switcher);
    this.append(this.left, this.center, this.right);

    this.hint.setAttribute("aria-hidden", "true");
    this.trigger.button.append(this.hint);
    this.trigger.button.setAttribute("aria-keyshortcuts", "Control+K Meta+K");

    this.bind();
    this.sync();
  }

  disconnectedCallback() {
    if (this.unsubscribe) this.unsubscribe();
    this.unsubscribe = null;
    clearInterval(this.poll);
  }

  bind() {
    if (this.unsubscribe) this.unsubscribe();
    this.unsubscribe = app.subscribe(() => this.sync());
    clearInterval(this.poll);
    this.poll = setInterval(() => this.syncFeed(), 1000);
  }

  openPalette() {
    document.dispatchEvent(new CustomEvent("ps-open-palette", { detail: { opener: this.trigger } }));
  }

  setAuthorPressed(pressed) {
    this.authorButton.setAttribute("pressed", pressed ? "true" : "false");
  }

  setMenuExpanded(expanded) {
    this.menuButton.setAttribute("expanded", expanded ? "true" : "false");
  }

  sync() {
    const config = app.get().config;
    const epoch = config && config.epoch ? String(config.epoch) : "";
    this.epoch.hidden = !epoch;
    if (epoch && this.epochDigest.getAttribute("value") !== epoch) {
      this.epochDigest.setAttribute("value", epoch);
      const seen = getPref("epoch-seen", null);
      let changed = seen && seen.value === epoch ? seen.at : null;
      if (!changed) {
        changed = Date.now();
        setPref("epoch-seen", { value: epoch, at: changed });
      }
      const when = relTime(changed);
      this.epochDigest.tooltip.setAttribute("text", `${epoch}. Changed ${when.text}`);
    }
    const author = flag("author");
    if (author.enabled) {
      this.authorButton.removeAttribute("disabled");
      this.authorButton.removeAttribute("reason");
    } else {
      this.authorButton.setAttribute("disabled", "");
      this.authorButton.setAttribute("reason", author.reason || "Author panel is turned off");
    }
    this.syncFeed();
  }

  syncFeed() {
    const state = app.get();
    let key = FEED_STATES[feedState()] || "offline";
    if (state.offline || state.session !== "active") key = "offline";
    if (this.status.getAttribute("state") !== key) this.status.setAttribute("state", key);
    if (key === "reconnecting") {
      const delay = feedStatus().nextDelay;
      if (delay) this.status.setAttribute("seconds", String(Math.ceil(delay / 1000)));
      else this.status.removeAttribute("seconds");
    } else {
      this.status.removeAttribute("seconds");
    }
  }
}

customElements.define("ps-topbar", PsTopbar);
