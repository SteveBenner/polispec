import { BANDS, chipHref, entryKey } from "../map/layout.js";
import { middleTruncate } from "../core/format.js";
import { shortCount } from "./ps-map-card.js";

const NS = "http://www.w3.org/2000/svg";
const TYPEAHEAD_RESET = 700;

function icon(name, className) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", className ? "ps-icon " + className : "ps-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

function plural(count, one, many) {
  return `${count} ${count === 1 ? one : many || one + "s"}`;
}

function entryNode(entry, model, prefix) {
  const key = entryKey(entry);
  const inherits = model.inherits.get(key);
  const globs = (entry.globs || []).map((glob, i) => ({
    id: `${prefix}:${key}:glob:${i}`,
    label: middleTruncate(glob.glob, 40),
    title: glob.glob,
    secondary: `${glob.matched} worktrees match`,
    mono: true,
  }));
  const inheritedGroups = [];
  for (const band of BANDS) {
    const chips = model.chips.filter((chip) => chip.band === band.key && chip.reaches.includes(key));
    if (chips.length) {
      inheritedGroups.push({
        id: `${prefix}:${key}:inh:${band.key}`,
        label: band.label,
        secondary: plural(chips.length, "module instance"),
        children: chips.map((chip) => ({ id: `${prefix}:${key}:inh:${chip.key}`, label: chip.name, mono: true, href: chipHref(chip) })),
      });
    }
  }
  const children = [...globs];
  children.push({
    id: `${prefix}:${key}:inherits`,
    label: "Inherits from",
    secondary: inherits ? `${inherits.shipped} shipped, ${inherits.global} shelf, ${inherits.exceptions} exceptions` : "",
    children: inheritedGroups,
  });
  return {
    id: `${prefix}:${key}`,
    label: entry.id,
    title: entry.id,
    secondary: entry.status + (entry.error ? ", policy did not load" : ""),
    status: entry.status,
    counts: entry.counts,
    href: `#/detail/${encodeURIComponent(entry.kind)}/${encodeURIComponent(entry.id)}`,
    children,
  };
}

export function buildTree(model) {
  const top = [];
  for (const band of BANDS) {
    const chips = model.chips.filter((chip) => chip.band === band.key);
    top.push({
      id: "band:" + band.key,
      label: band.label,
      secondary: plural(chips.length, "module instance"),
      children: chips.map((chip) => ({
        id: "chip:" + chip.key,
        label: chip.name,
        mono: true,
        secondary: `reaches ${plural(chip.reaches.length, "entry", "entries")}`,
        href: chipHref(chip),
        children: chip.reaches.map((key) => {
          const entry = model.byKey.get(key);
          return { id: `chip:${chip.key}:${key}`, label: entry.id, secondary: entry.status, href: `#/detail/${encodeURIComponent(entry.kind)}/${encodeURIComponent(entry.id)}`, counts: entry.counts };
        }),
      })),
    });
  }
  top.push({ id: "projects", label: "Projects", secondary: String(model.projects.length), children: model.projects.map((entry) => entryNode(entry, model, "p")) });
  top.push({ id: "paths", label: "Path entries", secondary: String(model.paths.length), children: model.paths.map((entry) => entryNode(entry, model, "x")) });
  return top;
}

class PsMapTree extends HTMLElement {
  connectedCallback() {
    if (this.root) return;
    this.setAttribute("data-tree", "");
    this.root = document.createElement("ul");
    this.root.setAttribute("role", "tree");
    this.root.setAttribute("aria-label", "Policy map as a list");
    this.append(this.root);
    this.typed = "";
    this.typedTimer = 0;
    this.root.addEventListener("keydown", (event) => this.onKey(event));
    this.root.addEventListener("click", (event) => this.onClick(event));
    this.root.addEventListener("focusin", (event) => {
      const item = event.target.closest && event.target.closest("[role=treeitem]");
      if (item) this.setCurrent(item, false);
    });
    this.root.addEventListener("pointerover", (event) => {
      const item = event.target.closest && event.target.closest("[role=treeitem]");
      this.dispatchEvent(new CustomEvent("ps-tree-inspect", { bubbles: true, detail: { text: item ? item.getAttribute("data-inspect") || "" : "" } }));
    });
    if (this.pending) this.setData(this.pending);
  }

  disconnectedCallback() {
    clearTimeout(this.typedTimer);
  }

  setData(model) {
    if (!this.root) {
      this.pending = model;
      return;
    }
    this.model = model;
    this.root.textContent = "";
    const nodes = buildTree(model);
    for (const node of nodes) this.root.append(this.renderNode(node, 1, true));
    const first = this.root.querySelector("[role=treeitem]");
    if (first) this.setCurrent(first, false);
  }

