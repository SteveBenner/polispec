let sequence = 0;

class PsTabs extends HTMLElement {
  static observedAttributes = ["selected"];

  connectedCallback() {
    if (this.list) return;
    sequence += 1;
    this.uid = `ps-tabs-${sequence}`;
    this.panels = [...this.querySelectorAll(":scope > [data-tab]")];
    this.list = document.createElement("div");
    this.list.className = "ps-tablist";
    this.list.setAttribute("role", "tablist");
    if (this.hasAttribute("label")) this.list.setAttribute("aria-label", this.getAttribute("label"));
    this.prepend(this.list);
    this.current = this.getAttribute("selected") || this.panels[0]?.dataset.tab;
    this.list.addEventListener("click", (event) => {
      const tab = event.target.closest("[role=tab]");
      if (tab) this.select(tab.dataset.tab, false);
    });
    this.list.addEventListener("keydown", (event) => this.onKey(event));
    this.render();
  }

  attributeChangedCallback(name, oldValue, value) {
    if (!this.list || name !== "selected" || value === this.current) return;
    this.current = value;
    this.render();
  }

  get value() {
    return this.current;
  }

  render() {
    this.list.textContent = "";
    this.panels.forEach((panel, index) => {
      const id = panel.dataset.tab;
      const tab = document.createElement("button");
      tab.type = "button";
      tab.className = "ps-native";
      tab.id = `${this.uid}-tab-${index}`;
      tab.dataset.tab = id;
      tab.setAttribute("role", "tab");
      tab.setAttribute("aria-controls", `${this.uid}-panel-${index}`);
      const selected = id === this.current;
      tab.setAttribute("aria-selected", selected ? "true" : "false");
      tab.tabIndex = selected ? 0 : -1;
      const text = document.createElement("span");
      text.textContent = panel.dataset.label || id;
      tab.append(text);
      if (panel.dataset.count !== undefined) {
        const count = document.createElement("span");
        count.className = "ps-count num";
        count.textContent = panel.dataset.count;
        tab.append(count);
      }
      this.list.append(tab);
      panel.id = `${this.uid}-panel-${index}`;
      panel.setAttribute("role", "tabpanel");
      panel.setAttribute("aria-labelledby", tab.id);
      panel.tabIndex = 0;
      panel.hidden = !selected;
    });
  }

  select(id, focus) {
    const changed = id !== this.current;
    this.current = id;
    this.render();
    const tab = this.list.querySelector("[aria-selected=true]");
    if (focus) tab?.focus();
    tab?.scrollIntoView({ block: "nearest", inline: "nearest" });
    if (changed) this.dispatchEvent(new CustomEvent("ps-tab-change", { bubbles: true, detail: { id } }));
  }

  onKey(event) {
    const tabs = [...this.list.querySelectorAll("[role=tab]")];
    const index = tabs.indexOf(document.activeElement);
    if (index < 0) return;
    let next = -1;
    if (event.key === "ArrowRight") next = (index + 1) % tabs.length;
    else if (event.key === "ArrowLeft") next = (index - 1 + tabs.length) % tabs.length;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = tabs.length - 1;
    if (next < 0) return;
    event.preventDefault();
    this.select(tabs[next].dataset.tab, true);
  }
}

customElements.define("ps-tabs", PsTabs);
