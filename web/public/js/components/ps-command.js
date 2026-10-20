const NS = "http://www.w3.org/2000/svg";
const COPIED_MS = 1500;

function icon(name) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "ps-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

class PsCommand extends HTMLElement {
  static observedAttributes = ["command", "operator", "why"];

  connectedCallback() {
    if (this.block) return;
    if (!this.hasAttribute("command")) this.setAttribute("command", this.textContent.trim());
    this.textContent = "";
    this.whoLine = document.createElement("div");
    this.whoLine.className = "ps-who";
    this.block = document.createElement("div");
    this.block.className = "ps-block";
    this.lead = document.createElement("span");
    this.lead.className = "ps-lead";
    this.code = document.createElement("code");
    this.code.className = "ps-code mono";
    this.copyButton = document.createElement("ps-icon-button");
    this.copyButton.setAttribute("icon", "copy");
    this.copyButton.setAttribute("label", "Copy command");
    this.copyButton.setAttribute("size", "sm");
    this.block.append(this.lead, this.code, this.copyButton);
    this.live = document.createElement("span");
    this.live.className = "visually-hidden";
    this.live.setAttribute("role", "status");
    this.append(this.whoLine, this.block, this.live);
    this.copyButton.addEventListener("click", () => this.copy());
    this.update();
  }

  disconnectedCallback() {
    clearTimeout(this.resetTimer);
  }

  attributeChangedCallback() {
    if (this.block) this.update();
  }

  update() {
    const operator = this.hasAttribute("operator");
    const why = this.getAttribute("why") || "";
    const who = operator ? "Operator only. Run in a terminal." : "Run in a terminal.";
    this.whoLine.textContent = why ? `${who} ${why}` : who;
    this.lead.replaceChildren(icon(operator ? "lock" : "terminal"));
    this.code.textContent = this.getAttribute("command") || "";
    this.block.setAttribute("data-operator", operator ? "true" : "false");
  }

  async copy() {
    const text = this.getAttribute("command") || "";
    clearTimeout(this.resetTimer);
    try {
      await navigator.clipboard.writeText(text);
      this.copyButton.setAttribute("icon", "check");
      this.live.textContent = "";
      requestAnimationFrame(() => {
        this.live.textContent = "Command copied";
      });
      this.dispatchEvent(new CustomEvent("ps-copied", { bubbles: true, detail: { text, message: "Copied" } }));
      this.resetTimer = setTimeout(() => this.copyButton.setAttribute("icon", "copy"), COPIED_MS);
    } catch (error) {
      const range = document.createRange();
      range.selectNodeContents(this.code);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      this.live.textContent = "Select and copy the command.";
      this.dispatchEvent(new CustomEvent("ps-copy-failed", { bubbles: true, detail: { text, message: "Select and copy the command." } }));
    }
  }
}

customElements.define("ps-command", PsCommand);
