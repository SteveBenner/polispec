import * as cm from "../../vendor/codemirror/codemirror.js";

const ESCAPE_WINDOW_MS = 1000;
const FLASH_MS = 2000;

const SEVERITY = { error: "error", danger: "error", warn: "warning", warning: "warning", info: "info" };

const flashEffect = cm.StateEffect.define();
const flashField = cm.StateField.define({
  create: () => cm.Decoration.none,
  update(value, transaction) {
    let next = value.map(transaction.changes);
    for (const effect of transaction.effects) {
      if (effect.is(flashEffect)) {
        next = effect.value ? cm.Decoration.set([cm.Decoration.mark({ class: "cm-inserted" }).range(effect.value.from, effect.value.to)]) : cm.Decoration.none;
      }
    }
    return next;
  },
  provide: (field) => cm.EditorView.decorations.from(field),
});

const markerSurface = { backgroundColor: "var(--control-bg)", color: "var(--text)" };

function selectionRules() {
  const rules = {};
  for (const mode of ["&"]) {
    rules[`${mode}.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground`] = { background: "var(--accent-soft)" };
    rules[`${mode} .cm-selectionBackground`] = { background: "var(--accent-soft)" };
    rules[`${mode}.cm-focused .cm-matchingBracket`] = { backgroundColor: "var(--accent-soft)", outline: "1px solid var(--accent)" };
    rules[`${mode}.cm-focused .cm-nonmatchingBracket`] = { backgroundColor: "transparent", outline: "1px solid var(--danger)" };
    rules[`${mode} .cm-activeLine`] = { backgroundColor: "var(--row-hover)" };
    rules[`${mode} .cm-activeLineGutter`] = { backgroundColor: "var(--row-hover)", color: "var(--text)" };
    rules[`${mode} .cm-gutters`] = {
      backgroundColor: "var(--surface-2)",
      color: "var(--text-faint)",
      border: "none",
      borderInlineEnd: "1px solid var(--border)",
    };
    rules[`${mode} .cm-tooltip`] = {
      backgroundColor: "var(--bg-elev)",
      color: "var(--text)",
      border: "1px solid var(--border-strong)",
      borderRadius: "var(--radius-sm)",
      boxShadow: "var(--shadow)",
    };
    rules[`${mode} .cm-panels`] = { backgroundColor: "var(--surface-2)", color: "var(--text)" };
    rules[`${mode} .cm-button`] = {
      backgroundImage: "none",
      backgroundColor: "var(--surface)",
      color: "var(--text)",
      border: "1px solid var(--control-border)",
      borderRadius: "var(--radius-sm)",
    };
    rules[`${mode} .cm-textfield`] = {
      backgroundColor: "var(--control-bg)",
      color: "var(--text)",
      border: "1px solid var(--control-border)",
      borderRadius: "var(--radius-sm)",
    };
  }
  return rules;
}

