const NS = "http://www.w3.org/2000/svg";
const SEARCH_THRESHOLD = 12;
const TYPEAHEAD_RESET = 600;
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

class PsSelect extends HTMLElement {
  static observedAttributes = ["label", "value", "placeholder", "disabled", "state", "reason", "hide-label", "searchable"];

  connectedCallback() {
    if (this.trigger) return;
    sequence += 1;
    this.uid = `ps-select-${sequence}`;
    this.items = this.items || this.readOptionsAttribute();
    this.current = this.getAttribute("value");
    this.isOpen = false;
    this.activeIndex = -1;
    this.query = "";
    this.typed = "";
    this.typedTimer = 0;
    this.labelEl = document.createElement("span");
    this.labelEl.className = "ps-label";
    this.labelEl.id = `${this.uid}-label`;
    this.trigger = document.createElement("button");
    this.trigger.type = "button";
    this.trigger.className = "ps-native";
    this.trigger.setAttribute("aria-haspopup", "listbox");
    this.trigger.setAttribute("aria-expanded", "false");
    this.trigger.setAttribute("aria-controls", `${this.uid}-popup`);
    this.valueEl = document.createElement("span");
    this.valueEl.className = "ps-value";
    this.trigger.append(this.valueEl, icon("chevron-down"));
    this.popup = document.createElement("div");
    this.popup.className = "ps-popup";
    this.popup.id = `${this.uid}-popup`;
    this.popup.hidden = true;
    this.filter = document.createElement("input");
    this.filter.type = "text";
    this.filter.className = "ps-native ps-filter";
    this.filter.setAttribute("role", "combobox");
    this.filter.setAttribute("aria-autocomplete", "list");
    this.filter.setAttribute("aria-label", "Filter options");
    this.filter.setAttribute("aria-controls", `${this.uid}-list`);
    this.filter.autocomplete = "off";
    this.filter.spellcheck = false;
    this.filter.hidden = true;
    this.list = document.createElement("div");
    this.list.className = "ps-list";
    this.list.id = `${this.uid}-list`;
    this.list.setAttribute("role", "listbox");
    this.list.tabIndex = -1;
    this.popup.append(this.filter, this.list);
    this.append(this.labelEl, this.trigger, this.popup);
    this.trigger.addEventListener("click", () => (this.isOpen ? this.close(true) : this.open()));
    this.trigger.addEventListener("keydown", (event) => this.onTriggerKey(event));
    this.popup.addEventListener("keydown", (event) => this.onPopupKey(event));
    this.filter.addEventListener("input", () => {
      this.query = this.filter.value;
      this.activeIndex = this.visible().length ? 0 : -1;
      this.renderList();
    });
    this.list.addEventListener("mousedown", (event) => event.preventDefault());
    this.list.addEventListener("click", (event) => {
      const row = event.target.closest("[data-index]");
      if (row) this.choose(this.visible()[Number(row.dataset.index)]);
      const retry = event.target.closest("[data-retry]");
      if (retry) this.dispatchEvent(new CustomEvent("ps-retry", { bubbles: true }));
    });
    this.list.addEventListener("pointermove", (event) => {
      const row = event.target.closest("[data-index]");
      if (row && Number(row.dataset.index) !== this.activeIndex) {
        this.activeIndex = Number(row.dataset.index);
        this.syncActive();
      }
    });
    this.addEventListener("focusout", (event) => {
      if (this.isOpen && !this.contains(event.relatedTarget)) this.close(false);
    });
    this.onOutside = (event) => {
      if (this.isOpen && !this.contains(event.target)) this.close(false);
    };
    this.onReflow = () => {
      if (this.isOpen) this.place();
    };
    this.update();
  }

  disconnectedCallback() {
    document.removeEventListener("pointerdown", this.onOutside, true);
    window.removeEventListener("resize", this.onReflow);
    window.removeEventListener("scroll", this.onReflow, true);
    clearTimeout(this.typedTimer);
  }

  attributeChangedCallback(name, oldValue, value) {
    if (!this.trigger) return;
    if (name === "value") this.current = value;
    this.update();
  }

  readOptionsAttribute() {
    const raw = this.getAttribute("options");
    if (!raw) return [];
    try {
      return JSON.parse(raw);
    } catch (error) {
      return [];
    }
  }

  get options() {
    return this.items || [];
  }

