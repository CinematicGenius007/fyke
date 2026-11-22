// Puts the active theme on the page as CSS custom properties, which every stylesheet
// reads. Nothing else in the UI names a color, a font or a radius.
//
//   --ground, --ink-soft, …          colors (Palette)
//   --font-reading, -title, -ui, -code
//   --ui-600, --title-600, …         each weight after the reader's steps (D11)
//   --radius-control, -panel, -sheet
import type { FontTokens, FontWeights, RadiusTokens } from "../model/prefs";
import { shifted, weightLadder } from "../model/prefs";
import { css } from "./color";
import { type Palette, tokenNames, tokens } from "./palette";

const kebab = (name: string) => name.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase());

export function applyPalette(palette: Palette, root: HTMLElement = document.documentElement): void {
  for (const name of tokenNames) root.style.setProperty(`--${kebab(name)}`, css(palette.colors[name]));
  root.style.setProperty("color-scheme", palette.isDark ? "dark" : "light");
  root.dataset.theme = palette.id;
  root.dataset.dark = palette.isDark ? "1" : "0";
}

const family = (name: string | null | undefined, fallback: string) => `"${(name ?? fallback).replace(/["\\]/g, "")}"`;

export function applyFonts(fonts: FontTokens, root: HTMLElement = document.documentElement): void {
  root.style.setProperty("--font-reading", family(fonts.reading, tokens.fonts.reading));
  root.style.setProperty("--font-title", family(fonts.title ?? fonts.reading, tokens.fonts.reading));
  root.style.setProperty("--font-ui", family(fonts.ui, tokens.fonts.ui));
  root.style.setProperty("--font-code", family(fonts.code, tokens.fonts.code));
}

export function applyWeights(weights: FontWeights, root: HTMLElement = document.documentElement): void {
  for (const kind of ["reading", "title", "ui", "code"] as const) {
    for (const weight of weightLadder) root.style.setProperty(`--${kind}-${weight}`, String(shifted(weight, weights[kind])));
  }
}

export function applyRadii(radii: RadiusTokens, root: HTMLElement = document.documentElement): void {
  root.style.setProperty("--radius-control", `${radii.control ?? tokens.radii.control}px`);
  root.style.setProperty("--radius-panel", `${radii.panel ?? tokens.radii.panel}px`);
  root.style.setProperty("--radius-sheet", `${radii.sheet ?? tokens.radii.sheet}px`);
}
