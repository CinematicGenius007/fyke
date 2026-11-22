// View state only (gui/Sources/Reader/AppModel.swift). Everything durable lives behind
// the daemon, and this store reloads from it when an event says something changed.
import { batch, createRoot, createSignal } from "solid-js";
import { createStore, produce, reconcile, unwrap } from "solid-js/store";
import { Plural } from "../logic/Plural";
import { type DaemonEvent, RPCFailure, transport } from "../transport";
import { type CatchUpModel, createCatchUp } from "./catchUp";
import { createLibrary } from "./library";
import { prefs } from "./prefs";
import type { Block, Entry, EntryPage, EntrySummary, Feed, Folder, Items, Routine, RoutineAction, Stats } from "./types";
import { feedName, jobIsWriting, newRoutine } from "./types";
import { Dates } from "../ui/format";
import { isSafeLink } from "../ui/links";
import { createUndoCenter } from "./undo";
import { createCommands } from "./commands";
import { createSearch } from "./search";
import { Rule } from "../logic/Rule";
import { ViewName } from "../logic/ViewName";

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

export type SettingsTab = "General" | "Reading" | "Tokens" | "Agents" | "Data";

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
  discussionRequest: number;
  webAddress: string | null;
  webBrowserAddress: string | null;
  showingAddFeed: boolean;
  addFeedAddress: string;
  /** The folder Add feed puts a new feed in, from a folder's menu. */
  addFeedFolder: number | null;
  showingType: boolean;
  showingShortcuts: boolean;
  showingSettings: boolean;
  settingsTab: SettingsTab;
  editingTheme: string | null;
  showingActivity: boolean;
  confirmation: Confirmation;
  renaming: Renaming;
  selectedBrief: number | null;
  pinCitation?: number;
  openRecipe: number | null;
  routineDraft: Routine | null;
  ask: { question: string; viewId: number | null } | null;
  saveRequests: number;
  healthFeed: number | null;
}

/** The daemon names its refusals. These are the ones a person can act on
 * (AppModel.words(for:)); the rest keep the daemon's own message. */
const knownFailures: [string, string][] = [
  ["UnknownMethod", "This needs a newer Fyke service. Quit and open Fyke again."],
  ["InvalidRule", "That rule has a word the reader cannot use."],
  ["InvalidName", "Give it a name."],
  ["RevisionConflict", "This changed elsewhere since you opened it."],
  ["TierDenied", "Fyke's service refused the change."],
  ["WriterNotFound", "No writer is installed. Choose one in Settings · Agents."],
  ["ConflictingFilters", "A view cannot be combined with other filters."],
];

