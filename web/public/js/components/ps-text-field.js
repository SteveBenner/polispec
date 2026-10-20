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

class PsTextField extends HTMLElement {
  static observedAttributes = [
    "label", "value", "placeholder", "name", "help", "error", "disabled", "readonly",
    "mono", "icon", "clearable", "hide-label", "autocomplete", "reserve", "reason", "maxlength",
  ];

  connectedCallback() {
    if (this.input) return;
    sequence += 1;
    this.fieldId = `ps-tf-${sequence}`;
    this.touched = false;
    this.validator = this.validator || null;
    this.validateTimer = 0;
    this.labelEl = document.createElement("label");
    this.labelEl.className = "ps-label";
    this.labelEl.htmlFor = this.fieldId;
    this.box = document.createElement("div");
    this.box.className = "ps-box";
    this.input = document.createElement("input");
    this.input.type = "text";
    this.input.className = "ps-native";
    this.input.id = this.fieldId;
    this.input.value = this.getAttribute("value") || "";
    this.clearButton = document.createElement("ps-icon-button");
    this.clearButton.setAttribute("icon", "close");
    this.clearButton.setAttribute("size", "xs");
    this.clearButton.setAttribute("data-clear", "");
    this.clearButton.hidden = true;
    this.box.append(this.input, this.clearButton);
    this.message = document.createElement("div");
    this.message.className = "ps-message";
    this.message.id = `${this.fieldId}-message`;
    this.append(this.labelEl, this.box, this.message);
    this.glyph = null;
    this.input.addEventListener("input", () => this.onInput());
    this.input.addEventListener("change", () => {
      this.dispatchEvent(new CustomEvent("ps-change", { bubbles: true, detail: { value: this.value } }));
    });
    this.input.addEventListener("blur", () => {
      this.touched = true;
      clearTimeout(this.validateTimer);
      this.validate();
    });
    this.clearButton.addEventListener("click", () => {
      this.input.value = "";
      this.input.focus();
      this.onInput();
    });
    this.box.addEventListener("pointerdown", (event) => {
      if (event.target === this.box) {
        event.preventDefault();
        this.input.focus();
      }
    });
    this.update();
  }

  disconnectedCallback() {
    clearTimeout(this.validateTimer);
  }

  attributeChangedCallback(name, oldValue, value) {
    if (!this.input) return;
    if (name === "value" && this.input.value !== (value || "")) this.input.value = value || "";
    this.update();
  }

  get value() {
    return this.input ? this.input.value : this.getAttribute("value") || "";
  }

  set value(next) {
    if (!this.input) {
      this.setAttribute("value", next);
      return;
    }
    this.input.value = next;
    this.update();
  }

  focus(options) {
    this.input?.focus(options);
  }

  onInput() {
    this.dispatchEvent(new CustomEvent("ps-input", { bubbles: true, detail: { value: this.value } }));
    if (this.showing && this.validator && !this.validator(this.value)) this.setError("");
    clearTimeout(this.validateTimer);
    this.validateTimer = setTimeout(() => {
      this.touched = true;
      this.validate();
    }, VALIDATE_DELAY);
    this.syncClear();
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

  syncClear() {
    const wanted = this.hasAttribute("clearable") && this.value !== "" && !this.hasAttribute("disabled") && !this.hasAttribute("readonly");
    this.clearButton.hidden = !wanted;
  }

  update() {
    const label = this.getAttribute("label") || "";
    this.labelEl.textContent = label;
    this.labelEl.classList.toggle("visually-hidden", this.hasAttribute("hide-label"));
    this.labelEl.hidden = !label;
    this.clearButton.setAttribute("label", `Clear ${label.toLowerCase() || "field"}`);
    const input = this.input;
    input.placeholder = this.getAttribute("placeholder") || "";
    if (this.hasAttribute("name")) input.name = this.getAttribute("name");
    input.disabled = this.hasAttribute("disabled");
    input.readOnly = this.hasAttribute("readonly");
    input.autocomplete = this.getAttribute("autocomplete") || "off";
    input.spellcheck = false;
    if (this.hasAttribute("maxlength")) input.maxLength = Number(this.getAttribute("maxlength"));
    const iconName = this.getAttribute("icon");
    if (this.glyph && this.glyph.dataset.name !== iconName) {
      this.glyph.remove();
      this.glyph = null;
    }
    if (iconName && !this.glyph) {
      this.glyph = icon(iconName);
      this.glyph.dataset.name = iconName;
      this.box.prepend(this.glyph);
    }
    this.syncClear();
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
    const reserved = Boolean(error || help || this.validator || this.hasAttribute("reserve") || this.hasAttribute("help"));
    this.message.hidden = !reserved;
    if (error) {
      input.setAttribute("aria-invalid", "true");
    } else {
      input.removeAttribute("aria-invalid");
    }
    const extra = (input.getAttribute("data-describedby-extra") || "").split(/\s+/).filter(Boolean);
    const describedby = [...extra];
    if (error || help) describedby.push(this.message.id);
    if (describedby.length) input.setAttribute("aria-describedby", describedby.join(" "));
    else input.removeAttribute("aria-describedby");
    if (this.hasAttribute("mono")) input.classList.add("mono");
    else input.classList.remove("mono");
  }
}

customElements.define("ps-text-field", PsTextField);