const theme = cm.EditorView.theme({
  "&": {
    ...markerSurface,
    height: "100%",
    minHeight: "0",
    fontFamily: "var(--font-mono)",
    fontSize: "var(--text-sm)",
    lineHeight: "var(--lh-sm)",
    border: "1px solid var(--border)",
    borderRadius: "var(--radius-sm)",
  },
  "&.cm-focused": { outline: "var(--focus-w) solid var(--focus-ring)", outlineOffset: "calc(var(--focus-w) * -1)" },
  ".cm-scroller": { fontFamily: "var(--font-mono)", lineHeight: "var(--lh-sm)", overflow: "auto" },
  ".cm-content": { caretColor: "var(--accent)", padding: "var(--space-1) 0" },
  ".cm-line": { padding: "0 var(--space-2)" },
  ".cm-cursor, .cm-dropCursor": { borderLeftColor: "var(--accent)" },
  ".cm-lineNumbers .cm-gutterElement": { padding: "0 var(--space-2) 0 var(--space-3)", minWidth: "var(--space-6)" },
  ".cm-foldGutter .cm-gutterElement": { cursor: "pointer", color: "var(--text-faint)" },
  ".cm-foldPlaceholder": {
    backgroundColor: "var(--surface-2)",
    color: "var(--text-dim)",
    border: "1px solid var(--border)",
    borderRadius: "var(--radius-sm)",
  },
  ".cm-selectionMatch": { backgroundColor: "var(--accent-soft)" },
  ".cm-searchMatch": { backgroundColor: "var(--accent-soft)", outline: "1px solid var(--accent)" },
  ".cm-searchMatch.cm-searchMatch-selected": { backgroundColor: "var(--accent-soft)", outline: "2px solid var(--accent)" },
  ".cm-inserted": { backgroundColor: "var(--accent-soft)" },
  ".cm-lintRange": { backgroundImage: "none", paddingBottom: "0" },
  ".cm-lintRange-error": { backgroundImage: "none", textDecoration: "underline wavy var(--danger)", textUnderlineOffset: "3px" },
  ".cm-lintRange-warning": { backgroundImage: "none", textDecoration: "underline wavy var(--warn)", textUnderlineOffset: "3px" },
  ".cm-lintRange-info": { backgroundImage: "none", textDecoration: "underline dotted var(--text-dim)", textUnderlineOffset: "3px" },
  ".cm-lintRange-active": { backgroundColor: "var(--accent-soft)" },
  ".cm-lintPoint:after": { borderBottomColor: "var(--danger)" },
  ".cm-lintPoint-warning:after": { borderBottomColor: "var(--warn)" },
  ".cm-lint-marker": { content: "none", width: "8px", height: "8px", marginTop: "5px" },
  ".cm-lint-marker-error": { content: "none", backgroundColor: "var(--danger)", borderRadius: "50%" },
  ".cm-lint-marker-warning": { content: "none", backgroundColor: "var(--warn)", clipPath: "polygon(50% 0, 100% 100%, 0 100%)" },
  ".cm-lint-marker-info": { content: "none", backgroundColor: "var(--text-dim)", borderRadius: "50%" },
  ".cm-diagnostic": { padding: "var(--space-1) var(--space-2)", fontSize: "var(--text-xs)", lineHeight: "var(--lh-xs)" },
  ".cm-diagnostic-error": { borderInlineStartColor: "var(--danger)" },
  ".cm-diagnostic-warning": { borderInlineStartColor: "var(--warn)" },
  ".cm-diagnostic-info": { borderInlineStartColor: "var(--text-dim)" },
  ".cm-panel.cm-search": { fontSize: "var(--text-xs)", lineHeight: "var(--lh-xs)", padding: "var(--space-1) var(--space-2)" },
  ".cm-panel.cm-search label": { color: "var(--text-dim)" },
  ".cm-panel.cm-search [name=close]": { color: "var(--text-dim)" },
  "@media (max-width: 767px) and (pointer: coarse)": {
    "&": { fontSize: "16px", lineHeight: "20px" },
    ".cm-scroller": { lineHeight: "20px" },
    ".cm-panel.cm-search input, .cm-panel.cm-search button": { fontSize: "16px" },
  },
  ...selectionRules(),
});

const highlight = cm.HighlightStyle.define([
  { tag: [cm.tags.propertyName, cm.tags.definition(cm.tags.propertyName)], color: "var(--accent)" },
  { tag: [cm.tags.string, cm.tags.special(cm.tags.string)], color: "var(--text)" },
  { tag: [cm.tags.number, cm.tags.bool, cm.tags.null], color: "var(--ok)" },
  { tag: [cm.tags.lineComment, cm.tags.blockComment, cm.tags.comment], color: "var(--text-faint)", fontStyle: "italic" },
  { tag: [cm.tags.separator, cm.tags.punctuation, cm.tags.squareBracket, cm.tags.brace, cm.tags.operator], color: "var(--text-dim)" },
  { tag: [cm.tags.labelName, cm.tags.meta, cm.tags.typeName, cm.tags.keyword], color: "var(--text-dim)", fontWeight: "var(--weight-medium)" },
  { tag: cm.tags.invalid, color: "var(--danger)" },
]);

function toOffset(state, line, col) {
  const count = state.doc.lines;
  const safeLine = Math.min(Math.max(1, Number(line) || 1), count);
  const row = state.doc.line(safeLine);
  const offset = Math.max(0, (Number(col) || 1) - 1);
  return Math.min(row.from + offset, row.to);
}

