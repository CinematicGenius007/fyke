// Palettes, as gui/Sources/Reader/Theme.swift builds them. Light and dark come straight
// from gui/tokens.css (mirrored in `tokens` below and checked against that file by
// tests/unit/theme.test.ts). Newsprint and Terminal define three colors each, and the
// rest follow from them by the same mixes as on the Mac.
import { black, mix, parseHex, type RGBA, toHex } from "./color";

export const tokenNames = [
  "ground",
  "surface",
  "selected",
  "selectedStrong",
  "hairline",
  "control",
  "ink",
  "inkSoft",
  "muted",
  "unread",
  "read",
  "onAccent",
  "scrim",
] as const;
export type TokenName = (typeof tokenNames)[number];

/** How config.json spells each token in a custom theme. */
export const wireName: Record<TokenName, string> = {
  ground: "ground",
  surface: "surface",
  selected: "selected",
  selectedStrong: "selected_strong",
  hairline: "hairline",
  control: "control",
  ink: "ink",
  inkSoft: "ink_soft",
  muted: "muted",
  unread: "unread",
  read: "read",
  onAccent: "on_accent",
  scrim: "scrim",
};

/** The labels the Tokens pane lists them under, in its order. */
export const tokenLabels: Record<TokenName, string> = {
  ground: "Ground",
  surface: "Surface",
  selected: "Selected",
  selectedStrong: "Selected strong",
  hairline: "Hairline",
  control: "Control",
  ink: "Ink",
  inkSoft: "Ink soft",
  muted: "Muted",
  unread: "Unread",
  read: "Read",
  onAccent: "On accent",
  scrim: "Scrim",
};

export interface Palette {
  id: string;
  isDark: boolean;
  colors: Record<TokenName, RGBA>;
}

/** gui/tokens.css, as values. */
export const tokens = {
  light: {
    ground: "#FFFFFF", surface: "#F7F7F7", selected: "#F2F2F2", selectedStrong: "#E8E8E8", hairline: "#E8E8E8", control: "#CCCCCC",
    ink: "#111111", inkSoft: "#444444", muted: "#6A6A6A", unread: "#0A3CFF", read: "#5B2A9D", onAccent: "#FFFFFF", scrim: "#00000033",
  },
  dark: {
    ground: "#111111", surface: "#191919", selected: "#2A2A2A", selectedStrong: "#333333", hairline: "#2C2C2C", control: "#5A5A5A",
    ink: "#F2F2F2", inkSoft: "#C8C8C8", muted: "#A8A8A8", unread: "#8AA8FF", read: "#C3A6F2", onAccent: "#111111", scrim: "#00000080",
  },
  newsprint: { ground: "#F1EEE6", unread: "#111111", read: "#77736A" },
  terminal: { ground: "#000000", unread: "#39FF88", read: "#2A9D5C" },
  fonts: { reading: "Newsreader", ui: "Inter", code: "JetBrains Mono" },
  radii: { control: 6, panel: 10, sheet: 12 },
} as const;

const rgba = (text: string): RGBA => parseHex(text) ?? [0, 0, 0, 255];

function fromTokens(id: string, isDark: boolean, source: Record<TokenName, string>): Palette {
  const colors = {} as Record<TokenName, RGBA>;
  for (const name of tokenNames) colors[name] = rgba(source[name]);
  return { id, isDark, colors };
}

const light = fromTokens("light", false, tokens.light);
const dark = fromTokens("dark", true, tokens.dark);

const newsprint: Palette = (() => {
  const c = { ...light.colors };
  c.ground = rgba(tokens.newsprint.ground);
  c.unread = rgba(tokens.newsprint.unread);
  c.read = rgba(tokens.newsprint.read);
  c.surface = mix(c.ground, black, 0.04);
  c.selected = mix(c.ground, black, 0.07);
  c.selectedStrong = mix(c.ground, black, 0.11);
  c.hairline = mix(c.ground, black, 0.11);
  c.muted = c.read;
  c.onAccent = c.ground;
  return { id: "newsprint", isDark: false, colors: c };
})();

const terminal: Palette = (() => {
  const c = { ...dark.colors };
  c.ground = rgba(tokens.terminal.ground);
  c.unread = rgba(tokens.terminal.unread);
  c.read = rgba(tokens.terminal.read);
  c.ink = c.unread;
  c.inkSoft = mix(c.unread, black, 0.2);
  c.muted = c.read;
  c.surface = mix(c.unread, black, 0.93);
  c.selected = mix(c.unread, black, 0.86);
  c.selectedStrong = mix(c.unread, black, 0.8);
  c.hairline = mix(c.unread, black, 0.8);
  c.control = c.read;
  c.onAccent = c.ground;
  return { id: "terminal", isDark: true, colors: c };
})();

export const builtIns = ["light", "dark", "newsprint", "terminal"] as const;

const named: Record<string, Palette> = { light, dark, newsprint, terminal };

/** A built-in palette; anything unknown is Light, as on the Mac. */
export function builtIn(id: string): Palette {
  return named[id] ?? light;
}

/** Token overrides from a custom theme, as config.json holds them. */
export type ThemeTokens = Partial<Record<string, string | null>>;

/** A palette with the user's overrides on top. Unparseable values are ignored. */
export function applying(palette: Palette, overrides: ThemeTokens | undefined, id = palette.id): Palette {
  const colors = { ...palette.colors };
  for (const name of tokenNames) {
    const text = overrides?.[wireName[name]];
    const color = text ? parseHex(text) : null;
    if (color) colors[name] = color;
  }
  return { id, isDark: palette.isDark, colors };
}

/** Every token as `#RRGGBB[AA]`, for display and tests. */
export function hexes(palette: Palette): Record<TokenName, string> {
  const out = {} as Record<TokenName, string>;
  for (const name of tokenNames) out[name] = toHex(palette.colors[name]);
  return out;
}
