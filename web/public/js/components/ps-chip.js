const NS = "http://www.w3.org/2000/svg";

const KINDS = {
  verdict: {
    allow: { label: "Allow", icon: "allow", tone: "ok" },
    warn: { label: "Warn", icon: "warn", tone: "warn" },
    deny: { label: "Deny", icon: "deny", tone: "danger" },
  },
  status: {
    live: { label: "Live", icon: "circle-dot", tone: "ok" },
    onboarding: { label: "Onboarding", icon: "flag", tone: "accent" },
    retired: { label: "Retired", icon: "stop", tone: "faint" },
  },
  effect: {
    next_call: { label: "Next call", icon: "next-call", tone: "neutral" },
    new_session: { label: "New session", icon: "new-session", tone: "neutral" },
    reload: { label: "After /reload-plugins", icon: "reload", tone: "neutral" },
    trust: { label: "After trust review", icon: "trust", tone: "neutral" },
  },
  classification: {
    tightening: { label: "Tightening", icon: "tightening", tone: "ok" },
    neutral: { label: "Neutral", icon: "neutral", tone: "neutral" },
    loosening: { label: "Loosening", icon: "loosening", tone: "warn" },
    mixed: { label: "Mixed", icon: "mixed", tone: "warn" },
    global: { label: "Global", icon: "global", tone: "accent" },
  },
  session: {
    current: { label: "Current", icon: "circle-dot", tone: "ok" },
    pending: { label: "Pending", icon: "hourglass", tone: "dim" },
    reload_needed: { label: "Reload needed", icon: "reload", tone: "warn", command: "/reload-plugins" },
    stale_briefing: { label: "Stale briefing", icon: "warn", tone: "warn" },
    untrusted_hook: { label: "Untrusted hook", icon: "deny", tone: "danger" },
  },
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

class PsChip extends HTMLElement {
  static observedAttributes = ["kind", "value", "label", "size"];

  connectedCallback() {
    if (this.rendered) return;
    this.rendered = true;
    this.fallbackText = this.textContent.trim();
    this.render();
  }

  attributeChangedCallback() {
    if (this.rendered) this.render();
  }

  render() {
    const kind = this.getAttribute("kind") || "tag";
    const value = this.getAttribute("value");
    const entry = KINDS[kind] && KINDS[kind][value];
    const text = this.getAttribute("label") || (entry ? entry.label : this.fallbackText);
    this.textContent = "";
    this.setAttribute("data-tone", entry ? entry.tone : "neutral");
    const wrap = entry && entry.command ? document.createElement("button") : document.createElement("span");
    wrap.className = "ps-chip-body";
    if (entry && entry.icon) wrap.append(icon(entry.icon));
    const label = document.createElement("span");
    label.className = "ps-chip-label";
    label.textContent = text;
    wrap.append(label);
    if (entry && entry.command) {
      wrap.type = "button";
      wrap.classList.add("ps-native");
      wrap.setAttribute("aria-label", `${text}, copy ${entry.command}`);
      wrap.addEventListener("click", async () => {
        try {
          await navigator.clipboard.writeText(entry.command);
          this.dispatchEvent(new CustomEvent("ps-copied", { bubbles: true, detail: { text: entry.command } }));
        } catch (error) {
          this.dispatchEvent(new CustomEvent("ps-copy-failed", { bubbles: true, detail: { text: entry.command } }));
        }
      });
    }
    this.append(wrap);
    if (kind === "filter") {
      const remove = document.createElement("button");
      remove.type = "button";
      remove.className = "ps-native ps-remove";
      remove.setAttribute("aria-label", `Remove filter ${text}`);
      remove.append(icon("close"));
      remove.addEventListener("click", () => {
        this.dispatchEvent(new CustomEvent("ps-remove", { bubbles: true, detail: { label: text } }));
      });
      this.append(remove);
    }
  }
}

customElements.define("ps-chip", PsChip);
