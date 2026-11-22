// Views, recipes, briefs, routines, writers and jobs, as the daemon holds them
// (gui/Sources/Reader/Library.swift). This store only mirrors them: every change is an
// operation, and an event says when to read them again.
import { createStore, reconcile } from "solid-js/store";
import { Rule } from "../logic/Rule";
import { RPCFailure, transport } from "../transport";
import {
  type Artifact,
  artifact,
  J,
  type Job,
  job,
  type Previous,
  previous,
  jobIsActive,
  type Recipe,
  recipe,
  type Routine,
  routine,
  type SavedView,
  savedView,
  type Writer,
  writer,
} from "./types";

interface LibraryState {
  views: SavedView[];
  recipes: Recipe[];
  routines: Routine[];
  writers: Writer[];
  briefs: Artifact[];
  jobs: Job[];
  /** False when the daemon predates these operations. Screens then say so in place. */
  available: boolean;
  hasLoaded: boolean;
}

export function createLibrary() {
  const [state, set] = createStore<LibraryState>({
    views: [],
    recipes: [],
    routines: [],
    writers: [],
    briefs: [],
    jobs: [],
    available: true,
    hasLoaded: false,
  });

  /** One list call, read item by item. */
  async function items<T>(method: string, params: object, read: (j: J) => T | null): Promise<T[] | null> {
    try {
      const reply = new J(await transport().call(method, params));
      set("available", true);
      return (reply.get("items")?.array ?? []).map(read).filter((x): x is T => x !== null);
    } catch (error) {
      if (RPCFailure.from(error).isUnknownMethod) set("available", false);
      return null;
    }
  }

  async function loadViews() {
    const list = await items("views.list", {}, savedView);
    if (list) set("views", reconcile(list.sort((a, b) => a.position - b.position || a.id - b.id), { key: "id" }));
  }
  async function loadRecipes() {
    const list = await items("recipes.list", {}, recipe);
    if (list) set("recipes", reconcile(list, { key: "id" }));
  }
  async function loadRoutines() {
    const list = await items("routines.list", {}, routine);
    if (list) set("routines", reconcile(list, { key: "id" }));
  }
  async function loadBriefs() {
    const list = await items("briefs.list", { limit: 50 }, artifact);
    if (list) set("briefs", reconcile(list.filter((b) => b.kind === "digest"), { key: "id" }));
  }
  async function loadJobs() {
    const list = await items("jobs.list", { limit: 50 }, job);
    if (list) set("jobs", reconcile(list, { key: "id" }));
  }
  async function loadWriters() {
    const list = await items("writers.list", {}, writer);
    if (list) set("writers", reconcile(list, { key: "id" }));
  }

  return {
    state,
    async load() {
      await loadViews();
      if (state.available) await Promise.all([loadRecipes(), loadRoutines(), loadBriefs(), loadJobs(), loadWriters()]);
      set("hasLoaded", true);
    },
    loadViews,
    loadRecipes,
    loadRoutines,
    loadBriefs,
    loadJobs,
    loadWriters,

    /** Reads again only what an event names. */
    async handle(type: string) {
      switch (type) {
        case "view.changed":
          return loadViews();
        case "recipe.changed":
          return loadRecipes();
        case "routine.changed":
          return loadRoutines();
        case "job.changed":
          return loadJobs();
        case "artifact.new":
          await loadBriefs();
          return loadJobs();
        case "entry.state":
        case "entry.new":
        case "entries.changed":
        case "feed.changed":
          return loadViews();
      }
    },

    view: (id: number | null | undefined) => state.views.find((v) => v.id === id),
    recipe: (id: number | null | undefined) => state.recipes.find((r) => r.id === id),
    routine: (id: number | null | undefined) => state.routines.find((r) => r.id === id),

    activeJobs: () => state.jobs.filter(jobIsActive),

    /** Failed jobs from the last day that nothing has replaced since. */
    needsYou(): Job[] {
      const day = Date.now() - 86_400_000;
      return state.jobs.filter((j) => {
        if (j.state !== "failed" || ((j.finishedAt ?? j.createdAt)?.getTime() ?? 0) <= day) return false;
        return !state.jobs.some((o) => o.kind === j.kind && o.routineId === j.routineId && o.id > j.id && (o.state === "done" || jobIsActive(o)));
      });
    },

    nextRoutine(): Routine | undefined {
      return state.routines
        .filter((r) => r.enabled && r.nextRunAt)
        .sort((a, b) => a.nextRunAt!.getTime() - b.nextRunAt!.getTime())[0];
    },

    /** Creates a view, or with `id` changes one. `revision` refuses a change made on top of
     * someone else's. Returns the view as the daemon stored it. */
    async saveView(change: { id?: number; name: string; rule: Rule; revision?: number }): Promise<SavedView> {
      const reply = new J(
        await transport().call("views.put", { id: change.id, name: change.name, rule: Rule.normalized(change.rule), expected_revision: change.revision }),
      );
      await loadViews();
      const made = savedView(reply.get("view") ?? reply) ?? state.views.find((v) => v.id === reply.get("id")?.int);
      if (!made) throw new RPCFailure({ message: "The daemon did not return the view" });
      return made;
    },

    async moveView(id: number, position: number): Promise<void> {
      await transport().call("views.move", { id, position });
      await loadViews();
    },

    /** Fails with `in_use` while routines look in the view, unless they are detached. */
    async removeView(id: number, detach: boolean): Promise<void> {
      await transport().call("views.remove", { id, detach });
      await loadViews();
    },

    /** Marks many articles, a thousand at a time, and returns what each was, for Undo. */
    async mark(ids: number[], change: { read?: boolean; starred?: boolean; later?: boolean }): Promise<Map<number, Previous>> {
      const out = new Map<number, Previous>();
      for (let start = 0; start < ids.length; start += 1000) {
        const chunk = ids.slice(start, start + 1000);
        const reply = new J(await transport().call("entries.mark_many", { ids: chunk, ...change }));
        reply.get("previous")?.array.forEach((item, index) => {
          const was = previous(item);
          out.set(was.id ?? chunk[Math.min(index, chunk.length - 1)], was);
        });
      }
      return out;
    },

    /** Puts every article back as it was before a mark, grouped by value so that it
     * takes at most a few calls. */
    async restore(before: Map<number, Previous>): Promise<void> {
      for (const key of ["read", "starred", "later"] as const) {
        for (const value of [true, false]) {
          const ids = [...before].filter(([, was]) => was[key] === value).map(([id]) => id);
          if (ids.length) await transport().call("entries.mark_many", { ids, [key]: value });
        }
      }
    },
  };
}

export type Library = ReturnType<typeof createLibrary>;
