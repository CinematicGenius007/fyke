// Ctrl+K: every destination and every command in one list, matched as you type
// (gui/Sources/Reader/CommandPalette.swift `CommandModel`). Every action that exists in
// the app is here, so the keyboard reaches all of it.
import { createStore } from "solid-js/store";
import type { IconName } from "../ui/kit/Icon";
import { transport } from "../transport";
import type { AppModel as App } from "./app";
import { type EntrySummary, feedName, type Items } from "./types";

export interface Command {
  id: string;
  group: "go" | "act";
  title: string;
  detail?: string;
  icon: IconName;
  shortcut?: string;
  run: () => void;
}

/** Articles found as you type, at most this many. */
const ARTICLE_LIMIT = 4;
const TYPING_PAUSE_MS = 150;

interface CommandState {
  isShowing: boolean;
  query: string;
  selection: number;
  articles: EntrySummary[];
}

export function createCommands() {
  const [state, set] = createStore<CommandState>({ isShowing: false, query: "", selection: 0, articles: [] });
  let pending: ReturnType<typeof setTimeout> | undefined;
  let generation = 0;

  function searchArticles() {
    clearTimeout(pending);
    const mine = ++generation;
    set("selection", 0);
    const words = state.query.trim();
    if (words.length < 2) {
      set("articles", []);
      return;
    }
    pending = setTimeout(async () => {
      let found: EntrySummary[] = [];
      try {
        found = (await transport().call<Items<EntrySummary>>("entries.search", { query: words, limit: ARTICLE_LIMIT })).items ?? [];
      } catch {
        // The palette still lists its commands; the status line shows a lost service.
      }
      if (mine === generation) set("articles", found);
    }, TYPING_PAUSE_MS);
  }

  return {
    state,
    show() {
      generation++;
      set({ query: "", selection: 0, articles: [], isShowing: true });
    },
    close() {
      clearTimeout(pending);
      generation++;
      set("isShowing", false);
    },
    setQuery(query: string) {
      set("query", query);
      searchArticles();
    },
    select(index: number) {
      set("selection", index);
    },
  };
}

export type Commands = ReturnType<typeof createCommands>;

/** Everything the palette can do, built from what exists now. The Mac's brief, catch-up,
 * ask, routine and activity commands join as those features
 * do (docs/desktop-parity.md). */
export function allCommands(model: App): Command[] {
  const out: Command[] = [
    { id: "go.today", group: "go", title: "Today", detail: "Briefs", icon: "calendar", shortcut: "Ctrl+1", run: () => model.go({ kind: "today" }) },
    { id: "go.all", group: "go", title: "All", detail: `${model.totalUnread()} unread`, icon: "tray", shortcut: "Ctrl+2", run: () => model.go({ kind: "all" }) },
    { id: "go.starred", group: "go", title: "Starred", icon: "star", shortcut: "Ctrl+3", run: () => model.go({ kind: "starred" }) },
    { id: "go.routines", group: "go", title: "Routines", icon: "clock.arrow.circlepath", shortcut: "Ctrl+4", run: () => model.go({ kind: "routines" }) },
  ];
  for (const view of model.library.state.views) {
    out.push({ id: `go.view${view.id}`, group: "go", title: view.name, detail: `View · ${view.unread} unread`, icon: "line.3.horizontal.decrease", run: () => model.go({ kind: "view", id: view.id }) });
  }
  for (const folder of model.state.folders) {
    out.push({ id: `go.folder${folder.id}`, group: "go", title: folder.name, detail: "Folder", icon: "folder", run: () => model.go({ kind: "folder", id: folder.id }) });
  }
  for (const feed of model.state.feeds) {
    const folder = model.state.folders.find((f) => f.id === feed.folder_id)?.name;
    const detail = ["Feed", folder].filter(Boolean).join(" · ");
    out.push({ id: `go.feed${feed.id}`, group: "go", title: feedName(feed), detail, icon: "dot.radiowaves.up.forward", run: () => model.go({ kind: "feed", id: feed.id }) });
  }
  out.push(
    { id: "do.search", group: "act", title: "Search articles", icon: "magnifyingglass", shortcut: "Ctrl+F", run: () => model.search.show() },
    { id: "do.brief", group: "act", title: model.state.place.kind === "view" ? "Write a brief of this view" : "Write a brief",
      shortcut: "Ctrl+R", icon: "briefing", run: () => void model.runBrief() },
    { id: "do.catchup", group: "act", title: `Catch up on ${model.placeTitle()}`, icon: "rectangle.stack", shortcut: "Ctrl+J", run: () => void model.startCatchUp() },
    { id: "do.ask", group: "act", title: "Ask your feeds", icon: "sparkle", shortcut: "Ctrl+Shift+A", run: () => model.ask() },
    { id: "do.refresh", group: "act", title: "Refresh feeds", icon: "arrow.clockwise", shortcut: "R", run: () => model.refresh() },
    { id: "do.add", group: "act", title: "Add feed", icon: "plus", shortcut: "Ctrl+N", run: () => model.set("showingAddFeed", true) },
    { id: "do.folder", group: "act", title: "New folder", icon: "folder.badge.plus", run: () => void model.newFolder(null) },
    {
      id: "do.unread",
      group: "act",
      title: model.state.unreadOnly ? "Show all articles" : "Show unread only",
      icon: "circle",
      shortcut: "U",
      run: () => model.toggleUnreadOnly(),
    },
    { id: "do.activity", group: "act", title: "Show activity", icon: "circle", shortcut: "Ctrl+0", run: () => model.set("showingActivity", true) },
    { id: "do.shortcuts", group: "act", title: "Keyboard shortcuts", icon: "keyboard", shortcut: "?", run: () => model.set("showingShortcuts", true) },
    { id: "do.settings-agents", group: "act", title: "Settings · Agents", icon: "gearshape", run: () => model.openSettings("Agents") },
    { id: "do.settings", group: "act", title: "Settings", icon: "gearshape", shortcut: "Ctrl+,", run: () => model.openSettings() },
  );
  if (model.library.state.views.length) {
    out.push({ id: "do.routine", group: "act", title: "New routine", icon: "plus", run: () => model.draftRoutine() });
  }
  for (const routine of model.library.state.routines) {
    if (routine.id !== null && routine.viewId !== null) {
      const id = routine.id;
      out.push({ id: `do.routine${id}`, group: "act", title: `Run ${routine.name} now`, icon: "clock.arrow.circlepath", run: () => void model.runRoutine(id) });
    }
  }
  if (model.canMarkAllHere()) {
    out.push({ id: "do.markall", group: "act", title: `Mark all read in ${model.placeTitle()}`, icon: "checkmark.circle", run: () => model.markAllHere() });
  }
  const undo = model.undo.lastMessage();
  if (undo !== undefined) {
    out.push({ id: "do.undo", group: "act", title: `Undo: ${undo}`, icon: "arrow.uturn.backward", shortcut: "Ctrl+Z", run: () => model.undo.undoLast() });
  }
  return out;
}
