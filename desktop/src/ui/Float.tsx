// The one floating panel a window has open (gui/Sources/Reader/Controls.swift
// `FloatLayer`): right-click menus, and a submenu beside one. It sits above everything,
// so a panel is never clipped by the view that opened it, and a click anywhere else
// closes it.
import { createSignal, For, onMount, Show } from "solid-js";
import { Rule } from "./kit/Controls";
import { Icon } from "./kit/Icon";

export type MenuItem =
  | { title: string; detail?: string; checked?: boolean; indent?: number; submenu?: boolean; run: (row: HTMLElement) => void }
  | "rule";

interface Panel {
  anchor?: HTMLElement;
  id: number;
  x: number;
  y: number;
  /** The top of what opened it, so a panel with no room below opens above it. */
  above: number;
  width: number;
  items: MenuItem[];
}

const [item, setItem] = createSignal<Panel | null>(null);
const [side, setSide] = createSignal<Panel | null>(null);
let next = 0;

export const float = {
  isOpen: () => item() !== null,
  /** A menu at the pointer. */
  menu(event: MouseEvent, width: number, items: MenuItem[]) {
    event.preventDefault();
    setSide(null);
    const anchor = event.currentTarget as HTMLElement;
    const box = anchor.getBoundingClientRect();
    const x = event.clientX || box.left;
    const y = event.clientY || box.bottom;
    setItem({ id: next++, x, y, above: y, width, items, anchor });
  },
  below(anchor: HTMLElement, width: number, items: MenuItem[]) {
    const box = anchor.getBoundingClientRect();
    setSide(null);
    setItem({ id: next++, x: box.left, y: box.bottom, above: box.top, width, items, anchor });
  },
  /** A submenu beside the row that opens it. */
  side(row: HTMLElement, width: number, items: MenuItem[]) {
    const box = row.getBoundingClientRect();
    setSide({ id: next++, x: box.right + 8, y: box.top - 10, above: box.top - 10, width, items, anchor: row });
  },
  close(restoreFocus = false) {
    const anchor = item()?.anchor;
    setItem(null);
    setSide(null);
    if (restoreFocus) anchor?.focus();
  },
};

/** Rows past this many scroll, because a panel must fit inside its window. */
const LIMIT = 8;
const ROW = 30;

function Placed(props: { panel: Panel }) {
  let box!: HTMLDivElement;
  // Measured once it has a size: below the anchor, above it when the window has no
  // room below, and never past the window's edges.
  onMount(() => {
    const { width, height } = box.getBoundingClientRect();
    const below = props.panel.y + 4;
    const y = below + height > window.innerHeight - 8 ? Math.max(8, props.panel.above - height - 4) : below;
    const x = Math.min(Math.max(8, props.panel.x), Math.max(8, window.innerWidth - width - 8));
    box.style.transform = `translate(${x}px, ${y}px)`;
    box.style.visibility = "visible";
    box.querySelector<HTMLElement>("[role=menuitem]")?.focus({ preventScroll: true });
  });
  const rows = () => props.panel.items.filter((i) => i !== "rule").length;
  return (
    <div ref={box} class="float-panel" role="menu" style={{ width: `${props.panel.width}px` }} onKeyDown={(event) => {
      const direction = event.key === "ArrowDown" ? 1 : event.key === "ArrowUp" ? -1 : 0;
      if (direction === 0) return;
      event.preventDefault();
      const choices = [...box.querySelectorAll<HTMLElement>("[role=menuitem]")];
      const current = choices.indexOf(document.activeElement as HTMLElement);
      choices[(current + direction + choices.length) % choices.length]?.focus();
    }}>
      <div class="float-rows scroll" style={rows() > LIMIT ? { "max-height": `${LIMIT * ROW + 12}px` } : undefined}>
        <For each={props.panel.items}>{(entry) => (entry === "rule" ? <Rule class="float-rule" /> : <MenuRow item={entry} />)}</For>
      </div>
    </div>
  );
}

function MenuRow(props: { item: Exclude<MenuItem, "rule"> }) {
  return (
    <button
      type="button"
      class="menu-row"
      role="menuitem"
      style={props.item.indent ? { "padding-left": `${8 + props.item.indent}px` } : undefined}
      onClick={(event) => {
        if (!props.item.submenu) float.close();
        props.item.run(event.currentTarget);
      }}
    >
      <span class="menu-text">
        <span class="menu-title">{props.item.title}</span>
        <Show when={props.item.detail}>{(detail) => <span class="menu-detail">{detail()}</span>}</Show>
      </span>
      <Show when={props.item.checked}>
        <Icon name="check" size={14} color="var(--unread)" />
      </Show>
      <Show when={props.item.submenu}>
        <Icon name="right" size={14} />
      </Show>
    </button>
  );
}

export function FloatLayer() {
  return (
    <Show when={item()}>
      <div
        class="float-layer"
        onMouseDown={(event) => event.target === event.currentTarget && float.close()}
        onContextMenu={(event) => {
          event.preventDefault();
          if (event.target === event.currentTarget) float.close();
        }}
        onKeyDown={(event) => {
          if (event.key !== "Escape") return;
          event.preventDefault();
          event.stopPropagation();
          float.close(true);
        }}
      >
        <Show when={item()} keyed>
          {(panel) => <Placed panel={panel} />}
        </Show>
        <Show when={side()} keyed>
          {(panel) => <Placed panel={panel} />}
        </Show>
      </div>
    </Show>
  );
}
