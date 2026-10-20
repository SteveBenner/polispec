import "./ps-tabs.js";
import "./ps-button.js";
import "./ps-icon-button.js";
import "./ps-chip.js";
import "./ps-card.js";
import "./ps-banner.js";
import "./ps-state.js";
import "./ps-select.js";
import "./ps-textarea.js";
import "./ps-command.js";
import { get, post, del, BASE, endpoints } from "../core/api.js";
import { flag } from "../core/store.js";
import { announce } from "../core/announce.js";
import { middleTruncate } from "../core/format.js";
import * as router from "../core/router.js";

export const MAX_SESSIONS = 3;
export const TURN_LIMIT_MS = 180000;
export const IDLE_LIMIT_MS = 15 * 60 * 1000;
export const IDLE_WARN_MS = 13 * 60 * 1000;
export const PENDING_KEY = "polispec.web.author-draft";

const NS = "http://www.w3.org/2000/svg";
const TOOLS = ["delta", "tool", "draft", "status", "error", "done", "closed"];

function icon(name) {
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("class", "ps-icon");
  svg.setAttribute("aria-hidden", "true");
  const use = document.createElementNS(NS, "use");
  use.setAttribute("href", `icons/icons.svg#i-${name}`);
  svg.append(use);
  return svg;
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

export function rulebookList(catalog) {
  const out = [];
  const source = catalog && catalog.rulebooks;
  if (Array.isArray(source)) {
    for (const item of source) {
      if (item && item.kind && item.id) out.push({ kind: item.kind, id: item.id, scope: item.scope || item.kind });
    }
  } else if (source && typeof source === "object") {
    for (const [kind, list] of Object.entries(source)) {
      for (const item of Array.isArray(list) ? list : []) {
        const id = typeof item === "string" ? item : item && (item.id || item.name);
        if (id) out.push({ kind, id, scope: (item && item.scope) || kind });
      }
    }
  }
  return out;
}

let catalogPromise = null;

export function loadCatalog(force) {
  if (!catalogPromise || force) {
    catalogPromise = get(endpoints.catalog).catch((error) => {
      catalogPromise = null;
      throw error;
    });
  }
  return catalogPromise;
}

const bus = new Set();
const model = {
  sessions: [],
  active: 0,
  rateUntil: 0,
  target: null,
  disabled: null,
  counter: 0,
};

function emit(type, session, item) {
  for (const listener of [...bus]) listener(type, session, item);
}

export function subscribeAuthor(listener) {
  bus.add(listener);
  return () => bus.delete(listener);
}

export function setAuthorTarget(target) {
  model.target = target && target.kind && target.id ? { kind: target.kind, id: target.id } : null;
  emit("target", null, null);
}

export function takePendingDraft() {
  try {
    const raw = window.sessionStorage.getItem(PENDING_KEY);
    if (!raw) return null;
    window.sessionStorage.removeItem(PENDING_KEY);
    return JSON.parse(raw);
  } catch (error) {
    return null;
  }
}

function stashPending(draft) {
  try {
    window.sessionStorage.setItem(PENDING_KEY, JSON.stringify(draft));
  } catch (error) {
    return;
  }
}

function newSession() {
  model.counter += 1;
  const session = {
    n: model.sessions.length + 1,
    uid: model.counter,
    sid: null,
    items: [],
    state: "ready",
    source: null,
    tags: { harness: "", model: "", effort: "" },
    target: null,
    startedAt: 0,
    firstEvent: false,
    lastActivity: Date.now(),
    turnTimer: 0,
    closed: false,
    pending: null,
    lastIntent: "",
    itemSeq: 0,
  };
  return session;
}

function labelSessions() {
  model.sessions.forEach((session, index) => {
    session.n = index + 1;
  });
}

export function addSession() {
  if (model.sessions.length >= MAX_SESSIONS) return null;
  const session = newSession();
  model.sessions.push(session);
  labelSessions();
  model.active = model.sessions.length - 1;
  emit("sessions", session, null);
  return session;
}

export function activeSession() {
  if (!model.sessions.length) addSession();
  return model.sessions[model.active] || model.sessions[0];
}

function pushItem(session, item) {
  session.itemSeq += 1;
  item.id = `${session.uid}-${session.itemSeq}`;
  item.rev = 0;
  session.items.push(item);
  emit("item", session, item);
  return item;
}

function touch(session, item) {
  item.rev += 1;
  emit("update", session, item);
}

function setState(session, state) {
  if (session.state === state) return;
  session.state = state;
  emit("state", session, null);
}

function tailAssistant(session) {
  const item = session.items[session.items.length - 1];
  return item && item.kind === "assistant" ? item : null;
}

function dropItem(session, item) {
  const index = session.items.indexOf(item);
  if (index >= 0) session.items.splice(index, 1);
  emit("remove", session, item);
}

function streaming(session) {
  return ["thinking", "streaming", "waiting"].includes(session.state);
}

export function isBusy(session) {
  return streaming(session);
}

function endTurn(session, message) {
  clearTimeout(session.turnTimer);
  session.turnTimer = 0;
  for (const item of session.items.slice()) {
    if (item.kind === "assistant" && item.live) {
      item.live = false;
      item.thinking = false;
      if (item.text) touch(session, item);
      else dropItem(session, item);
    }
  }
  setState(session, "ready");
  session.lastActivity = Date.now();
  if (message) announce(message);
}

function armTimeout(session) {
  clearTimeout(session.turnTimer);
  session.turnTimer = setTimeout(() => {
    if (!streaming(session)) return;
    stopRequest(session);
    endTurn(session, "");
    pushItem(session, { kind: "error", title: "This turn took longer than 3 minutes and was stopped.", detail: "Turn timeout after 180 s", retry: true, intent: session.lastIntent });
    announce("This turn took longer than 3 minutes and was stopped.", { assertive: true });
  }, TURN_LIMIT_MS);
}

function ensureAssistant(session) {
  const tail = tailAssistant(session);
  if (tail && tail.live) return tail;
  return pushItem(session, { kind: "assistant", text: "", live: true, thinking: false, startedAt: Date.now() });
}

function onEvent(session, type, data) {
  session.lastActivity = Date.now();
  session.firstEvent = true;
  if (type === "delta") {
    const item = ensureAssistant(session);
    item.text += data.text || "";
    item.thinking = false;
    item.status = "";
    setState(session, "streaming");
    touch(session, item);
  } else if (type === "tool") {
    const tail = tailAssistant(session);
    if (tail && tail.live) {
      tail.live = false;
      tail.thinking = false;
      if (tail.text) touch(session, tail);
      else dropItem(session, tail);
    }
    setState(session, "streaming");
    pushItem(session, {
      kind: "trace",
      name: data.name || data.tool || "tool",
      target: data.target || data.path || "",
      decision: data.decision === "deny" || data.allowed === false ? "deny" : "allow",
      duration: data.duration_ms != null ? data.duration_ms : data.duration,
      args: data.args || data.input || null,
      reason: data.reason || "",
      expanded: false,
    });
  } else if (type === "status") {
    const item = ensureAssistant(session);
    if (data.state === "retrying" || data.retrying) {
      item.status = `Restarting the session (attempt ${data.attempt || 1} of 2)`;
      item.thinking = true;
      touch(session, item);
    }
  } else if (type === "draft") {
    const tail = tailAssistant(session);
    if (tail && tail.live) {
      tail.live = false;
      if (tail.text) touch(session, tail);
      else dropItem(session, tail);
    }
    session.turnDraft = true;
    pushItem(session, {
      kind: "draft",
      target: data.target || session.target || model.target || { kind: data.kind || "", id: data.id || "" },
      yaml: data.yaml || "",
      rationale: data.rationale || "",
      validation: data.validation || { ok: true, findings: data.findings || [] },
      plan: data.plan || null,
      adapter: data.adapter || "",
      refused: Boolean(data.description_refused || data.refused_description),
    });
    announce("Draft complete");
  } else if (type === "error") {
    stopSource(session);
    endTurn(session, "");
    pushItem(session, { kind: "error", title: data.message || "The author failed.", detail: [data.code, data.id || data.request_id].filter(Boolean).join(" "), retry: true, intent: session.lastIntent });
    announce(data.message || "The author failed.", { assertive: true });
  } else if (type === "done") {
    endTurn(session, session.turnDraft ? "" : "Turn complete");
  } else if (type === "closed") {
    closeIdle(session);
  }
}

function closeIdle(session) {
  stopSource(session);
  clearTimeout(session.turnTimer);
  session.closed = true;
  setState(session, "closed");
  pushItem(session, { kind: "notice", text: "Session closed after 15 minutes idle." });
}

function stopSource(session) {
  if (session.source) {
    session.source.close();
    session.source = null;
  }
}

function openStream(session) {
  stopSource(session);
  const source = new window.EventSource(BASE + endpoints.authorStream(session.sid));
  session.source = source;
  const handler = (type) => (event) => {
    let data = {};
    try {
      data = event.data ? JSON.parse(event.data) : {};
    } catch (error) {
      data = { text: event.data };
    }
    onEvent(session, type, data);
  };
  for (const type of TOOLS) source.addEventListener(type, handler(type));
  source.addEventListener("message", (event) => {
    try {
      const data = JSON.parse(event.data);
      if (data && TOOLS.includes(data.type)) onEvent(session, data.type, data);
    } catch (error) {
      return;
    }
  });
  source.addEventListener("error", () => {
    if (session.source !== source) return;
    if (source.readyState === 2 && streaming(session)) {
      session.source = null;
      endTurn(session, "");
      pushItem(session, { kind: "error", title: "The author stream closed before the turn finished.", detail: "Stream closed", retry: true, intent: session.lastIntent });
    }
  });
}

function stopRequest(session) {
  if (!session.sid) return Promise.resolve();
  return post(endpoints.authorStop(session.sid), {}).catch(() => null);
}

export function stopTurn(session) {
  if (!streaming(session)) return;
  const item = tailAssistant(session);
  stopRequest(session);
  endTurn(session, "Stopped");
  if (item && item.text) {
    item.stopped = true;
    touch(session, item);
  }
}

export async function closeSession(session) {
  stopSource(session);
  clearTimeout(session.turnTimer);
  const index = model.sessions.indexOf(session);
  if (index < 0) return;
  model.sessions.splice(index, 1);
  labelSessions();
  model.active = Math.max(0, Math.min(model.active, model.sessions.length - 1));
  emit("sessions", null, null);
  if (session.sid) await del(endpoints.authorSession(session.sid)).catch(() => null);
}

function refusal(session, error) {
  endTurn(session, "");
  if (error.kind === "disabled" || error.kind === "rate_limited") {
    const person = session.items.slice().reverse().find((item) => item.kind === "person");
    if (person) dropItem(session, person);
    session.restore = session.lastIntent;
  }
  if (error.kind === "disabled") {
    model.disabled = error.message;
    emit("disabled", session, null);
    return;
  }
  if (error.kind === "rate_limited") {
    const wait = error.retryAfter == null ? 60 : error.retryAfter;
    model.rateUntil = Date.now() + wait * 1000;
    emit("rate", session, null);
    return;
  }
  if (error.code === "busy" || (error.kind === "conflict" && /busy|three|sessions/i.test(error.message))) {
    pushItem(session, { kind: "error", title: "The author is busy. Three author sessions are already open on this host. Close one first.", detail: error.code || "busy", retry: false });
    return;
  }
  pushItem(session, { kind: "error", title: error.message || "The author request failed.", detail: [error.code, error.requestId, error.errorId].filter(Boolean).join(" "), retry: true, intent: session.lastIntent });
  announce(error.message || "The author request failed.", { assertive: true });
}

export async function sendTurn(session, text) {
  const intent = String(text || "").trim();
  if (!intent || streaming(session) || (model.rateUntil && Date.now() < model.rateUntil)) return false;
  const target = session.target || model.target || null;
  session.target = target;
  session.lastIntent = intent;
  session.startedAt = Date.now();
  session.firstEvent = false;
  session.turnDraft = false;
  session.restore = "";
  pushItem(session, { kind: "person", text: intent });
  pushItem(session, { kind: "assistant", text: "", live: true, thinking: true, startedAt: Date.now(), status: "" });
  setState(session, "thinking");
  armTimeout(session);
  try {
    if (!session.sid) {
      const body = { kind: target ? target.kind : "policy" };
      if (target && target.kind === "project") body.project = target.id;
      if (target) body.target_file = `${target.kind}/${target.id}`;
      if (session.resume) body.resume = session.resume;
      const created = await post(endpoints.authorSessions, body);
      session.sid = created.sid || created.id || created.session;
      session.resume = null;
      session.closed = false;
      const roster = created.roster || created;
      session.tags = { harness: roster.harness || "", model: roster.model || "", effort: roster.effort || "" };
      emit("state", session, null);
    }
    if (!session.source) openStream(session);
    await post(endpoints.authorTurns(session.sid), { intent, context: { target } });
  } catch (error) {
    if (error && error.kind === "conflict" && session.sid) {
      pushItem(session, { kind: "error", title: error.message || "The session is busy with another turn.", detail: error.code || "", retry: false });
      endTurn(session, "");
      return false;
    }
    refusal(session, error);
    return false;
  }
  return true;
}

export async function restartSession(session) {
  const old = session.sid;
  stopSource(session);
  session.sid = null;
  session.resume = old;
  session.closed = false;
  setState(session, "ready");
  emit("state", session, null);
}

export function openDraft(draft) {
  const payload = { target: draft.target, yaml: draft.yaml };
  const route = router.currentRoute();
  const here = route && route.name === "manager" && route.params[0] === draft.target.kind && route.params[1] === draft.target.id;
  if (here) {
    document.dispatchEvent(new CustomEvent("ps-author-draft", { detail: payload }));
    return;
  }
  stashPending(payload);
  router.navigate(`manager/${encodeURIComponent(draft.target.kind)}/${encodeURIComponent(draft.target.id)}`);
}

export async function reviewDraft(draft, opener) {
  const sheet = await import("./ps-plan-sheet.js");
  sheet.openPlan({ target: draft.target, change: { kind: "replace", yaml: draft.yaml, source: "author" } }, opener);
}

function renderMarkdown(text, host, caret) {
  host.replaceChildren();
  const lines = String(text).split("\n");
  let paragraph = [];
  let list = null;
  let fence = null;
  const inline = (parent, value) => {
    const parts = value.split(/(`[^`]+`)/);
    for (const part of parts) {
      if (part.length > 2 && part.startsWith("`") && part.endsWith("`")) parent.append(el("code", "", part.slice(1, -1)));
      else if (part) parent.append(document.createTextNode(part));
    }
  };
  const flush = () => {
    if (paragraph.length) {
      const p = el("p", "text-md");
      inline(p, paragraph.join(" "));
      host.append(p);
      paragraph = [];
    }
  };
  for (const line of lines) {
    if (fence) {
      if (/^\s*```/.test(line)) {
        fence = null;
      } else {
        fence.textContent += (fence.textContent ? "\n" : "") + line;
      }
      continue;
    }
    if (/^\s*```/.test(line)) {
      flush();
      list = null;
      const pre = el("pre", "author-code mono");
      host.append(pre);
      fence = pre;
      continue;
    }
    const item = /^\s*(?:[-*]|\d+\.)\s+(.*)$/.exec(line);
    if (item) {
      flush();
      if (!list) {
        list = el("ul", "author-list text-md");
        host.append(list);
      }
      const li = el("li");
      inline(li, item[1]);
      list.append(li);
      continue;
    }
    list = null;
    if (!line.trim()) flush();
    else paragraph.push(line.trim());
  }
  flush();
  if (caret) {
    const target = host.lastElementChild;
    const mark = el("span", "author-caret");
    mark.setAttribute("aria-hidden", "true");
    if (target && (target.tagName === "P" || target.tagName === "LI")) target.append(mark);
    else if (target && target.tagName === "UL" && target.lastElementChild) target.lastElementChild.append(mark);
    else host.append(mark);
  }
}

function seconds(since) {
  return Math.max(0, Math.floor((Date.now() - since) / 1000));
}

function stateLabel(session) {
  const idle = Date.now() - session.lastActivity;
  if (session.closed || session.state === "closed") return "Closed";
  if (session.state === "thinking") return `Thinking ${seconds(session.startedAt)} s`;
  if (session.state === "streaming") return `Streaming ${seconds(session.startedAt)} s`;
  if (session.state === "waiting") return "Waiting";
  if (session.sid && idle >= IDLE_WARN_MS) return `Closing in ${Math.max(1, Math.ceil((IDLE_LIMIT_MS - idle) / 60000))} min`;
  return "Ready";
}

let tickerStarted = false;

function startTicker() {
  if (tickerStarted) return;
  tickerStarted = true;
  setInterval(() => {
    for (const session of model.sessions) {
      if (streaming(session)) {
        const item = session.items.find((entry) => entry.kind === "assistant" && entry.thinking);
        if (item) touch(session, item);
      } else if (session.sid && !session.closed && Date.now() - session.lastActivity >= IDLE_LIMIT_MS) {
        closeIdle(session);
      }
    }
    emit("tick", null, null);
  }, 1000);
}

let livePanel = null;
let pendingIntent = "";

document.addEventListener("ps-open-author", (event) => {
  const intent = event.detail && typeof event.detail.intent === "string" ? event.detail.intent.trim() : "";
  if (!intent) return;
  pendingIntent = intent;
  if (livePanel) livePanel.takeIntent();
});

class PsAuthorPanel extends HTMLElement {
  takeIntent() {
    const intent = pendingIntent;
    if (!intent || !this.input) return;
    pendingIntent = "";
    this.input.value = intent;
    setTimeout(() => {
      if (this.isConnected && this.input) this.input.focus();
    }, 0);
  }

  connectedCallback() {
    if (this.root) return;
    livePanel = this;
    startTicker();
    this.nodes = new Map();
    this.following = true;
    this.root = el("div", "author-root");
    this.append(this.root);
    this.build();
    this.unsubscribe = subscribeAuthor((type, session, item) => this.onModel(type, session, item));
    this.onKeyDown = (event) => {
      if (event.key === "Escape" && this.current() && streaming(this.current())) {
        event.preventDefault();
        event.stopPropagation();
        stopTurn(this.current());
      }
    };
    this.addEventListener("keydown", this.onKeyDown);
    this.syncTarget();
    this.takeIntent();
    loadCatalog().then((catalog) => {
      this.catalog = rulebookList(catalog);
      this.fillTargets();
    }).catch(() => {
      this.catalog = [];
      this.fillTargets();
    });
  }

  disconnectedCallback() {
    if (livePanel === this) livePanel = null;
    if (this.unsubscribe) this.unsubscribe();
    this.removeEventListener("keydown", this.onKeyDown);
  }

  current() {
    return model.sessions[model.active] || null;
  }

  syncTarget() {
    if (model.target) return;
    const route = router.currentRoute();
    if (route && route.name === "manager" && route.params[0] && route.params[1]) {
      model.target = { kind: route.params[0], id: route.params[1] };
    }
  }

  build() {
    const author = flag("author");
    this.root.replaceChildren();
    if (!author.enabled || model.disabled) {
      this.disabledView(author.reason || model.disabled);
      return;
    }
    if (!model.sessions.length) addSession();
    this.head = el("div", "author-head");
    this.tabsHost = el("div", "author-tabs-host");
    this.plus = document.createElement("ps-button");
    this.plus.setAttribute("size", "sm");
    this.plus.setAttribute("label", "New draft session");
    this.plus.text = "New draft";
    this.plus.addEventListener("click", () => {
      addSession();
    });
    this.head.append(this.tabsHost, this.plus);
    if (this.closest("ps-side-panel")) {
      const close = document.createElement("ps-icon-button");
      close.setAttribute("icon", "close");
      close.setAttribute("label", "Close the author panel");
      close.setAttribute("size", "sm");
      close.addEventListener("click", () => {
        const panel = this.closest("ps-side-panel");
        if (panel) panel.close();
      });
      this.head.append(close);
    }
    this.meta = el("div", "author-meta");
    this.tags = el("div", "author-tags mono text-2xs");
    this.stateText = el("span", "author-state text-xs");
    this.stateText.setAttribute("role", "status");
    this.closeSession = document.createElement("ps-icon-button");
    this.closeSession.setAttribute("icon", "close");
    this.closeSession.setAttribute("label", "Close this draft session");
    this.closeSession.setAttribute("size", "xs");
    this.closeSession.addEventListener("click", () => {
      const session = this.current();
      if (session) closeSession(session);
    });
    this.meta.append(this.tags, this.stateText, this.closeSession);
    this.threadWrap = el("div", "author-thread-wrap");
    this.thread = el("div", "author-thread");
    this.thread.setAttribute("role", "log");
    this.thread.setAttribute("aria-label", "Author conversation");
    this.thread.setAttribute("aria-live", "off");
    this.thread.tabIndex = 0;
    this.jump = document.createElement("ps-button");
    this.jump.setAttribute("size", "xs");
    this.jump.className = "author-jump";
    this.jump.text = "Jump to latest";
    this.jump.hidden = true;
    this.jump.addEventListener("click", () => this.scrollEnd(true));
    this.thread.addEventListener("scroll", () => {
      const gap = this.thread.scrollHeight - this.thread.scrollTop - this.thread.clientHeight;
      this.following = gap < 24;
      if (this.following) this.jump.hidden = true;
    });
    this.threadWrap.append(this.thread, this.jump);
    this.composer = el("div", "author-composer");
    this.input = document.createElement("ps-textarea");
    this.input.setAttribute("label", "Describe the change");
    this.input.setAttribute("submit", "");
    this.input.addEventListener("ps-submit", () => this.send());
    this.row = el("div", "author-composer-row");
    this.targetSelect = document.createElement("ps-select");
    this.targetSelect.setAttribute("label", "Target");
    this.targetSelect.setAttribute("hide-label", "");
    this.targetSelect.setAttribute("aria-label", "Target rulebook");
    this.targetSelect.setAttribute("placeholder", "Target rulebook");
    this.targetSelect.addEventListener("ps-change", (event) => {
      const [kind, ...rest] = String(event.detail.value).split("/");
      model.target = { kind, id: rest.join("/") };
      const session = this.current();
      if (session && !session.sid) session.target = model.target;
    });
    this.sendButton = document.createElement("ps-button");
    this.sendButton.setAttribute("variant", "primary");
    this.sendButton.setAttribute("size", "sm");
    this.sendButton.text = "Send";
    this.sendButton.addEventListener("click", () => this.onSendClick());
    this.restart = document.createElement("ps-button");
    this.restart.setAttribute("variant", "primary");
    this.restart.setAttribute("size", "sm");
    this.restart.text = "Start a new session";
    this.restart.hidden = true;
    this.restart.addEventListener("click", () => restartSession(this.current()));
    this.row.append(this.targetSelect, this.sendButton, this.restart);
    this.rate = el("p", "author-rate text-xs");
    this.rate.hidden = true;
    this.rate.setAttribute("role", "status");
    this.composer.append(this.input, this.row, this.rate);
    this.root.append(this.head, this.meta, this.threadWrap, this.composer);
    this.renderTabs();
    this.renderSession();
  }

  disabledView(reason) {
    const state = document.createElement("ps-state");
    state.setAttribute("kind", "disabled");
    state.setAttribute("feature", "The author");
    state.setAttribute("heading", "The author is turned off");
    state.setAttribute("body", reason || "Authoring is turned off on this host.");
    const command = document.createElement("ps-command");
    command.setAttribute("command", "polispec settings set polispec.author.enabled on");
    state.append(command);
    this.root.append(state);
  }

  renderTabs() {
    this.tabsHost.replaceChildren();
    const tabs = document.createElement("ps-tabs");
    tabs.setAttribute("label", "Author draft sessions");
    tabs.classList.add("author-tabs");
    model.sessions.forEach((session, index) => {
      const panel = el("div");
      panel.dataset.tab = String(index);
      panel.dataset.label = `Draft ${session.n}`;
      tabs.append(panel);
    });
    tabs.setAttribute("selected", String(model.active));
    this.tabsHost.append(tabs);
    tabs.addEventListener("ps-tab-change", (event) => {
      model.active = Number(event.detail.id);
      this.renderSession();
    });
    const full = model.sessions.length >= MAX_SESSIONS;
    if (full) {
      this.plus.setAttribute("disabled", "");
      this.plus.setAttribute("reason", "At most 3 author sessions. Close one first.");
    } else {
      this.plus.removeAttribute("disabled");
      this.plus.removeAttribute("reason");
    }
  }

  renderSession() {
    const session = this.current();
    this.nodes.clear();
    this.thread.replaceChildren();
    if (!session) return;
    for (const item of session.items) this.appendItem(session, item, false);
    this.renderMeta(session);
    this.renderComposer(session);
    this.scrollEnd(true);
    this.fillTargets();
  }

  renderMeta(session) {
    this.tags.replaceChildren();
    for (const key of ["harness", "model", "effort"]) {
      if (session.tags[key]) this.tags.append(el("span", "author-tag", session.tags[key]));
    }
    this.stateText.textContent = stateLabel(session);
  }

  renderComposer(session) {
    const busy = streaming(session);
    const waiting = model.rateUntil && Date.now() < model.rateUntil;
    this.sendButton.text = busy ? "Stop" : "Send";
    this.sendButton.setAttribute("variant", busy ? "secondary" : "primary");
    this.sendButton.hidden = session.closed;
    this.restart.hidden = !session.closed;
    if (waiting) {
      this.input.setAttribute("disabled", "");
      this.sendButton.setAttribute("disabled", "");
      this.rate.hidden = false;
      this.rate.textContent = `10 turns a minute per host. Try again in ${Math.max(1, Math.ceil((model.rateUntil - Date.now()) / 1000))} s.`;
    } else {
      this.input.toggleAttribute("disabled", session.closed);
      this.sendButton.removeAttribute("disabled");
      this.rate.hidden = true;
    }
  }

  fillTargets() {
    if (!this.targetSelect) return;
    const list = this.catalog || [];
    const options = list.map((item) => ({ value: `${item.kind}/${item.id}`, label: `${item.kind}: ${item.id}` }));
    const current = model.target ? `${model.target.kind}/${model.target.id}` : "";
    if (current && !options.some((option) => option.value === current)) options.unshift({ value: current, label: `${model.target.kind}: ${model.target.id}` });
    this.targetSelect.options = options;
    if (current) this.targetSelect.value = current;
  }

  onSendClick() {
    const session = this.current();
    if (!session) return;
    if (streaming(session)) stopTurn(session);
    else this.send();
  }

  async send() {
    const session = this.current();
    if (!session || streaming(session)) return;
    const text = this.input.value;
    if (!text.trim()) return;
    this.input.value = "";
    this.following = true;
    const sent = await sendTurn(session, text);
    if (!sent && session.restore && !this.input.value) this.input.value = session.restore;
  }

  onModel(type, session, item) {
    if (!this.root || !this.isConnected) return;
    if (type === "disabled") {
      this.build();
      return;
    }
    if (type === "sessions") {
      if (!this.tabsHost) return;
      this.renderTabs();
      this.renderSession();
      return;
    }
    if (type === "target") {
      this.fillTargets();
      return;
    }
    const current = this.current();
    if (!current) return;
    if (type === "tick") {
      this.renderMeta(current);
      this.renderComposer(current);
      return;
    }
    if (session !== current) return;
    if (type === "item") this.appendItem(session, item, true);
    else if (type === "update") this.updateItem(session, item);
    else if (type === "remove") {
      const node = this.nodes.get(item.id);
      if (node) node.remove();
      this.nodes.delete(item.id);
    } else if (type === "state" || type === "rate") {
      this.renderMeta(session);
      this.renderComposer(session);
      if (type === "state" && streaming(session) === false) this.thread.removeAttribute("aria-busy");
    }
  }

  appendItem(session, item, follow) {
    const node = this.buildItem(session, item);
    this.nodes.set(item.id, node);
    this.thread.append(node);
    if (item.kind === "person") this.following = true;
    if (follow) this.afterAppend();
  }

  updateItem(session, item) {
    const node = this.nodes.get(item.id);
    if (!node) return;
    const next = this.buildItem(session, item);
    node.replaceWith(next);
    this.nodes.set(item.id, next);
    this.afterAppend();
  }

  afterAppend() {
    if (this.following) this.scrollEnd(false);
    else this.jump.hidden = false;
  }

  scrollEnd(force) {
    if (!this.thread) return;
    this.thread.scrollTop = this.thread.scrollHeight;
    this.following = true;
    this.jump.hidden = true;
    if (force) this.thread.scrollTop = this.thread.scrollHeight;
  }

  buildItem(session, item) {
    const node = el("div", `author-item author-${item.kind}`);
    if (item.kind === "person") {
      node.textContent = item.text;
      return node;
    }
    if (item.kind === "assistant") return this.buildAssistant(node, item);
    if (item.kind === "trace") return this.buildTrace(node, session, item);
    if (item.kind === "draft") return this.buildDraft(item);
    if (item.kind === "notice") {
      node.classList.add("text-sm");
      node.textContent = item.text;
      return node;
    }
    return this.buildError(node, session, item);
  }

  buildAssistant(node, item) {
    if (item.thinking) {
      const elapsed = seconds(item.startedAt);
      const line = el("p", "author-thinking text-md");
      line.textContent = item.status || `Thinking, ${elapsed} s`;
      if (!item.status && elapsed >= 10) line.textContent += ". The first event can take up to 30 s.";
      node.append(line);
      return node;
    }
    renderMarkdown(item.text, node, item.live);
    if (item.stopped) node.append(el("p", "text-xs author-quiet", "Stopped."));
    return node;
  }

  buildTrace(node, session, item) {
    const row = el("div", "author-trace-row");
    const toggle = el("button", "ps-native author-trace-toggle");
    toggle.type = "button";
    toggle.setAttribute("aria-expanded", item.expanded ? "true" : "false");
    toggle.append(icon(item.expanded ? "chevron-down" : "chevron-right"));
    toggle.append(el("span", "mono text-xs", item.name));
    const target = el("span", "mono text-xs author-trace-target", middleTruncate(item.target, 28));
    if (item.target) target.title = item.target;
    toggle.append(target);
    const chip = document.createElement("ps-chip");
    chip.setAttribute("kind", "verdict");
    chip.setAttribute("value", item.decision);
    chip.setAttribute("label", item.decision === "allow" ? "Allowed by polispec" : "Denied by polispec");
    toggle.append(chip);
    if (item.duration != null) toggle.append(el("span", "num text-2xs author-quiet", `${Math.round(item.duration)} ms`));
    toggle.addEventListener("click", () => {
      item.expanded = !item.expanded;
      touch(session, item);
    });
    row.append(toggle);
    if (item.expanded) {
      const detail = el("div", "author-trace-detail");
      const args = el("pre", "mono text-xs author-code", JSON.stringify(item.args || { tool: item.name, target: item.target }, null, 2));
      detail.append(args);
      if (item.reason) detail.append(el("p", "text-xs", item.reason));
      row.append(detail);
    }
    node.append(row);
    return node;
  }

  buildError(node, session, item) {
    node.setAttribute("role", "alert");
    node.append(icon("deny"));
    const body = el("div", "author-error-body");
    body.append(el("p", "text-md", item.title));
    if (item.detail) body.append(el("p", "mono text-xs author-quiet", item.detail));
    const actions = el("div", "author-actions");
    if (item.retry) {
      const retry = document.createElement("ps-button");
      retry.setAttribute("size", "xs");
      retry.setAttribute("icon", "reset");
      retry.text = "Retry";
      retry.addEventListener("click", () => {
        dropItem(session, item);
        sendTurn(session, item.intent || session.lastIntent);
      });
      actions.append(retry);
    }
    const copy = document.createElement("ps-button");
    copy.setAttribute("variant", "ghost");
    copy.setAttribute("size", "xs");
    copy.setAttribute("icon", "copy");
    copy.text = "Copy details";
    copy.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText([item.title, item.detail].filter(Boolean).join("\n"));
        announce("Copied");
      } catch (error) {
        announce("Select and copy the details");
      }
    });
    actions.append(copy);
    body.append(actions);
    node.append(body);
    return node;
  }

  buildDraft(item) {
    const card = document.createElement("ps-card");
    card.className = "author-item author-draft";
    const name = `${item.target.kind || ""}${item.target.kind ? ": " : ""}${item.target.id || ""}`;
    card.append(el("div", "text-sm author-draft-title", `Draft for ${name || "the open rulebook"}`));
    const chips = el("div", "author-chips");
    const findings = (item.validation && item.validation.findings) || [];
    const errors = findings.filter((finding) => (finding.severity || "error") === "error").length;
    const validation = document.createElement("ps-chip");
    validation.setAttribute("kind", "verdict");
    if (item.validation && item.validation.ok === false) {
      validation.setAttribute("value", "deny");
      validation.setAttribute("label", `${errors || findings.length} errors`);
    } else {
      validation.setAttribute("value", "allow");
      validation.setAttribute("label", "Valid");
    }
    chips.append(validation);
    if (item.plan && item.plan.classification) {
      const klass = document.createElement("ps-chip");
      klass.setAttribute("kind", "classification");
      klass.setAttribute("value", item.plan.classification);
      chips.append(klass);
    }
    card.append(chips);
    if (item.refused) {
      const banner = document.createElement("ps-banner");
      banner.setAttribute("severity", "warn");
      banner.setAttribute("text", "Not added: readers of this rulebook run polispec older than 0.34.0.");
      card.append(banner);
    }
    if (item.rationale) {
      const rationale = el("p", "text-md author-rationale", item.rationale);
      rationale.dataset.clamped = item.showAll ? "false" : "true";
      card.append(rationale);
      const more = el("button", "ps-native author-more text-xs", item.showAll ? "Show less" : "Show more");
      more.type = "button";
      more.addEventListener("click", () => {
        item.showAll = !item.showAll;
        rationale.dataset.clamped = item.showAll ? "false" : "true";
        more.textContent = item.showAll ? "Show less" : "Show more";
      });
      card.append(more);
    }
    const actions = el("div", "author-actions");
    const open = document.createElement("ps-button");
    open.setAttribute("size", "sm");
    open.text = "Open in editor";
    open.addEventListener("click", () => openDraft(item));
    const review = document.createElement("ps-button");
    review.setAttribute("variant", "primary");
    review.setAttribute("size", "sm");
    review.text = "Review plan";
    review.addEventListener("click", () => reviewDraft(item, review));
    actions.append(open, review);
    card.append(actions);
    return card;
  }
}

customElements.define("ps-author-panel", PsAuthorPanel);

document.addEventListener("ps-author-context", (event) => setAuthorTarget(event.detail));