  set options(list) {
    this.items = list;
    if (this.trigger) this.update();
  }

  get value() {
    return this.current;
  }

  set value(next) {
    this.current = next;
    if (this.trigger) this.update();
  }

  focus(options) {
    this.trigger?.focus(options);
  }

  get searchable() {
    return this.hasAttribute("searchable") || this.items.length > SEARCH_THRESHOLD;
  }

  visible() {
    if (!this.query) return this.items;
    const needle = this.query.toLowerCase();
    return this.items.filter((item) => item.label.toLowerCase().includes(needle));
  }

  selectedItem() {
    return this.items.find((item) => item.value === this.current);
  }

  update() {
    const label = this.getAttribute("label") || "";
    this.labelEl.textContent = label;
    this.labelEl.hidden = !label || this.hasAttribute("hide-label");
    if (label) this.trigger.setAttribute("aria-labelledby", `${this.labelEl.id} ${this.valueEl.id || (this.valueEl.id = `${this.uid}-value`)}`);
    else this.trigger.removeAttribute("aria-labelledby");
    if (!label && this.getAttribute("aria-label")) this.trigger.setAttribute("aria-label", this.getAttribute("aria-label"));
    const item = this.selectedItem();
    this.valueEl.textContent = item ? item.label : this.getAttribute("placeholder") || "Select";
    this.valueEl.classList.toggle("ps-placeholder", !item);
    this.trigger.title = item ? item.label : "";
    const disabled = this.hasAttribute("disabled");
    if (disabled) this.trigger.setAttribute("aria-disabled", "true");
    else this.trigger.removeAttribute("aria-disabled");
    this.trigger.title = disabled && this.getAttribute("reason") ? this.getAttribute("reason") : item ? item.label : "";
    if (this.isOpen) this.renderList();
  }

  open() {
    if (this.isOpen || this.hasAttribute("disabled")) return;
    this.isOpen = true;
    this.query = "";
    this.filter.value = "";
    this.filter.hidden = !this.searchable;
    this.popup.hidden = false;
    this.trigger.setAttribute("aria-expanded", "true");
    const list = this.visible();
    const index = list.findIndex((item) => item.value === this.current);
    this.activeIndex = index >= 0 ? index : list.length ? 0 : -1;
    this.renderList();
    this.place();
    document.addEventListener("pointerdown", this.onOutside, true);
    window.addEventListener("resize", this.onReflow);
    window.addEventListener("scroll", this.onReflow, true);
    (this.searchable ? this.filter : this.list).focus({ preventScroll: true });
    this.dispatchEvent(new CustomEvent("ps-open", { bubbles: true }));
  }

  close(refocus) {
    if (!this.isOpen) return;
    this.isOpen = false;
    this.popup.hidden = true;
    this.trigger.setAttribute("aria-expanded", "false");
    document.removeEventListener("pointerdown", this.onOutside, true);
    window.removeEventListener("resize", this.onReflow);
    window.removeEventListener("scroll", this.onReflow, true);
    if (refocus) this.trigger.focus();
  }

  choose(item) {
    if (!item || item.disabled) return;
    const changed = item.value !== this.current;
    this.current = item.value;
    this.close(true);
    this.update();
    if (changed) this.dispatchEvent(new CustomEvent("ps-change", { bubbles: true, detail: { value: item.value, item } }));
  }

  place() {
    const anchor = this.trigger.getBoundingClientRect();
    const popup = this.popup;
    popup.style.minWidth = `${Math.max(anchor.width, 200)}px`;
    const height = popup.offsetHeight;
    const width = popup.offsetWidth;
    const margin = 4;
    const below = window.innerHeight - anchor.bottom - margin;
    const above = anchor.top - margin;
    let top = anchor.bottom + 2;
    if (height > below && above > below) top = Math.max(margin, anchor.top - height - 2);
    const left = Math.max(margin, Math.min(anchor.left, window.innerWidth - width - margin));
    popup.style.top = `${Math.round(top)}px`;
    popup.style.left = `${Math.round(left)}px`;
  }

