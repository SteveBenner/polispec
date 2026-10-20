class PsSkeleton extends HTMLElement {
  static observedAttributes = ["width", "height", "lines"];

  connectedCallback() {
    this.setAttribute("aria-hidden", "true");
    this.render();
  }

  attributeChangedCallback() {
    if (this.isConnected) this.render();
  }

  render() {
    const width = this.getAttribute("width");
    const height = this.getAttribute("height");
    if (width) this.style.width = width;
    else this.style.removeProperty("width");
    if (height) this.style.height = height;
    else this.style.removeProperty("height");
    const lines = Number(this.getAttribute("lines")) || 0;
    this.textContent = "";
    for (let i = 0; i < lines; i += 1) {
      const line = document.createElement("span");
      line.className = "ps-line";
      line.style.width = i === lines - 1 && lines > 1 ? "60%" : "100%";
      this.append(line);
    }
  }
}

customElements.define("ps-skeleton", PsSkeleton);
