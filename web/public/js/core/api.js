import { ApiError, fromResponse, offlineError, timeoutError } from "./errors.js";
import { app, flag } from "./store.js";
import { toast } from "./announce.js";

export const BASE = "/api/v1";
export const RETRY_LIMIT = 2;
export const RETRY_BASE_MS = 250;
export const RETRYABLE_STATUS = [502, 503, 504];
export const MUTATION_LIMIT = 30;
export const MUTATION_WINDOW_MS = 60000;

const FEATURE_GATES = [
  { pattern: /^\/author(\/|$)/, flag: "author" },
  { pattern: /^\/judgments\/stream$/, flag: "feed" },
];

let csrfToken = null;

export function setCsrf(token) {
  csrfToken = token || null;
}

export function hasCsrf() {
  return csrfToken !== null;
}

export const limiter = {
  tokens: MUTATION_LIMIT,
  stamp: performance.now(),
  refill() {
    const now = performance.now();
    const earned = ((now - this.stamp) / MUTATION_WINDOW_MS) * MUTATION_LIMIT;
    this.tokens = Math.min(MUTATION_LIMIT, this.tokens + earned);
    this.stamp = now;
  },
  take() {
    this.refill();
    if (this.tokens >= 1) {
      this.tokens -= 1;
      return { ok: true, wait: 0 };
    }
    const missing = 1 - this.tokens;
    const wait = Math.ceil((missing / MUTATION_LIMIT) * (MUTATION_WINDOW_MS / 1000));
    return { ok: false, wait };
  },
  available() {
    this.refill();
    return Math.floor(this.tokens);
  },
};

export function timeoutFor(method, path) {
  if (method === "GET" || method === "HEAD") return 10000;
  if (/^(\/api\/v1)?\/plans\/[^/]+\/apply$/.test(path)) return 120000;
  if (/^(\/api\/v1)?\/plans$/.test(path)) return 60000;
  return 30000;
}

export function retryDelay(index, random = Math.random()) {
  const base = RETRY_BASE_MS * 2 ** index;
  return Math.round(base * (0.5 + random));
}

function resolveUrl(path) {
  const absolute = /^[a-z][a-z0-9+.-]*:|^\/\//i.test(path);
  const raw = absolute ? path : path.startsWith(BASE) ? path : BASE + (path.startsWith("/") ? path : "/" + path);
  const url = new URL(raw, window.location.origin);
  if (url.origin !== window.location.origin) {
    throw new TypeError("Requests to another origin are refused: " + url.origin);
  }
  return url;
}

function sleep(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal && signal.aborted) {
      reject(new DOMException("Aborted", "AbortError"));
      return;
    }
    const timer = window.setTimeout(resolve, ms);
    if (signal) {
      signal.addEventListener(
        "abort",
        () => {
          window.clearTimeout(timer);
          reject(new DOMException("Aborted", "AbortError"));
        },
        { once: true }
      );
    }
  });
}

function checkFeature(pathname) {
  const relative = pathname.startsWith(BASE) ? pathname.slice(BASE.length) : pathname;
  for (const gate of FEATURE_GATES) {
    if (gate.pattern.test(relative)) {
      const state = flag(gate.flag);
      if (!state.enabled) {
        throw new ApiError("disabled", state.reason || "This feature is turned off on the server");
      }
    }
  }
}

function rateLimitCopy(seconds) {
  return "Too many changes in a minute. Try again in " + seconds + " s.";
}

function noteFailure(error, isExchange) {
  if (isExchange) return;
  const state = app.get();
  if (error.kind === "offline" && state.session === "active") {
    app.set({ offline: true });
  } else if (error.kind === "unauthorized") {
    if (state.session === "active") {
      app.set({ session: "session_ended", cause: "The session expired or was signed out" });
    } else if (state.session === "unknown" || state.session === "exchanging") {
      app.set({ session: "no_session", cause: null });
    }
  } else if (error.kind === "forbidden" && state.session === "active") {
    app.set({ session: "session_ended", cause: error.message });
  } else if (error.kind === "rate_limited") {
    toast(rateLimitCopy(error.retryAfter == null ? 60 : error.retryAfter), { kind: "error" });
  }
}

async function readBody(response) {
  const type = response.headers.get("Content-Type") || "";
  if (response.status === 204 || response.status === 304) return null;
  if (type.includes("json")) {
    try {
      return await response.json();
    } catch (error) {
      return null;
    }
  }
  return await response.text();
}

