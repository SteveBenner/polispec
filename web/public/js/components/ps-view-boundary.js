import "./ps-state.js";
import "./ps-button.js";
import "./ps-digest.js";
import { newErrorId } from "../core/errors.js";
import { app } from "../core/store.js";
import { announce } from "../core/announce.js";
import * as router from "../core/router.js";

function firstLine(error) {
  const message = error && error.message ? error.message : String(error);
  return message.split("\n")[0].trim() || "Unknown error";
}

class PsViewBoundary extends HTMLElement {
  connectedCallback() {
    if (this.state) return;
    const route = this.routeInfo;
    const error = this.failure;
    this.errorId = (error && error.errorId) || newErrorId();
    const message = firstLine(error);
    const config = app.get().config || {};
    const details = [
      `Route: ${route ? "#/" + [route.name, ...route.params].join("/") : window.location.hash}`,
      `Error id: ${this.errorId}`,
      `Message: ${message}`,
      `Stack: ${(error && error.stack) || "none"}`,
      `User agent: ${navigator.userAgent}`,
      `App version: ${config.version || "unknown"}`,
    ].join("\n");
    this.heading = document.createElement("h1");
    this.heading.tabIndex = -1;
    this.heading.textContent = route && route.title ? route.title : "This view";
    this.state = document.createElement("ps-state");
    this.state.setAttribute("kind", "error");
    this.state.setAttribute("heading", "This view failed to render");
    this.state.setAttribute("body", message);
    this.state.setAttribute("error-id", this.errorId);
    this.state.setAttribute("details", details);
    this.append(this.heading, this.state);
    this.state.addEventListener("ps-retry", (event) => {
      event.stopPropagation();
      router.navigate(window.location.hash || "map");
    });
    announce(`${this.heading.textContent} failed to render`, { assertive: true });
  }
}

customElements.define("ps-view-boundary", PsViewBoundary);

function ignorable(error) {
  return !error || error.name === "AbortError";
}

export function guard(container) {
  const show = (error, focus) => {
    if (ignorable(error)) return;
    if (app.get().session !== "active") return;
    const route = router.currentRoute();
    if (!route) return;
    if (container.querySelector("ps-view-boundary")) return;
    const boundary = document.createElement("ps-view-boundary");
    boundary.failure = error;
    boundary.routeInfo = route;
    container.replaceChildren(boundary);
    container.removeAttribute("aria-busy");
    if (focus) boundary.heading.focus();
  };

  const onRouteError = (event) => show(event.detail && event.detail.error, false);
  const onError = (event) => show(event.error, true);
  const onRejection = (event) => show(event.reason, true);

  document.addEventListener("ps-route-error", onRouteError);
  window.addEventListener("error", onError);
  window.addEventListener("unhandledrejection", onRejection);

  return () => {
    document.removeEventListener("ps-route-error", onRouteError);
    window.removeEventListener("error", onError);
    window.removeEventListener("unhandledrejection", onRejection);
  };
}
