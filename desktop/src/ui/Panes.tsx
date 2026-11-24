// The article list and the reader, with a divider between them that drags
// (gui/Sources/Reader/RootView.swift `Panes`).
import { createSignal, type JSX, onCleanup, onMount } from "solid-js";
import { prefs } from "../model/prefs";

export const LIST_STANDARD = 368;
const SMALLEST = 280;
/** The reader needs room to be read in. */
const READER_MINIMUM = 400;
/** The divider's grab area. Its line sits in the middle. */
export const DIVIDER_GRAB = 9;

export function Panes(props: { list: JSX.Element; reader: JSX.Element }) {
  let box: HTMLDivElement | undefined;
  const [available, setAvailable] = createSignal(1200);
  const [live, setLive] = createSignal<number | null>(null);
  const [dragging, setDragging] = createSignal(false);

  onMount(() => {
    const observer = new ResizeObserver(([item]) => setAvailable(item.contentRect.width));
    observer.observe(box!);
    onCleanup(() => observer.disconnect());
  });

  const widest = () => Math.max(SMALLEST, Math.min(640, available() - READER_MINIMUM));
  const clamp = (value: number) => Math.min(Math.max(value, SMALLEST), widest());
  const width = () => clamp(live() ?? prefs().ui.list_width);

  function start(event: PointerEvent) {
    if (event.button !== 0) return;
    const handle = event.currentTarget as HTMLElement;
    handle.setPointerCapture(event.pointerId);
    const origin = event.clientX;
    const from = width();
    setDragging(true);
    const move = (e: PointerEvent) => setLive(clamp(from + e.clientX - origin));
    const end = () => {
      handle.removeEventListener("pointermove", move);
      handle.removeEventListener("pointerup", end);
      handle.removeEventListener("pointercancel", end);
      const chosen = live();
      if (chosen !== null && chosen !== from) prefs().update((ui) => (ui.list_width = chosen));
      setLive(null);
      setDragging(false);
    };
    handle.addEventListener("pointermove", move);
    handle.addEventListener("pointerup", end);
    handle.addEventListener("pointercancel", end);
  }

  function keys(event: KeyboardEvent) {
    const step = event.shiftKey ? 40 : 8;
    const change = event.key === "ArrowLeft" ? -step : event.key === "ArrowRight" ? step : 0;
    if (!change) return;
    event.preventDefault();
    event.stopPropagation();
    const next = clamp(width() + change);
    prefs().update((ui) => (ui.list_width = next));
  }

  return (
    <div class="panes" ref={box}>
      <div class="pane-list" style={{ width: `${width()}px` }}>
        {props.list}
      </div>
      <div
        class="divider"
        classList={{ dragging: dragging() }}
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize the article list"
        aria-valuenow={Math.round(width())}
        aria-valuemin={SMALLEST}
        aria-valuemax={Math.round(widest())}
        tabindex="-1"
        onPointerDown={start}
        onKeyDown={keys}
        onDblClick={() => prefs().update((ui) => (ui.list_width = LIST_STANDARD))}
      >
        <div class="divider-line" />
      </div>
      <div class="pane-reader">{props.reader}</div>
    </div>
  );
}
