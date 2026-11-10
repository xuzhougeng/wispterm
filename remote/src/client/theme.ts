import type { ThemeMode } from "./types";
import { iconMoon, iconSun } from "./icons";
import { readSavedTheme, saveTheme } from "./storage";

type TerminalPalette = {
  background: string;
  foreground: string;
  cursor: string;
  selectionBackground: string;
};

const PALETTES: Record<ThemeMode, TerminalPalette> = {
  dark: {
    background: "#090f17",
    foreground: "#dce7f3",
    cursor: "#ffd479",
    selectionBackground: "#334155",
  },
  light: {
    background: "#fbf6ec",
    foreground: "#1c2330",
    cursor: "#b97a3d",
    selectionBackground: "#d6cdb8",
  },
};

type Subscriber = (palette: TerminalPalette, mode: ThemeMode) => void;
const subscribers = new Set<Subscriber>();

let mode: ThemeMode = readSavedTheme();

applyAttribute(mode);

function applyAttribute(next: ThemeMode): void {
  if (next === "light") {
    document.documentElement.dataset.theme = "light";
  } else {
    delete document.documentElement.dataset.theme;
  }
}

export function getTerminalPalette(target: ThemeMode = mode): TerminalPalette {
  return PALETTES[target];
}

export function setTheme(next: ThemeMode): void {
  mode = next;
  applyAttribute(next);
  saveTheme(next);
  const palette = PALETTES[next];
  for (const sub of subscribers) sub(palette, next);
  updateThemeToggleButtons();
}

export function toggleTheme(): void {
  setTheme(mode === "dark" ? "light" : "dark");
}

export function subscribeToTheme(sub: Subscriber): () => void {
  subscribers.add(sub);
  return () => subscribers.delete(sub);
}

export function updateThemeToggleButtons(): void {
  const label = mode === "dark" ? "Switch to light theme" : "Switch to dark theme";
  const icon = mode === "dark" ? iconSun() : iconMoon();
  document.querySelectorAll<HTMLButtonElement>("[data-theme-toggle]").forEach((button) => {
    button.setAttribute("aria-label", label);
    button.title = label;
    button.innerHTML = icon;
  });
}

export function bindThemeToggleButtons(): void {
  document.querySelectorAll<HTMLButtonElement>("[data-theme-toggle]").forEach((button) => {
    button.addEventListener("click", toggleTheme);
  });
  updateThemeToggleButtons();
}
