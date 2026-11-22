// The article list beside the reader (gui/Sources/Reader/RootView.swift `EntryList`).
import { createEffect, For, Show } from "solid-js";
import { Rule as SelectionRule } from "../logic/Rule";
import { app } from "../model/app";
import type { EntrySummary } from "../model/types";
import { entryDate, preview } from "../model/types";
import { Dates } from "./format";
import { Action, InlineLabel, Rule, SymbolButton } from "./kit/Controls";
import { StarToggle } from "./StarToggle";
import { ViewSentence } from "./ViewSentence";
import { float } from "./Float";
import { viewMenu } from "./Sidebar";

export function EntryList() {
  const model = app();
  const view = () => (model.state.place.kind === "view" ? model.library.view(model.state.place.id) : undefined);
  let scroller: HTMLDivElement | undefined;

  createEffect(() => {
    const id = model.state.selectedId;
    if (id !== null) scroller?.querySelector(`[data-entry="${id}"]`)?.scrollIntoView({ block: "nearest", behavior: "smooth" });
  });

  return (
    <section class="entry-list" aria-label={model.placeTitle()}>
      <header class="list-header" classList={{ ruled: !!view() }}>
        <div class="list-heading">
          <h2 class="list-title">{model.placeTitle()}</h2>
          <span class="list-unread">{model.placeUnread()} unread</span>
          <Show when={view()}>
            {(current) => {
              let actions!: HTMLButtonElement;
              return <SymbolButton ref={(button) => actions = button} icon="ellipsis" label="View actions" size={24}
                onClick={() => float.below(actions, 220, viewMenu(current()))} />;
            }}
          </Show>
        </div>
        <Show when={view()}>{(v) => <ViewSentence view={v()} />}</Show>
        <Show when={view()}>
          <Rule class="meets-divider" />
        </Show>
      </header>
      <div class="list-scroll scroll" ref={scroller}>
        <div class="list-rows">
          <Show when={model.state.entries.length === 0 && view() && model.state.hasLoaded}>
            <div class="inline-empty">
              <InlineLabel>View · {view()!.name}</InlineLabel>
              <div class="inline-title">Nothing matches yet</div>
              <div class="inline-detail">No article fits this rule right now. New articles that fit appear here as they arrive; tap a word above to widen it.</div>
              <Show when={view()?.rule.state === "unread" && view()}>{(current) =>
                <Action kind="primary" onClick={() => {
                  const { id, revision, rule } = current();
                  void model.setViewRule(id, revision, SelectionRule.setState(rule, "any"));
                }}>Include read articles</Action>
              }</Show>
            </div>
          </Show>
          <For each={model.state.entries}>{(row, index) => <EntryRow row={row} last={index() === model.state.entries.length - 1} />}</For>
        </div>
      </div>
    </section>
  );
}

function EntryRow(props: { row: EntrySummary; last: boolean }) {
  const model = app();
  const selected = () => model.state.selectedId === props.row.id;
  let seen = false;
  const watch = (el: HTMLElement) => {
    if (!props.last) return;
    const observer = new IntersectionObserver((items) => {
      if (!seen && items.some((i) => i.isIntersecting)) {
        seen = true;
        void model.loadMore();
      }
    });
    observer.observe(el);
  };
  return (
    <div class="entry-row" classList={{ selected: selected() }} data-entry={props.row.id} ref={watch}>
      <button type="button" class="entry-button" aria-current={selected() ? "true" : undefined} onClick={() => void model.open(props.row.id)}>
        <span class="entry-title" classList={{ read: props.row.read }}>
          {props.row.title ?? "Untitled"}
        </span>
        <Show when={preview(props.row)}>{(text) => <span class="entry-preview">{text()}</span>}</Show>
        <span class="entry-date">{Dates.short(entryDate(props.row))}</span>
      </button>
      <StarToggle row={props.row} showing={selected()} class="entry-star" />
    </div>
  );
}
