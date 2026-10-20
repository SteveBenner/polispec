import { getPref, setPref } from "./cache.js";

const CHORD_TIMEOUT_MS = 1500;
const TEXT_TARGETS =
  'input, textarea, select, [contenteditable=""], [contenteditable="true"], [role="textbox"], [role="combobox"], .cm-editor';
const registry = [];
let pendingPrefix = null;
let pendingTimer = null;
let started = false;

export const isMac = /Mac|iPhone|iPad/.test(window.navigator.platform || window.navigator.userAgent || "");

export function register(shortcut) {
  const entry = { group: "General", mod: false, ...shortcut };
  registry.push(entry);
  return () => {
    const index = registry.indexOf(entry);
    if (index !== -1) registry.splice(index, 1);
  };
}

export function list() {
  return registry.map(({ keys, description, group, mod }) => ({ keys, description, group, mod }));
}

export function isSingleKeyEnabled() {
  return getPref("shortcuts", true) !== false;
}

export function setSingleKeyEnabled(enabled) {
  setPref("shortcuts", Boolean(enabled));
}

function inTextField(event) {
  const targets = [event.target, document.activeElement];
  return targets.some((node) => node instanceof Element && node.closest(TEXT_TARGETS));
}

function normalize(key) {
  return key.length === 1 ? key.toLowerCase() : key;
}

function clearPending() {
  pendingPrefix = null;
  if (pendingTimer !== null) window.clearTimeout(pendingTimer);
  pendingTimer = null;
}

function run(entry, event) {
  event.preventDefault();
  entry.handler(event);
}

function onKeydown(event) {
  if (event.defaultPrevented || event.isComposing) return;
  const key = normalize(event.key);
  const modifier = isMac ? event.metaKey : event.ctrlKey;
  if (modifier && !event.altKey) {
    const match = registry.find((entry) => entry.mod && normalize(entry.keys) === key);
    if (match) run(match, event);
    return;
  }
  if (event.ctrlKey || event.metaKey || event.altKey) return;
  if (key === "Shift" || key === "Control" || key === "Meta" || key === "Alt") return;
  if (inTextField(event) || !isSingleKeyEnabled()) {
    clearPending();
    return;
  }
  if (pendingPrefix) {
    const chord = pendingPrefix + " " + key;
    clearPending();
    const hit = registry.find((entry) => !entry.mod && entry.keys === chord);
    if (hit) run(hit, event);
    return;
  }
  const single = registry.find((entry) => !entry.mod && entry.keys === key);
  if (single) {
    run(single, event);
    return;
  }
  if (registry.some((entry) => !entry.mod && entry.keys.startsWith(key + " "))) {
    pendingPrefix = key;
    pendingTimer = window.setTimeout(clearPending, CHORD_TIMEOUT_MS);
  }
}

export function start() {
  if (started) return;
  started = true;
  document.addEventListener("keydown", onKeydown);
}

export function stop() {
  started = false;
  clearPending();
  document.removeEventListener("keydown", onKeydown);
}
