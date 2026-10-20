import { get, post, del, endpoints, setCsrf } from "./api.js";
import { app } from "./store.js";

function clearHash() {
  try {
    window.history.replaceState(null, "", window.location.pathname + window.location.search + "#/map");
  } catch (error) {
    window.location.hash = "#/map";
  }
}

function takeCode() {
  const hash = window.location.hash;
  if (!hash.startsWith("#k=")) return null;
  let code = hash.slice(3);
  try {
    code = decodeURIComponent(code);
  } catch (error) {
    code = hash.slice(3);
  }
  clearHash();
  return code;
}

function gateForFailure(error, fallback) {
  if (error.kind === "offline" || error.kind === "timeout") return "server_unreachable";
  return fallback;
}

export async function loadConfig() {
  const config = await get(endpoints.config);
  app.set({ config });
  return config;
}

async function exchange(code) {
  app.set({ session: "exchanging", cause: null });
  try {
    const result = await post(endpoints.session, { code });
    setCsrf(result && result.csrf);
  } catch (error) {
    setCsrf(null);
    app.set({ session: gateForFailure(error, "link_used_or_expired"), cause: error.message });
    return false;
  }
  try {
    await loadConfig();
  } catch (error) {
    app.set({ session: gateForFailure(error, "session_ended"), cause: error.message });
    return false;
  }
  app.set({ session: "active", cause: null, offline: false });
  return true;
}

async function probe() {
  app.set({ session: "exchanging", cause: null });
  try {
    const current = await get(endpoints.session);
    setCsrf(current && current.csrf);
    await loadConfig();
    app.set({ session: "active", cause: null, offline: false });
    return true;
  } catch (error) {
    setCsrf(null);
    if (error.kind === "unauthorized") {
      app.set({ session: "no_session", cause: null });
    } else {
      app.set({ session: "server_unreachable", cause: error.message });
    }
    return false;
  }
}

export async function bootSession() {
  const code = takeCode();
  if (code !== null) return exchange(code);
  return probe();
}

export function watchLinks() {
  window.addEventListener("hashchange", () => {
    if (!window.location.hash.startsWith("#k=")) return;
    const code = takeCode();
    if (code !== null) exchange(code);
  });
}

export async function endSession() {
  try {
    await del(endpoints.session);
  } finally {
    setCsrf(null);
    app.set({ session: "session_ended", cause: "Signed out" });
  }
}
