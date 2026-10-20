import { CHOICES, LABELS, getChoice, setChoice } from "../core/theme.js";
import { announce } from "../core/announce.js";

const NS = "http://www.w3.org/2000/svg";
const LONG_PRESS_MS = 500;
let sequence = 0;

function glyph(choice) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "ps-icon ps-icon-lg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#t-${choice}`);
  svg.append(use);
  return svg;
}

function checkIcon() {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "ps-icon ps-check");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", "icons/icons.svg#i-check");
  svg.append(use);
  return svg;
}

function neighbor(choice, step) {
  const index = CHOICES.indexOf(choice);
  return CHOICES[(index + step + CHOICES.length) % CHOICES.length];
}

class PsThemeSwitcher extends HTMLElement {
  connectedCallback() {
    if (this.button) {
      this.bindDocument();
      this.update();
      return;
    }
    sequence += 1;
    this.uid = `ps-theme-switcher-${sequence}`;
    this.button = document.createElement("button");
    this.button.type = "button";
    this.button.className = "ps-native";
    this.button.setAttribute("aria-haspopup", "listbox");
    this.button.setAttribute("aria-expanded", "false");
    this.icon = glyph(getChoice());
    this.button.append(this.icon);
    this.append(this.button);
    this.pressTimer = 0;
    this.suppressClick = false;
    this.listEl = null;
    this.button.addEventListener("click", (event) => {
      if (this.suppressClick) {
        this.suppressClick = false;
        event.preventDefault();
        return;
      }
      this.step(event.shiftKey ? -1 : 1);
    });
    this.button.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && event.shiftKey) {
        event.preventDefault();
        this.openList();
      }
    });
    this.button.addEventListener("contextmenu", (event) => {
      event.preventDefault();
      this.openList();
    });
    this.button.addEventListener("pointerdown", (event) => {
      if (event.button !== 0) return;
      clearTimeout(this.pressTimer);
      this.pressTimer = setTimeout(() => {
        this.suppressClick = true;
        this.openList();
      }, LONG_PRESS_MS);
    });
    for (const name of ["pointerup", "pointerleave", "pointercancel"]) {
      this.button.addEventListener(name, () => clearTimeout(this.pressTimer));
    }
    this.onChange = () => this.update();
    this.onOutside = (event) => {
      if (this.listEl && !this.listEl.contains(event.target) && !this.button.contains(event.target)) this.closeList(false);
    };
    this.bindDocument();
    this.update();
  }

  disconnectedCallback() {
    clearTimeout(this.pressTimer);
    document.removeEventListener("ps-theme-change", this.onChange);
    this.closeList(false);
  }

  bindDocument() {
    document.removeEventListener("ps-theme-change", this.onChange);
    document.addEventListener("ps-theme-change", this.onChange);
  }

  step(direction) {
    const choice = setChoice(neighbor(getChoice(), direction));
    announce(`Theme: ${LABELS[choice]}`);
  }

  update() {
    const current = getChoice();
    const next = neighbor(current, 1);
    const previous = neighbor(current, -1);
    this.icon.firstElementChild.setAttribute("href", `icons/icons.svg#t-${current}`);
    this.button.setAttribute(
      "aria-label",
      `Theme: ${LABELS[current]}. Activate for ${LABELS[next]}. Shift and activate for ${LABELS[previous]}.`
    );
    this.button.title = `Theme: ${LABELS[current]}. Next: ${LABELS[next]}`;
    if (this.listEl) {
      for (const option of this.listEl.querySelectorAll("[role=option]")) {
        option.setAttribute("aria-selected", option.dataset.choice === current ? "true" : "false");
      }
    }
  }

  openList() {
    if (this.listEl) return;
    const current = getChoice();
    this.listEl = document.createElement("div");
    this.listEl.className = "ps-popover";
    this.listEl.setAttribute("role", "listbox");
    this.listEl.id = `${this.uid}-list`;
    this.listEl.setAttribute("aria-label", "Theme");
    for (const choice of CHOICES) {
      const option = document.createElement("div");
      option.className = "ps-option";
      option.setAttribute("role", "option");
      option.dataset.choice = choice;
      option.tabIndex = -1;
      option.setAttribute("aria-selected", choice === current ? "true" : "false");
      const label = document.createElement("span");
      label.className = "ps-label";
      label.textContent = LABELS[choice];
      option.append(glyph(choice), label, checkIcon());
      option.addEventListener("click", () => this.pick(choice));
      option.addEventListener("pointermove", () => option.focus({ preventScroll: true }));
      this.listEl.append(option);
    }
    this.listEl.addEventListener("keydown", (event) => this.onListKey(event));
    this.append(this.listEl);
    this.button.setAttribute("aria-expanded", "true");
    this.button.setAttribute("aria-controls", this.listEl.id);
    this.place();
    document.addEventListener("pointerdown", this.onOutside, true);
    this.listEl.querySelector("[aria-selected=true]").focus();
  }

  place() {
    const anchor = this.button.getBoundingClientRect();
    const own = this.listEl.getBoundingClientRect();
    const margin = 8;
    let left = anchor.right - own.width;
    left = Math.max(margin, Math.min(left, window.innerWidth - own.width - margin));
    let top = anchor.bottom + 4;
    if (top + own.height > window.innerHeight - margin) top = Math.max(margin, anchor.top - own.height - 4);
    this.listEl.style.left = `${Math.round(left)}px`;
    this.listEl.style.top = `${Math.round(top)}px`;
  }

  onListKey(event) {
    const options = [...this.listEl.querySelectorAll("[role=option]")];
    const index = options.indexOf(document.activeElement);
    if (event.key === "ArrowDown") {
      event.preventDefault();
      options[(index + 1) % options.length].focus();
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      options[(index - 1 + options.length) % options.length].focus();
    } else if (event.key === "Home") {
      event.preventDefault();
      options[0].focus();
    } else if (event.key === "End") {
      event.preventDefault();
      options[options.length - 1].focus();
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      if (index >= 0) this.pick(options[index].dataset.choice);
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      this.closeList(true);
    } else if (event.key === "Tab") {
      this.closeList(false);
    }
  }

  pick(choice) {
    setChoice(choice);
    announce(`Theme: ${LABELS[choice]}`);
    this.closeList(true);
  }

  closeList(restoreFocus) {
    if (!this.listEl) return;
    this.listEl.remove();
    this.listEl = null;
    document.removeEventListener("pointerdown", this.onOutside, true);
    this.button.setAttribute("aria-expanded", "false");
    this.button.removeAttribute("aria-controls");
    if (restoreFocus) this.button.focus();
  }
}

customElements.define("ps-theme-switcher", PsThemeSwitcher);
