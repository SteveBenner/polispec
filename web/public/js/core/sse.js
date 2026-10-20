import { BASE, endpoints, get } from "./api.js";
import { app, flag } from "./store.js";

export const BUFFER_SIZE = 1000;
export const BACKOFF_STEPS_MS = [1000, 2000, 4000, 8000, 16000];
export const BACKOFF_STEADY_MS = 30000;
export const BACKOFF_JITTER = 0.3;

let state = "closed";
let source = null;
let timer = null;
let attempts = 0;
let nextDelay = null;
let started = false;
let events = [];
const listeners = new Set();

export function backoff(attempt, random = Math.random()) {
  const base = attempt < BACKOFF_STEPS_MS.length ? BACKOFF_STEPS_MS[attempt] : BACKOFF_STEADY_MS;
  return Math.round(base * (1 - BACKOFF_JITTER + 2 * BACKOFF_JITTER * random));
}

function emit(type, payload) {
  for (const listener of [...listeners]) listener(type, payload);
}

function setState(next) {
  if (state === next) return;
  state = next;
  app.set({ feed: next });
  emit("state", next);
}

function closeSource() {
  if (!source) return;
  source.close();
  source = null;
}

function clearTimer() {
  if (timer !== null) window.clearTimeout(timer);
  timer = null;
  nextDelay = null;
}

function push(record) {
  events.push(record);
  if (events.length > BUFFER_SIZE) events.splice(0, events.length - BUFFER_SIZE);
  emit("judgment", record);
}

function schedule() {
  clearTimer();
  if (!started) return;
  if (document.hidden) {
    setState("paused");
    return;
  }
  setState("reconnecting");
  const delay = backoff(attempts);
  attempts += 1;
  nextDelay = delay;
  timer = window.setTimeout(connect, delay);
}

function connect() {
  clearTimer();
  closeSource();
  if (!started) return;
  if (document.hidden) {
    setState("paused");
    return;
  }
  setState(attempts === 0 ? "connecting" : "reconnecting");
  source = new window.EventSource(BASE + endpoints.stream);
  source.addEventListener("open", () => {
    attempts = 0;
    setState("live");
  });
  source.addEventListener("judgment", (event) => {
    let record = event.data;
    try {
      record = JSON.parse(event.data);
    } catch (error) {
      record = event.data;
    }
    push(record);
  });
  source.addEventListener("error", async () => {
    closeSource();
    if (attempts === 0) {
      await get(endpoints.config, { retry: false }).catch(() => null);
    }
    if (!started) return;
    if (app.get().session !== "active") {
      stop();
      return;
    }
    schedule();
  });
}

function onVisibility() {
  if (!started) return;
  if (document.hidden) {
    clearTimer();
    closeSource();
    setState("paused");
    return;
  }
  if (state === "paused") connect();
}

export function start() {
  if (started) return;
  if (!flag("feed.enabled").enabled) {
    setState("disabled");
    return;
  }
  started = true;
  document.addEventListener("visibilitychange", onVisibility);
  if (document.hidden) setState("paused");
  else connect();
}

export function stop() {
  started = false;
  document.removeEventListener("visibilitychange", onVisibility);
  clearTimer();
  closeSource();
  attempts = 0;
  setState("closed");
}

export function subscribe(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function getState() {
  return state;
}

export function getEvents() {
  return events.slice();
}

export function status() {
  return { state, attempts, nextDelay, buffered: events.length };
}
