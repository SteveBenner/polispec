import { app, readOnly, READ_ONLY_REASON } from "../core/store.js";

const NS = "http://www.w3.org/2000/svg";

function icon(name) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "ps-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

let sequence = 0;

class PsButton extends HTMLElement {
  static observedAttributes = ["icon", "label", "disabled", "busy", "busy-label", "reason", "type", "write"];

  connectedCallback() {
    if (this.button) {
      this.watch();
      this.update();
      return;
    }
    if (this.visibleText === undefined) this.visibleText = this.textContent.trim();
    sequence += 1;
    this.textContent = "";
    this.button = document.createElement("button");
    this.button.type = this.getAttribute("type") || "button";
    this.button.className = "ps-native";
    this.button.id = `ps-button-${sequence}`;
    this.glyph = null;
    this.textNode = document.createElement("span");
    this.textNode.className = "ps-text";
    this.button.append(this.textNode);
    this.tooltip = document.createElement("ps-tooltip");
    this.tooltip.setAttribute("for", this.button.id);
    this.append(this.button, this.tooltip);
    this.busyStart = 0;
    this.busyTimer = 0;
    this.addEventListener(
      "click",
      (event) => {
        if (this.blocked()) {
          event.preventDefault();
          event.stopImmediatePropagation();
        }
      },
      true,
    );
    this.watch();
    this.update();
  }

  watch() {
    if (this.unsubscribe) return;
    this.unsubscribe = app.subscribe(() => {
      if (this.hasAttribute("write")) this.update();
    });
  }

  disconnectedCallback() {
    clearInterval(this.busyTimer);
    this.busyTimer = 0;
    if (this.unsubscribe) this.unsubscribe();
    this.unsubscribe = null;
  }

  attributeChangedCallback(name) {
    if (!this.button) return;
    if (name === "busy") this.syncBusyTimer();
    this.update();
  }

  get text() {
    return this.visibleText;
  }

  set text(value) {
    this.visibleText = value;
    if (this.button) this.update();
  }

  focus(options) {
    this.button?.focus(options);
  }

  blocked() {
    return this.hasAttribute("disabled") || this.hasAttribute("busy") || this.locked();
  }

  locked() {
    return this.hasAttribute("write") && readOnly();
  }

  syncBusyTimer() {
    clearInterval(this.busyTimer);
    this.busyTimer = 0;
    if (!this.hasAttribute("busy")) return;
    this.busyStart = Date.now();
    this.busyTimer = setInterval(() => this.update(), 1000);
  }

  update() {
    const busy = this.hasAttribute("busy");
    if (busy && !this.busyTimer) this.syncBusyTimer();
    const locked = this.locked();
    const disabled = this.hasAttribute("disabled") || locked;
    const label = this.getAttribute("label");
    let text = this.visibleText;
    if (busy) {
      text = this.getAttribute("busy-label") || text;
      const seconds = Math.floor((Date.now() - this.busyStart) / 1000);
      if (seconds >= 2) text = `${text}, ${seconds} s`;
    }
    this.textNode.textContent = text;
    this.textNode.hidden = !text;
    const iconName = busy ? "hourglass" : this.getAttribute("icon");
    if (this.glyph && this.glyph.dataset.name !== iconName) {
      this.glyph.remove();
      this.glyph = null;
    }
    if (iconName && !this.glyph) {
      this.glyph = icon(iconName);
      this.glyph.dataset.name = iconName;
      this.button.prepend(this.glyph);
    }
    if (!text && label) this.button.setAttribute("aria-label", label);
    else this.button.removeAttribute("aria-label");
    this.button.toggleAttribute("data-icon-only", !text);
    if (disabled || busy) this.button.setAttribute("aria-disabled", "true");
    else this.button.removeAttribute("aria-disabled");
    if (busy) this.button.setAttribute("aria-busy", "true");
    else this.button.removeAttribute("aria-busy");
    const reason = locked ? READ_ONLY_REASON : this.getAttribute("reason");
    const tip = disabled && reason ? reason : !text && label ? label : "";
    if (tip) this.tooltip.setAttribute("text", tip);
    else this.tooltip.removeAttribute("text");
  }
}

customElements.define("ps-button", PsButton);