  renderList() {
    const state = this.getAttribute("state");
    this.list.textContent = "";
    this.list.removeAttribute("aria-activedescendant");
    this.list.setAttribute("aria-labelledby", this.labelEl.id);
    this.filter.removeAttribute("aria-activedescendant");
    if (state === "loading") {
      this.list.setAttribute("aria-busy", "true");
      for (let i = 0; i < 2; i += 1) {
        const row = document.createElement("div");
        row.className = "ps-row ps-row-skeleton";
        row.setAttribute("aria-hidden", "true");
        row.append(document.createElement("ps-skeleton"));
        this.list.append(row);
      }
      const status = document.createElement("div");
      status.className = "ps-row ps-row-note";
      status.setAttribute("role", "status");
      status.textContent = "Loading";
      this.list.append(status);
      return;
    }
    this.list.removeAttribute("aria-busy");
    if (state === "error") {
      const row = document.createElement("div");
      row.className = "ps-row ps-row-note";
      row.setAttribute("role", "alert");
      const text = document.createElement("span");
      text.textContent = "Options did not load";
      const retry = document.createElement("button");
      retry.type = "button";
      retry.className = "ps-native ps-retry";
      retry.setAttribute("data-retry", "");
      retry.textContent = "Retry";
      row.append(text, retry);
      this.list.append(row);
      return;
    }
    const list = this.visible();
    if (!list.length) {
      const row = document.createElement("div");
      row.className = "ps-row ps-row-note";
      row.textContent = "No options";
      this.list.append(row);
      return;
    }
    list.forEach((item, index) => {
      const row = document.createElement("div");
      row.className = "ps-row ps-option";
      row.id = `${this.uid}-opt-${index}`;
      row.setAttribute("role", "option");
      row.dataset.index = String(index);
      row.setAttribute("aria-selected", item.value === this.current ? "true" : "false");
      if (item.disabled) row.setAttribute("aria-disabled", "true");
      const mark = document.createElement("span");
      mark.className = "ps-mark";
      if (item.value === this.current) mark.append(icon("check"));
      const text = document.createElement("span");
      text.className = "ps-option-text";
      text.textContent = item.label;
      text.title = item.label;
      row.append(mark, text);
      this.list.append(row);
    });
    this.syncActive();
  }

  syncActive() {
    const rows = this.list.querySelectorAll("[role=option]");
    rows.forEach((row, index) => row.classList.toggle("ps-active", index === this.activeIndex));
    const row = rows[this.activeIndex];
    const target = this.searchable ? this.filter : this.list;
    if (row) {
      target.setAttribute("aria-activedescendant", row.id);
      row.scrollIntoView({ block: "nearest" });
    } else {
      target.removeAttribute("aria-activedescendant");
    }
  }

  move(delta) {
    const count = this.visible().length;
    if (!count) return;
    this.activeIndex = Math.max(0, Math.min(count - 1, this.activeIndex + delta));
    this.syncActive();
  }

  prefixMatch(character, items, from) {
    clearTimeout(this.typedTimer);
    this.typed += character.toLowerCase();
    this.typedTimer = setTimeout(() => {
      this.typed = "";
    }, TYPEAHEAD_RESET);
    const ordered = [...items.slice(from + 1), ...items.slice(0, from + 1)];
    return ordered.find((item) => !item.disabled && item.label.toLowerCase().startsWith(this.typed));
  }

  onTriggerKey(event) {
    if (event.key === "Enter" || event.key === " " || event.key === "ArrowDown") {
      event.preventDefault();
      this.open();
      return;
    }
    if (event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey) {
      const index = this.items.findIndex((item) => item.value === this.current);
      const match = this.prefixMatch(event.key, this.items, index);
      if (match) this.choose(match);
    }
  }

  onPopupKey(event) {
    const key = event.key;
    if (key === "ArrowDown") {
      event.preventDefault();
      this.move(1);
    } else if (key === "ArrowUp") {
      event.preventDefault();
      this.move(-1);
    } else if (key === "Home") {
      event.preventDefault();
      this.activeIndex = 0;
      this.syncActive();
    } else if (key === "End") {
      event.preventDefault();
      this.activeIndex = this.visible().length - 1;
      this.syncActive();
    } else if (key === "Enter") {
      event.preventDefault();
      this.choose(this.visible()[this.activeIndex]);
    } else if (key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      this.close(true);
    } else if (key === "Tab") {
      this.close(true);
    } else if (!this.searchable && key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey) {
      const match = this.prefixMatch(key, this.visible(), this.activeIndex);
      if (match) {
        this.activeIndex = this.visible().indexOf(match);
        this.syncActive();
      }
    }
  }
}

customElements.define("ps-select", PsSelect);
