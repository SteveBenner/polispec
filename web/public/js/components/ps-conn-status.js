const NS = "http://www.w3.org/2000/svg";

const STATES = {
  live: { word: "Live", tone: "ok" },
  reconnecting: { word: "Reconnecting", tone: "warn" },
  paused: { word: "Paused", tone: "dim" },
  offline: { word: "Offline", tone: "danger" },
  off: { word: "Turned off", tone: "faint" },
};

function icon(name) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "ps-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

class PsConnStatus extends HTMLElement {
  static observedAttributes = ["state", "seconds", "href"];

  connectedCallback() {
    if (this.link) return;
    this.link = document.createElement("a");
    this.link.className = "ps-native";
    this.link.append(icon("signal"));
    this.word = document.createElement("span");
    this.word.className = "ps-word";
    this.link.append(this.word);
    this.append(this.link);
    this.update();
  }

  attributeChangedCallback() {
    if (this.link) this.update();
  }

  update() {
    const key = STATES[this.getAttribute("state")] ? this.getAttribute("state") : "live";
    const entry = STATES[key];
    let word = entry.word;
    if (key === "reconnecting" && this.hasAttribute("seconds")) word = `Reconnecting in ${this.getAttribute("seconds")} s`;
    this.word.textContent = word;
    this.setAttribute("data-tone", entry.tone);
    this.link.setAttribute("href", this.getAttribute("href") || "#/feed");
    this.link.setAttribute("aria-label", `Live feed: ${word}`);
  }
}

customElements.define("ps-conn-status", PsConnStatus);
