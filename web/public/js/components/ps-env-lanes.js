const ORDER = ["dev", "test", "prod"];
const BRANCH = { dev: "main", test: "test", prod: "stable" };

class PsEnvLanes extends HTMLElement {
  connectedCallback() {
    if (this.prepared) return;
    this.prepared = true;
    this.items = this.items || {};
    this.setAttribute("role", "group");
    if (!this.hasAttribute("aria-label")) this.setAttribute("aria-label", "Environments");
    this.render();
  }

  get lanes() {
    return this.items;
  }

  set lanes(value) {
    this.items = value || {};
    if (this.prepared) this.render();
  }

  render() {
    this.textContent = "";
    for (const env of ORDER) {
      const data = this.items[env] || {};
      const lane = document.createElement("div");
      lane.className = "ps-lane";
      lane.setAttribute("role", "group");
      lane.setAttribute("aria-label", `${env}, branch ${BRANCH[env]}`);
      lane.dataset.env = env;
      const head = document.createElement("div");
      head.className = "ps-lane-head";
      head.textContent = `${env} ${BRANCH[env]}`;
      lane.append(head);
      if (data.verdict) {
        const chip = document.createElement("ps-chip");
        chip.setAttribute("kind", "verdict");
        chip.setAttribute("value", data.verdict);
        lane.append(chip);
      }
      const primary = document.createElement("div");
      primary.className = "ps-lane-primary mono";
      primary.textContent = data.primary || "";
      primary.title = data.primary || "";
      lane.append(primary);
      const secondary = document.createElement("div");
      secondary.className = "ps-lane-secondary";
      secondary.textContent = data.secondary || "";
      lane.append(secondary);
      this.append(lane);
    }
  }
}

customElements.define("ps-env-lanes", PsEnvLanes);
