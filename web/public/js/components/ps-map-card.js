import { middleTruncate, shortDigest } from "../core/format.js";
import { BANDS } from "../map/layout.js";

const NS = "http://www.w3.org/2000/svg";

function icon(name, className) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", className ? "ps-icon " + className : "ps-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

export function shortCount(value) {
  const number = Number(value) || 0;
  if (number > 9999) return "10k+";
  return String(number);
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

class PsMapCard extends HTMLElement {
  connectedCallback() {
    this.render();
  }

  configure(config) {
    this.config = config;
    if (this.isConnected) this.render();
  }

  render() {
    const config = this.config;
    if (!config) return;
    this.textContent = "";
    if (config.child) this.renderChild(config);
    else this.renderEntry(config);
  }

  renderChild(config) {
    this.setAttribute("data-child", "");
    const body = document.createElement("ps-card");
    body.className = "ps-map-body";
    const glob = el("div", "ps-glob mono", middleTruncate(config.glob, 28));
    glob.title = config.glob;
    const matched = el("div", "ps-matched", `${config.matched} worktrees match`);
    body.append(glob, matched);
    this.append(body);
  }

  renderEntry(config) {
    const { entry, inherits, blast } = config;
    this.removeAttribute("data-child");
    const partial = Boolean(entry.error);
    this.toggleAttribute("data-partial", partial);
    this.toggleAttribute("data-pinned", Boolean(config.pinned));
    const body = document.createElement("ps-card");
    body.className = "ps-map-body";

    const strip = el("span", "ps-strip");
    const parts = [];
    BANDS.forEach((band) => {
      const reached = inherits && inherits[band.key] > 0;
      const seg = el("i");
      if (reached) {
        seg.setAttribute("data-on", "");
        parts.push(band.label);
      }
      strip.append(seg);
    });
    strip.title = partial ? entry.error : parts.length ? "Inherits from " + parts.join(", ") : "Inherits from no layer";
    if (partial) strip.setAttribute("data-danger", "");

    const head = el("div", "ps-head");
    const link = document.createElement("a");
    link.className = "ps-name";
    link.href = `#/detail/${encodeURIComponent(entry.kind)}/${encodeURIComponent(entry.id)}`;
    link.textContent = entry.id;
    link.title = entry.id;
    link.setAttribute("aria-label", `${entry.id}, ${entry.kind === "path" ? "path entry" : "project"}, ${entry.status}`);
    const status = document.createElement("ps-chip");
    status.setAttribute("kind", "status");
    status.setAttribute("value", entry.status);
    head.append(link, status);
    if (config.pinned) {
      const pin = icon("pin", "ps-pin");
      pin.setAttribute("role", "img");
      pin.setAttribute("aria-label", "Position saved");
      pin.removeAttribute("aria-hidden");
      head.insertBefore(pin, status);
    }

    const summary = el("div", "ps-summary", entry.summary || "");
    summary.title = entry.summary || "";

    const desc = el("div", "ps-desc");
    if (partial) {
      desc.setAttribute("data-danger", "");
      desc.append(icon("deny"), el("span", "", "Policy did not load"));
    } else if (!entry.description) {
      desc.setAttribute("data-missing", "");
      desc.append(icon("warn"), el("span", "", "No description"));
    } else {
      desc.textContent = entry.description;
    }

    const foot = el("div", "ps-foot");
    if (entry.digest) {
      const digest = document.createElement("ps-digest");
      digest.setAttribute("value", shortDigest(entry.digest, 64));
      digest.setAttribute("kind", "dev policy digest");
      digest.setAttribute("length", "8");
      foot.append(digest);
    } else {
      foot.append(el("span", "ps-nopolicy", "No policy"));
    }
    if (blast) {
      const flips = blast.stricter + blast.looser;
      const chip = document.createElement("ps-chip");
      chip.className = "ps-flips";
      chip.setAttribute("label", `${flips} flips`);
      chip.setAttribute("data-tone-flip", blast.stricter >= blast.looser ? "stricter" : "looser");
      foot.append(chip);
    } else if (config.preview) {
      const mark = document.createElement("ps-chip");
      mark.className = "ps-preview-mark";
      mark.setAttribute("label", "Preview");
      foot.append(mark);
    } else {
      const counts = el("div", "ps-counts");
      counts.setAttribute("role", "group");
      const c = entry.counts || { allow: 0, warn: 0, deny: 0 };
      counts.setAttribute("aria-label", `Verdicts: ${c.allow} allow, ${c.warn} warn, ${c.deny} deny`);
      for (const verdict of ["allow", "warn", "deny"]) {
        const pair = el("span", "ps-count");
        pair.setAttribute("data-verdict", verdict);
        pair.title = `${c[verdict]} ${verdict}`;
        pair.append(icon(verdict), el("span", "num", shortCount(c[verdict])));
        counts.append(pair);
      }
      foot.append(counts);
    }

    body.append(strip, head, summary, desc, foot);
    this.append(body);
  }
}

if (!customElements.get("ps-map-card")) customElements.define("ps-map-card", PsMapCard);
