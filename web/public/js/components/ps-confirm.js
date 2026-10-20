const NS = "http://www.w3.org/2000/svg";
const ANNOUNCE_DELAY = 500;
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

class PsConfirm extends HTMLElement {
  static observedAttributes = ["expected", "mode", "action", "busy-label", "busy", "error"];

  connectedCallback() {
    if (this.field) return;
    sequence += 1;
    this.uid = `ps-confirm-${sequence}`;
    this.intro = document.createElement("p");
    this.intro.className = "ps-intro";
    this.intro.id = `${this.uid}-intro`;
    this.expectedChip = document.createElement("ps-chip");
    this.expectedChip.setAttribute("kind", "tag");
    this.expectedChip.id = `${this.uid}-expected`;
    this.row = document.createElement("div");
    this.row.className = "ps-row";
    this.field = document.createElement("ps-text-field");
    this.field.setAttribute("mono", "");
    this.field.setAttribute("size", "md");
    this.button = document.createElement("ps-button");
    this.button.setAttribute("variant", "primary");
    this.button.setAttribute("size", "md");
    this.button.setAttribute("write", "");
    this.row.append(this.field, this.button);
    this.status = document.createElement("div");
    this.status.className = "ps-status";
    this.status.id = `${this.uid}-status`;
    this.announcer = document.createElement("span");
    this.announcer.className = "visually-hidden";
    this.announcer.setAttribute("role", "status");
    this.append(this.intro, this.expectedChip, this.row, this.status, this.announcer);
    this.actionLabel = this.getAttribute("action") || "Apply plan";
    this.button.text = this.actionLabel;
    this.input = this.field.input;
    this.input.setAttribute("data-describedby-extra", `${this.intro.id} ${this.expectedChip.id} ${this.status.id}`);
    this.input.addEventListener("input", () => {
      this.refresh();
      clearTimeout(this.announceTimer);
      this.announceTimer = setTimeout(() => {
        this.announcer.textContent = this.matches() ? "Matches" : "Does not match yet";
      }, ANNOUNCE_DELAY);
    });
    this.input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        this.submit();
      }
    });
    this.button.addEventListener("click", () => this.submit());
    this.update();
  }

  disconnectedCallback() {
    clearTimeout(this.announceTimer);
  }

  attributeChangedCallback() {
    if (this.field) this.update();
  }

  get value() {
    return this.field ? this.field.value : "";
  }

  matches() {
    return this.value.trim() === (this.getAttribute("expected") || "") && this.getAttribute("expected") !== "";
  }

  update() {
    const phrase = this.getAttribute("mode") === "phrase";
    this.intro.textContent = phrase ? "Type the phrase to continue." : "Type the plan id to apply.";
    this.expectedChip.setAttribute("label", this.getAttribute("expected") || "");
    this.field.setAttribute("label", phrase ? "Phrase" : "Plan id");
    const error = this.getAttribute("error");
    if (error) this.field.setAttribute("error", error);
    else this.field.removeAttribute("error");
    this.button.text = this.getAttribute("action") || "Apply plan";
    if (this.hasAttribute("busy-label")) this.button.setAttribute("busy-label", this.getAttribute("busy-label"));
    this.button.toggleAttribute("busy", this.hasAttribute("busy"));
    this.refresh();
  }

  refresh() {
    const ok = this.matches();
    this.status.textContent = "";
    if (ok) {
      this.status.setAttribute("data-match", "true");
      this.status.append(icon("allow"), document.createTextNode("Matches"));
    } else {
      this.status.removeAttribute("data-match");
      this.status.textContent = "Does not match yet";
    }
    if (ok) {
      this.button.removeAttribute("disabled");
      this.button.removeAttribute("reason");
    } else {
      this.button.setAttribute("disabled", "");
      this.button.setAttribute("reason", this.getAttribute("mode") === "phrase" ? "Type the phrase to enable this" : "Type the plan id to enable this");
    }
  }

  submit() {
    if (!this.matches() || this.hasAttribute("busy")) return;
    this.dispatchEvent(new CustomEvent("ps-confirm", { bubbles: true, detail: { value: this.value.trim() } }));
  }

  focus(options) {
    this.field?.focus(options);
  }
}

customElements.define("ps-confirm", PsConfirm);
