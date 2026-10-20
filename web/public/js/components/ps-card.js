class PsCard extends HTMLElement {
  static observedAttributes = ["interactive"];

  connectedCallback() {
    if (this.prepared) return;
    this.prepared = true;
    this.addEventListener("keydown", (event) => {
      if (!this.hasAttribute("interactive") || event.target !== this) return;
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        this.click();
      }
    });
    this.sync();
  }

  attributeChangedCallback() {
    if (this.prepared) this.sync();
  }

  sync() {
    if (this.hasAttribute("interactive")) {
      if (!this.hasAttribute("tabindex")) this.tabIndex = 0;
      if (!this.hasAttribute("role")) this.setAttribute("role", "button");
    } else {
      if (this.getAttribute("tabindex") === "0") this.removeAttribute("tabindex");
    }
  }
}

customElements.define("ps-card", PsCard);
