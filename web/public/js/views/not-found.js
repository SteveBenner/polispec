import "../components/ps-state.js";
import { navigate } from "../core/router.js";

export async function render(container, params, signal) {
  const section = document.createElement("section");
  section.className = "view not-found";
  const header = document.createElement("header");
  header.className = "view-header";
  const heading = document.createElement("h1");
  heading.tabIndex = -1;
  heading.textContent = "Not found";
  header.append(heading);
  const state = document.createElement("ps-state");
  state.setAttribute("kind", "empty_first_run");
  state.setAttribute("glyph", "question");
  state.setAttribute("heading", "There is no view at this address");
  state.setAttribute("body", `Nothing is served at ${window.location.hash || "#/"}. Pick a view from the navigation, or open the map.`);
  state.setAttribute("action", "Open map");
  state.addEventListener("ps-action", () => navigate("map"));
  section.append(header, state);
  if (signal && signal.aborted) return;
  container.replaceChildren(section);
}