export async function requestFull(method, path, options = {}) {
  const verb = method.toUpperCase();
  const url = resolveUrl(path);
  const isRead = verb === "GET" || verb === "HEAD";
  const isExchange = verb === "POST" && url.pathname === BASE + "/session";
  const timeout = options.timeout || timeoutFor(verb, url.pathname);
  checkFeature(url.pathname);

  if (!isRead && !isExchange) {
    if (!hasCsrf()) {
      const missing = new ApiError("forbidden", "This tab has no CSRF token. Open a new link from the terminal.", {
        status: 403,
      });
      noteFailure(missing, false);
      throw missing;
    }
    const grant = limiter.take();
    if (!grant.ok) {
      toast(rateLimitCopy(grant.wait), { kind: "error" });
      throw new ApiError("rate_limited", rateLimitCopy(grant.wait), { retryAfter: grant.wait });
    }
  }

  const headers = { Accept: "application/json" };
  let payload;
  if (options.body !== undefined) {
    headers["Content-Type"] = "application/json";
    payload = JSON.stringify(options.body);
  }
  if (!isRead && csrfToken) headers["X-Polispec-CSRF"] = csrfToken;
  if (options.etag) headers["If-None-Match"] = options.etag;

  const retryable = isRead && options.retry !== false;
  const started = performance.now();
  let attempt = 0;

  for (;;) {
    attempt += 1;
    const controller = new AbortController();
    let timedOut = false;
    const timer = window.setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, timeout);
    const forward = () => controller.abort();
    if (options.signal) {
      if (options.signal.aborted) controller.abort();
      options.signal.addEventListener("abort", forward, { once: true });
    }

    let response;
    let data;
    try {
      response = await window.fetch(url, {
        method: verb,
        headers,
        body: payload,
        credentials: "same-origin",
        cache: "no-store",
        signal: controller.signal,
      });
      data = await readBody(response);
    } catch (cause) {
      const elapsed = Math.round(performance.now() - started);
      if (timedOut) {
        const error = timeoutError(elapsed, attempt);
        noteFailure(error, isExchange);
        throw error;
      }
      if (options.signal && options.signal.aborted) throw cause;
      if (retryable && attempt <= RETRY_LIMIT) {
        await sleep(retryDelay(attempt - 1), options.signal);
        continue;
      }
      const error = offlineError(attempt, elapsed);
      noteFailure(error, isExchange);
      throw error;
    } finally {
      window.clearTimeout(timer);
      if (options.signal) options.signal.removeEventListener("abort", forward);
    }

    if (retryable && RETRYABLE_STATUS.includes(response.status) && attempt <= RETRY_LIMIT) {
      await sleep(retryDelay(attempt - 1), options.signal);
      continue;
    }

    const elapsed = Math.round(performance.now() - started);
    if (response.ok || response.status === 304) {
      if (app.get().offline) app.set({ offline: false });
      return { status: response.status, data, etag: response.headers.get("ETag"), attempts: attempt };
    }
    const error = fromResponse(response, data, attempt, elapsed);
    noteFailure(error, isExchange);
    throw error;
  }
}

export async function get(path, options) {
  return (await requestFull("GET", path, options)).data;
}

export async function post(path, body, options = {}) {
  return (await requestFull("POST", path, { ...options, body })).data;
}

export async function put(path, body, options = {}) {
  return (await requestFull("PUT", path, { ...options, body })).data;
}

export async function del(path, options) {
  return (await requestFull("DELETE", path, options)).data;
}

function query(params) {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params || {})) {
    if (value !== undefined && value !== null && value !== "") search.set(key, String(value));
  }
  const text = search.toString();
  return text ? "?" + text : "";
}

const enc = encodeURIComponent;

export const endpoints = {
  session: "/session",
  config: "/config",
  map: "/map",
  catalog: "/catalog",
  editions: "/editions",
  source: (kind, id) => `/rulebooks/${enc(kind)}/${enc(id)}/source`,
  composition: (kind, id, params) => `/rulebooks/${enc(kind)}/${enc(id)}/composition${query(params)}`,
  history: (kind, id, params) => `/rulebooks/${enc(kind)}/${enc(id)}/history${query(params)}`,
  lint: "/lint",
  plans: "/plans",
  plan: (id) => `/plans/${enc(id)}`,
  apply: (id) => `/plans/${enc(id)}/apply`,
  explain: "/explain",
  explainText: "/explain-text",
  blastRadius: "/blast-radius",
  pipeline: "/pipeline",
  heatmap: (params) => `/heatmap${query(params)}`,
  sessions: (params) => `/sessions${query(params)}`,
  changes: (params) => `/changes${query(params)}`,
  judgments: (params) => `/judgments${query(params)}`,
  stream: "/judgments/stream",
  exceptions: "/exceptions",
  proposals: "/exceptions/proposals",
  exceptionVerb: (verb) => `/exceptions/${enc(verb)}`,
  run: (id, params) => `/runs/${enc(id)}${query(params)}`,
  runPhrase: (id) => `/runs/${enc(id)}/phrase`,
  manifestIndex: "/manifest/index",
  manifest: (id) => `/manifest/${enc(id)}`,
  badge: (id) => `/badge/${enc(id)}.svg`,
  register: "/register",
  authorSessions: "/author/sessions",
  authorTurns: (sid) => `/author/sessions/${enc(sid)}/turns`,
  authorStream: (sid) => `/author/sessions/${enc(sid)}/stream`,
  authorStop: (sid) => `/author/sessions/${enc(sid)}/stop`,
  authorSession: (sid) => `/author/sessions/${enc(sid)}`,
  state: (name) => `/state/${enc(name)}`,
};
