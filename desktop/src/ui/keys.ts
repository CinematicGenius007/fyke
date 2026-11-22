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
    j: () => void model.startCatchUp(),
    r: () => void model.runBrief(),
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
    s: () => model.set("saveRequests", (requests) => requests + 1),
  };
  const shifted: Record<string, () => void> = {
    a: () => model.ask(),
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
  if (event.defaultPrevented || event.isComposing || model.state.showingAddFeed || document.querySelector(".settings-move[open]")) return;
  const catchUp = model.catchUp();
  if (catchUp) {
    if ((event.ctrlKey || event.metaKey) && !event.altKey && !event.shiftKey && event.key.toLowerCase() === "z") {
      event.preventDefault();
      void catchUp.undo();
      return;
    }
    if (event.ctrlKey || event.metaKey || event.altKey) return;
    const decisions = { ArrowLeft: "skip", ArrowDown: "later", ArrowRight: "read", Enter: "read" } as const;
    const decision = decisions[event.key as keyof typeof decisions];
    if (event.key === "Escape") {
      event.preventDefault();
      model.closeCatchUp();
    } else if (decision && !(event.key === "Enter" && (event.target as HTMLElement | null)?.tagName === "BUTTON")) {
      event.preventDefault();
      void catchUp.decide(decision);
    }
    return;
  }
  // An open menu takes the keys: Esc closes it, and nothing behind it acts.
  if (float.isOpen()) {
    if (model.state.showingActivity && (event.ctrlKey || event.metaKey) && event.key === "0") {
      event.preventDefault();
      float.close(true);
      return;
    }
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
  if (model.state.webAddress) {
    if (event.key === "Escape" || event.key === "O") {
      event.preventDefault();
      if (event.key === "Escape") model.closeWeb();
      else model.openInBrowser();
    }
    return;
  }
  if (model.state.ask) {
    if (event.key === "Escape") {
      event.preventDefault();
      model.back();
    }
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
    O: () => model.openInBrowser(),
    f: () => model.fetchFull(),
    c: () => model.set("discussionRequest", (request) => request + 1),
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
