// The reader's keys, the same as the Mac's and the terminal app's where they have them
// (gui/Sources/Reader/RootView.swift `handle`). Ctrl stands in for the Mac's Command.
import { app } from "../model/app";
import { float } from "./Float";

/** Typing into a field keeps its letters. */
function typing(target: EventTarget | null): boolean {
  const el = target as HTMLElement | null;
  return !!el && (el.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName));
}

/** The Mac's menu commands (ReaderApp.swift `commands`), with Ctrl for Command. Each
 * key also stops what the webview would do with it (K1–K13). */
function command(event: KeyboardEvent): boolean {
  const model = app();
  const key = event.key.toLowerCase();
  const shift = event.shiftKey;
  // A dialog is modal: nothing behind it acts.
  if (model.state.confirmation) return false;
  const go = (kind: "today" | "all" | "starred" | "routines") => () => model.go({ kind });
  const plain: Record<string, () => void> = {
    ",": () => model.openSettings(),
    n: () => model.set("showingAddFeed", true),
    f: () => {
      model.commands.close();
      model.search.show();
    },
    k: () => {
      model.search.close();
      model.commands.show();
    },
    "1": go("today"),
    "2": go("all"),
    "3": go("starred"),
    "4": go("routines"),
    "0": () => model.set("showingActivity", (v) => !v),
    // Text being edited keeps its own undo.
    z: () => (typing(event.target) ? undefined : model.undo.undoLast()),
    // Ctrl+S saves what is in front; the search panel takes it while it shows.
    s: () => undefined,
  };
  const shifted: Record<string, () => void> = {
    k: () => model.canMarkAllHere() && model.markAllHere(),
  };
  const run = (shift ? shifted : plain)[key];
  if (!run) return false;
  if (key === "z" && typing(event.target)) return false;
  event.preventDefault();
  run();
  return true;
}

export function handleKey(event: KeyboardEvent): void {
  const model = app();
  if (event.defaultPrevented || event.isComposing || model.state.showingAddFeed) return;
  // An open menu takes the keys: Esc closes it, and nothing behind it acts.
  if (float.isOpen()) {
    if (event.key === "Escape") float.close(true);
    if (!typing(event.target) && !["Enter", " ", "Tab"].includes(event.key)) event.preventDefault();
    return;
  }
  if (event.ctrlKey || event.metaKey) {
    if (!event.altKey) command(event);
    return;
  }
  if (event.altKey) return;
  // These hold their own focus and keys.
  if (model.search.state.isShowing || model.commands.state.isShowing) return;
  if (typing(event.target)) return;
  // A confirmation keeps the data on Esc; nothing behind it acts.
  if (model.state.confirmation) {
    if (event.key === "Escape") model.set("confirmation", null);
    // A focused button takes Return, Space and Tab itself.
    if (!["Enter", " ", "Tab"].includes(event.key)) event.preventDefault();
    return;
  }
  if (model.state.renaming) return;
  if (model.state.showingShortcuts) {
    if (event.key === "Escape" || event.key === "?") model.set("showingShortcuts", false);
    return void event.preventDefault();
  }
  if (model.state.showingSettings) {
    if (event.key === "Escape") {
      model.set("showingSettings", false);
      event.preventDefault();
    }
    return;
  }
  const act: Record<string, () => void> = {
    Enter: () => model.openSelected(),
    Escape: () => model.back(),
    ArrowDown: () => model.moveSelection(1),
    ArrowUp: () => model.moveSelection(-1),
    j: () => model.moveSelection(1),
    k: () => model.moveSelection(-1),
    n: () => model.nextUnread(),
    s: () => model.toggleStar(),
    m: () => model.toggleRead(),
    u: () => model.toggleUnreadOnly(),
    o: () => model.openPage(),
    O: () => model.openPage(),
    f: () => model.fetchFull(),
    r: () => model.refresh(),
    a: () => model.set("showingAddFeed", true),
    t: () => model.set("showingType", (v) => !v),
    "/": () => model.search.show(),
    "?": () => model.set("showingShortcuts", true),
  };
  // A focused button takes Return and Space itself.
  if (event.key === "Enter" && (event.target as HTMLElement | null)?.tagName === "BUTTON") return;
  const run = act[event.key];
  if (!run) return;
  event.preventDefault();
  run();
}
