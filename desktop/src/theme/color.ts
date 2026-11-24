// Colors as the Mac app computes them. SwiftUI's `Color.mix(with:by:)` mixes in its
// perceptual space, which is OKLab: `mix` here gives the same 8-bit values (see
// tests/unit/theme.test.ts, whose expected values were printed by SwiftUI).

export type RGBA = [number, number, number, number];

/** `#RRGGBB` or `#RRGGBBAA`, with or without the `#`. Null for anything else. */
export function parseHex(text: string): RGBA | null {
  const digits = text.startsWith("#") ? text.slice(1) : text;
  if (!/^([0-9a-f]{6}|[0-9a-f]{8})$/iu.test(digits)) return null;
  const value = (i: number) => parseInt(digits.slice(i, i + 2), 16);
  return [value(0), value(2), value(4), digits.length === 8 ? value(6) : 255];
}

/** `#RRGGBB`, or `#RRGGBBAA` when not opaque, in capitals as the Mac writes it. */
export function toHex([r, g, b, a]: RGBA): string {
  const two = (v: number) => Math.round(v).toString(16).padStart(2, "0").toUpperCase();
  return "#" + two(r) + two(g) + two(b) + (Math.round(a) === 255 ? "" : two(a));
}

const toLinear = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
const toGamma = (c: number) => (c <= 0.0031308 ? 12.92 * c : 1.055 * c ** (1 / 2.4) - 0.055);

function toOklab(r8: number, g8: number, b8: number): [number, number, number] {
  const [r, g, b] = [r8, g8, b8].map((v) => toLinear(v / 255));
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ];
}

function fromOklab([L, A, B]: [number, number, number]): [number, number, number] {
  const l = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3;
  const m = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3;
  const s = (L - 0.0894841775 * A - 1.291485548 * B) ** 3;
  const linear = [
    4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
    -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
  ];
  return linear.map((v) => Math.round(Math.min(1, Math.max(0, toGamma(v))) * 255)) as [number, number, number];
}

/** `color` moved `by` (0…1) of the way to `other`, as SwiftUI's `mix` does. Alpha mixes linearly. */
export function mix(color: RGBA, other: RGBA, by: number): RGBA {
  const a = toOklab(color[0], color[1], color[2]);
  const b = toOklab(other[0], other[1], other[2]);
  const [r, g, bl] = fromOklab([a[0] + (b[0] - a[0]) * by, a[1] + (b[1] - a[1]) * by, a[2] + (b[2] - a[2]) * by]);
  return [r, g, bl, Math.round(color[3] + (other[3] - color[3]) * by)];
}

export const black: RGBA = [0, 0, 0, 255];

/** WCAG relative luminance, for the contrast note in the color panel. */
export function luminance([r, g, b]: RGBA): number {
  return 0.2126 * toLinear(r / 255) + 0.7152 * toLinear(g / 255) + 0.0722 * toLinear(b / 255);
}

export function contrast(a: RGBA, b: RGBA): number {
  const [x, y] = [luminance(a), luminance(b)];
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}

/** A CSS color for a token value. */
export function css([r, g, b, a]: RGBA): string {
  return a === 255 ? `rgb(${r} ${g} ${b})` : `rgb(${r} ${g} ${b} / ${+(a / 255).toFixed(4)})`;
}
