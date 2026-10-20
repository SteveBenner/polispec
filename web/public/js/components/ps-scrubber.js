const PAD = 12;
const MIN_STEP = 4;
const LABEL_GAP = 4;
const CHAR_WIDTH = 6.6;

let sequence = 0;

function short(ref) {
  return String(ref).slice(0, 8);
}

class PsScrubber extends HTMLElement {
  connectedCallback() {
    if (this.region) return;
    sequence += 1;
    this.uid = `ps-scrubber-${sequence}`;
    this.items = this.items || [];
    this.a = this.a ?? 0;
    this.b = this.b ?? Math.max(0, this.items.length - 1);
    this.region = document.createElement("div");
    this.region.className = "ps-region";
    this.region.setAttribute("role", "group");
    this.region.setAttribute("aria-label", this.getAttribute("label") || "History range");
    this.track = document.createElement("div");
    this.track.className = "ps-track";
    this.region.append(this.track);
    this.readouts = document.createElement("div");
    this.readouts.className = "ps-readouts";
    this.readoutA = document.createElement("span");
    this.readoutA.className = "ps-readout mono";
    this.readoutB = document.createElement("span");
    this.readoutB.className = "ps-readout mono";
    this.readouts.append(this.readoutA, this.readoutB);
    this.pickers = document.createElement("div");
    this.pickers.className = "ps-pickers";
    this.pickerA = document.createElement("ps-select");
    this.pickerA.setAttribute("label", "From ref");
    this.pickerB = document.createElement("ps-select");
    this.pickerB.setAttribute("label", "To ref");
    this.pickers.append(this.pickerA, this.pickerB);
    this.append(this.region, this.readouts, this.pickers);
    this.pickers.hidden = this.hasAttribute("no-pickers");
    this.pickerA.addEventListener("ps-change", (event) => {
      event.stopPropagation();
      this.setIndex("a", this.items.findIndex((item) => item.ref === event.detail.value), true);
    });
    this.pickerB.addEventListener("ps-change", (event) => {
      event.stopPropagation();
      this.setIndex("b", this.items.findIndex((item) => item.ref === event.detail.value), true);
    });
    this.track.addEventListener("pointerdown", (event) => this.onTrackPointer(event));
    this.observer = new ResizeObserver(() => this.layout());
    this.observer.observe(this.region);
    this.rebuild();
  }

  disconnectedCallback() {
    this.observer?.disconnect();
  }

  get commits() {
    return this.items;
  }

  set commits(list) {
    this.items = list || [];
    this.a = Math.min(this.a ?? 0, Math.max(0, this.items.length - 2));
    this.b = this.items.length - 1;
    if (this.region) this.rebuild();
  }

  get range() {
    return { a: this.a, b: this.b };
  }

  set range(value) {
    this.a = value.a;
    this.b = value.b;
    if (this.region) this.sync(false);
  }

  count() {
    return this.items.length;
  }

  x(index) {
    const n = this.count();
    if (n < 2) return PAD;
    return PAD + (index * (this.innerWidth - 2 * PAD)) / (n - 1);
  }

  rebuild() {
    this.track.textContent = "";
    const n = this.count();
    if (n === 0) {
      this.track.textContent = "No history";
      this.track.classList.add("ps-empty");
      return;
    }
    this.track.classList.remove("ps-empty");
    this.line = document.createElement("div");
    this.line.className = "ps-line";
    this.band = document.createElement("div");
    this.band.className = "ps-band";
    this.track.append(this.line, this.band);
    this.ticks = this.items.map((item, index) => {
      const tick = document.createElement("div");
      tick.className = item.tag ? "ps-tick ps-tag" : "ps-tick";
      tick.dataset.index = String(index);
      tick.title = `${short(item.ref)}${item.tag ? ` ${item.tag}` : ""} ${item.date || ""}`.trim();
      if (item.tag) {
        const label = document.createElement("span");
        label.className = "ps-tag-label mono";
        label.textContent = item.tag;
        tick.append(label);
      }
      this.track.append(tick);
      return tick;
    });
    this.thumbA = this.makeThumb("a", "From ref");
    this.thumbB = this.makeThumb("b", "To ref");
    this.track.append(this.thumbA, this.thumbB);
    const options = this.items.map((item) => ({ value: item.ref, label: `${short(item.ref)} ${item.tag || item.date || ""}`.trim() }));
    this.pickerA.options = options;
    this.pickerB.options = options;
    this.layout();
  }

  makeThumb(which, label) {
    const thumb = document.createElement("div");
    thumb.className = "ps-thumb";
    thumb.tabIndex = 0;
    thumb.setAttribute("role", "slider");
    thumb.setAttribute("aria-label", label);
    thumb.setAttribute("aria-orientation", "horizontal");
    thumb.dataset.thumb = which;
    thumb.addEventListener("keydown", (event) => this.onKey(event, which));
    thumb.addEventListener("pointerdown", (event) => {
      event.preventDefault();
      event.stopPropagation();
      thumb.focus();
      thumb.setPointerCapture(event.pointerId);
      thumb.dataset.dragging = "true";
    });
    thumb.addEventListener("pointermove", (event) => {
      if (thumb.dataset.dragging) this.setIndex(which, this.indexAt(event.clientX), true);
    });
    const end = () => {
      delete thumb.dataset.dragging;
    };
    thumb.addEventListener("pointerup", end);
    thumb.addEventListener("pointercancel", end);
    return thumb;
  }

