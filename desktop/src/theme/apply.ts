// Puts a palette on the page as CSS custom properties, `--ground`, `--ink-soft` and so
// on, which every stylesheet reads. Nothing else in the UI names a color.
import { css } from "./color";
import { type Palette, tokenNames, tokens } from "./palette";

const kebab = (name: string) => name.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase());

export function applyPalette(palette: Palette, root: HTMLElement = document.documentElement): void {
  for (const name of tokenNames) root.style.setProperty(`--${kebab(name)}`, css(palette.colors[name]));
  root.style.setProperty("color-scheme", palette.isDark ? "dark" : "light");
  root.dataset.theme = palette.id;
}

export function applyFonts(fonts: { reading?: string; ui?: string; code?: string }, root: HTMLElement = document.documentElement): void {
  root.style.setProperty("--font-reading", `"${fonts.reading ?? tokens.fonts.reading}"`);
  root.style.setProperty("--font-ui", `"${fonts.ui ?? tokens.fonts.ui}"`);
  root.style.setProperty("--font-code", `"${fonts.code ?? tokens.fonts.code}"`);
}
