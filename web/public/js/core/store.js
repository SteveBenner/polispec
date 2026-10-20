export function createStore(initial) {
  let state = { ...initial };
  const listeners = new Set();
  return {
    get() {
      return state;
    },
    set(patch) {
      const next = { ...state, ...patch };
      const changed = Object.keys(patch).some((key) => next[key] !== state[key]);
      state = next;
      if (changed) for (const listener of [...listeners]) listener(state);
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}

export const app = createStore({
  session: "unknown",
  cause: null,
  offline: false,
  config: null,
  feed: "closed",
});

export function flag(name) {
  const flags = (app.get().config && app.get().config.flags) || {};
  const node = flags[name];
  if (!node || typeof node !== "object") return { enabled: true, reason: "" };
  const on = node.enabled !== false && node.allowed !== false;
  return { enabled: on, reason: node.reason || "" };
}

export function descriptionAllowed() {
  return flag("description");
}

export const READ_ONLY_REASON = "Read-only. This server was started with --read-only; changes are made from a terminal.";

export function readOnly() {
  const config = app.get().config;
  return Boolean(config && config.read_only === true);
}
