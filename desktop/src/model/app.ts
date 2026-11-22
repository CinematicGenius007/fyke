// View state only (gui/Sources/Reader/AppModel.swift). Everything durable lives behind
// the daemon, and this store reloads from it when an event says something changed.
import { batch, createRoot } from "solid-js";
import { createStore, produce, reconcile } from "solid-js/store";
import { Plural } from "../logic/Plural";
import { type DaemonEvent, RPCFailure, transport } from "../transport";
import { createLibrary } from "./library";
import { prefs } from "./prefs";
import type { Block, Entry, EntryPage, EntrySummary, Feed, Folder, Items, Stats } from "./types";
import { feedName, jobIsWriting } from "./types";
import { Dates } from "../ui/format";
import { createUndoCenter } from "./undo";

/** The daemon this app speaks to (`api_version` in stats.get). */
export const API_VERSION = 2;

export type Place =
  | { kind: "today" }
  | { kind: "all" }
  | { kind: "starred" }
  | { kind: "routines" }
  | { kind: "feed"; id: number }
  | { kind: "folder"; id: number }
  | { kind: "view"; id: number };

export const samePlace = (a: Place, b: Place) => a.kind === b.kind && ("id" in a ? a.id : 0) === ("id" in b ? b.id : 0);
const placeId = (place: Place) => ("id" in place ? place.id : null);

export type Renaming = { kind: "feed" | "folder" | "view"; id: number } | null;

export type Confirmation = { kind: "deleteFolder"; folder: Folder } | { kind: "removeFeed"; feed: Feed } | null;

export interface Article {
  entry: Entry;
  blocks: Block[];
}

interface State {
  feeds: Feed[];
  folders: Folder[];
  place: Place;
  entries: EntrySummary[];
  nextCursor: string | null;
  selectedId: number | null;
  article: Article | null;
  unreadOnly: boolean;
  hasLoaded: boolean;
  /** True once the first load and any screen asked for at launch are done. */
  launched: boolean;
  problem: string | null;
  updatedAt: Date | null;
  fullTextStatus: string | null;
  showingAddFeed: boolean;
  showingType: boolean;
  showingShortcuts: boolean;
  showingSettings: boolean;
  showingActivity: boolean;
  confirmation: Confirmation;
  renaming: Renaming;
  selectedBrief: number | null;
  healthFeed: number | null;
}

/** The words for a failure: the daemon names its refusals, and only some need words. */
export function words(error: unknown): string {
  return RPCFailure.from(error).message;
}

