class PsSegmented extends HTMLElement {
  static observedAttributes = ["value", "label", "disabled"];

  connectedCallback() {
    if (this.group) return;
    this.items = this.items || this.readOptionsAttribute();
    this.current = this.getAttribute("value") ?? this.items[0]?.value ?? null;
    this.setAttribute("role", "radiogroup");
    this.addEventListener("keydown", (event) => this.onKey(event));
    this.addEventListener("click", (event) => {
      const segment = event.target.closest("[role=radio]");
      if (segment && !this.hasAttribute("disabled")) this.select(segment.dataset.value, true);
    });
    this.group = true;
    this.render();
  }

  attributeChangedCallback(name, oldValue, value) {
    if (!this.group) return;
    if (name === "value") this.current = value;
    this.render();
  }

  readOptionsAttribute() {
    const raw = this.getAttribute("options");
    if (!raw) return [];
    try {
      return JSON.parse(raw);
    } catch (error) {
      return [];
    }
  }

  get options() {
    return this.items;
  }

  set options(list) {
    this.items = list;
    if (this.group) this.render();
  }

  get value() {
    return this.current;
  }

  set value(next) {
    this.current = next;
    if (this.group) this.render();
  }

  render() {
    this.setAttribute("aria-label", this.getAttribute("label") || "");
    if (this.hasAttribute("disabled")) this.setAttribute("aria-disabled", "true");
    else this.removeAttribute("aria-disabled");
    this.textContent = "";
    const has = this.items.some((item) => item.value === this.current);
    this.items.forEach((item, index) => {
      const segment = document.createElement("button");
      segment.type = "button";
      segment.className = "ps-native";
      segment.setAttribute("role", "radio");
      segment.dataset.value = item.value;
      const selected = item.value === this.current;
      segment.setAttribute("aria-checked", selected ? "true" : "false");
      segment.tabIndex = selected || (!has && index === 0) ? 0 : -1;
      segment.textContent = item.label;
      this.append(segment);
    });
  }

  select(value, focus) {
    const changed = value !== this.current;
    this.current = value;
    this.render();
    if (focus) this.querySelector("[aria-checked=true]")?.focus();
    if (changed) this.dispatchEvent(new CustomEvent("ps-change", { bubbles: true, detail: { value } }));
  }

  onKey(event) {
    if (this.hasAttribute("disabled")) return;
    const segments = [...this.querySelectorAll("[role=radio]")];
    const index = segments.indexOf(document.activeElement);
    if (index < 0) return;
    let next = -1;
    if (event.key === "ArrowRight" || event.key === "ArrowDown") next = (index + 1) % segments.length;
    else if (event.key === "ArrowLeft" || event.key === "ArrowUp") next = (index - 1 + segments.length) % segments.length;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = segments.length - 1;
    if (next < 0) return;
    event.preventDefault();
    this.select(segments[next].dataset.value, true);
  }

  focus(options) {
    this.querySelector("[tabindex='0']")?.focus(options);
  }
}

customElements.define("ps-segmented", PsSegmented);
