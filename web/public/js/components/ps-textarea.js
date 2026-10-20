const NS = "http://www.w3.org/2000/svg";
const VALIDATE_DELAY = 600;
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

class PsTextarea extends HTMLElement {
  static observedAttributes = [
    "label", "value", "placeholder", "name", "help", "error", "disabled", "readonly",
    "mono", "hide-label", "reserve", "reason", "submit",
  ];

  connectedCallback() {
    if (this.area) return;
    sequence += 1;
    this.fieldId = `ps-ta-${sequence}`;
    this.touched = false;
    this.validator = this.validator || null;
    this.validateTimer = 0;
    this.nativeGrow = typeof CSS !== "undefined" && CSS.supports("field-sizing", "content");
    this.labelEl = document.createElement("label");
    this.labelEl.className = "ps-label";
    this.labelEl.htmlFor = this.fieldId;
    this.box = document.createElement("div");
    this.box.className = "ps-box";
    this.area = document.createElement("textarea");
    this.area.className = "ps-native";
    this.area.id = this.fieldId;
    this.area.rows = 2;
    this.area.value = this.getAttribute("value") || "";
    this.box.append(this.area);
    this.message = document.createElement("div");
    this.message.className = "ps-message";
    this.message.id = `${this.fieldId}-message`;
    this.append(this.labelEl, this.box, this.message);
    this.area.addEventListener("input", () => {
      this.grow();
      this.dispatchEvent(new CustomEvent("ps-input", { bubbles: true, detail: { value: this.value } }));
      if (this.showing && this.validator && !this.validator(this.value)) this.setError("");
      clearTimeout(this.validateTimer);
      this.validateTimer = setTimeout(() => {
        this.touched = true;
        this.validate();
      }, VALIDATE_DELAY);
    });
    this.area.addEventListener("change", () => {
      this.dispatchEvent(new CustomEvent("ps-change", { bubbles: true, detail: { value: this.value } }));
    });
    this.area.addEventListener("blur", () => {
      this.touched = true;
      clearTimeout(this.validateTimer);
      this.validate();
    });
    this.area.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && (event.metaKey || event.ctrlKey) && this.hasAttribute("submit")) {
        event.preventDefault();
        this.dispatchEvent(new CustomEvent("ps-submit", { bubbles: true, detail: { value: this.value } }));
      }
    });
    this.box.addEventListener("pointerdown", (event) => {
      if (event.target === this.box) {
        event.preventDefault();
        this.area.focus();
      }
    });
    this.update();
    this.grow();
  }

  disconnectedCallback() {
    clearTimeout(this.validateTimer);
  }

  attributeChangedCallback(name, oldValue, value) {
    if (!this.area) return;
    if (name === "value" && this.area.value !== (value || "")) {
      this.area.value = value || "";
      this.grow();
    }
    this.update();
  }

  get value() {
    return this.area ? this.area.value : this.getAttribute("value") || "";
  }

  set value(next) {
    if (!this.area) {
      this.setAttribute("value", next);
      return;
    }
    this.area.value = next;
    this.grow();
    this.update();
  }

  focus(options) {
    this.area?.focus(options);
  }

  grow() {
    if (this.nativeGrow) return;
    const area = this.area;
    area.style.height = "auto";
    const line = parseFloat(getComputedStyle(area).lineHeight) || 18;
    const max = line * 8;
    const min = line * 2;
    area.style.height = `${Math.min(Math.max(area.scrollHeight, min), max)}px`;
  }

  validate() {
    if (!this.touched || !this.validator) return true;
    const result = this.validator(this.value);
    this.setError(result || "");
    return !result;
  }

  setError(text) {
    this.showing = text;
    this.update();
  }

  update() {
    const label = this.getAttribute("label") || "";
    this.labelEl.textContent = label;
    this.labelEl.classList.toggle("visually-hidden", this.hasAttribute("hide-label"));
    this.labelEl.hidden = !label;
    const area = this.area;
    area.placeholder = this.getAttribute("placeholder") || "";
    if (this.hasAttribute("name")) area.name = this.getAttribute("name");
    area.disabled = this.hasAttribute("disabled");
    area.readOnly = this.hasAttribute("readonly");
    area.spellcheck = false;
    const error = this.getAttribute("error") || this.showing || "";
    const help = this.hasAttribute("disabled") && this.getAttribute("reason") ? this.getAttribute("reason") : this.getAttribute("help") || "";
    this.message.textContent = "";
    if (error) {
      this.message.append(icon("deny"));
      const span = document.createElement("span");
      span.textContent = error;
      this.message.append(span);
      this.message.setAttribute("data-kind", "error");
    } else {
      this.message.textContent = help;
      this.message.removeAttribute("data-kind");
    }
    this.message.hidden = !(error || help || this.validator || this.hasAttribute("reserve"));
    if (error) area.setAttribute("aria-invalid", "true");
    else area.removeAttribute("aria-invalid");
    if (error || help) area.setAttribute("aria-describedby", this.message.id);
    else area.removeAttribute("aria-describedby");
    area.classList.toggle("mono", this.hasAttribute("mono"));
  }
}

customElements.define("ps-textarea", PsTextarea);
