import "./ps-button.js";

let sequence = 0;

class PsPlanTray extends HTMLElement {
  connectedCallback() {
    if (this.bar) return;
    sequence += 1;
    this.uid = `ps-plan-tray-${sequence}`;
    this.hidden = true;
    this.bar = document.createElement("div");
    this.bar.className = "ps-bar";
    this.summary = document.createElement("div");
    this.summary.className = "ps-summary";
    this.actions = document.createElement("div");
    this.actions.className = "ps-actions";
    this.toggleButton = document.createElement("ps-button");
    this.toggleButton.setAttribute("size", "sm");
    this.toggleButton.setAttribute("icon", "chevron-down");
    this.toggleButton.text = "Show blast radius";
    this.reviewButton = document.createElement("ps-button");
    this.reviewButton.setAttribute("variant", "primary");
    this.reviewButton.setAttribute("size", "sm");
    this.reviewButton.text = "Review plan";
    this.actions.append(this.toggleButton, this.reviewButton);
    this.bar.append(this.summary, this.actions);
    this.panel = document.createElement("div");
    this.panel.className = "ps-expanded";
    this.panel.id = `${this.uid}-panel`;
    this.panel.hidden = true;
    this.append(this.bar, this.panel);
    this.toggleButton.addEventListener("click", () => this.setExpanded(this.panel.hidden));
    this.reviewButton.addEventListener("click", () => {
      this.dispatchEvent(new CustomEvent("ps-review-plan", { bubbles: true, detail: this.draft }));
    });
    this.onDraft = (event) => this.setDraft(event.detail);
    document.addEventListener("ps-draft-change", this.onDraft);
    this.syncToggle();
  }

  disconnectedCallback() {
    document.removeEventListener("ps-draft-change", this.onDraft);
  }

  setExpanded(expanded) {
    this.panel.hidden = !expanded;
    this.syncToggle();
    this.dispatchEvent(new CustomEvent("ps-blast-toggle", { bubbles: true, detail: { expanded } }));
  }

  syncToggle() {
    const expanded = !this.panel.hidden;
    this.toggleButton.text = expanded ? "Hide blast radius" : "Show blast radius";
    this.toggleButton.setAttribute("icon", expanded ? "chevron-down" : "chevron-right");
    this.toggleButton.button.setAttribute("aria-expanded", expanded ? "true" : "false");
    this.toggleButton.button.setAttribute("aria-controls", this.panel.id);
    this.toggleButton.setAttribute("data-expanded", expanded ? "true" : "false");
  }

  setDraft(detail) {
    this.draft = detail || null;
    if (!detail) {
      this.hidden = true;
      this.setExpanded(false);
      this.summary.textContent = "";
      return;
    }
    this.hidden = false;
    this.summary.textContent = detail.summary || this.compose(detail);
    this.summary.title = this.summary.textContent;
  }

  compose(detail) {
    const parts = [];
    if (detail.rulebook) parts.push(`Draft of ${detail.rulebook}: ${detail.changed ?? 0} rules changed.`);
    if (detail.flips !== undefined) {
      parts.push(`Blast radius, last 14 days: ${detail.flips} rows flip in ${detail.projects ?? 0} projects.`);
    }
    return parts.join(" ");
  }
}

customElements.define("ps-plan-tray", PsPlanTray);
