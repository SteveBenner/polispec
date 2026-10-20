class PsToggle extends HTMLElement {
  static observedAttributes = ["checked", "disabled", "label", "reason"];

  connectedCallback() {
    if (this.button) return;
    this.visibleText = this.getAttribute("label") ?? this.textContent.trim();
    this.textContent = "";
    this.button = document.createElement("button");
    this.button.type = "button";
    this.button.className = "ps-native";
    this.button.setAttribute("role", "switch");
    this.track = document.createElement("span");
    this.track.className = "ps-track";
    this.track.setAttribute("aria-hidden", "true");
    const thumb = document.createElement("span");
    thumb.className = "ps-thumb";
    this.track.append(thumb);
    this.textNode = document.createElement("span");
    this.textNode.className = "ps-text";
    this.button.append(this.track, this.textNode);
    this.append(this.button);
    this.button.addEventListener("click", () => {
      if (this.hasAttribute("disabled")) return;
      this.checked = !this.checked;
      this.dispatchEvent(new CustomEvent("ps-change", { bubbles: true, detail: { checked: this.checked } }));
    });
    this.update();
  }

  attributeChangedCallback() {
    if (this.button) this.update();
  }

  get checked() {
    return this.hasAttribute("checked");
  }

  set checked(value) {
    this.toggleAttribute("checked", Boolean(value));
  }

  focus(options) {
    this.button?.focus(options);
  }

  update() {
    this.textNode.textContent = this.hasAttribute("label") ? this.getAttribute("label") : this.visibleText;
    this.button.setAttribute("aria-checked", this.checked ? "true" : "false");
    if (this.hasAttribute("disabled")) this.button.setAttribute("aria-disabled", "true");
    else this.button.removeAttribute("aria-disabled");
    this.button.title = this.hasAttribute("disabled") ? this.getAttribute("reason") || "" : "";
  }
}

customElements.define("ps-toggle", PsToggle);
