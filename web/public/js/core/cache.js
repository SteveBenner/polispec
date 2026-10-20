import { requestFull } from "./api.js";
import { formatDuration } from "./format.js";

const VIEW_PREFIX = "polispec.web.view:";
const PREF_PREFIX = "polispec.web.pref.";
const memoryViews = new Map();
const memoryPrefs = new Map();

function area(name) {
  try {
    return name === "session" ? window.sessionStorage : window.localStorage;
  } catch (error) {
    return null;
  }
}

export function readView(key) {
  const storage = area("session");
  if (storage) {
    try {
      const raw = storage.getItem(VIEW_PREFIX + key);
      if (raw) return JSON.parse(raw);
    } catch (error) {
      return memoryViews.get(key) || null;
    }
  }
  return memoryViews.get(key) || null;
}

export function writeView(key, entry) {
  const record = { etag: entry.etag || null, savedAt: Date.now(), payload: entry.payload };
  memoryViews.set(key, record);
  const storage = area("session");
  if (!storage) return record;
  try {
    storage.setItem(VIEW_PREFIX + key, JSON.stringify(record));
  } catch (error) {
    return record;
  }
  return record;
}

export function clearViews() {
  memoryViews.clear();
  const storage = area("session");
  if (!storage) return;
  try {
    const doomed = [];
    for (let index = 0; index < storage.length; index += 1) {
      const name = storage.key(index);
      if (name && name.startsWith(VIEW_PREFIX)) doomed.push(name);
    }
    for (const name of doomed) storage.removeItem(name);
  } catch (error) {
    return;
  }
}

export function getPref(name, fallback) {
  if (memoryPrefs.has(name)) return memoryPrefs.get(name);
  const storage = area("local");
  if (!storage) return fallback;
  try {
    const raw = storage.getItem(PREF_PREFIX + name);
    if (raw === null) return fallback;
    return JSON.parse(raw);
  } catch (error) {
    return fallback;
  }
}

export function setPref(name, value) {
  memoryPrefs.set(name, value);
  const storage = area("local");
  if (!storage) return;
  try {
    storage.setItem(PREF_PREFIX + name, JSON.stringify(value));
  } catch (error) {
    return;
  }
}

function buildChip(savedAt, state, onRetry) {
  const chip = document.createElement("ps-chip");
  chip.setAttribute("data-freshness", "");
  chip.setAttribute("state", state);
  const age = "Cached " + formatDuration(Date.now() - savedAt);
  chip.append(document.createTextNode(age + (state === "failed" ? ", refresh failed" : ", refreshing")));
  if (state === "failed") {
    const retry = document.createElement("button");
    retry.type = "button";
    retry.setAttribute("aria-label", "Retry");
    retry.setAttribute("data-retry", "");
    retry.innerHTML = '<svg class="ps-icon" aria-hidden="true"><use href="icons/icons.svg#i-reset"/></svg>';
    retry.addEventListener("click", onRetry, { once: true });
    chip.append(retry);
  }
  return chip;
}

export async function loadView({ key, path, chipHost, signal, render }) {
  const cached = readView(key);
  let chip = null;
  const setChip = (next) => {
    if (chip) chip.remove();
    chip = next;
    if (chip && chipHost) chipHost.append(chip);
  };

  const refresh = async () => {
    try {
      const result = await requestFull("GET", path, { signal, etag: cached ? cached.etag : null });
      if (result.status === 304 && cached) {
        setChip(null);
        return cached.payload;
      }
      writeView(key, { etag: result.etag, payload: result.data });
      render(result.data, { cached: false, savedAt: Date.now() });
      setChip(null);
      return result.data;
    } catch (error) {
      if (signal && signal.aborted) throw error;
      if (!cached) throw error;
      setChip(
        buildChip(cached.savedAt, "failed", () => {
          setChip(buildChip(cached.savedAt, "refreshing"));
          refresh().catch(() => {});
        })
      );
      return cached.payload;
    }
  };

  if (cached) {
    render(cached.payload, { cached: true, savedAt: cached.savedAt });
    setChip(buildChip(cached.savedAt, "refreshing"));
  }
  return refresh();
}
