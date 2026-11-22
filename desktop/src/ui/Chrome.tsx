// The window's own controls, which Fyke draws because the window has no system frame
// (docs/desktop-parity.md D3 and D4). The Mac keeps its traffic lights in the sidebar's
// top 48 points; here the same strip moves the window, and the buttons sit at the top
// right of the content, drawn as each system draws them.
import { createSignal, onCleanup, onMount, Show } from "solid-js";
import { transport } from "../transport";

export type ChromeKind = "windows" | "linux";

/** Which chrome the window shows, set once at start (main.tsx), or none in a browser. */
export function chromeKind(): ChromeKind | null {
  const kind = document.documentElement.dataset.chrome;
  return kind === "windows" || kind === "linux" ? kind : null;
}

/** The strip at the top of the window that moves it, as the Mac's title bar area does. */
export const DRAG_HEIGHT = 48;

/** What a press on the strip must leave alone, because it acts on its own. */
const INTERACTIVE = "button, a[href], input, textarea, select, label, summary, [role=button], [role=menuitem], [role=tab], [role=checkbox], [role=option], [contenteditable], [draggable=true], .divider";

/** A press on empty space in the top strip drags the window; a double press maximizes it. */
export function titleBarPress(event: MouseEvent): boolean {
  if (!chromeKind() || event.button !== 0 || event.clientY >= DRAG_HEIGHT) return false;
  const target = event.target as Element | null;
  if (!target || target.closest(INTERACTIVE) || target.closest(".scrim, .float-layer")) return false;
  event.preventDefault();
  void transport().windowAction(event.detail === 2 ? "maximize" : "drag");
  return true;
}

export function WindowButtons() {
  const [maximized, setMaximized] = createSignal(false);
  onMount(() => {
    let stop: (() => void) | undefined;
    let gone = false;
    void transport()
      .observeMaximized(setMaximized)
      .then((unlisten) => (gone ? unlisten() : (stop = unlisten)))
      .catch(() => undefined);
    onCleanup(() => {
      gone = true;
      stop?.();
    });
  });
  const act = (action: "minimize" | "maximize" | "close") => () => void transport().windowAction(action);
  // Caption buttons are not tab stops on either system; the system keys (Alt+Space,
  // Super+Up and Alt+F4) reach them from the keyboard.
  return (
    <Show when={chromeKind()}>
      {(kind) => (
        <div class={`window-buttons ${kind()}`} role="group" aria-label="Window">
          <button type="button" tabIndex={-1} class="window-button" aria-label="Minimize" title="Minimize" onClick={act("minimize")}>
            <Glyph kind={kind()} name="minimize" />
          </button>
          <button type="button" tabIndex={-1} class="window-button" aria-label={maximized() ? "Restore" : "Maximize"} title={maximized() ? "Restore" : "Maximize"} onClick={act("maximize")}>
            <Glyph kind={kind()} name={maximized() ? "restore" : "maximize"} />
          </button>
          <button type="button" tabIndex={-1} class="window-button close" aria-label="Close" title="Close" onClick={act("close")}>
            <Glyph kind={kind()} name="close" />
          </button>
        </div>
      )}
    </Show>
  );
}

/** Windows draws 10-pixel glyphs with one-pixel strokes; Adwaita draws 16-pixel symbolic icons. */
function Glyph(props: { kind: ChromeKind; name: "minimize" | "maximize" | "restore" | "close" }) {
  const windows = () => props.kind === "windows";
  const size = () => (windows() ? 10 : 16);
  const paths = (): string => {
    if (windows()) {
      switch (props.name) {
        case "minimize":
          return "M0 5.5h10";
        case "maximize":
          return "M0.5 0.5h9v9h-9z";
        case "restore":
          return "M0.5 2.5h7v7h-7z M2.5 2.5v-2h7v7h-2";
        case "close":
          return "M0.5 0.5l9 9 M9.5 0.5l-9 9";
      }
    }
    switch (props.name) {
      case "minimize":
        return "M4 11.5h8";
      case "maximize":
        return "M4.5 4.5h7v7h-7z";
      case "restore":
        return "M4.5 6.5h5v5h-5z M6.5 6.5v-2h5v5h-2";
      case "close":
        return "M4.5 4.5l7 7 M11.5 4.5l-7 7";
    }
  };
  return (
    <svg width={size()} height={size()} viewBox={`0 0 ${size()} ${size()}`} aria-hidden="true" fill="none" stroke="currentColor" stroke-width={windows() ? 1 : 1.5}>
      <path d={paths()} />
    </svg>
  );
}
