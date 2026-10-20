import "./ps-icon-button.js";
import "./ps-state.js";
import { flag } from "../core/store.js";

const FOCUSABLE = 'a[href], button:not([disabled]):not([aria-disabled="true"]), input, textarea, [tabindex]:not([tabindex="-1"])';
let sequence = 0;

export function trapTab(container, event) {
  if (event.key !== "Tab") return;
  const nodes = [...container.querySelectorAll(FOCUSABLE)].filter((node) => node.getClientRects().length);
  if (!nodes.length) {
    event.preventDefault();
    return;
  }
  const first = nodes[0];
  const last = nodes[nodes.length - 1];
  const active = document.activeElement;
  if (event.shiftKey && (active === first || !container.contains(active))) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && (active === last || !container.contains(active))) {
    event.preventDefault();
    first.focus();
  }
}

class PsSidePanel extends HTMLElement {
  static observedAttributes = ["heading", "mode"];

  connectedCallback() {
    if (this.sheet) return;
    sequence += 1;
    this.uid = `ps-side-panel-${sequence}`;
    this.hidden = true;
    const content = [...this.childNodes];
    this.scrim = document.createElement("div");
    this.scrim.className = "ps-scrim";
    this.sheet = document.createElement("div");
    this.sheet.className = "ps-sheet";
    this.sheet.setAttribute("role", "complementary");
    this.sheet.setAttribute("aria-labelledby", `${this.uid}-title`);
    const header = document.createElement("header");
    header.className = "ps-header";
    this.titleEl = document.createElement("h2");
    this.titleEl.id = `${this.uid}-title`;
    this.closeButton = document.createElement("ps-icon-button");
    this.closeButton.setAttribute("icon", "close");
    this.closeButton.setAttribute("label", "Close panel");
    this.closeButton.setAttribute("size", "sm");
    header.append(this.titleEl, this.closeButton);
    this.body = document.createElement("div");
    this.body.className = "ps-body";
    for (const node of content) this.body.append(node);
    this.sheet.append(header, this.body);
    this.append(this.scrim, this.sheet);
    this.closeButton.addEventListener("click", () => this.close());
    this.scrim.addEventListener("click", () => this.close());
    this.addEventListener("keydown", (event) => this.onKey(event));
    this.update();
  }

  attributeChangedCallback() {
    if (this.sheet) this.update();
  }

  update() {
    this.titleEl.textContent = this.getAttribute("heading") || "";
    const overlay = this.isOverlay();
    if (overlay && this.isOpen()) this.sheet.setAttribute("aria-modal", "true");
    else this.sheet.removeAttribute("aria-modal");
  }

  isOverlay() {
    const mode = this.getAttribute("mode");
    return mode === "overlay" || mode === "sheet";
  }

  isOpen() {
    return this.hasAttribute("open");
  }

  show(opener) {
    if (this.isOpen()) return;
    this.opener = opener || document.activeElement;
    this.setAttribute("open", "");
    this.hidden = false;
    this.update();
    this.fillDefault();
    this.closeButton.focus();
    this.dispatchEvent(new CustomEvent("ps-panel-open", { bubbles: true }));
  }

  close() {
    if (!this.isOpen()) return;
    this.removeAttribute("open");
    this.hidden = true;
    this.update();
    const opener = this.opener;
    this.opener = null;
    if (opener && opener.isConnected) opener.focus();
    this.dispatchEvent(new CustomEvent("ps-panel-close", { bubbles: true }));
  }

  toggle(opener) {
    if (this.isOpen()) this.close();
    else this.show(opener);
  }

  fillDefault() {
    const author = flag("author");
    const defined = window.customElements.get("ps-author-panel");
    const existing = this.body.querySelector("[data-panel-default]");
    if (!author.enabled) {
      this.body.replaceChildren(this.disabledState(author.reason));
      return;
    }
    if (defined && !this.body.querySelector("ps-author-panel")) {
      this.body.replaceChildren(document.createElement("ps-author-panel"));
      return;
    }
    if (!defined && !existing && !this.body.childElementCount) {
      this.body.replaceChildren(this.emptyState());
    }
  }

  disabledState(reason) {
    const state = document.createElement("ps-state");
    state.setAttribute("kind", "disabled");
    state.setAttribute("feature", "Author panel");
    state.setAttribute("body", reason || "Authoring is turned off on this host.");
    state.dataset.panelDefault = "";
    return state;
  }

  emptyState() {
    const state = document.createElement("ps-state");
    state.setAttribute("kind", "empty_first_run");
    state.setAttribute("heading", "Nothing to show here yet");
    state.setAttribute("body", "The author panel opens in this space.");
    state.dataset.panelDefault = "";
    return state;
  }

  onKey(event) {
    if (!this.isOpen()) return;
    if (event.key === "Escape" && this.isOverlay()) {
      event.preventDefault();
      event.stopPropagation();
      this.close();
      return;
    }
    if (this.isOverlay()) trapTab(this.sheet, event);
  }
}

customElements.define("ps-side-panel", PsSidePanel);
