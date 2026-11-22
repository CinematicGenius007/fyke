// Icons as inline SVG on a 16 unit grid.
//
// The Mac draws two kinds. Its own glyphs (Controls.swift `Glyph`) are paths, ported
// here point for point. The rest are SF Symbols, which Apple licenses for its own
// platforms only, so these are drawn equivalents of the same shapes (parity D20).
import type { JSX } from "solid-js";

/** SF's gearshape: eight square teeth on a ring. */
const gearOutline = (() => {
  const teeth = 8;
  const outer = 6.7;
  const inner = 5.1;
  const half = Math.PI / teeth / 2.1;
  const at = (radius: number, angle: number) => `${(8 + radius * Math.cos(angle)).toFixed(2)} ${(8 + radius * Math.sin(angle)).toFixed(2)}`;
  const points: string[] = [];
  for (let i = 0; i < teeth; i++) {
    const middle = (i * 2 * Math.PI) / teeth - Math.PI / 2;
    points.push(at(inner, middle - half * 1.5), at(outer, middle - half * 0.8), at(outer, middle + half * 0.8), at(inner, middle + half * 1.5));
  }
  return `M${points.join("L")}Z`;
})();

/** Each icon's SVG body. Strokes inherit `stroke-width`; `fill` marks filled shapes. */
const shapes = {
  // Controls.swift glyphs
  search: () => <><circle cx="7" cy="7" r="4.25" /><path d="M10.2 10.2L13.5 13.5" /></>,
  briefing: () => <path d="M3 3.5H13M3 8H13M3 12.5H9" />,
  inbox: () => <><rect x="2.75" y="2.75" width="10.5" height="10.5" rx="2" /><path d="M2.75 9.5H5.75L6.75 11H9.25L10.25 9.5H13.25" /></>,
  star: () => <path d="M8 2.2L9.8 5.9L13.8 6.5L10.9 9.3L11.6 13.3L8 11.4L4.4 13.3L5.1 9.3L2.2 6.5L6.2 5.9Z" />,
  circle: () => <circle cx="8" cy="8" r="5.25" />,
  globe: () => <><circle cx="8" cy="8" r="5.75" /><path d="M2.5 8H13.5" /><ellipse cx="8" cy="8" rx="2.5" ry="5.7" /></>,
  reload: () => <path d="M12.8 8A4.8 4.8 0 1 1 11.39 4.61M12.8 2.5V5.5H9.8" />,
  left: () => <path d="M9.5 3.5L5 8L9.5 12.5" />,
  right: () => <path d="M6 4L10 8L6 12" />,
  down: () => <path d="M4 6L8 10L12 6" />,
  up: () => <path d="M4 10L8 6L12 10" />,
  check: () => <path d="M3.5 8.5L6.5 11.5L12.5 4.5" />,
  lock: () => <><rect x="3.5" y="7" width="9" height="6.5" rx="1.5" /><path d="M5.5 7V5A2.5 2.5 0 0 1 10.5 5V7" /></>,
  folder: () => <path d="M2.5 12V4.5L3.5 3.5H6.5L8 5H12.5L13.5 6V12L12.5 13H3.5Z" />,
  arrowLeft: () => <path d="M13 8H3.5M7 4.5L3.5 8L7 11.5" />,
  arrowRight: () => <path d="M3 8H12.5M9 4.5L12.5 8L9 11.5" />,
  close: () => <path d="M4 4L12 12M12 4L4 12" />,
  plus: () => <path d="M8 3V13M3 8H13" />,
  gear: () => (
    <>
      <circle cx="8" cy="8" r="2" />
      <path d="M8 1.75V3.5M8 12.5V14.25M1.75 8H3.5M12.5 8H14.25M3.6 3.6L4.8 4.8M11.2 11.2L12.4 12.4M3.6 12.4L4.8 11.2M11.2 4.8L12.4 3.6" />
    </>
  ),
  sparkle: () => <path d="M8 2L9.4 6.6L14 8L9.4 9.4L8 14L6.6 9.4L2 8L6.6 6.6Z" />,
  database: () => <><ellipse cx="8" cy="4" rx="5" ry="2" /><path d="M3 4V12C3 14.7 13 14.7 13 12V4M3 8C3 10.7 13 10.7 13 8" /></>,
  warning: () => <path d="M8 2.5L14 13H2ZM8 6.5V9.5M8 11.25V11.26" />,

  // Drawn equivalents of the SF Symbols the Mac uses
  magnifyingglass: () => <><circle cx="6.9" cy="6.9" r="4.65" /><path d="M10.3 10.3L14 14" /></>,
  calendar: () => (
    <>
      <rect x="1.9" y="2.6" width="12.2" height="11.4" rx="2.2" />
      <path d="M1.9 5.6H14.1" />
      <g class="dots">
        <circle cx="5" cy="8.2" r="0.65" /><circle cx="8" cy="8.2" r="0.65" /><circle cx="11" cy="8.2" r="0.65" />
        <circle cx="5" cy="10.9" r="0.65" /><circle cx="8" cy="10.9" r="0.65" /><circle cx="11" cy="10.9" r="0.65" />
      </g>
    </>
  ),
  tray: () => <path d="M1.8 9.2V12.4C1.8 13.3 2.5 14 3.4 14H12.6C13.5 14 14.2 13.3 14.2 12.4V9.2L12.3 4.3C12.1 3.8 11.6 3.5 11.1 3.5H4.9C4.4 3.5 3.9 3.8 3.7 4.3ZM1.8 9.2H5.6C5.6 10.6 6.6 11.4 8 11.4S10.4 10.6 10.4 9.2H14.2" />,
  "rectangle.stack": () => <><rect x="2" y="5.6" width="12" height="8.6" rx="1.8" /><path d="M3.6 3.7H12.4M5.2 1.9H10.8" /></>,
  "line.3.horizontal.decrease": () => <path d="M2 4.2H14M4.4 8H11.6M6.6 11.8H9.4" />,
  "clock.arrow.circlepath": () => <path d="M2.6 8.4A5.6 5.6 0 1 0 4.3 4.3M1.4 6.9L2.6 8.6L4.2 7.1M8.2 5.2V8.4L10.4 9.8" />,
  gearshape: () => <><path d={gearOutline} /><circle cx="8" cy="8" r="2.2" /></>,
  "dot.radiowaves.up.forward": () => (
    <>
      <circle cx="8" cy="8.5" r="1.2" />
      <path d="M5.6 6.1A3.4 3.4 0 0 0 5.6 10.9M10.4 6.1A3.4 3.4 0 0 1 10.4 10.9M3.6 3.9A6.3 6.3 0 0 0 3.6 13.1M12.4 3.9A6.3 6.3 0 0 1 12.4 13.1" />
    </>
  ),
  "arrow.clockwise": () => <path d="M13.2 8.6A5.2 5.2 0 1 1 11.6 4.3M12 1.6V4.7H8.9" />,
  "checkmark.circle": () => <><circle cx="8" cy="8" r="6" /><path d="M5.4 8.2L7.2 10L10.7 6.2" /></>,
  "arrow.uturn.backward": () => <path d="M5.5 3.5L2.5 6.5L5.5 9.5M2.5 6.5H10A3.5 3.5 0 0 1 10 13.5H7" />,
  "folder.badge.plus": () => <path d="M2.5 12V4.5L3.5 3.5H6.5L8 5H12.5L13.5 6V8M8.5 13H3.5L2.5 12M12 9.5V14.5M9.5 12H14.5" />,
  keyboard: () => <><rect x="1.5" y="4" width="13" height="8.5" rx="1.5" /><path d="M4 6.6H4.01M6.67 6.6H6.68M9.33 6.6H9.34M12 6.6H12.01M4 9H4.01M12 9H12.01M6 10.2H10" /></>,
  return: () => <path d="M13 3.5V8.5A1.5 1.5 0 0 1 11.5 10H3.5M6.5 7L3.5 10L6.5 13" />,
  ellipsis: () => <g class="dots"><circle cx="3.4" cy="8" r="1.15" /><circle cx="8" cy="8" r="1.15" /><circle cx="12.6" cy="8" r="1.15" /></g>,
} satisfies Record<string, () => JSX.Element>;

export type IconName = keyof typeof shapes;

/** Stroke widths on the 16 grid: the glyphs' 1.5, and SF Symbols' regular weight. */
const symbolStroke = 1.25;
const glyphs = new Set<string>(["search", "briefing", "inbox", "star", "circle", "globe", "reload", "left", "right", "down", "up", "check", "lock", "folder", "arrowLeft", "arrowRight", "close", "plus", "gear", "sparkle", "database", "warning"]);

export function Icon(props: { name: IconName; size?: number; filled?: boolean; color?: string; stroke?: number; class?: string }) {
  const size = () => props.size ?? 16;
  const stroke = () => props.stroke ?? (glyphs.has(props.name) ? 1.5 : symbolStroke);
  return (
    <svg
      class={`icon${props.filled ? " filled" : ""}${props.class ? ` ${props.class}` : ""}`}
      width={size()}
      height={size()}
      viewBox="0 0 16 16"
      aria-hidden="true"
      style={{ color: props.color, "stroke-width": String(stroke()) }}
    >
      {shapes[props.name]()}
    </svg>
  );
}
