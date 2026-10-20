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
  let value = flags[name];
  if (value === undefined && name.includes(".")) {
    const [head, ...rest] = name.split(".");
    const node = flags[head];
    if (node && typeof node === "object" && rest.join(".") === "enabled" && "enabled" in node) {
      return { enabled: node.enabled !== false, reason: node.reason || "" };
    }
    value = rest.reduce((cursor, key) => (cursor && typeof cursor === "object" ? cursor[key] : undefined), node);
  }
  if (value === undefined) return { enabled: true, reason: "" };
  if (typeof value === "object" && value !== null) {
    return { enabled: value.enabled !== false, reason: value.reason || "" };
  }
  return { enabled: value !== false, reason: "" };
}
