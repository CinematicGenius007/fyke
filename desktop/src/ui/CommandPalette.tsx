// The command palette (gui/Sources/Reader/CommandPalette.swift): a 620 wide popover
// panel 120 below the top of the window. Empty, it lists places and the first commands;
// typed into, it ranks both by their letters and adds matching articles.
import { createEffect, For, type JSX, onMount, Show } from "solid-js";
import { Fuzzy, type Match } from "../logic/Fuzzy";
import { app } from "../model/app";
import { allCommands, type Command } from "../model/commands";
import { entryDate, type EntrySummary } from "../model/types";
import { Dates } from "./format";
import { KeyHint, Rule, SectionLabel } from "./kit/Controls";
import { Icon } from "./kit/Icon";

type Row = { kind: "command"; id: string; command: Command; match: Match } | { kind: "article"; id: string; entry: EntrySummary };

interface Section {
  title: string;
  rows: Row[];
}

const NONE: Match = { score: 0, positions: [] };

/** Matched letters in the ink's weight, the rest regular. */
export function highlight(text: string, positions: number[]): JSX.Element[] {
  const marked = new Set(positions);
  const out: JSX.Element[] = [];
  let run = "";
  let runMarked = false;
  const flush = () => {
    if (run) out.push(runMarked ? <b class="palette-mark">{run}</b> : run);
    run = "";
  };
  Array.from(text).forEach((character, index) => {
    const isMarked = marked.has(index);
    if (isMarked !== runMarked) flush();
    runMarked = isMarked;
    run += character;
  });
  flush();
  return out;
}

export function CommandPalette() {
  const model = app();
  const commands = model.commands;
  let field!: HTMLInputElement;
  let list: HTMLDivElement | undefined;

  // As AppKit does when a field with text in it takes focus, the text starts selected.
  onMount(() => {
    field.focus();
    field.select();
  });

  const command = (item: Command, match: Match): Row => ({ kind: "command", id: item.id, command: item, match });

  const sections = (): Section[] => {
    const all = allCommands(model);
    const query = commands.state.query.trim();
    if (!query) {
      const go = all.filter((c) => c.group === "go").slice(0, 4 + model.library.state.views.length);
      const act = all.filter((c) => c.group === "act").slice(0, 8);
      return [
        { title: "Go to", rows: go.map((c) => command(c, NONE)) },
        { title: "Do", rows: act.map((c) => command(c, NONE)) },
      ];
    }
    const ranked = Fuzzy.rank(query, all, (c) => c.title);
    const go = ranked.filter((r) => r.item.group === "go").slice(0, 5);
    const act = ranked.filter((r) => r.item.group === "act").slice(0, 5);
    const out: Section[] = [];
    if (go.length) out.push({ title: "Go to", rows: go.map((r) => command(r.item, r.match)) });
    if (act.length) out.push({ title: "Do", rows: act.map((r) => command(r.item, r.match)) });
    const articles = commands.state.articles;
    if (articles.length) out.push({ title: `Articles · ${articles.length}`, rows: articles.map((entry) => ({ kind: "article", id: `article${entry.id}`, entry })) });
    return out;
  };

  const flat = () => sections().flatMap((s) => s.rows);

  createEffect(() => {
    const index = commands.state.selection;
    list?.querySelectorAll<HTMLElement>(".palette-row")[index]?.scrollIntoView({ block: "nearest" });
  });

  function move(offset: number) {
    const count = flat().length;
    if (count === 0) return;
    commands.select(Math.min(Math.max(commands.state.selection + offset, 0), count - 1));
  }

  function run(index: number) {
    const row = flat()[index];
    if (!row) return;
    commands.close();
    if (row.kind === "command") row.command.run();
    else model.openResult(row.entry.id);
  }

  function onKey(event: KeyboardEvent) {
    if (event.key === "Escape") commands.close();
    else if (event.key === "ArrowDown") move(1);
    else if (event.key === "ArrowUp") move(-1);
    else if (event.key === "Enter" && !event.isComposing) run(commands.state.selection);
    // Tab asks your feeds on the Mac; Ask is planned. Tab stays in the field meanwhile.
    else if (event.key === "Tab") undefined;
    else return;
    event.preventDefault();
    event.stopPropagation();
  }

  return (
    <div class="scrim quiet" onClick={(event) => event.target === event.currentTarget && commands.close()}>
      <div class="palette" role="dialog" aria-label="Command palette" onKeyDown={onKey}>
        <div class="palette-query">
          <Icon name="magnifyingglass" size={16} color="var(--muted)" />
          <input
            ref={field}
            class="palette-field"
            type="text"
            spellcheck={false}
            autocomplete="off"
            placeholder="Go to, do, or find…"
            aria-label="Command"
            value={commands.state.query}
            onInput={(event) => commands.setQuery(event.currentTarget.value)}
          />
          <span class="palette-esc">esc</span>
        </div>
        <Rule />
        <div ref={list} class="palette-list scroll" role="listbox" aria-label="Commands">
          <For each={sections()}>
            {(section) => (
              <>
                <SectionLabel text={section.title} class="palette-section" />
                <For each={section.rows}>
                  {(row) => {
                    const index = () => flat().findIndex((r) => r.id === row.id);
                    const selected = () => index() === commands.state.selection;
                    return (
                      <button
                        type="button"
                        class="palette-row"
                        classList={{ selected: selected(), article: row.kind === "article" }}
                        role="option"
                        aria-selected={selected()}
                        tabIndex={-1}
                        onClick={() => run(index())}
                      >
                        {row.kind === "command" ? <CommandRow command={row.command} match={row.match} selected={selected()} /> : <ArticleRow entry={row.entry} />}
                      </button>
                    );
                  }}
                </For>
              </>
            )}
          </For>
        </div>
      </div>
    </div>
  );
}

function CommandRow(props: { command: Command; match: Match; selected: boolean }) {
  return (
    <>
      <span class="palette-icon">
        <Icon name={props.command.icon} size={16} />
      </span>
      <span class="palette-title">{highlight(props.command.title, props.match.positions)}</span>
      <Show when={props.command.detail}>{(detail) => <span class="palette-detail">{detail()}</span>}</Show>
      <Show
        when={props.command.shortcut}
        fallback={
          <Show when={props.selected}>
            <Icon name="return" size={11} color="var(--muted)" />
          </Show>
        }
      >
        {(shortcut) => <KeyHint text={shortcut()} />}
      </Show>
    </>
  );
}

function ArticleRow(props: { entry: EntrySummary }) {
  return (
    <>
      <span class="palette-icon palette-dot">
        <span class="dot" style={{ background: props.entry.read ? "transparent" : "var(--unread)" }} />
      </span>
      <span class="palette-article">
        <span class="palette-article-title" classList={{ read: props.entry.read }}>
          {props.entry.title ?? "Untitled"}
        </span>
        <span class="palette-article-meta">{[props.entry.feed_title, Dates.relative(entryDate(props.entry))].filter(Boolean).join(" · ")}</span>
      </span>
    </>
  );
}
