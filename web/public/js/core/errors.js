export const KINDS = [
  "offline",
  "unauthorized",
  "forbidden",
  "conflict",
  "invalid",
  "rate_limited",
  "server",
  "timeout",
  "disabled",
];

export function newErrorId() {
  const bytes = new Uint8Array(4);
  window.crypto.getRandomValues(bytes);
  let hex = "";
  for (const byte of bytes) hex += byte.toString(16).padStart(2, "0");
  return "err_" + hex;
}

export class ApiError extends Error {
  constructor(kind, message, details = {}) {
    super(message);
    this.name = "ApiError";
    this.kind = kind;
    this.status = details.status || 0;
    this.code = details.code || null;
    this.reason = details.reason || null;
    this.findings = details.findings || null;
    this.retryAfter = details.retryAfter == null ? null : details.retryAfter;
    this.elapsed = details.elapsed == null ? null : details.elapsed;
    this.attempts = details.attempts || 1;
    this.requestId = details.requestId || null;
    this.errorId = newErrorId();
  }
}

export function kindForStatus(status) {
  if (status === 401) return "unauthorized";
  if (status === 403) return "forbidden";
  if (status === 409) return "conflict";
  if (status === 400 || status === 422) return "invalid";
  if (status === 429) return "rate_limited";
  return "server";
}

export function parseRetryAfter(value) {
  if (value == null || value === "") return null;
  const seconds = Number(value);
  if (Number.isFinite(seconds)) return Math.max(0, Math.ceil(seconds));
  const date = Date.parse(value);
  if (Number.isNaN(date)) return null;
  return Math.max(0, Math.ceil((date - Date.now()) / 1000));
}

export function fromResponse(response, body, attempts, elapsed) {
  const payload = body && typeof body === "object" ? body : {};
  const disabled = response.status === 403 && payload.error === "disabled";
  const kind = disabled ? "disabled" : kindForStatus(response.status);
  const message = (disabled && payload.reason) || payload.message || response.statusText || "Request failed with status " + response.status;
  return new ApiError(kind, message, {
    status: response.status,
    code: payload.error || null,
    reason: typeof payload.reason === "string" ? payload.reason : null,
    findings: payload.findings || null,
    retryAfter: parseRetryAfter(response.headers.get("Retry-After")),
    requestId: response.headers.get("X-Request-Id") || null,
    attempts,
    elapsed,
  });
}

export function offlineError(attempts, elapsed) {
  return new ApiError("offline", "polispec web is not responding", {
    attempts,
    elapsed,
  });
}

export function timeoutError(elapsed, attempts) {
  return new ApiError("timeout", "The request timed out after " + (elapsed / 1000).toFixed(1) + " s", {
    elapsed,
    attempts,
  });
}
