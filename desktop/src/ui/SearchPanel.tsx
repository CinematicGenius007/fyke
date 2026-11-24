// The search popup (gui/Sources/Reader/Search.swift `SearchPanel`): a 640 wide panel
// 96 below the top of the window, over the scrim. Its field keeps the keys; the app's
// key map stays out of the way while it shows.
import { createEffect, For, type JSX, Match, onMount, Show, Switch } from "solid-js";
import { app } from "../model/app";
import { entryDate, type EntrySummary, preview } from "../model/types";
import { Dates } from "./format";
import { Action, KeyHint, Rule } from "./kit/Controls";
import { Icon } from "./kit/Icon";

const ROW_HEIGHT = 64;
const ROW_GAP = 2;
const VISIBLE_ROWS = 8;

/** The snippet with each searched word set in the ink color and semibold. */
export function highlighted(text: string, words: string[]): JSX.Element[] {
  const source = text.replaceAll("...", "…");
  const marks = words.filter(Boolean).map((w) => w.toLowerCase());
  if (!marks.length) return [source];
  const lower = source.toLowerCase();
  const out: JSX.Element[] = [];
  let at = 0;
  let plain = 0;
  while (at < source.length) {
    const word = marks.find((w) => lower.startsWith(w, at));
    if (!word) {
      at++;
      continue;
    }
    if (at > plain) out.push(source.slice(plain, at));
    out.push(<b class="search-mark">{source.slice(at, at + word.length)}</b>);
    at += word.length;
    plain = at;
  }
  if (plain < source.length) out.push(source.slice(plain));
  return out;
}

export function SearchPanel() {
  const model = app();
  const search = model.search;
  let field!: HTMLInputElement;
  let list: HTMLDivElement | undefined;

  // As AppKit does when a field with text in it takes focus, the text starts selected.
  onMount(() => {
    field.focus();
    field.select();
  });

  createEffect(() => {
    const index = search.state.selection;
    list?.querySelectorAll<HTMLElement>(".search-row")[index]?.scrollIntoView({ block: "nearest" });
  });

  function onKey(event: KeyboardEvent) {
    const ctrl = event.ctrlKey || event.metaKey;
    if (event.key === "Escape") search.close();
    else if (event.key === "ArrowDown") search.move(1);
    else if (event.key === "ArrowUp") search.move(-1);
    else if (event.key === "Enter" && !event.isComposing) {
      const row = search.selected();
      if (row) model.openResult(row.id);
    } else if (ctrl && !event.shiftKey && event.key.toLowerCase() === "s") {
      if (!search.isBlank()) model.saveSearchAsView();
    } else return;
    event.preventDefault();
    event.stopPropagation();
  }

  const height = () => Math.min(search.state.results.length, VISIBLE_ROWS) * (ROW_HEIGHT + ROW_GAP) - ROW_GAP + 16;

  return (
    <div class="scrim" onClick={(event) => event.target === event.currentTarget && search.close()}>
      <div class="search-panel" role="dialog" aria-label="Search" onKeyDown={onKey}>
        <div class="search-query">
          <Icon name="search" color="var(--muted)" />
          <input
            ref={field}
            class="search-field"
            type="text"
            spellcheck={false}
            autocomplete="off"
            placeholder="Search your feeds"
            aria-label="Search your feeds"
            value={search.state.query}
            onInput={(event) => search.setQuery(event.currentTarget.value)}
          />
          <Show when={search.countLabel()}>{(label) => <span class="search-count">{label()}</span>}</Show>
        </div>
        <Rule />
        <Switch>
          <Match when={search.isBlank()}>
            <div class="search-note">
              <span class="search-note-main">Finds words in titles, article text and feed names.</span>
              <span class="search-note-detail">Every word must match. Results come newest first.</span>
            </div>
          </Match>
          <Match when={search.state.results.length === 0 && search.state.hasAnswer}>
            <div class="search-note">
              <span class="search-none">Nothing matches “{search.state.query}”.</span>
              <span class="search-note-main muted">Try fewer or related words.</span>
            </div>
          </Match>
          <Match when={search.state.results.length === 0}>
            <div style={{ height: "40px" }} />
          </Match>
          <Match when={true}>
            <div ref={list} class="search-results scroll" style={{ height: `${height()}px` }} role="listbox" aria-label="Results">
              <For each={search.state.results}>
                {(row, index) => <ResultRow row={row} selected={index() === search.state.selection} onOpen={() => model.openResult(row.id)} />}
              </For>
            </div>
          </Match>
        </Switch>
        <Rule />
        <div class="search-footer">
          <button type="button" class="search-scope" onClick={() => search.toggleUnreadOnly()}>
            {search.state.unreadOnly ? "Unread only" : "All articles"}
          </button>
          <span class="search-keys">
            <span>↑↓ Move</span>
            <span>Return Open</span>
            <span>Esc Close</span>
          </span>
          <Action compact disabled={search.isBlank() || !model.library.state.available} onClick={() => model.saveSearchAsView()}>
            Save as view <KeyHint text="Ctrl+S" />
          </Action>
        </div>
      </div>
    </div>
  );
}

function ResultRow(props: { row: EntrySummary; selected: boolean; onOpen: () => void }) {
  const search = app().search;
  return (
    <button
      type="button"
      class="search-row"
      classList={{ selected: props.selected }}
      role="option"
      aria-selected={props.selected}
      tabIndex={-1}
      onClick={() => props.onOpen()}
    >
      <span class="search-row-content">
        <span class="search-row-text">
        <span class="search-row-title" classList={{ read: props.row.read }}>
          {props.row.title ?? "Untitled"}
        </span>
        <Show when={preview(props.row)}>{(text) => <span class="search-row-preview">{highlighted(text(), search.words())}</span>}</Show>
      </span>
        <span class="search-row-meta">
          <span>{props.row.feed_title ?? ""}</span>
          <span>{Dates.relative(entryDate(props.row))}</span>
        </span>
      </span>
    </button>
  );
}
