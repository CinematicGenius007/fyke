// The search panel's state (gui/Sources/Reader/Search.swift `SearchModel`). It lives
// apart from the app's list, so opening search leaves the list and the reader behind it
// untouched.
import { createStore } from "solid-js/store";
import { transport } from "../transport";
import type { EntrySummary, Items } from "./types";

export const SEARCH_LIMIT = 100;
/** Waits for a pause in typing, so that each word costs one request. */
const TYPING_PAUSE_MS = 150;

interface SearchState {
  isShowing: boolean;
  query: string;
  results: EntrySummary[];
  selection: number;
  unreadOnly: boolean;
  /** True once the current query has an answer, so a slow reply does not flash "nothing found". */
  hasAnswer: boolean;
}

export function createSearch() {
  const [state, set] = createStore<SearchState>({
    isShowing: false,
    query: "",
    results: [],
    selection: 0,
    unreadOnly: false,
    hasAnswer: false,
  });
  let pending: ReturnType<typeof setTimeout> | undefined;
  // Each run has a number; a reply for an older one is dropped.
  let generation = 0;

  const words = () => state.query.split(/\s+/u).filter(Boolean);
  const isBlank = () => words().length === 0;

  function run() {
    clearTimeout(pending);
    const mine = ++generation;
    set("hasAnswer", false);
    if (isBlank()) {
      set({ results: [], selection: 0 });
      return;
    }
    const params = { query: state.query, limit: SEARCH_LIMIT, unread_only: state.unreadOnly };
    pending = setTimeout(async () => {
      let found: EntrySummary[] = [];
      try {
        found = (await transport().call<Items<EntrySummary>>("entries.search", params)).items ?? [];
      } catch {
        // Nothing found reads the same as a failed search here; the status line shows a lost service.
      }
      if (mine !== generation) return;
      set({ results: found, selection: 0, hasAnswer: true });
    }, TYPING_PAUSE_MS);
  }

  return {
    state,
    words,
    isBlank,
    run,
    countLabel(): string | null {
      if (!state.hasAnswer || state.results.length === 0) return null;
      if (state.results.length === SEARCH_LIMIT) return `${SEARCH_LIMIT}+ results`;
      return state.results.length === 1 ? "1 result" : `${state.results.length} results`;
    },
    show() {
      set("isShowing", true);
    },
    setQuery(query: string) {
      set("query", query);
      run();
    },
    close() {
      clearTimeout(pending);
      generation++;
      set({ isShowing: false, query: "", results: [], selection: 0, hasAnswer: false });
    },
    toggleUnreadOnly() {
      set("unreadOnly", (v) => !v);
      run();
    },
    move(offset: number) {
      if (state.results.length === 0) return;
      set("selection", Math.min(Math.max(state.selection + offset, 0), state.results.length - 1));
    },
    selected: (): EntrySummary | undefined => state.results[state.selection],
  };
}

export type Search = ReturnType<typeof createSearch>;
