let sequence = 0;

class PsCombobox extends HTMLElement {
  static observedAttributes = ["label", "placeholder", "disabled", "multiple", "help", "hide-label", "value"];

  connectedCallback() {
    if (this.field) return;
    sequence += 1;
    this.uid = `ps-combobox-${sequence}`;
    this.items = this.items || [];
    this.selected = this.selected || [];
    this.isOpen = false;
    this.activeIndex = -1;
    this.field = document.createElement("ps-text-field");
    this.syncFieldAttributes();
    this.chips = document.createElement("span");
    this.chips.className = "ps-chips";
    this.popup = document.createElement("div");
    this.popup.className = "ps-popup";
    this.popup.hidden = true;
    this.list = document.createElement("div");
    this.list.className = "ps-list";
    this.list.id = `${this.uid}-list`;
    this.list.setAttribute("role", "listbox");
    this.popup.append(this.list);
    this.append(this.field, this.popup);
    this.input = this.field.input;
    this.field.box.prepend(this.chips);
    this.input.setAttribute("role", "combobox");
    this.input.setAttribute("aria-autocomplete", "list");
    this.input.setAttribute("aria-expanded", "false");
    this.input.setAttribute("aria-controls", this.list.id);
    this.list.setAttribute("aria-label", this.getAttribute("label") || "Options");
    this.input.addEventListener("input", () => {
      if (!this.isOpen) this.open();
      this.activeIndex = this.visible().length ? 0 : -1;
      this.renderList();
    });
    this.input.addEventListener("keydown", (event) => this.onKey(event));
    this.list.addEventListener("mousedown", (event) => event.preventDefault());
    this.list.addEventListener("click", (event) => {
      const row = event.target.closest("[data-index]");
      if (row) this.pick(this.visible()[Number(row.dataset.index)]);
    });
    this.list.addEventListener("pointermove", (event) => {
      const row = event.target.closest("[data-index]");
      if (row && Number(row.dataset.index) !== this.activeIndex) {
        this.activeIndex = Number(row.dataset.index);
        this.syncActive();
      }
    });
    this.chips.addEventListener("ps-remove", (event) => {
      const value = event.target.getAttribute("data-value");
      this.selected = this.selected.filter((entry) => entry !== value);
      this.renderChips();
      this.emit();
      this.input.focus();
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
    this.renderChips();
    this.syncSingleValue();
  }

  disconnectedCallback() {
    document.removeEventListener("pointerdown", this.onOutside, true);
    window.removeEventListener("resize", this.onReflow);
    window.removeEventListener("scroll", this.onReflow, true);
  }

  attributeChangedCallback() {
    if (this.field) this.syncFieldAttributes();
  }

  syncFieldAttributes() {
    for (const name of ["label", "placeholder", "disabled", "help", "hide-label"]) {
      if (this.hasAttribute(name)) this.field.setAttribute(name, this.getAttribute(name));
      else this.field.removeAttribute(name);
    }
    const size = this.getAttribute("size");
    if (size) this.field.setAttribute("size", size);
  }

  get multiple() {
    return this.hasAttribute("multiple");
  }

  get options() {
    return this.items || [];
  }

  set options(list) {
    this.items = list;
    if (this.field) {
      this.renderChips();
      this.syncSingleValue();
      if (this.isOpen) this.renderList();
    }
  }

  get value() {
    return this.multiple ? [...(this.selected || [])] : (this.selected || [])[0] ?? null;
  }

  set value(next) {
    this.selected = Array.isArray(next) ? [...next] : next == null ? [] : [next];
    if (this.field) {
      this.renderChips();
      this.syncSingleValue();
    }
  }

  focus(options) {
    this.input?.focus(options);
  }

  labelOf(value) {
    const item = this.items.find((entry) => entry.value === value);
    return item ? item.label : value;
  }

  syncSingleValue() {
    if (this.multiple) return;
    this.input.value = this.selected.length ? this.labelOf(this.selected[0]) : "";
  }

  renderChips() {
    this.chips.textContent = "";
    if (!this.multiple) return;
    for (const value of this.selected) {
      const chip = document.createElement("ps-chip");
      chip.setAttribute("kind", "filter");
      chip.setAttribute("data-value", value);
      chip.setAttribute("label", this.labelOf(value));
      this.chips.append(chip);
    }
  }

  visible() {
    const text = this.multiple || this.isFiltering ? this.input.value.toLowerCase() : "";
    const items = this.items.filter((item) => !this.multiple || !this.selected.includes(item.value));
    if (!text) return items;
    return items.filter((item) => item.label.toLowerCase().includes(text));
  }

  emit() {
    this.dispatchEvent(new CustomEvent("ps-change", { bubbles: true, detail: { value: this.value } }));
  }

  open() {
    if (this.isOpen || this.hasAttribute("disabled")) return;
    this.isOpen = true;
    this.popup.hidden = false;
    this.input.setAttribute("aria-expanded", "true");
    this.activeIndex = this.visible().length ? 0 : -1;
    this.renderList();
    this.place();
    document.addEventListener("pointerdown", this.onOutside, true);
    window.addEventListener("resize", this.onReflow);
    window.addEventListener("scroll", this.onReflow, true);
  }

  close(clear) {
    if (!this.isOpen) return;
    this.isOpen = false;
    this.isFiltering = false;
    this.popup.hidden = true;
    this.input.setAttribute("aria-expanded", "false");
    this.input.removeAttribute("aria-activedescendant");
    document.removeEventListener("pointerdown", this.onOutside, true);
    window.removeEventListener("resize", this.onReflow);
    window.removeEventListener("scroll", this.onReflow, true);
    if (clear === "clear") {
      if (this.multiple) this.input.value = "";
      else this.syncSingleValue();
    }
  }

  pick(item) {
    if (!item || item.disabled) return;
    if (this.multiple) {
      this.selected = [...this.selected, item.value];
      this.input.value = "";
      this.renderChips();
      this.activeIndex = 0;
      this.renderList();
    } else {
      this.selected = [item.value];
      this.syncSingleValue();
      this.close(false);
    }
    this.emit();
  }

  place() {
    const anchor = this.field.box.getBoundingClientRect();
    const popup = this.popup;
    popup.style.minWidth = `${anchor.width}px`;
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
    this.list.textContent = "";
    const items = this.visible();
    if (!items.length) {
      const row = document.createElement("div");
      row.className = "ps-row ps-row-note";
      row.textContent = "No matches";
      this.list.append(row);
      this.input.removeAttribute("aria-activedescendant");
      return;
    }
    items.forEach((item, index) => {
      const row = document.createElement("div");
      row.className = "ps-row ps-option";
      row.id = `${this.uid}-opt-${index}`;
      row.setAttribute("role", "option");
      row.dataset.index = String(index);
      row.setAttribute("aria-selected", this.selected.includes(item.value) ? "true" : "false");
      row.textContent = item.label;
      row.title = item.label;
      this.list.append(row);
    });
    this.syncActive();
  }

  syncActive() {
    const rows = this.list.querySelectorAll("[role=option]");
    rows.forEach((row, index) => row.classList.toggle("ps-active", index === this.activeIndex));
    const row = rows[this.activeIndex];
    if (row) {
      this.input.setAttribute("aria-activedescendant", row.id);
      row.scrollIntoView({ block: "nearest" });
    } else {
      this.input.removeAttribute("aria-activedescendant");
    }
  }

  move(delta) {
    const count = this.visible().length;
    if (!count) return;
    this.activeIndex = Math.max(0, Math.min(count - 1, this.activeIndex + delta));
    this.syncActive();
  }

  onKey(event) {
    const key = event.key;
    if (key === "ArrowDown") {
      event.preventDefault();
      if (!this.isOpen) this.open();
      else this.move(1);
    } else if (key === "ArrowUp") {
      event.preventDefault();
      if (this.isOpen) this.move(-1);
    } else if (key === "Enter") {
      if (this.isOpen) {
        event.preventDefault();
        this.pick(this.visible()[this.activeIndex]);
      }
    } else if (key === "Backspace") {
      if (this.multiple && this.input.value === "" && this.selected.length) {
        this.selected = this.selected.slice(0, -1);
        this.renderChips();
        this.emit();
        if (this.isOpen) this.renderList();
      }
    } else if (key === "Escape") {
      if (this.isOpen) {
        event.preventDefault();
        event.stopPropagation();
        this.close(false);
      } else if (this.input.value !== "") {
        event.preventDefault();
        event.stopPropagation();
        this.input.value = "";
        if (!this.multiple) {
          this.selected = [];
          this.emit();
        }
      }
    } else if (key === "Tab") {
      this.close("clear");
    } else if (key.length === 1) {
      this.isFiltering = true;
    }
  }
}

customElements.define("ps-combobox", PsCombobox);
