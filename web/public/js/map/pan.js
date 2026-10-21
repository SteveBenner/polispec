export const ZOOM_STEPS = [0.5, 0.75, 1, 1.25, 1.5];
export const MIN_ZOOM = ZOOM_STEPS[0];
export const MAX_ZOOM = ZOOM_STEPS[ZOOM_STEPS.length - 1];

export function clampZoom(z) {
  return Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, z));
}

export function nextStep(z, direction) {
  if (direction > 0) {
    for (const step of ZOOM_STEPS) if (step > z + 0.001) return step;
    return MAX_ZOOM;
  }
  for (let i = ZOOM_STEPS.length - 1; i >= 0; i -= 1) if (ZOOM_STEPS[i] < z - 0.001) return ZOOM_STEPS[i];
  return MIN_ZOOM;
}

export class PanZoom {
  constructor(onChange) {
    this.x = 0;
    this.y = 0;
    this.z = 1;
    this.onChange = onChange || (() => {});
  }

  set(x, y, z) {
    this.x = x;
    this.y = y;
    this.z = clampZoom(z === undefined ? this.z : z);
    this.onChange(this);
  }

  panBy(dx, dy) {
    this.set(this.x + dx, this.y + dy);
  }

  zoomTo(z, px, py) {
    const next = clampZoom(z);
    const ratio = next / this.z;
    this.set(px - (px - this.x) * ratio, py - (py - this.y) * ratio, next);
  }

  zoomStep(direction, px, py) {
    this.zoomTo(nextStep(this.z, direction), px, py);
  }

  fit(viewW, viewH, bounds) {
    const ratio = viewW / bounds.width;
    const z = clampZoom(Math.min(1, ratio));
    const width = bounds.width * z;
    const x = (viewW - width) / 2 - bounds.x * z;
    this.set(x, -bounds.y * z, z);
  }

  reveal(rect, viewW, viewH, margin = 24) {
    let dx = 0;
    let dy = 0;
    const left = rect.x * this.z + this.x;
    const top = rect.y * this.z + this.y;
    const right = left + rect.w * this.z;
    const bottom = top + rect.h * this.z;
    if (left < margin) dx = margin - left;
    else if (right > viewW - margin) dx = viewW - margin - right;
    if (top < margin) dy = margin - top;
    else if (bottom > viewH - margin) dy = viewH - margin - bottom;
    if (dx || dy) this.panBy(dx, dy);
  }
}

export function bindPointerPan(host, pan, isBackground) {
  let drag = null;
  host.addEventListener("pointerdown", (event) => {
    if (event.button !== 0 || !isBackground(event.target)) return;
    drag = { id: event.pointerId, x: event.clientX, y: event.clientY };
    host.setPointerCapture(event.pointerId);
    host.dataset.panning = "true";
  });
  host.addEventListener("pointermove", (event) => {
    if (!drag || drag.id !== event.pointerId) return;
    pan.panBy(event.clientX - drag.x, event.clientY - drag.y);
    drag.x = event.clientX;
    drag.y = event.clientY;
  });
  const end = (event) => {
    if (!drag || drag.id !== event.pointerId) return;
    drag = null;
    delete host.dataset.panning;
    if (host.hasPointerCapture(event.pointerId)) host.releasePointerCapture(event.pointerId);
  };
  host.addEventListener("pointerup", end);
  host.addEventListener("pointercancel", end);
}

export function bindWheel(host, pan) {
  host.addEventListener(
    "wheel",
    (event) => {
      event.preventDefault();
      const rect = host.getBoundingClientRect();
      if (event.ctrlKey || event.metaKey) {
        const px = event.clientX - rect.left;
        const py = event.clientY - rect.top;
        const factor = Math.exp(-event.deltaY * 0.0025);
        pan.zoomTo(pan.z * factor, px, py);
        return;
      }
      if (event.shiftKey) pan.panBy(-(event.deltaX || event.deltaY), 0);
      else pan.panBy(-event.deltaX, -event.deltaY);
    },
    { passive: false }
  );
}