export function words(error: unknown): string {
  const failure = RPCFailure.from(error);
  return knownFailures.find(([kind]) => failure.is(kind))?.[1] ?? failure.message;
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
    discussionRequest: 0,
    webAddress: null,
    webBrowserAddress: null,
    showingAddFeed: false,
    addFeedAddress: "",
    addFeedFolder: null,
    showingType: false,
    showingShortcuts: false,
    showingSettings: false,
    settingsTab: "General",
    editingTheme: null,
    showingActivity: false,
    confirmation: null,
    renaming: null,
    selectedBrief: null,
    openRecipe: null,
    routineDraft: null,
    ask: null,
    saveRequests: 0,
    healthFeed: null,
  });

  const [briefPending, setBriefPending] = createSignal(false);
  const [catchUp, setCatchUp] = createSignal<CatchUpModel | null>(null);
  const library = createLibrary();
  const undo = createUndoCenter();
  const search = createSearch();
  const commands = createCommands();
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
    // A service that does not answer at all is not replaced: `start` says it did not start.
    // An older one may answer with a refusal, such as an unknown method, which has a code.
    const first = await transport()
      .call<Stats>("stats.get")
      .catch((error: unknown) => RPCFailure.from(error));
    if (first instanceof RPCFailure ? first.code === undefined || first.code === null : (first.api_version ?? 0) >= API_VERSION) return;
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
        // The native side posts it as the event arrives (src-tauri/src/notify.rs, D15).
        break;
      default:
        scheduleReload();
    }
  }

  async function start(openScreen: () => Promise<void> = async () => undefined) {
    stopEvents?.();
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
      closeWeb();
      set("openRecipe", null);
      set("routineDraft", null);
      set("ask", null);
      set("article", null);
      set("selectedId", null);
      set("entries", []);
      set("nextCursor", null);
      if (place.kind === "today") set("selectedBrief", state.selectedBrief ?? library.state.briefs[0]?.id ?? null);
    });
    void reloadEntries().catch(() => undefined);
  }

  /** A search result opens in All unless the place on screen lists articles already. */
  function openResult(id: number) {
    search.close();
    set("showingSettings", false);
    if (!listsEntries()) go({ kind: "all" });
    void open(id);
  }

  async function startCatchUp() {
    if (catchUp()) return;
    const params = listParams();
    if (params.view_id === undefined) params.unread_only = true;
    const session = createCatchUp(listsEntries() ? placeTitle() : "All", params, library, words, (id) => {
      if (catchUp() !== session) return;
      setCatchUp(null);
      if (!listsEntries()) go({ kind: "all" });
      void open(id);
    });
    setCatchUp(session);
    await session.load();
  }

  function closeCatchUp() {
    setCatchUp(null);
    void reload();
  }

  // MARK: Briefs

  const selectedBrief = () => library.state.briefs.find((brief) => brief.id === state.selectedBrief) ?? library.state.briefs[0];

  function selectBrief(id: number) {
    batch(() => {
      set("selectedBrief", id);
      set("article", null);
      set("selectedId", null);
      set("openRecipe", null);
      set("pinCitation", undefined);
    });
  }

  async function runBrief(viewId?: number | null, recipeId?: number) {
    if (briefPending() || briefJob()) return;
    setBriefPending(true);
    const previous = state.place.kind === "today" ? selectedBrief() : undefined;
    const view = viewId ?? (state.place.kind === "view" ? state.place.id : previous?.viewId);
    try {
      await library.queueWriting("briefs.run", {
        view_id: view,
        rule: view == null ? previous?.rule ?? { state: "unread" } : undefined,
        recipe_id: recipeId ?? previous?.recipeId ?? library.state.recipes[0]?.id,
      });
      if (state.place.kind !== "today") go({ kind: "today" });
      batch(() => {
        set("selectedBrief", null);
        set("article", null);
      });
      await library.loadBriefs();
    } catch (error) {
      fail(error);
    } finally {
      setBriefPending(false);
    }
  }

  function openRecipe(id?: number | null) {
    const target = id ?? library.state.recipes[0]?.id;
    if (target === undefined) return;
    go({ kind: "today" });
    set("openRecipe", target);
  }

  async function cancelJob(id: number) {
    try {
      await library.cancelJob(id);
    } catch (error) {
      fail(error);
    }
  }

  async function restartService() {
    try {
      stopEvents?.();
      await transport().call("daemon.stop");
      await start();
    } catch (error) {
      fail(error);
    }
  }

  // MARK: Views

  function saveSearchAsView() {
    if (search.isBlank()) return;
    const rule = Rule.fromSearch(search.state.query, search.state.unreadOnly);
    search.close();
    void saveAsView(rule);
  }

  async function saveAsView(rule: Rule, name?: string) {
    const taken = new Set(library.state.views.map((v) => v.name));
    const chosen = ViewName.unique(name ?? ViewName.suggest(rule), taken);
    try {
      const view = await library.saveView({ name: chosen, rule });
      go({ kind: "view", id: view.id });
      set("renaming", { kind: "view", id: view.id });
      undo.push(`Saved “${view.name}” as a view`, async () => {
        await library.removeView(view.id, true).catch(() => undefined);
        if (samePlace(state.place, { kind: "view", id: view.id })) go({ kind: "all" });
      });
    } catch (error) {
      fail(error);
    }
  }

  function renameView(id: number, name: string) {
    set("renaming", null);
    const view = library.state.views.find((v) => v.id === id);
    if (!view || !name.trim() || name === view.name) return;
    library.saveView({ id, name, rule: view.rule, revision: view.revision }).catch(fail);
  }

  async function setViewRule(id: number, revision: number, rule: Rule) {
    const view = library.view(id);
    if (!view) return;
    const conflict = "This view changed elsewhere. It now shows the newer rule.";
    if (view.revision !== revision) {
      set("problem", conflict);
      return;
    }
    if (Rule.same(view.rule, rule)) return;
    const { name } = view;
    const previous = structuredClone(unwrap(view.rule));
    try {
      const saved = await library.saveView({ id, name, rule, revision });
      undo.push(`Changed “${name}”`, async () => {
        const current = library.view(id);
        if (!current) return;
        if (!Rule.same(current.rule, saved.rule)) {
          set("problem", conflict);
          return;
        }
        try {
          await library.saveView({ id, name: current.name, rule: previous, revision: current.revision });
          await reloadEntries();
        } catch (error) {
          fail(error);
        }
      });
      await reloadEntries();
    } catch (error) {
      if (RPCFailure.from(error).is("RevisionConflict")) {
        await library.loadViews();
        await reloadEntries().catch(() => undefined);
        set("problem", conflict);
      } else fail(error);
    }
  }

  function moveView(id: number, by: number) {
    const views = library.state.views;
    const index = views.findIndex((v) => v.id === id);
    if (index < 0) return;
    const target = Math.min(Math.max(index + by, 0), views.length - 1);
    if (target === index) return;
    library.moveView(id, target).catch(fail);
  }

  /** Removes at once. Undo restores its position and reconnects detached routines. */
  async function removeView(id: number) {
    const view = library.state.views.find((v) => v.id === id);
    if (!view) return;
    const kept = { name: view.name, rule: structuredClone(unwrap(view.rule)), position: view.position };
    const routines = library.state.routines.filter((routine) => routine.viewId === id).map((routine) => structuredClone(unwrap(routine)));
    if (samePlace(state.place, { kind: "view", id })) go({ kind: "all" });
    try {
      await library.removeView(id, true);
      undo.push(`Removed “${kept.name}”`, async () => {
        try {
          const made = await library.saveView({ name: kept.name, rule: kept.rule });
          await library.moveView(made.id, kept.position);
          for (const prior of routines) {
            const detached = library.routine(prior.id);
            if (detached && detached.viewId === null && detached.revision === prior.revision) {
              await library.saveRoutine({ ...detached, enabled: prior.enabled, viewId: made.id });
            }
          }
        } catch (error) {
          fail(error);
        }
      });
    } catch (error) {
      fail(error);
    }
  }

  function ask(question = "") {
    batch(() => {
      set("showingSettings", false);
      closeWeb();
      set("ask", { question, viewId: state.place.kind === "view" ? state.place.id : null });
    });
  }

  // MARK: Routines

  function draftRoutine(viewId?: number | null, name?: string, actions?: RoutineAction[]) {
    const view = library.view(viewId ?? (state.place.kind === "view" ? state.place.id : null)) ?? library.state.views[0];
    if (!view) return;
    const draft = newRoutine(name ?? `Morning ${view.name.toLowerCase()}`, view.id);
    draft.actions = (actions ?? draft.actions).map((action) =>
      action.kind === "brief" ? { ...action, recipe_id: library.state.recipes[0]?.id } : action,
    );
    go({ kind: "routines" });
    set("routineDraft", draft);
  }

  async function toggleRoutine(routine: Routine, enabled: boolean) {
    try {
      const updated = await library.saveRoutine({ ...routine, enabled });
      if (state.routineDraft?.id === updated.id) set("routineDraft", updated);
    } catch (error) {
      fail(error);
      await library.loadRoutines();
    }
  }

  async function runRoutine(id: number) {
    try {
      await library.runRoutine(id);
      set("showingActivity", true);
    } catch (error) {
      fail(error);
    }
  }

  async function removeRoutine(routine: Routine) {
    if (routine.id === null) return;
    const kept = structuredClone(unwrap(routine));
    try {
      await library.removeRoutine(routine.id);
      if (state.routineDraft?.id === routine.id) set("routineDraft", library.state.routines[0] ?? null);
      undo.push(`Removed “${kept.name}”`, async () => {
        try {
          await library.saveRoutine({ ...kept, id: null, revision: null });
        } catch (error) {
          fail(error);
        }
      });
    } catch (error) {
      fail(error);
    }
  }

  // MARK: Folders and feeds (AppModel.swift "Folders and feeds")

  /** Runs a change to subscriptions, then shows the result. The daemon names its
   * refusals, and only the one a person can cause needs words. The refusal shows after
   * the reload, which would otherwise clear it. */
  async function change(work: () => Promise<unknown>): Promise<void> {
    let refusal: string | null = null;
    try {
      await work();
    } catch (error) {
      refusal = RPCFailure.from(error).is("FolderExists") ? "A folder with that name is already there" : words(error);
    }
    await reload();
    if (refusal) set("problem", refusal);
  }

  async function importOpml() {
    try {
      if (await transport().importOpml()) await reload();
    } catch (error) {
      fail(error);
    }
  }

  async function exportOpml() {
    try {
      await transport().exportOpml();
    } catch (error) {
      fail(error);
    }
  }

  /** Makes a folder and starts renaming it, so that naming is one step. */
  async function newFolder(parent: number | null, holding?: number) {
    const taken = new Set(childFolders(parent).map((f) => f.name));
    const names = ["New folder", ...Array.from({ length: 98 }, (_, i) => `New folder ${i + 2}`)];
    const name = names.find((n) => !taken.has(n)) ?? "New folder";
    try {
      const made = await transport().call<{ id: number }>("folders.add", { name, parent_id: parent });
      if (parent !== null) prefs().update((ui) => void (ui.collapsed_folders = ui.collapsed_folders.filter((f) => f !== parent)));
      if (holding !== undefined) await transport().call("feeds.update", { id: holding, folder_id: made.id });
      await reload();
      set("renaming", { kind: "folder", id: made.id });
    } catch (error) {
      fail(error);
    }
  }

  function renameFolder(id: number, name: string) {
    set("renaming", null);
    return change(() => transport().call("folders.rename", { id, name }));
  }

  function moveFolder(id: number, parent: number | null) {
    return change(() => transport().call("folders.move", { id, parent_id: parent }));
  }

  function leavesPlace(folder: number): boolean {
    const place = state.place;
    if (place.kind === "feed") return feedsInside(folder).some((f) => f.id === place.id);
    if (place.kind === "folder") return foldersInside(folder).some((f) => f.id === place.id);
    return false;
  }

  function removeFolder(id: number, deleteContents: boolean) {
    if (samePlace(state.place, { kind: "folder", id }) || (deleteContents && leavesPlace(id))) go({ kind: "all" });
    return change(() => transport().call("folders.remove", { id, delete_contents: deleteContents }));
  }

  function renameFeed(id: number, name: string) {
    set("renaming", null);
    return change(() => transport().call("feeds.update", { id, title: name }));
  }

  function moveFeed(id: number, folder: number | null) {
    return change(() => transport().call("feeds.update", folder === null ? { id, top_level: true } : { id, folder_id: folder }));
  }

  function refreshFeed(id: number) {
    return change(() => transport().call("feeds.refresh", { id }, { slow: true }));
  }

  function removeFeed(id: number) {
    if (samePlace(state.place, { kind: "feed", id })) go({ kind: "all" });
    return change(() => transport().call("feeds.remove", { id }));
  }

  function toggleUnreadOnly() {
    set("unreadOnly", (v) => !v);
    void reloadEntries().catch(fail);
  }

  async function open(id: number): Promise<void> {
    batch(() => {
      set("selectedId", id);
      set("fullTextStatus", null);
      closeWeb();
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
    if (state.webAddress !== null) {
      closeWeb();
    } else if (state.ask !== null) {
      set("ask", null);
    } else if (state.openRecipe !== null) {
      set("openRecipe", null);
    } else if (state.place.kind === "today" && state.article) {
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
      await (
        place.kind === "feed" ? transport().call("feeds.refresh", { id: place.id }, { slow: true }) : transport().call("feeds.refresh_all", {}, { slow: true })
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

  function pageAddress() {
    return state.article?.entry.url ?? state.entries.find((entry) => entry.id === state.selectedId)?.url;
  }

  function openPage() {
    const url = pageAddress();
    if (url) openLink(url);
  }

  function openInBrowser() {
    const url = state.webBrowserAddress ?? pageAddress();
    if (isSafeLink(url)) void transport().openExternal(url).catch(fail);
  }

  function closeWeb() {
    batch(() => {
      set("webAddress", null);
      set("webBrowserAddress", null);
    });
  }

  function openLink(url: string, inBrowser = false) {
    if (!isSafeLink(url)) return;
    if (inBrowser || prefs().ui.open_links === "browser") {
      void transport().openExternal(url).catch(fail);
    } else {
      batch(() => {
        set("webAddress", url);
        set("webBrowserAddress", url);
      });
    }
  }

  function openSettings(tab?: SettingsTab) {
    batch(() => {
      closeWeb();
      if (tab) set("settingsTab", tab);
      set("showingSettings", true);
    });
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
  function showFeedHealth(id: number) {
    const parentIds = new Set<number>();
    let parent = state.feeds.find((feed) => feed.id === id)?.folder_id;
    while (parent != null && !parentIds.has(parent)) {
      parentIds.add(parent);
      parent = state.folders.find((folder) => folder.id === parent)?.parent_id;
    }
    if (prefs().ui.collapsed_folders.some((folder) => parentIds.has(folder))) {
      prefs().update((ui) => void (ui.collapsed_folders = ui.collapsed_folders.filter((folder) => !parentIds.has(folder))));
    }
    set("healthFeed", id);
  }

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
      case "starred":
        go({ kind: "starred" });
        await reloadEntries().catch(() => undefined);
        await sleep(300);
        if (state.entries[0]) await open(state.entries[0].id);
        break;
      case "folder": {
        const folder = state.folders[0];
        if (!folder) break;
        go({ kind: "folder", id: folder.id });
        await reloadEntries().catch(() => undefined);
        await sleep(300);
        if (state.entries[0]) await open(state.entries[0].id);
        break;
      }
      case "view-empty": {
        // The newest view, which the check makes to match nothing.
        const view = library.state.views.at(-1);
        if (view) go({ kind: "view", id: view.id });
        break;
      }
      case "today":
      case "briefing":
      case "recipe":
        go({ kind: "today" });
        if (mode.FYKE_PIN_CITATION) set("pinCitation", Number(mode.FYKE_PIN_CITATION));
        if (mode.FYKE_SCREEN === "recipe") openRecipe();
        break;
      case "settings": {
        const tab = ["General", "Reading", "Tokens", "Agents", "Data"].find((item) => item.toLowerCase() === mode.FYKE_TAB?.toLowerCase());
        openSettings(tab as SettingsTab | undefined);
        break;
      }
      case "web":
        if (mode.FYKE_ADDRESS) openLink(mode.FYKE_ADDRESS);
        break;
      case "ask":
        if (library.state.views[0]) go({ kind: "view", id: library.state.views[0].id });
        ask(mode.FYKE_QUERY ?? "What arrived this week?");
        break;
      case "routines":
        go({ kind: "routines" });
        if (library.state.routines[0]) set("routineDraft", library.state.routines[0]);
        else draftRoutine();
        break;
      case "toast":
        undo.push("Marked 12 articles in Databases as read", () => undefined);
        break;
      case "activity":
        set("showingActivity", true);
        break;
      case "health":
        if (state.feeds[0]) showFeedHealth(failingFeeds()[0]?.id ?? state.feeds[0].id);
        break;
      case "catchup":
        await startCatchUp();
        break;
      case "add":
        batch(() => {
          set("addFeedAddress", mode.FYKE_ADDRESS ?? "");
          set("showingAddFeed", true);
        });
        break;
      case "shortcuts":
        set("showingShortcuts", true);
        break;
      case "delete-folder":
        if (state.folders[0]) set("confirmation", { kind: "deleteFolder", folder: state.folders[0] });
        break;
      case "rename-folder":
        if (state.folders[0]) set("renaming", { kind: "folder", id: state.folders[0].id });
        break;
      case "rename-feed":
        if (state.feeds[0]) set("renaming", { kind: "feed", id: state.feeds[0].id });
        break;
      case "palette":
        // One batch, so the field mounts with the words in it and selects them.
        batch(() => {
          commands.show();
          commands.setQuery(mode.FYKE_QUERY ?? "");
        });
        break;
      case "search":
        // The words go in first, so the field starts with them selected, as on the Mac.
        search.setQuery(mode.FYKE_QUERY ?? "");
        search.show();
        break;
    }
  }

  return {
    state,
    set,
    failingFeeds,
    showFeedHealth,
    isFailing,
    briefJob,
    briefPending,
    selectedBrief,
    selectBrief,
    ask,
    runBrief,
    openRecipe,
    cancelJob,
    restartService,
    hasNewBrief,
    statusIsBusy,
    statusNeedsYou,
    statusWords,
    openScreen,
    library,
    undo,
    search,
    commands,
    openResult,
    catchUp,
    startCatchUp,
    closeCatchUp,
    saveSearchAsView,
    saveAsView,
    renameView,
    setViewRule,
    moveView,
    removeView,
    draftRoutine,
    toggleRoutine,
    runRoutine,
    removeRoutine,
    importOpml,
    exportOpml,
    refreshFeed,
    newFolder,
    renameFolder,
    moveFolder,
    removeFolder,
    renameFeed,
    moveFeed,
    removeFeed,
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
    openInBrowser,
    closeWeb,
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
