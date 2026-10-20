const NS = "http://www.w3.org/2000/svg";
export const EDGE_HIDE_ABOVE = 200;

export function buildEdges(layout) {
  const cardByKey = new Map();
  for (const card of layout.cards) cardByKey.set(card.key, card);
  const edges = [];
  for (const band of layout.bands) {
    for (const chip of band.chips) {
      for (const key of chip.reaches) {
        const card = cardByKey.get(key);
        if (!card) continue;
        edges.push({
          key: chip.key + ">" + key,
          chip: chip.key,
          card: key,
          band: band.key,
          x1: chip.x + chip.w / 2,
          y1: chip.y + chip.h,
          x2: card.x + card.w / 2,
          y2: card.y,
          partial: Boolean(card.entry.error),
        });
      }
    }
  }
  return edges;
}

export function pathD(edge) {
  const d = edge.y2 - edge.y1;
  return `M${edge.x1} ${edge.y1} C${edge.x1} ${edge.y1 + d / 2} ${edge.x2} ${edge.y2 - d / 2} ${edge.x2} ${edge.y2}`;
}

export function blastEdges(layout, source, flips) {
  const cardByKey = new Map();
  for (const card of layout.cards) cardByKey.set(card.entry.id, card);
  let anchor = null;
  for (const band of layout.bands) {
    for (const chip of band.chips) {
      if (source && chip.id === source.module && chip.band === (source.layer || chip.band)) anchor = chip;
    }
  }
  if (!anchor && source && source.layer) {
    const band = layout.bands.find((item) => item.key === source.layer);
    if (band && band.chips.length) anchor = band.chips[0];
  }
  if (!anchor) return [];
  const out = [];
  for (const [id, flip] of flips) {
    const card = cardByKey.get(id);
    if (!card) continue;
    out.push({
      key: "blast>" + id,
      card: card.key,
      tone: flip.stricter >= flip.looser ? "stricter" : "looser",
      x1: anchor.x + anchor.w / 2,
      y1: anchor.y + anchor.h,
      x2: card.x + card.w / 2,
      y2: card.y,
    });
  }
  return out;
}

export function createSvg(width, height) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "ps-map-edges");
  svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("width", String(width));
  svg.setAttribute("height", String(height));
  svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
  return svg;
}

export function renderEdges(svg, edges, options = {}) {
  if (!options.append) svg.textContent = "";
  const nodes = new Map();
  for (const edge of edges) {
    const path = document.createElementNS(NS, "path");
    path.setAttribute("d", pathD(edge));
    path.setAttribute("fill", "none");
    path.setAttribute("vector-effect", "non-scaling-stroke");
    path.setAttribute("class", "ps-edge" + (edge.partial ? " ps-edge-partial" : "") + (edge.tone ? " ps-edge-blast" : ""));
    if (edge.tone) path.setAttribute("data-tone", edge.tone);
    path.dataset.key = edge.key;
    svg.append(path);
    nodes.set(edge.key, path);
  }
  return nodes;
}

export function raise(svg, node) {
  svg.append(node);
}