  renderNode(node, level, top) {
    const li = document.createElement("li");
    li.setAttribute("role", "treeitem");
    li.dataset.id = node.id;
    li.setAttribute("aria-level", String(level));
    li.tabIndex = -1;
    if (node.href) li.dataset.href = node.href;
    const hasChildren = Boolean(node.children && node.children.length);
    if (node.children) li.setAttribute("aria-expanded", "false");
    const row = document.createElement("div");
    row.className = "ps-tree-row";
    row.style.paddingInlineStart = `calc(var(--space-4) * ${level - 1})`;
    const chevron = icon("chevron-right", "ps-chevron");
    if (!node.children) chevron.setAttribute("data-leaf", "");
    const label = document.createElement("span");
    label.className = "ps-tree-label" + (node.mono ? " mono" : "");
    label.textContent = node.label;
    if (node.title) label.title = node.title;
    row.append(chevron, label);
    if (node.secondary) {
      const secondary = document.createElement("span");
      secondary.className = "ps-tree-secondary";
      secondary.textContent = node.secondary;
      row.append(secondary);
    }
    if (node.counts) {
      const counts = document.createElement("span");
      counts.className = "ps-tree-counts";
      counts.setAttribute("aria-label", `Verdicts: ${node.counts.allow} allow, ${node.counts.warn} warn, ${node.counts.deny} deny`);
      for (const verdict of ["allow", "warn", "deny"]) {
        const pair = document.createElement("span");
        pair.className = "ps-count";
        pair.dataset.verdict = verdict;
        const number = document.createElement("span");
        number.className = "num";
        number.textContent = shortCount(node.counts[verdict]);
        pair.append(icon(verdict), number);
        counts.append(pair);
      }
      row.append(counts);
    }
    li.append(row);
    li.setAttribute("data-inspect", node.label + (node.secondary ? ": " + node.secondary : ""));
    if (hasChildren) {
      const group = document.createElement("ul");
      group.setAttribute("role", "group");
      group.hidden = true;
      for (const child of node.children) group.append(this.renderNode(child, level + 1, false));
      li.append(group);
    } else if (node.children) {
      const empty = document.createElement("ul");
      empty.setAttribute("role", "group");
      empty.hidden = true;
      li.append(empty);
    }
    return li;
  }

  items() {
    return [...this.root.querySelectorAll("[role=treeitem]")].filter((item) => {
      let parent = item.parentElement;
      while (parent && parent !== this.root) {
        if (parent.hidden) return false;
        parent = parent.parentElement;
      }
      return true;
    });
  }

  setCurrent(item, focus) {
    for (const other of this.root.querySelectorAll("[role=treeitem][tabindex='0']")) other.tabIndex = -1;
    item.tabIndex = 0;
    for (const other of this.root.querySelectorAll("[aria-selected]")) other.removeAttribute("aria-selected");
    item.setAttribute("aria-selected", "true");
    if (focus) item.focus();
  }

  expanded(item) {
    return item.getAttribute("aria-expanded") === "true";
  }

  toggle(item, open) {
    if (!item.hasAttribute("aria-expanded")) return;
    const group = item.querySelector(":scope > [role=group]");
    item.setAttribute("aria-expanded", open ? "true" : "false");
    if (group) group.hidden = !open;
    const chevron = item.querySelector(":scope > .ps-tree-row .ps-chevron");
    if (chevron) chevron.toggleAttribute("data-open", open);
  }

  parentItem(item) {
    return item.parentElement ? item.parentElement.closest("[role=treeitem]") : null;
  }

  open(item) {
    const href = item.dataset.href;
    if (href) window.location.hash = href;
  }

  onClick(event) {
    const row = event.target.closest && event.target.closest(".ps-tree-row");
    if (!row) return;
    const item = row.parentElement;
    this.setCurrent(item, true);
    if (event.target.closest(".ps-chevron") || !item.dataset.href) {
      if (item.hasAttribute("aria-expanded")) this.toggle(item, !this.expanded(item));
    } else {
      this.open(item);
    }
  }

  onKey(event) {
    const item = event.target.closest("[role=treeitem]");
    if (!item || event.target !== item) return;
    if (event.ctrlKey || event.metaKey || event.altKey) return;
    const list = this.items();
    const index = list.indexOf(item);
    let handled = true;
    switch (event.key) {
      case "ArrowDown":
        if (index < list.length - 1) this.setCurrent(list[index + 1], true);
        break;
      case "ArrowUp":
        if (index > 0) this.setCurrent(list[index - 1], true);
        break;
      case "ArrowRight":
        if (item.hasAttribute("aria-expanded")) {
          if (!this.expanded(item)) this.toggle(item, true);
          else {
            const child = item.querySelector(":scope > [role=group] > [role=treeitem]");
            if (child) this.setCurrent(child, true);
          }
        }
        break;
      case "ArrowLeft":
        if (this.expanded(item)) this.toggle(item, false);
        else {
          const parent = this.parentItem(item);
          if (parent) this.setCurrent(parent, true);
        }
        break;
      case "Home":
        this.setCurrent(list[0], true);
        break;
      case "End":
        this.setCurrent(list[list.length - 1], true);
        break;
      case "Enter":
      case " ":
        if (item.dataset.href && event.key === "Enter") this.open(item);
        else if (item.hasAttribute("aria-expanded")) this.toggle(item, !this.expanded(item));
        break;
      default:
        handled = false;
    }
    if (!handled && event.key.length === 1 && /\S/.test(event.key)) {
      handled = true;
      this.typed += event.key.toLowerCase();
      clearTimeout(this.typedTimer);
      this.typedTimer = setTimeout(() => {
        this.typed = "";
      }, TYPEAHEAD_RESET);
      const ordered = [...list.slice(index + 1), ...list.slice(0, index + 1)];
      const hit = ordered.find((entry) => entry.querySelector(".ps-tree-label").textContent.toLowerCase().startsWith(this.typed));
      if (hit) this.setCurrent(hit, true);
    }
    if (handled) event.preventDefault();
  }
}

if (!customElements.get("ps-map-tree")) customElements.define("ps-map-tree", PsMapTree);
