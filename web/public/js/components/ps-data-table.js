const NS = "http://www.w3.org/2000/svg";
const VIRTUAL_THRESHOLD = 500;
const OVERSCAN = 20;
const SKELETON_ROWS = 8;
const SKELETON_DELAY = 200;
const STILL_LOADING = 5000;
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

function textOf(value) {
  if (value == null) return "";
  if (value instanceof Node) return value.textContent;
  return String(value);
}

class PsDataTable extends HTMLElement {
  static observedAttributes = ["caption", "compact", "state", "show-caption", "openable", "expandable", "height"];

  connectedCallback() {
    if (this.scroller) return;
    sequence += 1;
    this.uid = `ps-table-${sequence}`;
    this.cols = this.cols || [];
    this.items = this.items || [];
    this.sortState = null;
    this.expanded = new Set();
    this.selectedIndex = -1;
    this.partialInfo = this.partialInfo || null;
    this.emptyConfig = this.emptyConfig || { kind: "empty_first_run", heading: "Nothing here yet" };
    this.errorConfig = this.errorConfig || { heading: "Rows did not load" };
    this.scroller = document.createElement("div");
    this.scroller.className = "ps-table-scroll";
    this.scroller.setAttribute("role", "region");
    this.scroller.tabIndex = 0;
    this.table = document.createElement("table");
    this.captionEl = document.createElement("caption");
    this.colgroup = document.createElement("colgroup");
    this.thead = document.createElement("thead");
    this.tbody = document.createElement("tbody");
    this.table.append(this.captionEl, this.colgroup, this.thead, this.tbody);
    this.scroller.append(this.table);
    this.append(this.scroller);
    this.scroller.addEventListener("keydown", (event) => this.onKey(event));
    this.scroller.addEventListener("scroll", () => {
      if (this.virtual()) this.renderBody();
    });
    this.tbody.addEventListener("click", (event) => this.onBodyClick(event));
    this.thead.addEventListener("click", (event) => {
      const button = event.target.closest("[data-sort]");
      if (button) this.toggleSort(button.dataset.sort);
    });
    this.renderAll();
    if (this.state() === "loading") this.applyState("loading");
  }

  disconnectedCallback() {
    clearTimeout(this.skeletonTimer);
    clearInterval(this.stillTimer);
  }

  attributeChangedCallback(name, oldValue, value) {
    if (!this.scroller) return;
    if (name === "state") this.applyState(value);
    else this.renderAll();
  }

  get columns() {
    return this.cols;
  }

  set columns(list) {
    this.cols = list;
    if (this.scroller) this.renderAll();
  }

  get rows() {
    return this.items;
  }

  set rows(list) {
    this.items = list || [];
    this.selectedIndex = -1;
    if (this.scroller) this.renderBody();
  }

  get partial() {
    return this.partialInfo;
  }

  set partial(value) {
    this.partialInfo = value;
    if (this.scroller) this.renderBody();
  }

  get emptyState() {
    return this.emptyConfig;
  }

  set emptyState(value) {
    this.emptyConfig = value;
    if (this.scroller) this.renderBody();
  }

  get errorState() {
    return this.errorConfig;
  }

  set errorState(value) {
    this.errorConfig = value;
    if (this.scroller) this.renderBody();
  }

  get selected() {
    return this.selectedIndex;
  }

  rowKey(row, index) {
    const key = this.keyField;
    if (typeof key === "function") return key(row);
    if (key) return row[key];
    return index;
  }

  set keyBy(value) {
    this.keyField = value;
  }

  rowHeight() {
    const name = this.hasAttribute("compact") ? "--row-compact" : "--row";
    return parseFloat(getComputedStyle(document.documentElement).getPropertyValue(name)) || 28;
  }

  virtual() {
    return this.state() === "ready" && this.items.length > VIRTUAL_THRESHOLD;
  }

  state() {
    return this.getAttribute("state") || "ready";
  }

