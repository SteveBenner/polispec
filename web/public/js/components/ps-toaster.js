import "./ps-icon-button.js";
import "./ps-button.js";
import { announce } from "../core/announce.js";

const NS = "http://www.w3.org/2000/svg";
const VISIBLE = 3;
const AUTO_DISMISS_MS = 5000;
const LEAVE_MS = 190;
const ICONS = { success: "allow", info: "info", error: "error", warn: "warn" };
let sequence = 0;

function icon(name) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "ps-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

class PsToaster extends HTMLElement {
  connectedCallback() {
    if (this.list) return;
    this.items = [];
    this.list = document.createElement("div");
    this.list.className = "ps-stack";
    this.more = document.createElement("div");
    this.more.className = "ps-more";
    this.more.hidden = true;
    this.list.append(this.more);
    this.append(this.list);
    this.onToast = (event) => this.add(event.detail || {});
    this.onCopied = (event) => {
      const detail = event.detail || {};
      this.add({ kind: "success", title: detail.message || "Copied" });
      if (!event.target.closest || !event.target.closest("ps-command")) announce(detail.message || "Copied");
    };
    this.onCopyFailed = (event) => {
      const detail = event.detail || {};
      this.add({ kind: "info", title: detail.message || "Select and copy the value." });
    };
    document.addEventListener("ps-toast", this.onToast);
    document.addEventListener("ps-copied", this.onCopied);
    document.addEventListener("ps-copy-failed", this.onCopyFailed);
  }

  disconnectedCallback() {
    document.removeEventListener("ps-toast", this.onToast);
    document.removeEventListener("ps-copied", this.onCopied);
    document.removeEventListener("ps-copy-failed", this.onCopyFailed);
    for (const item of this.items || []) clearTimeout(item.timer);
  }

  add(detail) {
    const kind = ICONS[detail.kind] ? detail.kind : "info";
    const title = detail.title || detail.text || "";
    const body = detail.title ? detail.text || "" : "";
    if (!title) return null;
    sequence += 1;
    const element = document.createElement("div");
    element.className = "ps-toast";
    element.dataset.kind = kind;
    element.id = `ps-toast-${sequence}`;
    element.tabIndex = 0;
    const lead = document.createElement("span");
    lead.className = "ps-lead";
    lead.append(icon(ICONS[kind]));
    const text = document.createElement("div");
    text.className = "ps-text";
    const heading = document.createElement("div");
    heading.className = "ps-title";
    heading.textContent = title;
    text.append(heading);
    if (body) {
      const line = document.createElement("div");
      line.className = "ps-body";
      line.textContent = body;
      text.append(line);
    }
    const item = { element, kind, timer: 0, action: detail.action || null };
    if (item.action && item.action.label) {
      const button = document.createElement("ps-button");
      button.setAttribute("variant", "ghost");
      button.setAttribute("size", "xs");
      button.text = item.action.label;
      button.addEventListener("click", () => this.run(item));
      text.append(button);
    }
    const dismiss = document.createElement("ps-icon-button");
    dismiss.setAttribute("icon", "close");
    dismiss.setAttribute("label", "Dismiss");
    dismiss.setAttribute("size", "xs");
    dismiss.addEventListener("click", () => this.remove(item));
    element.append(lead, text, dismiss);
    element.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && event.target === element && item.action) {
        event.preventDefault();
        this.run(item);
      } else if (event.key === "Escape") {
        event.preventDefault();
        this.remove(item);
      }
    });
    for (const name of ["pointerenter", "focusin"]) element.addEventListener(name, () => this.pause(item));
    for (const name of ["pointerleave", "focusout"]) {
      element.addEventListener(name, () => {
        if (!element.matches(":hover") && !element.contains(document.activeElement)) this.arm(item);
      });
    }
    this.items.push(item);
    this.list.append(element);
    this.arm(item);
    this.layout();
    return item;
  }

  run(item) {
    const action = item.action;
    const handler = action && (action.run || action.handler);
    this.remove(item);
    if (typeof handler === "function") handler();
  }

  arm(item) {
    clearTimeout(item.timer);
    if (item.kind === "error") return;
    item.timer = setTimeout(() => this.remove(item), AUTO_DISMISS_MS);
  }

  pause(item) {
    clearTimeout(item.timer);
  }

  remove(item) {
    const index = this.items.indexOf(item);
    if (index === -1) return;
    clearTimeout(item.timer);
    this.items.splice(index, 1);
    const hadFocus = item.element.contains(document.activeElement);
    item.element.dataset.leaving = "";
    setTimeout(() => item.element.remove(), LEAVE_MS);
    this.layout();
    if (hadFocus) {
      const last = this.items[this.items.length - 1];
      if (last) last.element.focus();
    }
  }

  layout() {
    const hidden = Math.max(0, this.items.length - VISIBLE);
    this.items.forEach((item, index) => {
      item.element.hidden = index < hidden;
    });
    this.more.hidden = hidden === 0;
    this.more.textContent = hidden ? `and ${hidden} more` : "";
  }
}

customElements.define("ps-toaster", PsToaster);
