const NS = "http://www.w3.org/2000/svg";

function icon(name) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "ps-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

class PsState extends HTMLElement {
  static observedAttributes = ["kind", "heading", "body", "action", "error-id", "details", "feature", "glyph"];

  connectedCallback() {
    if (this.main) return;
    this.extras = [...this.childNodes];
    this.textContent = "";
    this.lead = document.createElement("span");
    this.lead.className = "ps-lead";
    this.main = document.createElement("div");
    this.main.className = "ps-main";
    this.append(this.lead, this.main);
    this.update();
  }

  attributeChangedCallback() {
    if (this.main) this.update();
  }

  update() {
    const kind = this.getAttribute("kind") || "empty_first_run";
    this.setAttribute("data-kind", kind);
    this.setAttribute("role", kind === "error" ? "alert" : "status");
    const feature = this.getAttribute("feature");
    let heading = this.getAttribute("heading") || "";
    let glyph = this.getAttribute("glyph") || "info";
    if (kind === "empty_filtered") {
      heading = heading || "No rows match these filters";
      glyph = "filter";
    } else if (kind === "empty_cleared") {
      glyph = "check";
    } else if (kind === "error") {
      glyph = "deny";
    } else if (kind === "disabled") {
      glyph = this.getAttribute("glyph") || "lock";
      if (!heading && feature) heading = `${feature} is turned off`;
    }
    this.lead.replaceChildren(icon(glyph));
    this.main.textContent = "";
    const title = document.createElement("div");
    title.className = "ps-title";
    title.textContent = heading;
    this.main.append(title);
    const body = this.getAttribute("body");
    if (body) {
      const line = document.createElement("div");
      line.className = "ps-body";
      line.textContent = body;
      this.main.append(line);
    }
    if (kind === "error" && this.hasAttribute("error-id")) {
      const idLine = document.createElement("div");
      idLine.className = "ps-body";
      idLine.append(document.createTextNode("Error id "));
      const digest = document.createElement("ps-digest");
      digest.setAttribute("kind", "error id");
      digest.setAttribute("value", this.getAttribute("error-id"));
      digest.setAttribute("length", String(this.getAttribute("error-id").length));
      idLine.append(digest);
      this.main.append(idLine);
    }
    const actions = document.createElement("div");
    actions.className = "ps-actions";
    if (kind === "error") {
      const retry = document.createElement("ps-button");
      retry.setAttribute("size", "xs");
      retry.setAttribute("icon", "reset");
      retry.text = "Retry";
      retry.addEventListener("click", () => this.dispatchEvent(new CustomEvent("ps-retry", { bubbles: true })));
      const copy = document.createElement("ps-button");
      copy.setAttribute("variant", "ghost");
      copy.setAttribute("size", "xs");
      copy.setAttribute("icon", "copy");
      copy.text = "Copy details";
      copy.addEventListener("click", async () => {
        const text = [heading, body, this.getAttribute("error-id"), this.getAttribute("details")].filter(Boolean).join("\n");
        try {
          await navigator.clipboard.writeText(text);
          this.dispatchEvent(new CustomEvent("ps-copied", { bubbles: true, detail: { text, message: "Copied" } }));
        } catch (error) {
          this.dispatchEvent(new CustomEvent("ps-copy-failed", { bubbles: true, detail: { text } }));
        }
      });
      actions.append(retry, copy);
    } else if (this.getAttribute("action") && kind !== "empty_cleared") {
      const button = document.createElement("ps-button");
      button.setAttribute("size", "xs");
      button.text = this.getAttribute("action");
      button.addEventListener("click", () => this.dispatchEvent(new CustomEvent("ps-action", { bubbles: true })));
      actions.append(button);
    }
    for (const node of this.extras) {
      if (node.nodeType === 1) actions.append(node);
    }
    if (actions.childElementCount) this.main.append(actions);
  }
}

customElements.define("ps-state", PsState);
