const counts = new Intl.NumberFormat();

export function shortDigest(sha, length = 8) {
  if (typeof sha !== "string") return "";
  const bare = sha.includes(":") ? sha.slice(sha.indexOf(":") + 1) : sha;
  return bare.slice(0, length);
}

export function middleTruncate(id, limit = 16) {
  const text = String(id == null ? "" : id);
  if (text.length <= limit || limit < 3) return text;
  const keep = limit - 1;
  const head = Math.ceil(keep / 2);
  const tail = keep - head;
  return text.slice(0, head) + "…" + (tail > 0 ? text.slice(text.length - tail) : "");
}

export function formatCount(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return "";
  return counts.format(number);
}

export function formatDuration(milliseconds) {
  const seconds = Math.max(0, Math.round(milliseconds / 1000));
  if (seconds < 60) return seconds + " s";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return minutes + " min";
  const hours = Math.round(minutes / 60);
  if (hours < 48) return hours + " h";
  return Math.round(hours / 24) + " d";
}

export function relTime(value, now = Date.now()) {
  const stamp = value instanceof Date ? value.getTime() : typeof value === "number" ? value : Date.parse(value);
  if (!Number.isFinite(stamp)) return { text: "", title: "" };
  const delta = now - stamp;
  const text = delta < 1000 ? "just now" : formatDuration(delta) + " ago";
  return { text, title: new Date(stamp).toISOString() };
}

export function relTimeElement(value) {
  const { text, title } = relTime(value);
  const element = document.createElement("time");
  element.textContent = text;
  if (title) {
    element.title = title;
    element.setAttribute("datetime", title);
  }
  return element;
}