export function toDiagnostics(state, findings) {
  const out = [];
  for (const finding of findings || []) {
    const line = finding.line || (finding.span && finding.span.line) || 1;
    const col = finding.col || finding.column || (finding.span && finding.span.col) || 1;
    const from = finding.from != null ? Math.min(finding.from, state.doc.length) : toOffset(state, line, col);
    let to = finding.to != null ? Math.min(finding.to, state.doc.length) : null;
    if (to == null) {
      const endLine = finding.end_line || (finding.span && finding.span.end_line);
      const endCol = finding.end_col || (finding.span && finding.span.end_col);
      if (endLine && endCol) to = toOffset(state, endLine, endCol);
      else to = state.doc.lineAt(from).to;
    }
    if (to <= from) to = Math.min(state.doc.length, from + 1);
    out.push({
      from,
      to,
      severity: SEVERITY[finding.severity] || "error",
      message: (finding.code ? finding.code + ": " : "") + (finding.message || ""),
    });
  }
  return out;
}

export function createYamlEditor(el, options = {}) {
  const callbacks = {
    change: options.onChange || null,
    selection: options.onSelection || null,
    plan: options.onPlan || null,
    escape: options.onEscapeTwice || null,
  };
  let lastEscape = 0;
  let flashTimer = 0;
  const readOnly = new cm.Compartment();

  const keys = [
    {
      key: "Mod-s",
      preventDefault: true,
      run: () => {
        if (callbacks.plan) callbacks.plan();
        return true;
      },
    },
    {
      key: "Escape",
      run: () => {
        const now = Date.now();
        const twice = now - lastEscape < ESCAPE_WINDOW_MS;
        lastEscape = now;
        if (twice && callbacks.escape) {
          lastEscape = 0;
          callbacks.escape();
          return true;
        }
        return false;
      },
    },
  ];

  const extensions = [
    cm.lineNumbers(),
    cm.highlightActiveLineGutter(),
    cm.foldGutter(),
    cm.lintGutter(),
    cm.history(),
    cm.drawSelection(),
    cm.indentOnInput(),
    cm.bracketMatching(),
    cm.highlightActiveLine(),
    cm.highlightSelectionMatches(),
    cm.search({ top: true }),
    cm.indentUnit.of("  "),
    cm.yaml(),
    cm.syntaxHighlighting(highlight),
    theme,
    flashField,
    cm.keymap.of([...keys, ...cm.defaultKeymap, ...cm.historyKeymap, ...cm.foldKeymap, ...cm.searchKeymap, ...cm.lintKeymap]),
    readOnly.of(cm.EditorState.readOnly.of(Boolean(options.readOnly))),
    cm.EditorView.contentAttributes.of({ "aria-label": options.ariaLabel || "YAML editor", spellcheck: "false" }),
    cm.EditorView.updateListener.of((update) => {
      if (update.docChanged && callbacks.change) callbacks.change(update.state.doc.toString(), update);
      if ((update.selectionSet || update.docChanged) && callbacks.selection) {
        const head = update.state.selection.main.head;
        const line = update.state.doc.lineAt(head);
        callbacks.selection({ line: line.number, col: head - line.from + 1, offset: head });
      }
    }),
  ];

  const root = el.shadowRoot || el.attachShadow({ mode: "open" });
  const view = new cm.EditorView({
    parent: root,
    root,
    state: cm.EditorState.create({ doc: options.doc || "", extensions }),
  });

  return {
    view,
    get value() {
      return view.state.doc.toString();
    },
    setValue(text) {
      if (text === view.state.doc.toString()) return;
      view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text }, selection: { anchor: Math.min(view.state.selection.main.head, text.length) } });
    },
    setReadOnly(flag) {
      view.dispatch({ effects: readOnly.reconfigure(cm.EditorState.readOnly.of(Boolean(flag))) });
    },
    setDiagnostics(findings) {
      view.dispatch(cm.setDiagnostics(view.state, toDiagnostics(view.state, findings)));
    },
    focus() {
      view.focus();
    },
    cursor() {
      const head = view.state.selection.main.head;
      const line = view.state.doc.lineAt(head);
      return { line: line.number, col: head - line.from + 1, offset: head };
    },
    goTo(line, col) {
      const offset = toOffset(view.state, line, col);
      view.dispatch({ selection: { anchor: offset }, scrollIntoView: true });
      view.focus();
    },
    insert(at, text) {
      const to = at + text.length;
      view.dispatch({
        changes: { from: at, insert: text },
        selection: cm.EditorSelection.range(at, to),
        effects: [flashEffect.of({ from: at, to }), cm.EditorView.scrollIntoView(at, { y: "nearest" })],
        scrollIntoView: true,
      });
      clearTimeout(flashTimer);
      flashTimer = setTimeout(() => {
        if (view.dom.isConnected) view.dispatch({ effects: flashEffect.of(null) });
      }, FLASH_MS);
      return { from: at, to };
    },
    onPlan(handler) {
      callbacks.plan = handler;
    },
    destroy() {
      clearTimeout(flashTimer);
      view.destroy();
    },
  };
}