  applyState(value) {
    clearTimeout(this.skeletonTimer);
    clearInterval(this.stillTimer);
    this.showSkeleton = false;
    this.loadingSeconds = 0;
    if (value === "loading") {
      this.loadStart = Date.now();
      this.skeletonTimer = setTimeout(() => {
        this.showSkeleton = true;
        this.renderAll();
      }, SKELETON_DELAY);
      this.stillTimer = setInterval(() => {
        if (Date.now() - this.loadStart >= STILL_LOADING) {
          this.loadingSeconds = Math.floor((Date.now() - this.loadStart) / 1000);
          this.renderCaption();
        }
      }, 1000);
    }
    this.renderAll();
  }

  sorted() {
    if (!this.sortState) return this.items;
    const { key, dir } = this.sortState;
    const column = this.cols.find((entry) => entry.key === key);
    const read = (row) => (column && column.sortValue ? column.sortValue(row) : row[key]);
    const list = [...this.items];
    list.sort((a, b) => {
      const left = read(a);
      const right = read(b);
      const both = typeof left === "number" && typeof right === "number";
      const result = both ? left - right : String(left ?? "").localeCompare(String(right ?? ""), undefined, { numeric: true });
      return dir === "asc" ? result : -result;
    });
    return list;
  }

  toggleSort(key) {
    if (this.sortState && this.sortState.key === key) {
      this.sortState = this.sortState.dir === "asc" ? { key, dir: "desc" } : null;
    } else {
      this.sortState = { key, dir: "asc" };
    }
    this.renderHead();
    this.renderBody();
    this.dispatchEvent(new CustomEvent("ps-sort", { bubbles: true, detail: this.sortState }));
    const button = this.thead.querySelector(`[data-sort="${key}"]`);
    button?.focus();
  }

  renderAll() {
    this.scroller.setAttribute("aria-label", this.getAttribute("caption") || "Table");
    this.toggleAttribute("data-virtual", this.virtual());
    this.renderCaption();
    this.renderColgroup();
    this.renderHead();
    this.renderBody();
  }

  renderCaption() {
    const base = this.getAttribute("caption") || "Table";
    let text = base;
    if (this.state() === "loading") {
      text = this.loadingSeconds ? `${base}. Still loading, ${this.loadingSeconds} s` : `${base}. Loading`;
    }
    this.captionEl.textContent = text;
    this.captionEl.classList.toggle("visually-hidden", !this.hasAttribute("show-caption"));
    if (this.state() === "loading") this.table.setAttribute("aria-busy", "true");
    else this.table.removeAttribute("aria-busy");
  }

  leading() {
    return this.hasAttribute("expandable") ? 1 : 0;
  }

  span() {
    return this.cols.length + this.leading();
  }

  renderColgroup() {
    this.colgroup.textContent = "";
    if (this.leading()) {
      const col = document.createElement("col");
      col.style.width = "28px";
      this.colgroup.append(col);
    }
    let total = this.leading() ? 28 : 0;
    let allFixed = true;
    for (const column of this.cols) {
      const col = document.createElement("col");
      if (column.width) col.style.width = column.width;
      this.colgroup.append(col);
      if (/px$/.test(column.width || "")) total += parseFloat(column.width);
      else allFixed = false;
    }
    this.table.style.minWidth = allFixed && total ? `${total}px` : "";
  }

  renderHead() {
    this.thead.textContent = "";
    const row = document.createElement("tr");
    if (this.leading()) {
      const th = document.createElement("th");
      th.scope = "col";
      th.className = "ps-lead";
      const hidden = document.createElement("span");
      hidden.className = "visually-hidden";
      hidden.textContent = "Expand";
      th.append(hidden);
      row.append(th);
    }
    for (const column of this.cols) {
      const th = document.createElement("th");
      th.scope = "col";
      th.dataset.align = column.align === "end" ? "end" : "start";
      if (column.sortable) {
        const active = this.sortState && this.sortState.key === column.key;
        th.setAttribute("aria-sort", active ? (this.sortState.dir === "asc" ? "ascending" : "descending") : "none");
        const button = document.createElement("button");
        button.type = "button";
        button.className = "ps-native ps-sort";
        button.dataset.sort = column.key;
        if (active && column.align === "end") button.append(icon(this.sortState.dir === "asc" ? "sort-asc" : "sort-desc"));
        const label = document.createElement("span");
        label.textContent = column.label;
        button.append(label);
        if (active && column.align !== "end") button.append(icon(this.sortState.dir === "asc" ? "sort-asc" : "sort-desc"));
        th.append(button);
      } else {
        th.textContent = column.label;
      }
      row.append(th);
    }
    this.thead.append(row);
  }

