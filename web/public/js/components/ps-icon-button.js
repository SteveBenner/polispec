const NS = "http://www.w3.org/2000/svg";

function icon(name, large) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", large ? "ps-icon ps-icon-lg" : "ps-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

let sequence = 0;

class PsIconButton extends HTMLElement {
  static observedAttributes = ["icon", "label", "pressed", "disabled", "icon-size", "reason", "expanded", "controls"];

  connectedCallback() {
    if (this.button) return;
    this.textContent = "";
    this.button = document.createElement("button");
    this.button.type = "button";
    sequence += 1;
    this.button.className = "ps-native";
    this.button.id = `ps-icon-button-${sequence}`;
    this.tooltip = document.createElement("ps-tooltip");
    this.tooltip.setAttribute("for", this.button.id);
    this.append(this.button, this.tooltip);
    this.glyph = null;
    this.addEventListener(
      "click",
      (event) => {
        if (this.hasAttribute("disabled")) {
          event.preventDefault();
          event.stopImmediatePropagation();
        }
      },
      true,
    );
    this.update();
  }

  attributeChangedCallback() {
    if (this.button) this.update();
  }

  focus(options) {
    this.button?.focus(options);
  }

  update() {
    const name = this.getAttribute("icon");
    const large = this.getAttribute("icon-size") === "lg";
    const key = `${name}:${large}`;
    if (this.glyph && this.glyph.dataset.key !== key) {
      this.glyph.remove();
      this.glyph = null;
    }
    if (name && !this.glyph) {
      this.glyph = icon(name, large);
      this.glyph.dataset.key = key;
      this.button.append(this.glyph);
    }
    const label = this.getAttribute("label") || "";
    this.button.setAttribute("aria-label", label);
    const disabled = this.hasAttribute("disabled");
    if (disabled) this.button.setAttribute("aria-disabled", "true");
    else this.button.removeAttribute("aria-disabled");
    if (this.hasAttribute("pressed")) {
      this.button.setAttribute("aria-pressed", this.getAttribute("pressed") === "false" ? "false" : "true");
    } else {
      this.button.removeAttribute("aria-pressed");
    }
    if (this.hasAttribute("expanded")) this.button.setAttribute("aria-expanded", this.getAttribute("expanded") === "false" ? "false" : "true");
    else this.button.removeAttribute("aria-expanded");
    if (this.hasAttribute("controls")) this.button.setAttribute("aria-controls", this.getAttribute("controls"));
    else this.button.removeAttribute("aria-controls");
    const reason = this.getAttribute("reason");
    this.tooltip.setAttribute("text", disabled && reason ? `${label}. ${reason}` : label);
  }
}

customElements.define("ps-icon-button", PsIconButton);
