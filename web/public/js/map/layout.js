export const BANDS = [
  { key: "shipped", label: "Shipped", plural: "shipped" },
  { key: "global", label: "Global shelf", plural: "shelf" },
  { key: "exceptions", label: "Exceptions", plural: "exception" },
];

export const STATUS_ORDER = { live: 0, onboarding: 1, retired: 2 };
export const COLLAPSE_EXCEPTIONS_AT = 6;
export const LABEL_W = 120;
export const CHIP_H = 24;
export const CHIP_GAP = 8;
export const CHIP_PAD = 8;
export const CHIP_MAX = 220;
export const GROUP_LABEL_H = 24;
export const COLLAPSED_KEY = "exceptions:__all";

export function columnCount(count) {
  if (count <= 0) return 3;
  return Math.max(1, Math.min(8, Math.round(Math.sqrt(count * 1.6))));
}

export function entryKey(entry) {
  return entry.kind + ":" + entry.id;
}

export function sortEntries(entries) {
  return [...entries].sort((a, b) => {
    const rank = (STATUS_ORDER[a.status] ?? 3) - (STATUS_ORDER[b.status] ?? 3);
    if (rank !== 0) return rank;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
}

export function buildModel(payload) {
  const entries = sortEntries(payload.entries || []);
  const byId = new Map();
  const byKey = new Map();
  for (const entry of entries) {
    byKey.set(entryKey(entry), entry);
    if (!byId.has(entry.id)) byId.set(entry.id, entry);
  }
  const chips = [];
  const reachByEntry = new Map();
  const inherits = new Map();
  for (const entry of entries) {
    inherits.set(entryKey(entry), { shipped: 0, global: 0, exceptions: 0 });
    reachByEntry.set(entryKey(entry), new Set());
  }
  for (const band of BANDS) {
    const list = (payload.layers && payload.layers[band.key]) || [];
    for (const item of list) {
      const reaches = [];
      for (const id of item.reaches || []) {
        const entry = byId.get(id);
        if (entry) reaches.push(entryKey(entry));
      }
      const chip = { key: band.key + ":" + item.id, band: band.key, id: item.id, name: item.name || item.id, reaches };
      chips.push(chip);
      for (const key of reaches) {
        reachByEntry.get(key).add(chip.key);
        inherits.get(key)[band.key] += 1;
      }
    }
  }
  const projects = entries.filter((entry) => entry.kind !== "path");
  const paths = entries.filter((entry) => entry.kind === "path");
  return { entries, projects, paths, byKey, chips, reachByEntry, inherits, count: entries.length };
}

export function defaultMetrics(measure) {
  return {
    cardW: 240,
    cardH: 116,
    childH: 52,
    colGap: 24,
    rowGap: 48,
    bandH: 48,
    bandGap: 8,
    bandToGrid: 64,
    pad: 32,
    childGap: 8,
    measure,
  };
}

function chipWidth(label, measure) {
  return Math.min(CHIP_MAX, Math.ceil(measure(label)) + CHIP_PAD * 2 + 2);
}

function packRows(items, available) {
  const rows = [];
  let row = [];
  let used = 0;
  for (const item of items) {
    const next = row.length ? used + CHIP_GAP + item.w : item.w;
    if (row.length && next > available) {
      rows.push(row);
      row = [item];
      used = item.w;
    } else {
      row.push(item);
      used = next;
    }
  }
  if (row.length) rows.push(row);
  return rows;
}

function layoutBands(model, metrics, W, options) {
  const bands = [];
  let y = metrics.pad;
  for (const band of BANDS) {
    let items = model.chips.filter((chip) => chip.band === band.key);
    const count = items.length;
    let collapsed = false;
    if (band.key === "exceptions" && count > COLLAPSE_EXCEPTIONS_AT && !options.expandExceptions) {
      const union = new Set();
      for (const chip of items) for (const key of chip.reaches) union.add(key);
      items = [{ key: COLLAPSED_KEY, band: band.key, id: "__all", name: count + " exceptions", reaches: [...union], collapsed: true }];
      collapsed = true;
    }
    const sized = items.map((chip) => ({ ...chip, w: chipWidth(chip.name, metrics.measure), h: CHIP_H }));
    const symmetric = W - LABEL_W * 2 >= 240;
    const left = symmetric ? LABEL_W : LABEL_W + CHIP_GAP;
    const right = symmetric ? W - LABEL_W : W - CHIP_GAP;
    const available = right - left;
    const rows = packRows(sized, available);
    const axis = (left + right) / 2;
    const rowCount = Math.max(1, rows.length);
    const height = Math.max(metrics.bandH, 24 + rowCount * CHIP_H + (rowCount - 1) * CHIP_GAP);
    const placed = [];
    rows.forEach((row, r) => {
      const rowW = row.reduce((sum, item) => sum + item.w, 0) + CHIP_GAP * (row.length - 1);
      let x = axis - rowW / 2;
      const top = y + (height - (rowCount * CHIP_H + (rowCount - 1) * CHIP_GAP)) / 2 + r * (CHIP_H + CHIP_GAP);
      for (const item of row) {
        placed.push({ ...item, x: metrics.pad + x, y: top, rowIndex: r });
        x += item.w + CHIP_GAP;
      }
    });
    bands.push({ key: band.key, label: band.label, count, collapsed, expandable: band.key === "exceptions" && count > COLLAPSE_EXCEPTIONS_AT, x: metrics.pad, y, w: W, h: height, axis: metrics.pad + axis, chips: placed });
    y += height + metrics.bandGap;
  }
  return { bands, bottom: y - metrics.bandGap };
}

function stackHeight(entry, metrics) {
  const n = (entry.globs || []).length;
  return metrics.cardH + n * (metrics.childH + metrics.childGap);
}

function layoutSection(list, N, startY, metrics, positions, cards) {
  let y = startY;
  for (let i = 0; i < list.length; i += N) {
    const row = list.slice(i, i + N);
    const offset = ((N - row.length) * (metrics.cardW + metrics.colGap)) / 2;
    let rowH = 0;
    row.forEach((entry, c) => {
      const key = entryKey(entry);
      let x = metrics.pad + offset + c * (metrics.cardW + metrics.colGap);
      let cy = y;
      const saved = positions && positions[key];
      if (saved && Number.isFinite(saved.x) && Number.isFinite(saved.y)) {
        x = saved.x;
        cy = saved.y;
      }
      const children = (entry.globs || []).map((glob, g) => ({
        key: key + "#" + g,
        parent: key,
        glob: glob.glob,
        matched: glob.matched,
        x,
        y: cy + metrics.cardH + metrics.childGap + g * (metrics.childH + metrics.childGap),
        w: metrics.cardW,
        h: metrics.childH,
      }));
      cards.push({ key, entry, x, y: cy, w: metrics.cardW, h: metrics.cardH, pinned: Boolean(saved), children });
      rowH = Math.max(rowH, stackHeight(entry, metrics));
    });
    y += rowH + metrics.rowGap;
  }
  return y - metrics.rowGap;
}

export function computeLayout(model, metrics, options = {}) {
  const N = columnCount(model.count);
  const W = N * metrics.cardW + (N - 1) * metrics.colGap;
  const { bands, bottom } = layoutBands(model, metrics, W, options);
  const gridY = bottom + metrics.bandToGrid;
  const cards = [];
  const labels = [];
  let end = gridY;
  let emptyBox = null;
  if (model.count === 0) {
    emptyBox = { x: metrics.pad, y: gridY, w: W, h: 200 };
    end = gridY + emptyBox.h;
  } else {
    if (model.projects.length) end = layoutSection(model.projects, N, gridY, metrics, options.positions, cards);
    if (model.paths.length) {
      const labelY = model.projects.length ? end + metrics.rowGap : gridY;
      labels.push({ text: "Path entries", x: metrics.pad, y: labelY, w: W, h: GROUP_LABEL_H });
      end = layoutSection(model.paths, N, labelY + GROUP_LABEL_H + metrics.childGap, metrics, options.positions, cards);
    }
  }
  let maxX = metrics.pad + W;
  let maxY = end;
  let minX = metrics.pad;
  let minY = metrics.pad;
  for (const card of cards) {
    maxX = Math.max(maxX, card.x + card.w);
    minX = Math.min(minX, card.x);
    minY = Math.min(minY, card.y);
    const tail = card.children.length ? card.children[card.children.length - 1] : card;
    maxY = Math.max(maxY, tail.y + tail.h);
  }
  return {
    N,
    W,
    bands,
    cards,
    labels,
    emptyBox,
    bounds: { x: Math.min(0, minX - metrics.pad), y: Math.min(0, minY - metrics.pad), width: maxX + metrics.pad, height: maxY + metrics.pad },
  };
}

export function skeletonLayout(metrics) {
  const model = buildModel({ entries: [], layers: {} });
  const layout = computeLayout({ ...model, count: 6, projects: [], paths: [], chips: [] }, metrics, {});
  const placeholders = [];
  const N = columnCount(6);
  const gridY = layout.bands[layout.bands.length - 1].y + layout.bands[layout.bands.length - 1].h + metrics.bandToGrid;
  for (let i = 0; i < 6; i += 1) {
    const row = Math.floor(i / N);
    const col = i % N;
    placeholders.push({ x: metrics.pad + col * (metrics.cardW + metrics.colGap), y: gridY + row * (metrics.cardH + metrics.rowGap), w: metrics.cardW, h: metrics.cardH });
  }
  const last = placeholders[placeholders.length - 1];
  return { bands: layout.bands, W: layout.W, placeholders, bounds: { x: 0, y: 0, width: metrics.pad * 2 + layout.W, height: last.y + last.h + metrics.pad } };
}

export function positionOf(layout, key) {
  const card = layout.cards.find((item) => item.key === key);
  return card ? { x: card.x, y: card.y } : null;
}
