const DEBOUNCE_MS = 1000;
const last = new Map();
const timers = new Map();

function region(assertive) {
  return document.getElementById(assertive ? "live-assertive" : "live-polite");
}

export function announce(text, { assertive = false } = {}) {
  const message = String(text || "").trim();
  if (!message) return false;
  const now = Date.now();
  const key = (assertive ? "a:" : "p:") + message;
  const seen = last.get(key);
  if (seen !== undefined && now - seen < DEBOUNCE_MS) return false;
  last.set(key, now);
  const target = region(assertive);
  if (!target) return false;
  window.clearTimeout(timers.get(assertive));
  target.textContent = "";
  timers.set(
    assertive,
    window.setTimeout(() => {
      target.textContent = message;
    }, 20)
  );
  return true;
}

export function toast(text, { kind = "info", title = "", action = null } = {}) {
  const detail = { text, kind, title, action };
  document.dispatchEvent(new CustomEvent("ps-toast", { detail, bubbles: true }));
  announce(title ? title + ". " + text : text, { assertive: kind === "error" });
}