  fullRow(node, className) {
    const tr = document.createElement("tr");
    tr.className = className;
    const td = document.createElement("td");
    td.colSpan = Math.max(1, this.span());
    td.append(node);
    tr.append(td);
    return tr;
  }

  renderBody() {
    const top = this.scroller.scrollTop;
    const viewHeight = Math.max(this.scroller.clientHeight, 480);
    const rowH = this.rowHeight();
    this.tbody.textContent = "";
    const state = this.state();
    this.toggleAttribute("data-virtual", this.virtual());
    if (state === "loading") {
      if (!this.showSkeleton && !this.items.length) return;
      if (this.showSkeleton) {
        for (let r = 0; r < SKELETON_ROWS; r += 1) {
          const tr = document.createElement("tr");
          tr.className = "ps-skeleton-row";
          for (let c = 0; c < this.span(); c += 1) {
            const td = document.createElement("td");
            const block = document.createElement("ps-skeleton");
            block.setAttribute("width", `${60 + ((r * 7 + c * 13) % 5) * 5}%`);
            td.append(block);
            tr.append(td);
          }
          this.tbody.append(tr);
        }
        return;
      }
    }
    if (state === "error") {
      const node = document.createElement("ps-state");
      node.setAttribute("kind", "error");
      for (const [name, value] of Object.entries(this.errorConfig)) node.setAttribute(name, value);
      this.tbody.append(this.fullRow(node, "ps-state-row"));
      return;
    }
    if (state === "empty" || (state !== "loading" && !this.items.length)) {
      const node = document.createElement("ps-state");
      for (const [name, value] of Object.entries(this.emptyConfig)) node.setAttribute(name, value);
      this.tbody.append(this.fullRow(node, "ps-state-row"));
      return;
    }
    if (state === "partial" && this.partialInfo) {
      const banner = document.createElement("ps-banner");
      banner.setAttribute("severity", "warn");
      banner.setAttribute("text", `${this.partialInfo.failed} of ${this.partialInfo.total} ${this.partialInfo.noun || "projects"} did not respond.`);
      banner.setAttribute("action", "Retry");
      banner.addEventListener("ps-action", () => {
        this.dispatchEvent(new CustomEvent("ps-retry", { bubbles: true, detail: { partial: true } }));
      });
      this.tbody.append(this.fullRow(banner, "ps-banner-row"));
    }
    const list = this.sorted();
    this.displayed = list;
    let start = 0;
    let end = list.length;
    if (this.virtual()) {
      const visible = Math.ceil(viewHeight / rowH);
      start = Math.max(0, Math.floor(top / rowH) - OVERSCAN);
      end = Math.min(list.length, Math.floor(top / rowH) + visible + OVERSCAN);
      this.tbody.append(this.spacer(start * rowH));
    }
    for (let index = start; index < end; index += 1) {
      this.renderRow(list[index], index);
    }
    if (this.virtual()) this.tbody.append(this.spacer((list.length - end) * rowH));
  }

  spacer(height) {
    const tr = document.createElement("tr");
    tr.className = "ps-spacer";
    tr.setAttribute("aria-hidden", "true");
    tr.style.height = `${height}px`;
    const td = document.createElement("td");
    td.colSpan = Math.max(1, this.span());
    tr.append(td);
    return tr;
  }