const RULE_START = /^(\s*)-\s*(?:\{\s*)?id:\s*["']?([^,\s}"']+)/;
const TOP_KEY = /^([A-Za-z_][\w-]*):/;
const GROUP_LINE = /^\s*group:\s*["']?([^"'\s,}]+)/;
const GROUP_FLOW = /\bgroup:\s*["']?([^"'\s,}]+)/;

function topBlocks(lines) {
  const blocks = [];
  let current = null;
  lines.forEach((text, index) => {
    const match = TOP_KEY.exec(text);
    if (match) {
      if (current) current.end = index - 1;
      current = { key: match[1], start: index, end: lines.length - 1 };
      blocks.push(current);
    }
  });
  if (current) current.end = lines.length - 1;
  return blocks;
}

export function parseOutline(text) {
  const lines = text.split("\n");
  const blocks = topBlocks(lines);
  const items = [];
  for (const block of blocks) {
    if (block.key !== "rules" && block.key !== "includes") continue;
    let open = null;
    for (let i = block.start + 1; i <= block.end; i += 1) {
      const line = lines[i];
      if (block.key === "rules") {
        const start = RULE_START.exec(line);
        if (start && start[1].length <= 4) {
          if (open) open.end = i - 1;
          open = { type: "rule", id: start[2], start: i, end: block.end, indent: start[1].length, group: "" };
          items.push(open);
          const flow = GROUP_FLOW.exec(line);
          if (flow) open.group = flow[1];
          continue;
        }
      } else {
        const include = /^(\s*)-\s*(?:\{?\s*module:\s*)?["']?([a-z0-9][a-z0-9-]*)/.exec(line);
        if (include && include[1].length <= 4) {
          if (open) open.end = i - 1;
          open = { type: "module", id: include[2], start: i, end: block.end, indent: include[1].length, group: "" };
          items.push(open);
          continue;
        }
      }
      if (open && block.key === "rules") {
        const group = GROUP_LINE.exec(line);
        if (group && !open.group) open.group = group[1];
      }
    }
    if (open) open.end = block.end;
    while (open && open.end > open.start && lines[open.end].trim() === "") open.end -= 1;
  }
  for (let i = 0; i < items.length; i += 1) {
    const next = items[i + 1];
    if (next && next.start <= items[i].end) items[i].end = next.start - 1;
  }
  return { items, lines };
}

export function itemAtLine(outline, line) {
  const index = line - 1;
  return outline.items.find((item) => index >= item.start && index <= item.end) || null;
}

export function moveItem(text, fromId, toIndexInType) {
  const outline = parseOutline(text);
  const subject = outline.items.find((item) => item.id === fromId);
  if (!subject) return null;
  const peers = outline.items.filter((item) => item.type === subject.type);
  const position = peers.indexOf(subject);
  const target = Math.max(0, Math.min(peers.length - 1, toIndexInType));
  if (target === position) return { text, index: position, total: peers.length };
  const lines = outline.lines;
  const chunk = lines.slice(subject.start, subject.end + 1);
  const rest = lines.slice(0, subject.start).concat(lines.slice(subject.end + 1));
  const remaining = peers.filter((item) => item !== subject);
  let insertAt;
  if (target >= remaining.length) {
    const last = remaining[remaining.length - 1];
    insertAt = last.end + 1 - (last.start > subject.start ? chunk.length : 0);
  } else {
    const anchor = remaining[target];
    insertAt = anchor.start - (anchor.start > subject.start ? chunk.length : 0);
  }
  rest.splice(insertAt, 0, ...chunk);
  return { text: rest.join("\n"), index: target, total: peers.length };
}

export function setGroup(text, id, group) {
  const outline = parseOutline(text);
  const subject = outline.items.find((item) => item.id === id && item.type === "rule");
  if (!subject) return null;
  const lines = outline.lines;
  const first = lines[subject.start];
  if (/\{/.test(first) && /\}\s*,?\s*$/.test(lines[subject.end])) {
    const last = subject.end;
    let line = lines[last];
    if (GROUP_FLOW.test(line)) {
      line = line.replace(GROUP_FLOW, `group: ${group}`);
    } else {
      line = line.replace(/\s*\}(\s*,?\s*)$/, `, group: ${group} }$1`);
    }
    lines[last] = line;
    return lines.join("\n");
  }
  for (let i = subject.start; i <= subject.end; i += 1) {
    if (GROUP_LINE.test(lines[i])) {
      lines[i] = lines[i].replace(/group:.*$/, `group: ${group}`);
      return lines.join("\n");
    }
  }
  const pad = " ".repeat(subject.indent + 2);
  lines.splice(subject.start + 1, 0, `${pad}group: ${group}`);
  return lines.join("\n");
}

export function composePoint(text, cursorLine) {
  const lines = text.split("\n");
  const blocks = topBlocks(lines);
  const includes = blocks.find((block) => block.key === "includes");
  if (includes) {
    let end = includes.end;
    while (end > includes.start && lines[end].trim() === "") end -= 1;
    const outline = parseOutline(text);
    const inside = outline.items.find((item) => item.type === "module" && cursorLine - 1 >= item.start && cursorLine - 1 <= item.end);
    const lineIndex = inside ? inside.end : end;
    let offset = 0;
    for (let i = 0; i <= lineIndex; i += 1) offset += lines[i].length + 1;
    return { offset: Math.min(offset, text.length), prefix: offset > text.length ? "\n" : "", existing: true, indent: "  " };
  }
  const rules = blocks.find((block) => block.key === "rules");
  let offset = 0;
  if (rules) {
    for (let i = 0; i < rules.start; i += 1) offset += lines[i].length + 1;
  } else {
    offset = text.length + (text.endsWith("\n") || !text.length ? 0 : 1);
  }
  return { offset, prefix: !rules && !text.endsWith("\n") && text.length ? "\n" : "", existing: false, indent: "  " };
}

function scalar(value) {
  if (typeof value === "boolean" || typeof value === "number") return String(value);
  const text = String(value);
  if (/^[A-Za-z0-9_./~-][A-Za-z0-9_./~ -]*$/.test(text) && !/^(true|false|null|yes|no|on|off|\d+)$/i.test(text)) return text;
  return JSON.stringify(text);
}

export function includeSnippet(name, values, existing) {
  const entries = Object.entries(values || {}).filter(([, value]) => value !== "" && value !== undefined && !(Array.isArray(value) && !value.length));
  const lines = [];
  if (!entries.length) {
    lines.push(`  - ${name}`);
  } else {
    lines.push(`  - module: ${name}`);
    lines.push("    with:");
    for (const [key, value] of entries) {
      if (Array.isArray(value)) lines.push(`      ${key}: [${value.map(scalar).join(", ")}]`);
      else lines.push(`      ${key}: ${scalar(value)}`);
    }
  }
  const body = lines.join("\n") + "\n";
  return existing ? body : "includes:\n" + body;
}

const LCS_LIMIT = 4000000;

export function diffHunks(a, b) {
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start += 1;
  let endA = a.length;
  let endB = b.length;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) {
    endA -= 1;
    endB -= 1;
  }
  const n = endA - start;
  const m = endB - start;
  if (n === 0 && m === 0) return [];
  if (n * m > LCS_LIMIT || n === 0 || m === 0) return [{ aStart: start, aEnd: endA, bStart: start, bEnd: endB }];
  const width = m + 1;
  const table = new Uint32Array((n + 1) * width);
  for (let i = n - 1; i >= 0; i -= 1) {
    for (let j = m - 1; j >= 0; j -= 1) {
      table[i * width + j] = a[start + i] === b[start + j] ? table[(i + 1) * width + j + 1] + 1 : Math.max(table[(i + 1) * width + j], table[i * width + j + 1]);
    }
  }
  const hunks = [];
  let i = 0;
  let j = 0;
  let open = null;
  const close = () => {
    if (open) {
      hunks.push(open);
      open = null;
    }
  };
  while (i < n || j < m) {
    if (i < n && j < m && a[start + i] === b[start + j]) {
      close();
      i += 1;
      j += 1;
    } else {
      if (!open) open = { aStart: start + i, aEnd: start + i, bStart: start + j, bEnd: start + j };
      if (j < m && (i >= n || table[i * width + j + 1] >= table[(i + 1) * width + j])) {
        j += 1;
        open.bEnd = start + j;
      } else {
        i += 1;
        open.aEnd = start + i;
      }
    }
  }
  close();
  return hunks;
}

export function unifiedDiff(oldText, newText, name = "file") {
  const a = oldText.split("\n");
  const b = newText.split("\n");
  const hunks = diffHunks(a, b);
  if (!hunks.length) return "";
  const context = 3;
  const out = [`--- a/${name}`, `+++ b/${name}`];
  let index = 0;
  while (index < hunks.length) {
    let last = index;
    while (last + 1 < hunks.length && hunks[last + 1].aStart - hunks[last].aEnd <= context * 2) last += 1;
    const first = hunks[index];
    const tail = hunks[last];
    const aFrom = Math.max(0, first.aStart - context);
    const aTo = Math.min(a.length, tail.aEnd + context);
    const bFrom = first.bStart - (first.aStart - aFrom);
    const bTo = tail.bEnd + (aTo - tail.aEnd);
    out.push(`@@ -${aFrom + 1},${aTo - aFrom} +${bFrom + 1},${bTo - bFrom} @@`);
    let cursor = aFrom;
    for (let h = index; h <= last; h += 1) {
      const hunk = hunks[h];
      for (; cursor < hunk.aStart; cursor += 1) out.push(" " + a[cursor]);
      for (let k = hunk.aStart; k < hunk.aEnd; k += 1) out.push("-" + a[k]);
      for (let k = hunk.bStart; k < hunk.bEnd; k += 1) out.push("+" + b[k]);
      cursor = hunk.aEnd;
    }
    for (; cursor < aTo; cursor += 1) out.push(" " + a[cursor]);
    index = last + 1;
  }
  return out.join("\n");
}

export function merge3(baseText, oursText, theirsText) {
  const base = baseText.split("\n");
  const ours = oursText.split("\n");
  const theirs = theirsText.split("\n");
  const mine = diffHunks(base, ours).map((hunk) => ({ ...hunk, side: "ours", lines: ours.slice(hunk.bStart, hunk.bEnd) }));
  const other = diffHunks(base, theirs).map((hunk) => ({ ...hunk, side: "theirs", lines: theirs.slice(hunk.bStart, hunk.bEnd) }));
  const all = mine.concat(other).sort((x, y) => x.aStart - y.aStart || x.aEnd - y.aEnd);
  const kept = [];
  for (const hunk of all) {
    const previous = kept[kept.length - 1];
    if (previous) {
      const same = previous.aStart === hunk.aStart && previous.aEnd === hunk.aEnd && previous.lines.join("\n") === hunk.lines.join("\n");
      if (same) continue;
      const overlap = hunk.aStart < previous.aEnd || (hunk.aStart === previous.aEnd && (hunk.aStart === hunk.aEnd || previous.aStart === previous.aEnd));
      if (overlap) return null;
    }
    kept.push(hunk);
  }
  const out = [];
  let cursor = 0;
  for (const hunk of kept) {
    for (; cursor < hunk.aStart; cursor += 1) out.push(base[cursor]);
    out.push(...hunk.lines);
    cursor = hunk.aEnd;
  }
  for (; cursor < base.length; cursor += 1) out.push(base[cursor]);
  return out.join("\n");
}