function createApp() {
  const [state, set] = createStore<State>({
    feeds: [],
    folders: [],
    place: { kind: "all" },
    entries: [],
    nextCursor: null,
    selectedId: null,
    article: null,
    unreadOnly: false,
    hasLoaded: false,
    launched: false,
    problem: null,
    updatedAt: null,
    fullTextStatus: null,
    showingAddFeed: false,
    showingType: false,
    showingShortcuts: false,
    showingSettings: false,
    showingActivity: false,
    confirmation: null,
    renaming: null,
    selectedBrief: null,
    healthFeed: null,
  });

  const library = createLibrary();
  const undo = createUndoCenter();
  let pendingReload: ReturnType<typeof setTimeout> | undefined;
  let paused = false;
  let stopEvents: (() => void) | undefined;

  const fail = (error: unknown) => set("problem", words(error));

  // MARK: Derived

  const totalUnread = () => state.feeds.reduce((sum, f) => sum + f.unread, 0);
  const totalStarred = () => state.feeds.reduce((sum, f) => sum + f.starred, 0);
  const isEmpty = () => state.hasLoaded && state.feeds.length === 0;
  const childFolders = (parent: number | null) => state.folders.filter((f) => (f.parent_id ?? null) === parent);
  const foldersInside = (id: number): Folder[] => childFolders(id).flatMap((f) => [f, ...foldersInside(f.id)]);
  function feedsInside(id: number): Feed[] {
    const ids = new Set([id, ...foldersInside(id).map((f) => f.id)]);
    return state.feeds.filter((f) => f.folder_id != null && ids.has(f.folder_id));
  }
  const folderOutline = (parent: number | null = null, depth = 0): { folder: Folder; depth: number }[] =>
    childFolders(parent).flatMap((folder) => [{ folder, depth }, ...folderOutline(folder.id, depth + 1)]);

  function placeTitle(): string {
    const place = state.place;
    switch (place.kind) {
      case "today":
        return "Today";
      case "all":
        return "All";
      case "starred":
        return "Starred";
      case "routines":
        return "Routines";
      case "feed": {
        const feed = state.feeds.find((f) => f.id === place.id);
        return feed ? feedName(feed) : "Feed";
      }
      case "folder":
        return state.folders.find((f) => f.id === place.id)?.name ?? "Folder";
      case "view":
        return library.view(place.id)?.name ?? "View";
    }
  }

  function placeUnread(): number {
    const place = state.place;
    switch (place.kind) {
      case "feed":
        return state.feeds.find((f) => f.id === place.id)?.unread ?? 0;
      case "folder":
        return feedsInside(place.id).reduce((sum, f) => sum + f.unread, 0);
      case "view":
        return library.view(place.id)?.unread ?? 0;
      default:
        return totalUnread();
    }
  }

  /** Feeds, folders, views, Today and Routines show list and reader side by side.
   * All and Starred replace the timeline with the reader (D2). */
  const usesPanes = () => !["all", "starred"].includes(state.place.kind);
  /** Today and Routines list briefs and routines, not articles. */
  const listsEntries = () => state.place.kind !== "today" && state.place.kind !== "routines";
  /** Whether the sidebar marks `place` as the one showing. None is while Settings is. */
  const isShowing = (place: Place) => !state.showingSettings && samePlace(state.place, place);

  // MARK: Loading

  function listParams(): Record<string, unknown> {
    const place = state.place;
    // A view's rule replaces every other filter, which the daemon refuses to mix.
    if (place.kind === "view") return { view_id: place.id, limit: 100, with_summary: true };
    const params: Record<string, unknown> = { unread_only: state.unreadOnly, starred_only: place.kind === "starred", limit: 100, with_summary: true };
    if (place.kind === "feed") params.feed_id = place.id;
    if (place.kind === "folder") params.folder_id = place.id;
    return params;
  }

  async function reloadEntries(): Promise<void> {
    if (!listsEntries()) {
      set("entries", []);
      return;
    }
    const asked = state.place;
    // Keep as many rows as were loaded, so that a background update does not shorten
    // the list under the reader's scroll position.
    const params = { ...listParams(), limit: Math.max(100, Math.min(state.entries.length, 1000)) };
    const page = await transport().call<EntryPage>("entries.list", params);
    if (!samePlace(asked, state.place)) return;
    batch(() => {
      set("entries", reconcile(page.items, { key: "id" }));
      set("nextCursor", page.next_cursor ?? null);
    });
  }

  async function loadMore(): Promise<void> {
    const cursor = state.nextCursor;
    if (!cursor) return;
    set("nextCursor", null);
    try {
      const page = await transport().call<EntryPage>("entries.list", { ...listParams(), before: cursor });
      batch(() => {
        set("entries", (rows) => [...rows, ...page.items]);
        set("nextCursor", page.next_cursor ?? null);
      });
    } catch (error) {
      fail(error);
    }
  }

  async function reload(): Promise<void> {
    if (paused) return;
    try {
      const [feeds, folders] = await Promise.all([transport().call<Items<Feed>>("feeds.list"), transport().call<Items<Folder>>("folders.list")]);
      batch(() => {
        set("feeds", reconcile(feeds.items, { key: "id" }));
        set("folders", reconcile(folders.items, { key: "id" }));
      });
      await reloadEntries();
      await library.loadViews();
      batch(() => {
        set("updatedAt", new Date());
        set("problem", null);
      });
    } catch (error) {
      fail(error);
    }
  }

  /** A poll can produce hundreds of events at once. One reload covers them. */
  function scheduleReload() {
    if (paused) return;
    clearTimeout(pendingReload);
    pendingReload = setTimeout(() => void reload(), 250);
  }

  async function refreshCounts() {
    try {
      const list = await transport().call<Items<Feed>>("feeds.list");
      set("feeds", reconcile(list.items, { key: "id" }));
    } catch {
      // The next reload shows the counts.
    }
    // A view's count follows the same marks.
    await library.loadViews().catch(() => undefined);
  }

  /** The daemon outlives the app, so after an update it can be an older one, and
   * nothing else would replace it. Stopping it is safe: the next call starts ours. */
  async function replaceOutdatedDaemon() {
    const current = async () => {
      const stats = await transport()
        .call<Stats>("stats.get")
        .catch(() => null);
      return (stats?.api_version ?? 0) >= API_VERSION;
    };
    if (await current()) return;
    await transport()
      .call("daemon.stop")
      .catch(() => undefined);
    for (let i = 0; i < 50; i++) {
      await new Promise((r) => setTimeout(r, 100));
      if (await current()) return;
    }
  }

  /** Events about features reload only what they name. */
  async function handle(event: DaemonEvent) {
    switch (event.type) {
      case "view.changed":
      case "recipe.changed":
      case "routine.changed":
      case "job.changed":
      case "artifact.new":
        await library.handle(event.type);
        if (event.type === "view.changed" && state.place.kind === "view") await reloadEntries().catch(() => undefined);
        if (event.type === "artifact.new" && state.place.kind === "today" && state.selectedBrief === null) set("selectedBrief", library.state.briefs[0]?.id ?? null);
        break;
      case "routine.notify":
        // Notifications reach the system in phase 7 (D15).
        break;
      default:
        scheduleReload();
    }
  }

  async function start(openScreen: () => Promise<void> = async () => undefined) {
    await replaceOutdatedDaemon();
    await prefs().load();
    try {
      const stats = await transport().call<Stats>("stats.get");
      await reload();
      await library.load();
      set("hasLoaded", true);
      await openScreen();
      set("launched", true);
      stopEvents = transport().subscribe(stats.last_event_seq, (event) => void handle(event));
    } catch (error) {
      batch(() => {
        fail(error);
        set("hasLoaded", true);
        set("launched", true);
      });
    }
  }

  // MARK: Moving around

  function go(place: Place) {
    // Choosing the place Settings covers only uncovers it, with nothing reset.
    if (state.showingSettings) {
      set("showingSettings", false);
      if (samePlace(place, state.place)) return;
    }
    batch(() => {
      set("place", place);
      set("article", null);
      set("selectedId", null);
      set("entries", []);
      set("nextCursor", null);
      if (place.kind === "today") set("selectedBrief", state.selectedBrief ?? library.state.briefs[0]?.id ?? null);
    });
    void reloadEntries().catch(() => undefined);
  }

  function toggleUnreadOnly() {
    set("unreadOnly", (v) => !v);
    void reloadEntries().catch(fail);
  }

  async function open(id: number): Promise<void> {
    batch(() => {
      set("selectedId", id);
      set("fullTextStatus", null);
    });
    try {
      const entry = await transport().call<Entry>("entries.get", { id, format: "blocks" });
      const blocks = JSON.parse(entry.body) as Block[];
      if (state.selectedId !== id) return;
      set("article", { entry, blocks: Array.isArray(blocks) ? blocks : [] });
      if (!entry.read) await setRead(id, true);
    } catch (error) {
      fail(error);
    }
  }

  function update(id: number, change: (row: EntrySummary) => void) {
    set(
      "entries",
      (row) => row.id === id,
      produce((row) => change(row)),
    );
  }

  function applyRead(id: number, read: boolean) {
    update(id, (row) => (row.read = read));
    if (state.article?.entry.id === id) set("article", "entry", "read", read);
  }

  function applyStar(id: number, starred: boolean) {
    update(id, (row) => (row.starred = starred));
    if (state.article?.entry.id === id) set("article", "entry", "starred", starred);
  }

  async function setRead(id: number, read: boolean) {
    applyRead(id, read);
    try {
      await transport().call("entries.mark", { id, read });
    } catch (error) {
      applyRead(id, !read);
      fail(error);
    }
    await refreshCounts();
  }

  const currentId = () => state.article?.entry.id ?? state.selectedId;

  function toggleRead() {
    const id = currentId();
    if (id === null) return;
    const read = state.article?.entry.id === id ? state.article.entry.read : state.entries.find((r) => r.id === id)?.read;
    if (read === undefined) return;
    void setRead(id, !read);
  }

  function toggleStar(row?: number) {
    const id = row ?? currentId();
    if (id === null || id === undefined) return;
    const current = state.article?.entry.id === id ? state.article.entry.starred : state.entries.find((r) => r.id === id)?.starred;
    const starred = !(current ?? false);
    applyStar(id, starred);
    void (async () => {
      try {
        await transport().call("entries.mark", { id, starred });
      } catch (error) {
        applyStar(id, !starred);
        fail(error);
      }
      await refreshCounts();
    })();
  }

  function moveSelection(offset: number) {
    const rows = state.entries;
    if (!rows.length) return;
    const at = rows.findIndex((r) => r.id === state.selectedId);
    const index = at >= 0 ? at : offset > 0 ? -1 : rows.length;
    const next = Math.min(Math.max(index + offset, 0), rows.length - 1);
    set("selectedId", rows[next].id);
    if (state.article || usesPanes()) void open(rows[next].id);
  }

  function openSelected() {
    if (state.selectedId !== null) void open(state.selectedId);
  }

  function back() {
    if (state.place.kind === "today" && state.article) {
      batch(() => {
        set("article", null);
        set("selectedId", null);
      });
    } else if (!usesPanes()) {
      set("article", null);
    }
  }

  function nextUnread() {
    const start = state.entries.findIndex((r) => r.id === state.selectedId) + 1;
    const row = state.entries.slice(start).find((r) => !r.read);
    if (row) void open(row.id);
  }

  function refresh() {
    void (async () => {
      const place = state.place;
      await (place.kind === "feed"
        ? transport().call("feeds.refresh", { id: place.id }, { slow: true })
        : transport().call("feeds.refresh_all", {}, { slow: true })
      ).catch(() => undefined);
      await reload();
    })();
  }

  function fetchFull() {
    const id = state.article?.entry.id;
    if (id === undefined) return;
    set("fullTextStatus", "Fetching the article…");
    void (async () => {
      try {
        const result = await transport().call<{ status: string }>("entries.fetch_full", { id }, { slow: true });
        if (state.article?.entry.id !== id) return;
        if (result.status === "done") await open(id);
        else set("fullTextStatus", result.status === "later" ? "Could not reach the page. It will be tried again." : "No fuller article found on the page");
      } catch (error) {
        if (state.article?.entry.id === id) set("fullTextStatus", words(error));
      }
    })();
  }

  /** Opens the article's page. The web pane is planned (F26); until then the system
   * browser opens it. */
  function openPage() {
    const url = state.article?.entry.url;
    if (url) openLink(url);
  }

  function openLink(url: string) {
    if (!/^https?:/i.test(url)) return;
    void transport().openExternal(url).catch(fail);
  }

  function openSettings() {
    set("showingSettings", true);
  }

  // MARK: Marking many

  /** Whether "Mark all read" applies where the reader is. Starred, Today and Routines
   * are not a set of feeds, so it is not offered there. */
  const canMarkAllHere = () => ["all", "feed", "folder", "view"].includes(state.place.kind);

  function markAllHere() {
    const place = state.place;
    if (place.kind === "all") markAllRead();
    else if (place.kind === "feed") markAllRead({ feed: place.id });
    else if (place.kind === "folder") markAllRead({ folder: place.id });
    else if (place.kind === "view") markAllRead({ view: place.id });
  }

  function markAllRead(target: { feed?: number; folder?: number; view?: number } = {}) {
    void (async () => {
      const params: Record<string, unknown> = { limit: 1000 };
      if (target.feed !== undefined) params.feed_id = target.feed;
      if (target.folder !== undefined) params.folder_id = target.folder;
      if (target.view !== undefined) params.view_id = target.view;
      else params.unread_only = true;
      try {
        const ids: number[] = [];
        let cursor: string | null = null;
        do {
          const page: EntryPage = await transport().call<EntryPage>("entries.list", cursor ? { ...params, before: cursor } : params);
          ids.push(...page.items.filter((r) => !r.read).map((r) => r.id));
          cursor = page.next_cursor ?? null;
        } while (cursor && ids.length < 20000);
        if (!ids.length) return;
        const before = await library.mark(ids, { read: true });
        const feed = state.feeds.find((f) => f.id === target.feed);
        const name =
          (target.view !== undefined ? library.view(target.view)?.name : undefined) ??
          (feed ? feedName(feed) : undefined) ??
          (target.folder !== undefined ? state.folders.find((f) => f.id === target.folder)?.name : undefined) ??
          "All";
        undo.push(`Marked ${Plural.count(ids.length, "article")} in ${name} as read`, async () => {
          await library.restore(before).catch(() => undefined);
          await reload();
        });
      } catch (error) {
        const failure = RPCFailure.from(error);
        if (failure.isUnknownMethod && target.view === undefined) {
          // A daemon without mark_many still marks; it cannot offer Undo.
          await transport()
            .call("entries.mark_all", { feed_id: target.feed, folder_id: target.folder })
            .catch(() => undefined);
        } else {
          fail(error);
        }
      }
      await reload();
    })();
  }

  // MARK: Background work (Activity.swift, Features.swift)

  const isFailing = (feed: Feed) => feed.error_count > 0 && feed.last_error != null;
  const failingFeeds = () => state.feeds.filter(isFailing);
  const briefJob = () => library.activeJobs().find((j) => jobIsWriting(j) && !["answer", "ask", "try", "brief_try"].includes(j.kind));
  const hasNewBrief = () => {
    const newest = library.state.briefs[0]?.id;
    return newest !== undefined && state.place.kind !== "today" && newest !== state.selectedBrief;
  };
  const statusIsBusy = () => library.activeJobs().length > 0;
  const statusNeedsYou = () => library.needsYou().length > 0 || failingFeeds().length > 0;
  function statusWords(now: Date = new Date()): string {
    const active = library.activeJobs();
    if (active.length) {
      const job = active[0];
      const more = active.length - 1;
      const progress = job.total !== null ? (job.progress !== null ? ` ${job.progress} of ${job.total}` : "") : "…";
      return job.title + progress + (more > 0 ? ` · ${more} more` : "");
    }
    const attention = library.needsYou().length + (failingFeeds().length ? 1 : 0);
    if (attention > 0) return attention === 1 ? "1 thing needs you" : `${attention} things need you`;
    if (!state.updatedAt) return " ";
    return "Updated " + Dates.named(state.updatedAt, now);
  }

  // MARK: Test mode (AppModel.openRequestedScreen, Features.openFeatureScreen)

  const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

  async function openScreen(mode: Record<string, string>) {
    switch (mode.FYKE_SCREEN) {
      case "all":
        go({ kind: "all" });
        await reloadEntries().catch(() => undefined);
        await sleep(300);
        if (state.entries[0]) await open(state.entries[0].id);
        break;
      case "view": {
        const view = library.state.views[0];
        if (!view) break;
        go({ kind: "view", id: view.id });
        await reloadEntries().catch(() => undefined);
        await sleep(300);
        if (state.entries[0]) await open(state.entries[0].id);
        break;
      }
      case "feed": {
        const feed = state.feeds[Number.parseInt(mode.FYKE_FEED ?? "0", 10) || 0];
        if (!feed) break;
        go({ kind: "feed", id: feed.id });
        await reloadEntries().catch(() => undefined);
        await sleep(300);
        if (state.entries[1]) await open(state.entries[1].id);
        break;
      }
      case "today":
      case "briefing":
        go({ kind: "today" });
        break;
      case "shortcuts":
        set("showingShortcuts", true);
        break;
    }
  }

  return {
    state,
    set,
    failingFeeds,
    isFailing,
    briefJob,
    hasNewBrief,
    statusIsBusy,
    statusNeedsYou,
    statusWords,
    openScreen,
    library,
    undo,
    start,
    reload,
    reloadEntries,
    loadMore,
    go,
    open,
    openSelected,
    toggleUnreadOnly,
    toggleRead,
    toggleStar,
    moveSelection,
    back,
    nextUnread,
    refresh,
    fetchFull,
    openPage,
    openLink,
    openSettings,
    canMarkAllHere,
    markAllHere,
    markAllRead,
    totalUnread,
    totalStarred,
    isEmpty,
    childFolders,
    foldersInside,
    feedsInside,
    folderOutline,
    placeTitle,
    placeUnread,
    usesPanes,
    listsEntries,
    isShowing,
    placeId,
    pause(on: boolean) {
      paused = on;
      void transport().pause(on);
    },
    stop() {
      stopEvents?.();
    },
    toggleFolder(id: number) {
      prefs().update((ui) => {
        ui.collapsed_folders = ui.collapsed_folders.includes(id) ? ui.collapsed_folders.filter((f) => f !== id) : [...ui.collapsed_folders, id];
      });
    },
  };
}

export type AppModel = ReturnType<typeof createApp>;

let shared: AppModel | undefined;

export function app(): AppModel {
  shared ??= createRoot(createApp);
  return shared;
}
