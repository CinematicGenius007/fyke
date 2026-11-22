// The reader's keys, the same as the Mac's and the terminal app's where they have them
// (gui/Sources/Reader/RootView.swift `handle`). Ctrl stands in for the Mac's Command.
import { app } from "../model/app";

/** Typing into a field keeps its letters. */
function typing(target: EventTarget | null): boolean {
  const el = target as HTMLElement | null;
  return !!el && (el.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName));
}

export function handleKey(event: KeyboardEvent): void {
  const model = app();
  if (event.defaultPrevented || event.isComposing) return;
  if (event.ctrlKey || event.metaKey || event.altKey) {
    if ((event.ctrlKey || event.metaKey) && !event.shiftKey && event.key.toLowerCase() === "z" && !typing(event.target)) {
      event.preventDefault();
      model.undo.undoLast();
    }
    return;
  }
  if (typing(event.target)) return;
  if (model.state.confirmation) return void event.preventDefault();
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
    "?": () => model.set("showingShortcuts", true),
  };
  // A focused button takes Return and Space itself.
  if (event.key === "Enter" && (event.target as HTMLElement | null)?.tagName === "BUTTON") return;
  const run = act[event.key];
  if (!run) return;
  event.preventDefault();
  run();
}
