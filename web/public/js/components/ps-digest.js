function middleTruncate(text, keep) {
  if (text.length <= keep * 2 + 1) return text;
  return `${text.slice(0, keep)}…${text.slice(-keep)}`;
}

let sequence = 0;

class PsDigest extends HTMLElement {
  static observedAttributes = ["value", "kind", "length", "truncate"];

  connectedCallback() {
    if (this.button) return;
    this.button = document.createElement("button");
    this.button.type = "button";
    sequence += 1;
    this.button.className = "ps-native mono";
    this.button.id = `ps-digest-${sequence}`;
    this.tooltip = document.createElement("ps-tooltip");
    this.tooltip.setAttribute("for", this.button.id);
    this.append(this.button, this.tooltip);
    this.button.addEventListener("click", async () => {
      const value = this.getAttribute("value") || "";
      try {
        await navigator.clipboard.writeText(value);
        this.flash("Copied");
        this.dispatchEvent(new CustomEvent("ps-copied", { bubbles: true, detail: { text: value, message: "Copied" } }));
      } catch (error) {
        this.dispatchEvent(new CustomEvent("ps-copy-failed", { bubbles: true, detail: { text: value } }));
      }
    });
    this.update();
  }

  attributeChangedCallback() {
    if (this.button) this.update();
  }

  flash(message) {
    this.tooltip.setAttribute("text", message);
    this.tooltip.show();
    clearTimeout(this.flashTimer);
    this.flashTimer = setTimeout(() => {
      this.tooltip.hide();
      this.tooltip.setAttribute("text", this.getAttribute("value") || "");
    }, 1200);
  }

  update() {
    const value = this.getAttribute("value") || "";
    const length = Number(this.getAttribute("length")) || 8;
    const middle = this.getAttribute("truncate") === "middle";
    const prefixed = /^sha256:/.test(value);
    const shown = prefixed ? value.slice(7, 7 + Math.max(length, 12)) : value.slice(0, length);
    this.button.textContent = middle ? middleTruncate(value, length) : shown;
    const kind = this.getAttribute("kind") || "digest";
    this.button.setAttribute("aria-label", `Copy ${kind} ${value}`);
    this.tooltip.setAttribute("text", value);
  }
}

customElements.define("ps-digest", PsDigest);
