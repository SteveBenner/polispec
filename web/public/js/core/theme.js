export const STORAGE_KEY = "polispec.web.theme";

export const CHOICES = ["system", "light", "dark", "apple-noir", "apple-austere", "tronwave"];

export const LABELS = {
  system: "System",
  light: "Light",
  dark: "Dark",
  "apple-noir": "Apple Noir",
  "apple-austere": "Apple Austere",
  tronwave: "Tronwave",
};

const query = window.matchMedia("(prefers-color-scheme: dark)");

function readStored() {
  try {
    const stored = window.localStorage.getItem(STORAGE_KEY);
    return CHOICES.includes(stored) ? stored : null;
  } catch (error) {
    return null;
  }
}

function writeStored(id) {
  try {
    window.localStorage.setItem(STORAGE_KEY, id);
  } catch (error) {
    return;
  }
}

export function resolve(id) {
  if (id === "system") return query.matches ? "dark" : "light";
  return id;
}

export function getChoice() {
  const attribute = document.documentElement.getAttribute("data-theme-choice");
  if (CHOICES.includes(attribute)) return attribute;
  return readStored() || "system";
}

function apply(id) {
  const root = document.documentElement;
  const theme = resolve(id);
  root.setAttribute("data-theme-choice", id);
  root.setAttribute("data-theme", theme);
  document.dispatchEvent(new CustomEvent("ps-theme-change", { detail: { choice: id, theme } }));
}

export function setChoice(id) {
  if (!CHOICES.includes(id)) return getChoice();
  writeStored(id);
  apply(id);
  return id;
}

export function cycle(direction = 1) {
  const step = direction < 0 ? -1 : 1;
  const index = CHOICES.indexOf(getChoice());
  const next = CHOICES[(index + step + CHOICES.length) % CHOICES.length];
  return setChoice(next);
}

query.addEventListener("change", () => {
  if (getChoice() === "system") apply("system");
});
