// The small controls every screen shares (gui/Sources/Reader/Kit.swift, Controls.swift,
// Sidebar.swift). Sizes are the Mac's points; colors come from the theme's variables.
import { type JSX, Show, splitProps } from "solid-js";
import { Icon, type IconName } from "./Icon";

/** A count at the end of a row: the unread color, or muted when quiet or zero. */
export function Count(props: { value: number; quiet?: boolean }) {
  return (
    <span class="count" classList={{ quiet: props.quiet || props.value === 0 }} aria-label={props.quiet ? String(props.value) : `${props.value} unread`}>
      {props.value}
    </span>
  );
}

/** The caps label above a group: 11 px, weight 600, +0.06em, muted. */
export function SectionLabel(props: { text: string; class?: string }) {
  return (
    <span class={`section-label${props.class ? ` ${props.class}` : ""}`} role="heading" aria-level="2">
      {props.text.toUpperCase()}
    </span>
  );
}

export function Rule(props: { vertical?: boolean; strong?: boolean; class?: string }) {
  return <div class={`rule${props.vertical ? " vertical" : ""}${props.strong ? " strong" : ""}${props.class ? ` ${props.class}` : ""}`} role="presentation" />;
}

/** A turning arc. Reduced motion holds it still (see app.css). */
export function Spinner(props: { size?: number }) {
  const size = () => props.size ?? 14;
  return (
    <svg class="spinner" width={size()} height={size()} viewBox="0 0 16 16" role="img" aria-label="Working">
      <path d="M8 1.5A6.5 6.5 0 1 1 1.82 10" />
    </svg>
  );
}

/** A square button holding one symbol, with hover, pressed and selected fills. */
export function SymbolButton(props: { icon: IconName; label: string; size?: number; iconSize?: number; selected?: boolean; onClick: () => void; ref?: (el: HTMLButtonElement) => void }) {
  return (
    <button
      ref={props.ref}
      type="button"
      class="symbol-button"
      classList={{ selected: props.selected }}
      style={{ width: `${props.size ?? 28}px`, height: `${props.size ?? 28}px` }}
      title={props.label}
      aria-label={props.label}
      aria-pressed={props.selected === undefined ? undefined : props.selected}
      onClick={() => props.onClick()}
    >
      <Icon name={props.icon} size={props.iconSize ?? 16} />
    </button>
  );
}

/** A 30 px square button holding one glyph, without a fill of its own. */
export function IconButton(props: { icon: IconName; label: string; color?: string; filled?: boolean; enabled?: boolean; onClick: () => void }) {
  return (
    <button type="button" class="icon-button" title={props.label} aria-label={props.label} disabled={props.enabled === false} onClick={() => props.onClick()}>
      <Icon name={props.icon} filled={props.filled} color={props.enabled === false ? "var(--control)" : props.color} />
    </button>
  );
}

/** A word in a sentence that can be tapped: 24 high, filled, never bordered. */
export function Chip(props: { text: string; selected?: boolean; muted?: boolean; onClick?: () => void } & Omit<JSX.ButtonHTMLAttributes<HTMLButtonElement>, "onClick">) {
  const [own, rest] = splitProps(props, ["text", "selected", "muted", "onClick"]);
  return (
    <button type="button" class="chip" classList={{ selected: own.selected, muted: own.muted }} onClick={() => own.onClick?.()} {...rest}>
      {own.text}
    </button>
  );
}

/** A small dot: the unread mark and every status dot drawn like it. */
export function Dot(props: { color: string; label?: string }) {
  return <span class="dot" style={{ background: props.color }} role={props.label ? "img" : undefined} aria-label={props.label} />;
}

export function When<T>(props: { value: T | null | undefined | false; children: (value: T) => JSX.Element }) {
  return <Show when={props.value}>{(value) => props.children(value())}</Show>;
}

export type ActionKind = "primary" | "secondary" | "quiet" | "link" | "inverse";

/** A worded button (Kit.swift `ActionStyle`): 32 high, or 28 and a size smaller when compact. */
export function Action(
  props: { kind?: ActionKind; compact?: boolean; selected?: boolean; children: JSX.Element } & Omit<JSX.ButtonHTMLAttributes<HTMLButtonElement>, "children">,
) {
  const [own, rest] = splitProps(props, ["kind", "compact", "selected", "children", "class"]);
  return (
    <button
      type="button"
      class={`action ${own.kind ?? "secondary"}${own.class ? ` ${own.class}` : ""}`}
      classList={{ compact: own.compact, selected: own.selected }}
      {...rest}
    >
      {own.children}
    </button>
  );
}

/** A key's name in a small filled box, as menus and footers show it. */
export function KeyHint(props: { text: string; onDark?: boolean }) {
  return (
    <kbd class="key-hint" classList={{ "on-dark": props.onDark }}>
      {props.text}
    </kbd>
  );
}