  layout() {
    const n = this.count();
    if (n === 0) return;
    const width = this.region.clientWidth;
    const needed = (n - 1) * MIN_STEP + 2 * PAD;
    this.innerWidth = Math.max(width, needed);
    this.track.style.width = `${this.innerWidth}px`;
    this.line.style.left = `${PAD}px`;
    this.line.style.width = `${this.innerWidth - 2 * PAD}px`;
    let lastRight = -Infinity;
    this.ticks.forEach((tick, index) => {
      tick.style.left = `${this.x(index)}px`;
      const label = tick.firstElementChild;
      if (label) {
        const half = (this.items[index].tag.length * CHAR_WIDTH + 4) / 2;
        const left = this.x(index) - half;
        const fits = left >= lastRight + LABEL_GAP && left >= 0 && this.x(index) + half <= this.innerWidth;
        label.classList.toggle("ps-thinned", !fits);
        if (fits) lastRight = this.x(index) + half;
      }
    });
    this.sync(false);
  }

  indexAt(clientX) {
    const rect = this.track.getBoundingClientRect();
    const n = this.count();
    const ratio = (clientX - rect.left - PAD) / (this.innerWidth - 2 * PAD);
    return Math.max(0, Math.min(n - 1, Math.round(ratio * (n - 1))));
  }

  onTrackPointer(event) {
    if (event.target.closest(".ps-thumb") || this.count() < 2) return;
    const index = this.indexAt(event.clientX);
    const which = Math.abs(index - this.a) <= Math.abs(index - this.b) ? "a" : "b";
    this.setIndex(which, index, true);
    (which === "a" ? this.thumbA : this.thumbB).focus();
  }

  setIndex(which, index, emit) {
    const n = this.count();
    if (n === 0 || index < 0) return;
    let next = Math.max(0, Math.min(n - 1, index));
    if (n > 1) {
      if (which === "a") next = Math.min(next, this.b - 1);
      else next = Math.max(next, this.a + 1);
    }
    next = Math.max(0, Math.min(n - 1, next));
    if (this[which] === next) {
      this.sync(false);
      return;
    }
    this[which] = next;
    this.sync(true);
    if (emit) this.dispatchEvent(new CustomEvent("ps-scrub", { bubbles: true, detail: { a: this.a, b: this.b } }));
  }

  neighbourTag(from, step) {
    for (let i = from + step; i >= 0 && i < this.count(); i += step) {
      if (this.items[i].tag) return i;
    }
    return step > 0 ? this.count() - 1 : 0;
  }

  onKey(event, which) {
    const current = this[which];
    let target = null;
    if (event.key === "ArrowRight") target = current + 1;
    else if (event.key === "ArrowLeft") target = current - 1;
    else if (event.key === "PageUp") target = this.neighbourTag(current, -1);
    else if (event.key === "PageDown") target = this.neighbourTag(current, 1);
    else if (event.key === "Home") target = 0;
    else if (event.key === "End") target = this.count() - 1;
    else if (event.key === "Enter") {
      event.preventDefault();
      this.dispatchEvent(new CustomEvent("ps-apply", { bubbles: true, detail: { a: this.a, b: this.b } }));
      return;
    }
    if (target === null) return;
    event.preventDefault();
    this.setIndex(which, target, true);
  }

  sync(reveal) {
    const n = this.count();
    if (n === 0 || !this.thumbA) return;
    const place = (thumb, index) => {
      thumb.style.left = `${this.x(index)}px`;
      const item = this.items[index];
      thumb.setAttribute("aria-valuemin", "0");
      thumb.setAttribute("aria-valuemax", String(n - 1));
      thumb.setAttribute("aria-valuenow", String(index));
      thumb.setAttribute("aria-valuetext", [short(item.ref), item.tag, item.date].filter(Boolean).join(", "));
    };
    place(this.thumbA, this.a);
    place(this.thumbB, this.b);
    this.band.style.left = `${this.x(this.a)}px`;
    this.band.style.width = `${this.x(this.b) - this.x(this.a)}px`;
    const itemA = this.items[this.a];
    const itemB = this.items[this.b];
    this.readoutA.textContent = `A: ${short(itemA.ref)} ${itemA.date || ""}`.trim();
    this.readoutB.textContent = `B: ${short(itemB.ref)} ${itemB.date || ""}`.trim();
    this.pickerA.value = itemA.ref;
    this.pickerB.value = itemB.ref;
    if (reveal) {
      const thumb = document.activeElement === this.thumbB ? this.thumbB : this.thumbA;
      const index = thumb === this.thumbB ? this.b : this.a;
      const x = this.x(index);
      const left = this.region.scrollLeft;
      const width = this.region.clientWidth;
      if (x - PAD < left) this.region.scrollLeft = Math.max(0, x - PAD);
      else if (x + PAD > left + width) this.region.scrollLeft = x + PAD - width;
    }
  }
}

customElements.define("ps-scrubber", PsScrubber);
