const NS = "http://www.w3.org/2000/svg";

const SEVERITY = {
  info: { icon: "info", role: "status" },
  ok: { icon: "allow", role: "status" },
  warn: { icon: "warn", role: "status" },
  danger: { icon: "deny", role: "alert" },
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

class PsBanner extends HTMLElement {
  static observedAttributes = ["severity", "action", "text", "icon"];

  connectedCallback() {
    if (this.message) return;
    this.fallbackText = this.textContent.trim();
    this.textContent = "";
    this.lead = document.createElement("span");
    this.lead.className = "ps-lead";
    this.message = document.createElement("span");
    this.message.className = "ps-message";
    this.actionButton = document.createElement("ps-button");
    this.actionButton.setAttribute("variant", "ghost");
    this.actionButton.setAttribute("size", "xs");
    this.actionButton.hidden = true;
    this.actionButton.addEventListener("click", () => {
      this.dispatchEvent(new CustomEvent("ps-action", { bubbles: true }));
    });
    this.append(this.lead, this.message, this.actionButton);
    this.update();
  }

  attributeChangedCallback() {
    if (this.message) this.update();
  }

  update() {
    const severity = SEVERITY[this.getAttribute("severity")] ? this.getAttribute("severity") : "info";
    const config = SEVERITY[severity];
    this.setAttribute("data-severity", severity);
    this.setAttribute("role", config.role);
    this.lead.replaceChildren(icon(this.getAttribute("icon") || config.icon));
    this.message.textContent = this.hasAttribute("text") ? this.getAttribute("text") : this.fallbackText;
    const action = this.getAttribute("action");
    this.actionButton.hidden = !action;
    if (action) this.actionButton.text = action;
  }
}

customElements.define("ps-banner", PsBanner);
