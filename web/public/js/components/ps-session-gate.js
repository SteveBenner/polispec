import "./ps-command.js";
import "./ps-button.js";
import { app } from "../core/store.js";
import { bootSession } from "../core/session.js";

const NS = "http://www.w3.org/2000/svg";

const GATES = {
  exchanging: {
    title: "Opening polispec web",
    body: () => "Checking the one-time link.",
    hourglass: true,
  },
  link_used_or_expired: {
    title: "This link has already been used or has expired",
    body: () => "Each link works once. Get a new one in a terminal.",
    command: "polispec web url",
  },
  no_session: {
    title: "No session",
    body: () => "Run polispec web url in a terminal and open the link it prints.",
    command: "polispec web url",
  },
  session_ended: {
    title: "Session ended",
    body: (cause) => {
      const reason = String(cause || "").trim().replace(/[.\s]+$/, "");
      return reason ? `${reason}. Get a new link in a terminal.` : "Get a new link in a terminal.";
    },
    command: "polispec web url",
  },
  server_unreachable: {
    title: "polispec web is not running",
    body: () => "Start it again in a terminal. Cached views are shown when you reopen the link.",
    command: "polispec web --open",
    retry: true,
  },
};

function hourglass() {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "ps-icon ps-icon-lg");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", "icons/icons.svg#i-hourglass");
  svg.append(use);
  return svg;
}

class PsSessionGate extends HTMLElement {
  static observedAttributes = ["state"];

  connectedCallback() {
    if (this.panel) return;
    this.panel = document.createElement("div");
    this.panel.className = "ps-panel";
    this.append(this.panel);
    this.unsubscribe = app.subscribe(() => {
      if (this.signature() !== this.shown) this.render();
    });
    this.render();
  }

  disconnectedCallback() {
    if (this.unsubscribe) this.unsubscribe();
    this.unsubscribe = null;
  }

  attributeChangedCallback() {
    if (this.panel) this.render();
  }

  key() {
    return GATES[this.getAttribute("state")] ? this.getAttribute("state") : app.get().session;
  }

  signature() {
    return `${this.key()}|${app.get().cause || ""}`;
  }

  render() {
    const key = this.key();
    this.shown = this.signature();
    const spec = GATES[key] || GATES.no_session;
    this.setAttribute("data-gate", key);
    this.panel.setAttribute("role", key === "exchanging" ? "status" : "alert");
    const heading = document.createElement("h1");
    heading.tabIndex = -1;
    heading.textContent = spec.title;
    const children = [];
    if (spec.hourglass) {
      const lead = document.createElement("div");
      lead.className = "ps-lead";
      lead.append(hourglass());
      children.push(lead);
    }
    children.push(heading);
    const body = document.createElement("p");
    body.textContent = spec.body(app.get().cause);
    children.push(body);
    if (spec.command) {
      const command = document.createElement("ps-command");
      command.setAttribute("command", spec.command);
      children.push(command);
    }
    if (spec.retry) {
      const actions = document.createElement("div");
      actions.className = "ps-actions";
      const retry = document.createElement("ps-button");
      retry.setAttribute("variant", "primary");
      retry.setAttribute("size", "md");
      retry.setAttribute("busy-label", "Retrying");
      retry.text = "Retry";
      retry.addEventListener("click", async () => {
        retry.setAttribute("busy", "");
        try {
          await bootSession();
        } finally {
          if (retry.isConnected) retry.removeAttribute("busy");
        }
      });
      actions.append(retry);
      children.push(actions);
    }
    this.panel.replaceChildren(...children);
  }
}

customElements.define("ps-session-gate", PsSessionGate);