  renderRow(row, index) {
    const key = this.rowKey(row, index);
    const tr = document.createElement("tr");
    tr.dataset.index = String(index);
    if (index === this.selectedIndex) tr.setAttribute("aria-current", "true");
    if (this.leading()) {
      const td = document.createElement("td");
      td.className = "ps-lead";
      const open = this.expanded.has(key);
      const button = document.createElement("ps-icon-button");
      button.setAttribute("icon", open ? "chevron-down" : "chevron-right");
      button.setAttribute("label", open ? "Collapse row" : "Expand row");
      button.setAttribute("size", "sm");
      button.setAttribute("expanded", open ? "true" : "false");
      button.setAttribute("controls", `${this.uid}-detail-${index}`);
      button.dataset.toggle = String(index);
      td.append(button);
      tr.append(td);
      button.addEventListener("click", () => this.toggleRow(row, index));
    }
    this.cols.forEach((column, columnIndex) => {
      const td = document.createElement("td");
      if (column.align === "end") td.classList.add("num");
      if (column.mono) td.classList.add("mono");
      const value = column.render ? column.render(row) : row[column.key];
      const text = textOf(value);
      if (columnIndex === 0 && this.hasAttribute("openable")) {
        const opener = document.createElement("button");
        opener.type = "button";
        opener.className = "ps-native ps-open";
        opener.dataset.open = String(index);
        if (value instanceof Node) opener.append(value);
        else opener.textContent = text;
        td.append(opener);
      } else if (value instanceof Node) {
        td.append(value);
      } else {
        td.textContent = text;
      }
      td.title = text;
      tr.append(td);
    });
    this.tbody.append(tr);
    if (this.leading() && this.expanded.has(key)) {
      const detail = document.createElement("tr");
      detail.className = "ps-detail";
      detail.id = `${this.uid}-detail-${index}`;
      const td = document.createElement("td");
      td.colSpan = this.span();
      const content = this.renderDetail ? this.renderDetail(row) : "";
      if (content instanceof Node) td.append(content);
      else td.textContent = content;
      detail.append(td);
      this.tbody.append(detail);
    }
  }

  toggleRow(row, index) {
    const key = this.rowKey(row, index);
    if (this.expanded.has(key)) this.expanded.delete(key);
    else this.expanded.add(key);
    const focusIndex = index;
    this.renderBody();
    const button = this.tbody.querySelector(`[data-toggle="${focusIndex}"]`);
    button?.focus();
  }

  onBodyClick(event) {
    const opener = event.target.closest("[data-open]");
    if (opener) {
      const index = Number(opener.dataset.open);
      this.selectRow(index, false);
      this.dispatchEvent(new CustomEvent("ps-row-open", { bubbles: true, detail: { row: this.displayed[index], index } }));
    }
  }

  selectRow(index, scroll) {
    const list = this.displayed || [];
    if (!list.length) return;
    this.selectedIndex = Math.max(0, Math.min(list.length - 1, index));
    this.renderBody();
    const tr = this.tbody.querySelector(`tr[data-index="${this.selectedIndex}"]`);
    if (tr && scroll) tr.scrollIntoView({ block: "nearest" });
    this.dispatchEvent(new CustomEvent("ps-row-select", { bubbles: true, detail: { row: list[this.selectedIndex], index: this.selectedIndex } }));
  }

  onKey(event) {
    if (document.documentElement.dataset.shortcuts === "off") return;
    if (event.ctrlKey || event.metaKey || event.altKey) return;
    if (event.target.closest("input, textarea")) return;
    if (event.key === "j") {
      event.preventDefault();
      this.selectRow(this.selectedIndex + 1, true);
    } else if (event.key === "k") {
      event.preventDefault();
      this.selectRow(this.selectedIndex < 0 ? 0 : this.selectedIndex - 1, true);
    } else if (event.key === "Enter" && event.target === this.scroller && this.selectedIndex >= 0 && this.hasAttribute("openable")) {
      event.preventDefault();
      this.dispatchEvent(new CustomEvent("ps-row-open", { bubbles: true, detail: { row: this.displayed[this.selectedIndex], index: this.selectedIndex } }));
    }
  }
}

customElements.define("ps-data-table", PsDataTable);
