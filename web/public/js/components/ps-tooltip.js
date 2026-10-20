let sequence = 0;

const SHOW_DELAY = 400;
const HIDE_DELAY = 120;

class PsTooltip extends HTMLElement {
  static observedAttributes = ["text", "for"];

  connectedCallback() {
    if (this.bound) return;
    this.bound = true;
    sequence += 1;
    if (!this.id) this.id = `ps-tooltip-${sequence}`;
    this.setAttribute("role", "tooltip");
    this.hidden = true;
    this.showTimer = 0;
    this.hideTimer = 0;
    this.onEnter = () => this.schedule(SHOW_DELAY);
    this.onFocus = () => {
      if (this.attached && this.attached.matches(":focus-visible")) this.schedule(0);
    };
    this.onLeave = () => this.scheduleHide();
    this.onPress = () => this.hide();
    this.onKey = (event) => {
      if (event.key === "Escape" && !this.hidden) this.hide();
    };
    this.addEventListener("pointerenter", () => clearTimeout(this.hideTimer));
    this.addEventListener("pointerleave", () => this.scheduleHide());
    if (this.hasAttribute("text")) this.textContent = this.getAttribute("text");
    this.attach(this.resolveTarget());
  }

  disconnectedCallback() {
    this.detach();
    clearTimeout(this.showTimer);
    clearTimeout(this.hideTimer);
    document.removeEventListener("keydown", this.onKey);
    document.removeEventListener("ps-overlay-open", this.onPress);
    this.bound = false;
  }

  attributeChangedCallback(name, oldValue, value) {
    if (!this.bound) return;
    if (name === "text") this.text = value;
    if (name === "for") this.attach(this.resolveTarget());
  }

  get text() {
    return this.textContent;
  }

  set text(value) {
    this.textContent = value ?? "";
    this.syncDescription();
    if (!this.hidden) this.place();
  }

  get target() {
    return this.attached;
  }

  set target(element) {
    this.explicit = element;
    if (this.bound) this.attach(element);
  }

  resolveTarget() {
    if (this.explicit) return this.explicit;
    const id = this.getAttribute("for");
    if (id) return document.getElementById(id);
    return this.parentElement;
  }

  attach(element) {
    this.detach();
    if (!element) return;
    this.attached = element;
    element.addEventListener("pointerenter", this.onEnter);
    element.addEventListener("pointerleave", this.onLeave);
    element.addEventListener("focus", this.onFocus);
    element.addEventListener("blur", this.onLeave);
    element.addEventListener("click", this.onPress);
    this.syncDescription();
  }

  detach() {
    const element = this.attached;
    if (!element) return;
    element.removeEventListener("pointerenter", this.onEnter);
    element.removeEventListener("pointerleave", this.onLeave);
    element.removeEventListener("focus", this.onFocus);
    element.removeEventListener("blur", this.onLeave);
    element.removeEventListener("click", this.onPress);
    this.attached = null;
  }

  syncDescription() {
    const element = this.attached;
    if (!element) return;
    const ids = (element.getAttribute("aria-describedby") || "").split(/\s+/).filter(Boolean);
    const redundant = this.textContent.trim() === (element.getAttribute("aria-label") || "").trim();
    const next = ids.filter((id) => id !== this.id);
    if (!redundant && this.textContent.trim()) next.push(this.id);
    if (next.length) element.setAttribute("aria-describedby", next.join(" "));
    else element.removeAttribute("aria-describedby");
  }

  schedule(delay) {
    clearTimeout(this.hideTimer);
    clearTimeout(this.showTimer);
    if (!this.textContent.trim()) return;
    this.showTimer = setTimeout(() => this.show(), delay);
  }

  scheduleHide() {
    clearTimeout(this.showTimer);
    clearTimeout(this.hideTimer);
    this.hideTimer = setTimeout(() => this.hide(), HIDE_DELAY);
  }

  show() {
    if (!this.attached || !this.textContent.trim()) return;
    this.hidden = false;
    this.place();
    document.addEventListener("keydown", this.onKey);
    document.addEventListener("ps-overlay-open", this.onPress);
  }

  hide() {
    clearTimeout(this.showTimer);
    clearTimeout(this.hideTimer);
    this.hidden = true;
    document.removeEventListener("keydown", this.onKey);
    document.removeEventListener("ps-overlay-open", this.onPress);
  }

  place() {
    const margin = 8;
    this.style.left = "0px";
    this.style.top = "0px";
    this.style.maxWidth = `${Math.min(320, window.innerWidth - margin * 2)}px`;
    const anchor = this.attached.getBoundingClientRect();
    const own = this.getBoundingClientRect();
    const gap = 6;
    let top = anchor.top - own.height - gap;
    let side = "above";
    if (top < margin) {
      top = anchor.bottom + gap;
      side = "below";
    }
    top = Math.max(margin, Math.min(top, window.innerHeight - own.height - margin));
    let left = anchor.left + anchor.width / 2 - own.width / 2;
    left = Math.max(margin, Math.min(left, window.innerWidth - own.width - margin));
    this.style.left = `${Math.round(left)}px`;
    this.style.top = `${Math.round(top)}px`;
    this.setAttribute("data-side", side);
  }
}

customElements.define("ps-tooltip", PsTooltip);
