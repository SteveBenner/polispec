import "./ps-map-card.js";
import "./ps-state.js";
import "./ps-command.js";
import "./ps-skeleton.js";
import "./ps-chip.js";
import "./ps-digest.js";
import { announce } from "../core/announce.js";
import { BANDS, COLLAPSED_KEY, buildModel, computeLayout, defaultMetrics, skeletonLayout } from "../map/layout.js";
import { EDGE_HIDE_ABOVE, blastEdges, buildEdges, createSvg, pathD, renderEdges } from "../map/edges.js";
import { PanZoom, bindPointerPan, bindWheel } from "../map/pan.js";

const DRAG_THRESHOLD = 4;
const MOVE_STEP = 8;
const MOVE_STEP_FAST = 32;
const PAN_STEP = 32;
const PAN_STEP_FAST = 128;

function px(name, fallback) {
  const raw = getComputedStyle(document.documentElement).getPropertyValue(name);
  const value = parseFloat(raw);
  return Number.isFinite(value) ? value : fallback;
}

function plural(count, one, many) {
  return `${count} ${count === 1 ? one : many || one + "s"}`;
}

function div(className, text) {
  const node = document.createElement("div");
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function place(node, box) {
  node.style.left = box.x + "px";
  node.style.top = box.y + "px";
  if (box.w !== undefined) node.style.width = box.w + "px";
  if (box.h !== undefined) node.style.height = box.h + "px";
}

class PsMap extends HTMLElement {
  connectedCallback() {
    if (this.inner) return;
    this.setAttribute("role", "region");
    this.setAttribute("aria-label", "Policy map");
    this.tabIndex = 0;
    this.inner = div("ps-map-inner");
    this.add(this.inner);
    this.pan = new PanZoom(() => this.applyView());
    this.positions = {};
    this.expandExceptions = false;
    this.autoFit = true;
    this.hover = null;
    this.focused = null;
    this.moving = null;
    this.blast = null;
    this.model = null;
    this.layout = null;
    this.cardEls = new Map();
    this.chipEls = new Map();
    this.bandEls = new Map();
    this.edgeNodes = new Map();
    this.edges = [];
    this.state = "idle";
    bindPointerPan(this, this.pan, (target) => this.isBackground(target));
    bindWheel(this, this.pan);
    this.addEventListener("keydown", (event) => this.onKey(event));
    this.addEventListener("pointerover", (event) => this.onOver(event));
    this.addEventListener("pointerout", (event) => this.onOut(event));
    this.addEventListener("focusin", (event) => this.onFocusIn(event));
    this.addEventListener("focusout", (event) => this.onFocusOut(event));
    this.addEventListener("pointerdown", (event) => this.onCardDown(event));
    this.addEventListener("click", (event) => this.onClick(event), true);
    this.observer = new ResizeObserver(() => {
      if (this.autoFit && this.layout) this.fit();
    });
    this.observer.observe(this);
  }

  disconnectedCallback() {
    if (this.observer) this.observer.disconnect();
    this.inner = null;
    this.observer = null;
  }

  add(node) {
    this.append(node);
    return node;
  }

  isBackground(target) {
    if (!(target instanceof Element)) return true;
    return !target.closest("ps-map-card, .ps-mod, .ps-band-label, .ps-band-toggle, button, a, ps-state, ps-command");
  }

  metrics() {
    const canvas = document.createElement("canvas").getContext("2d");
    const font = getComputedStyle(document.documentElement).getPropertyValue("--font-mono").trim() || "monospace";
    canvas.font = `12px ${font}`;
    const base = defaultMetrics((text) => canvas.measureText(text).width);
    return {
      ...base,
      cardW: px("--card-w", base.cardW),
      cardH: px("--card-h", base.cardH),
      childH: px("--child-h", base.childH),
      colGap: px("--map-col-gap", base.colGap),
      rowGap: px("--map-row-gap", base.rowGap),
      bandH: px("--band-h", base.bandH),
      bandGap: px("--band-gap", base.bandGap),
      bandToGrid: px("--band-to-grid", base.bandToGrid),
      pad: px("--canvas-pad", base.pad),
    };
  }

  reset() {
    this.inner.textContent = "";
    this.cardEls.clear();
    this.chipEls.clear();
    this.bandEls.clear();
    this.edgeNodes.clear();
    this.svg = null;
    this.edges = [];
    this.hover = null;
    this.focused = null;
    this.moving = null;
  }

  applyView() {
    if (!this.inner) return;
    const { x, y, z } = this.pan;
    if (!this.programmatic) this.autoFit = false;
    this.inner.style.transform = `translate(${x}px, ${y}px) scale(${z})`;
    this.style.setProperty("--pan-x", x + "px");
    this.style.setProperty("--pan-y", y + "px");
    this.dispatchEvent(new CustomEvent("ps-map-zoom", { bubbles: true, detail: { z } }));
  }

  fit() {
    const bounds = this.layout ? this.layout.bounds : this.skeleton ? this.skeleton.bounds : null;
    if (!bounds) return;
    this.programmatic = true;
    this.pan.fit(this.clientWidth, this.clientHeight, bounds);
    this.programmatic = false;
  }

  userFit() {
    this.autoFit = true;
    this.fit();
  }

  zoomBy(direction) {
    this.autoFit = false;
    this.pan.zoomStep(direction, this.clientWidth / 2, this.clientHeight / 2);
  }

  get zoom() {
    return this.pan.z;
  }

  showLoading() {
    this.state = "loading";
    this.reset();
    this.layout = null;
    this.setAttribute("aria-busy", "true");
    const metrics = this.metrics();
    this.skeleton = skeletonLayout(metrics);
    this.inner.style.width = this.skeleton.bounds.width + "px";
    this.inner.style.height = this.skeleton.bounds.height + "px";
    for (const band of this.skeleton.bands) {
      const node = div("ps-band");
      node.setAttribute("data-skeleton", "");
      place(node, band);
      const sk = document.createElement("ps-skeleton");
      sk.setAttribute("width", "80px");
      sk.setAttribute("height", "16px");
      sk.className = "ps-band-skeleton";
      node.append(sk);
      this.inner.append(node);
    }
    for (const box of this.skeleton.placeholders) {
      const node = div("ps-skeleton-card");
      place(node, box);
      const sk = document.createElement("ps-skeleton");
      sk.setAttribute("lines", "4");
      node.append(sk);
      this.inner.append(node);
    }
    if (this.autoFit) this.fit();
  }

  showError(config) {
    this.state = "error";
    this.reset();
    this.layout = null;
    this.skeleton = null;
    this.removeAttribute("aria-busy");
    this.inner.style.width = "";
    this.inner.style.height = "";
    this.pan.set(0, 0, 1);
    const wrap = div("ps-map-overlay");
    const state = document.createElement("ps-state");
    state.setAttribute("kind", "error");
    state.setAttribute("heading", config.heading || "The map did not load");
    if (config.body) state.setAttribute("body", config.body);
    if (config.errorId) state.setAttribute("error-id", config.errorId);
    wrap.append(state);
    this.inner.append(wrap);
  }

  setPositions(positions) {
    this.positions = { ...(positions || {}) };
  }

  get savedCount() {
    return Object.keys(this.positions).length;
  }

  clearPositions() {
    this.positions = {};
    if (this.model) this.render(false);
  }

  setData(payload, options = {}) {
    this.state = "ready";
    this.removeAttribute("aria-busy");
    this.skeleton = null;
    this.payload = payload;
    this.model = buildModel(payload);
    this.render(options.fit !== false && !this.hasRendered);
    this.hasRendered = true;
  }

  setBlast(blast) {
    this.blast = blast || null;
    if (this.model) this.render(false);
  }

  setPreview(preview) {
    this.preview = preview || null;
    if (this.model) this.render(false);
  }

  isPreviewed(entry) {
    return Boolean(this.preview) && this.preview.kind === entry.kind && this.preview.id === entry.id;
  }

  blastFlips() {
    const flips = new Map();
    if (!this.blast) return flips;
    for (const project of this.blast.projects || []) {
      if ((project.stricter || 0) + (project.looser || 0) > 0) flips.set(project.id, project);
    }
    return flips;
  }

  render(fitAfter) {
    const model = this.model;
    const metrics = this.metrics();
    this.metricsNow = metrics;
    const hadHover = this.hover;
    this.reset();
    this.layout = computeLayout(model, metrics, { positions: this.positions, expandExceptions: this.expandExceptions });
    const layout = this.layout;
    const bounds = layout.bounds;
    this.inner.style.width = bounds.width + "px";
    this.inner.style.height = bounds.height + "px";
    this.svg = createSvg(bounds.width, bounds.height);
    this.inner.append(this.svg);
    this.edges = buildEdges(layout);
    this.drawBaseEdges();
    this.renderBands(layout);
    this.renderLabels(layout);
    this.renderCards(layout);
    this.renderEmpty(layout);
    this.drawBlast();
    if (fitAfter || this.autoFit) this.fit();
    else {
      this.programmatic = true;
      this.applyView();
      this.programmatic = false;
    }
    if (hadHover) this.hover = null;
    this.announceDefault();
  }

  renderBands(layout) {
    for (const band of layout.bands) {
      const node = div("ps-band");
      node.dataset.band = band.key;
      place(node, band);
      const label = document.createElement("button");
      label.type = "button";
      label.className = "ps-band-label";
      label.dataset.band = band.key;
      const name = document.createElement("span");
      name.className = "ps-band-name";
      name.textContent = band.label;
      const count = document.createElement("span");
      count.className = "num ps-band-count";
      count.textContent = String(band.count);
      label.append(name, count);
      label.setAttribute("aria-label", `${band.label}, ${plural(band.count, "module instance")}`);
      node.append(label);
      this.bandEls.set(band.key, label);
      if (band.expandable && this.expandExceptions) {
        const toggle = document.createElement("button");
        toggle.type = "button";
        toggle.className = "ps-band-toggle";
        toggle.textContent = "Collapse";
        toggle.dataset.toggle = "collapse";
        node.append(toggle);
      }
      this.inner.append(node);
      for (const chip of band.chips) {
        const holder = chip.collapsed ? document.createElement("button") : document.createElement("a");
        holder.className = "ps-mod";
        holder.dataset.chip = chip.key;
        holder.dataset.band = band.key;
        if (chip.collapsed) {
          holder.type = "button";
          holder.dataset.toggle = "expand";
          holder.setAttribute("aria-expanded", "false");
        } else {
          holder.href = `#/detail/module/${encodeURIComponent(chip.id)}`;
        }
        holder.textContent = chip.name;
        holder.title = chip.name;
        holder.setAttribute("aria-label", `${chip.name}, ${band.label.toLowerCase()}, reaches ${plural(chip.reaches.length, "entry", "entries")}`);
        place(holder, { x: chip.x, y: chip.y, w: chip.w, h: chip.h });
        this.inner.append(holder);
        this.chipEls.set(chip.key, holder);
      }
    }
  }

  renderLabels(layout) {
    for (const label of layout.labels) {
      const node = div("ps-group-label", label.text);
      place(node, label);
      this.inner.append(node);
    }
  }

  renderCards(layout) {
    const flips = this.blastFlips();
    for (const card of layout.cards) {
      const node = document.createElement("ps-map-card");
      node.dataset.key = card.key;
      place(node, card);
      node.configure({ entry: card.entry, inherits: this.model.inherits.get(card.key), pinned: card.pinned, blast: this.blast ? flips.get(card.entry.id) : null, preview: this.isPreviewed(card.entry) });
      if (this.blast && flips.has(card.entry.id)) node.setAttribute("data-flip", "");
      node.toggleAttribute("data-preview", this.isPreviewed(card.entry));
      this.inner.append(node);
      this.cardEls.set(card.key, node);
      card.children.forEach((child) => {
        const childNode = document.createElement("ps-map-card");
        childNode.dataset.key = child.key;
        childNode.dataset.parent = card.key;
        place(childNode, child);
        childNode.configure({ child: true, glob: child.glob, matched: child.matched });
        this.inner.append(childNode);
        this.cardEls.set(child.key, childNode);
      });
    }
  }

  renderEmpty(layout) {
    if (!layout.emptyBox) return;
    const wrap = div("ps-map-empty");
    place(wrap, layout.emptyBox);
    const state = document.createElement("ps-state");
    state.setAttribute("kind", "empty_first_run");
    state.setAttribute("heading", "No projects are governed yet");
    state.setAttribute("body", "Put a git repository under polispec in a terminal.");
    state.setAttribute("action", "Register a path");
    const command = document.createElement("ps-command");
    command.setAttribute("command", "polispec apply environment-control --repo <path> --variant service");
    state.append(command);
    wrap.append(state);
    this.inner.append(wrap);
  }

  edgesHidden() {
    return this.edges.length > EDGE_HIDE_ABOVE;
  }

  drawBaseEdges() {
    this.svg.textContent = "";
    this.edgeNodes = new Map();
    if (this.edgesHidden()) return;
    this.edgeNodes = renderEdges(this.svg, this.edges);
  }

  drawBlast() {
    if (!this.blast) return;
    const flips = this.blastFlips();
    const list = blastEdges(this.layout, this.blast.source, flips);
    this.blastList = list;
    const nodes = renderEdges(this.svg, list, { append: true });
    for (const [key, node] of nodes) {
      node.classList.add("ps-edge-pulse");
      this.edgeNodes.set(key, node);
    }
  }

  targetOf(node) {
    if (!(node instanceof Element)) return null;
    const chip = node.closest("[data-chip]");
    if (chip) return { type: "chip", key: chip.dataset.chip };
    const band = node.closest(".ps-band-label");
    if (band) return { type: "band", key: band.dataset.band };
    const card = node.closest("ps-map-card");
    if (card) return { type: "card", key: card.dataset.parent || card.dataset.key };
    return null;
  }

  onOver(event) {
    const target = this.targetOf(event.target);
    this.setHover(target);
  }

  onOut(event) {
    const into = this.targetOf(event.relatedTarget);
    if (!into) this.setHover(null);
  }

  onFocusIn(event) {
    const target = this.targetOf(event.target);
    this.focused = target;
    this.applyHot();
    const card = event.target.closest && event.target.closest("ps-map-card");
    if (card && this.layout && !event.target.matches(":hover")) this.revealKey(card.dataset.key);
  }

  onFocusOut(event) {
    if (!this.contains(event.relatedTarget)) this.focused = null;
    else this.focused = this.targetOf(event.relatedTarget);
    this.applyHot();
  }

  setHover(target) {
    const same = (this.hover && target && this.hover.type === target.type && this.hover.key === target.key) || (!this.hover && !target);
    if (same) return;
    this.hover = target;
    this.applyHot();
  }

  revealKey(key) {
    const card = this.layout.cards.find((item) => item.key === key);
    if (!card) return;
    const before = this.pan.x + "," + this.pan.y;
    this.pan.reveal({ x: card.x, y: card.y, w: card.w, h: card.h }, this.clientWidth, this.clientHeight);
    if (before !== this.pan.x + "," + this.pan.y) this.autoFit = false;
  }

  related(target) {
    const cards = new Set();
    const chips = new Set();
    const bands = new Set();
    const edgeKeys = new Set();
    const model = this.model;
    if (!target) return { cards, chips, bands, edgeKeys };
    const allChips = this.layout.bands.flatMap((band) => band.chips);
    if (target.type === "card") {
      const card = this.layout.cards.find((item) => item.key === target.key);
      cards.add(target.key);
      if (card) for (const child of card.children) cards.add(child.key);
      const reach = model.reachByEntry.get(target.key) || new Set();
      for (const chip of allChips) {
        const hit = chip.collapsed ? chip.reaches.includes(target.key) : reach.has(chip.key);
        if (hit) {
          chips.add(chip.key);
          bands.add(chip.band);
          edgeKeys.add(chip.key + ">" + target.key);
        }
      }
      if (this.blast) edgeKeys.add("blast>" + (card ? card.entry.id : ""));
    } else if (target.type === "chip") {
      const chip = allChips.find((item) => item.key === target.key);
      if (chip) {
        chips.add(chip.key);
        bands.add(chip.band);
        for (const key of chip.reaches) {
          cards.add(key);
          const card = this.layout.cards.find((item) => item.key === key);
          if (card) for (const child of card.children) cards.add(child.key);
          edgeKeys.add(chip.key + ">" + key);
        }
      }
    } else if (target.type === "band") {
      bands.add(target.key);
      for (const chip of allChips.filter((item) => item.band === target.key)) {
        chips.add(chip.key);
        for (const key of chip.reaches) {
          cards.add(key);
          const card = this.layout.cards.find((item) => item.key === key);
          if (card) for (const child of card.children) cards.add(child.key);
          edgeKeys.add(chip.key + ">" + key);
        }
      }
    }
    return { cards, chips, bands, edgeKeys };
  }

  applyHot() {
    if (!this.layout) return;
    const target = this.hover || this.focused;
    const set = this.related(target);
    this.hot = set;
    for (const [key, node] of this.cardEls) {
      if (set.cards.has(key)) node.setAttribute("data-related", "");
      else node.removeAttribute("data-related");
      if (target && target.type === "card" && (key === target.key)) node.setAttribute("data-hot", "");
      else node.removeAttribute("data-hot");
    }
    for (const [key, node] of this.chipEls) {
      if (set.chips.has(key)) node.setAttribute("data-related", "");
      else node.removeAttribute("data-related");
    }
    for (const [key, node] of this.bandEls) {
      if (set.bands.has(key)) node.setAttribute("data-related", "");
      else node.removeAttribute("data-related");
    }
    this.paintEdges(set, target);
    this.announceTarget(target);
  }

  paintEdges(set, target) {
    if (!this.svg) return;
    if (this.edgesHidden()) {
      for (const [key, node] of [...this.edgeNodes]) {
        if (!key.startsWith("blast>")) {
          node.remove();
          this.edgeNodes.delete(key);
        }
      }
      if (!target) return;
      const wanted = this.edges.filter((edge) => set.edgeKeys.has(edge.key));
      const nodes = renderEdges(this.svg, wanted, { append: true });
      for (const [key, node] of nodes) {
        node.setAttribute("data-hot", "");
        this.edgeNodes.set(key, node);
      }
      return;
    }
    for (const [key, node] of this.edgeNodes) {
      if (key.startsWith("blast>")) continue;
      if (set.edgeKeys.has(key)) {
        node.setAttribute("data-hot", "");
        this.svg.append(node);
      } else {
        node.removeAttribute("data-hot");
      }
    }
  }

  announceDefault() {
    this.dispatchEvent(new CustomEvent("ps-map-inspect", { bubbles: true, detail: { text: this.defaultText() } }));
  }

  defaultText() {
    if (this.edgesHidden()) return `Edges show on hover; ${this.edges.length} edges`;
    return "";
  }

  announceTarget(target) {
    let text = this.defaultText();
    const model = this.model;
    if (target && model) {
      if (target.type === "card") {
        const entry = model.byKey.get(target.key);
        const inh = model.inherits.get(target.key);
        if (entry && inh) {
          text = `${entry.id} inherits ${plural(inh.shipped, "shipped module")}, ${plural(inh.global, "shelf module")}, and ${plural(inh.exceptions, "exception")}`;
        }
      } else if (target.type === "chip") {
        const chip = this.layout.bands.flatMap((band) => band.chips).find((item) => item.key === target.key);
        if (chip) text = `${chip.name} (${BANDS.find((band) => band.key === chip.band).plural}) reaches ${this.describeReach(chip.reaches)}`;
      } else if (target.type === "band") {
        const band = this.layout.bands.find((item) => item.key === target.key);
        const reached = new Set();
        for (const chip of band.chips) for (const key of chip.reaches) reached.add(key);
        text = `${band.label}: ${plural(band.count, "module instance")} reach ${this.describeReach([...reached])}`;
      }
    }
    this.dispatchEvent(new CustomEvent("ps-map-inspect", { bubbles: true, detail: { text } }));
  }

  describeReach(keys) {
    let projects = 0;
    let paths = 0;
    for (const key of keys) {
      const entry = this.model.byKey.get(key);
      if (!entry) continue;
      if (entry.kind === "path") paths += 1;
      else projects += 1;
    }
    if (!paths) return plural(projects, "project");
    if (!projects) return plural(paths, "path entry", "path entries");
    return `${plural(projects, "project")} and ${plural(paths, "path entry", "path entries")}`;
  }

  onClick(event) {
    if (this.justDragged && performance.now() - this.justDragged < 400) {
      event.preventDefault();
      event.stopPropagation();
      this.justDragged = 0;
      return;
    }
    const toggle = event.target.closest && event.target.closest("[data-toggle]");
    if (toggle) {
      event.preventDefault();
      this.expandExceptions = toggle.dataset.toggle === "expand";
      this.render(false);
      const next = this.inner.querySelector(this.expandExceptions ? ".ps-band-toggle" : "[data-chip='" + COLLAPSED_KEY + "']");
      if (next) next.focus();
    }
  }

  onCardDown(event) {
    if (event.button !== 0 || this.moving) return;
    const head = event.target.closest && event.target.closest(".ps-head");
    const cardEl = head && head.closest("ps-map-card");
    if (!cardEl || cardEl.hasAttribute("data-child")) return;
    const key = cardEl.dataset.key;
    const card = this.layout.cards.find((item) => item.key === key);
    if (!card) return;
    const drag = { id: event.pointerId, startX: event.clientX, startY: event.clientY, x: card.x, y: card.y, active: false, key };
    const move = (ev) => {
      if (ev.pointerId !== drag.id) return;
      const dx = ev.clientX - drag.startX;
      const dy = ev.clientY - drag.startY;
      if (!drag.active && Math.hypot(dx, dy) < DRAG_THRESHOLD) return;
      drag.active = true;
      this.autoFit = false;
      this.moveCard(key, drag.x + dx / this.pan.z, drag.y + dy / this.pan.z);
    };
    const up = (ev) => {
      if (ev.pointerId !== drag.id) return;
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", up);
      if (drag.active) {
        this.justDragged = performance.now();
        this.commitMove(key);
      }
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
  }

  moveCard(key, x, y) {
    const card = this.layout.cards.find((item) => item.key === key);
    if (!card) return;
    const dx = x - card.x;
    const dy = y - card.y;
    card.x = x;
    card.y = y;
    place(this.cardEls.get(key), card);
    for (const child of card.children) {
      child.x += dx;
      child.y += dy;
      place(this.cardEls.get(child.key), child);
    }
    for (const edge of this.edges) {
      if (edge.card !== key) continue;
      edge.x2 = card.x + card.w / 2;
      edge.y2 = card.y;
      const node = this.edgeNodes.get(edge.key);
      if (node) node.setAttribute("d", pathD(edge));
    }
    if (this.blastList) {
      for (const edge of this.blastList) {
        if (edge.card !== key) continue;
        edge.x2 = card.x + card.w / 2;
        edge.y2 = card.y;
        const node = this.edgeNodes.get(edge.key);
        if (node) node.setAttribute("d", pathD(edge));
      }
    }
  }

  commitMove(key) {
    const card = this.layout.cards.find((item) => item.key === key);
    if (!card) return;
    this.positions[key] = { x: Math.round(card.x), y: Math.round(card.y) };
    card.pinned = true;
    const node = this.cardEls.get(key);
    const flips = this.blastFlips();
    node.configure({ entry: card.entry, inherits: this.model.inherits.get(key), pinned: true, blast: this.blast ? flips.get(card.entry.id) : null, preview: this.isPreviewed(card.entry) });
    this.dispatchEvent(new CustomEvent("ps-map-positions", { bubbles: true, detail: { positions: { ...this.positions } } }));
  }

  startMove(key) {
    const card = this.layout.cards.find((item) => item.key === key);
    if (!card) return;
    this.moving = { key, x: card.x, y: card.y, saved: this.positions[key] ? { ...this.positions[key] } : null };
    this.cardEls.get(key).setAttribute("data-moving", "");
    announce(`Moving ${card.entry.id}. Arrow keys move, Enter saves, Escape cancels.`);
  }

  endMove(save) {
    const info = this.moving;
    if (!info) return;
    this.moving = null;
    const node = this.cardEls.get(info.key);
    node.removeAttribute("data-moving");
    const name = this.layout.cards.find((item) => item.key === info.key).entry.id;
    if (save) {
      this.commitMove(info.key);
      announce(`Saved position of ${name}.`);
    } else {
      this.moveCard(info.key, info.x, info.y);
      announce(`Move of ${name} cancelled.`);
    }
    const link = node.querySelector(".ps-name");
    if (link) link.focus();
  }

  onKey(event) {
    if (this.moving) {
      const step = event.shiftKey ? MOVE_STEP_FAST : MOVE_STEP;
      const card = this.layout.cards.find((item) => item.key === this.moving.key);
      let handled = true;
      if (event.key === "ArrowLeft") this.moveCard(card.key, card.x - step, card.y);
      else if (event.key === "ArrowRight") this.moveCard(card.key, card.x + step, card.y);
      else if (event.key === "ArrowUp") this.moveCard(card.key, card.x, card.y - step);
      else if (event.key === "ArrowDown") this.moveCard(card.key, card.x, card.y + step);
      else if (event.key === "Enter") this.endMove(true);
      else if (event.key === "Escape") this.endMove(false);
      else handled = false;
      if (handled) {
        event.preventDefault();
        event.stopPropagation();
        if (this.moving) this.revealKey(card.key);
      }
      return;
    }
    const cardEl = event.target.closest && event.target.closest("ps-map-card");
    if (cardEl && !cardEl.hasAttribute("data-child") && (event.key === "m" || event.key === "M") && !event.ctrlKey && !event.metaKey && !event.altKey) {
      event.preventDefault();
      event.stopPropagation();
      this.autoFit = false;
      this.startMove(cardEl.dataset.key);
      return;
    }
    if (event.target !== this) return;
    const step = (event.shiftKey ? PAN_STEP_FAST : PAN_STEP) * this.pan.z;
    let handled = true;
    switch (event.key) {
      case "ArrowLeft":
        this.pan.panBy(step, 0);
        break;
      case "ArrowRight":
        this.pan.panBy(-step, 0);
        break;
      case "ArrowUp":
        this.pan.panBy(0, step);
        break;
      case "ArrowDown":
        this.pan.panBy(0, -step);
        break;
      case "+":
      case "=":
        this.zoomBy(1);
        break;
      case "-":
        this.zoomBy(-1);
        break;
      case "0":
        this.userFit();
        break;
      default:
        handled = false;
    }
    if (handled) {
      event.preventDefault();
      event.stopPropagation();
    }
  }
}

if (!customElements.get("ps-map")) customElements.define("ps-map", PsMap);
