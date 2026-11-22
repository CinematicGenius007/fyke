// The article list beside the reader (gui/Sources/Reader/RootView.swift `EntryList`).
import { createEffect, For, Show } from "solid-js";
import { RuleSentence } from "../logic/RuleSentence";
import { app } from "../model/app";
import type { EntrySummary } from "../model/types";
import { entryDate, feedName, preview } from "../model/types";
import { Dates } from "./format";
import { Chip, Rule, SymbolButton } from "./kit/Controls";
import { StarToggle } from "./StarToggle";

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
            <SymbolButton icon="ellipsis" label="View actions" size={24} onClick={() => undefined} />
          </Show>
        </div>
        <Show when={view()}>{(v) => <ViewSentence rule={v().rule} />}</Show>
        <Show when={view()}>
          <Rule class="meets-divider" />
        </Show>
      </header>
      <div class="list-scroll scroll" ref={scroller}>
        <div class="list-rows">
          <Show when={model.state.entries.length === 0 && view() && model.state.hasLoaded}>
            <div class="inline-empty">
              <div class="inline-label">View · {view()!.name}</div>
              <div class="inline-title">Nothing matches yet</div>
              <div class="inline-detail">No article fits this rule right now. New articles that fit appear here as they arrive; tap a word above to widen it.</div>
            </div>
          </Show>
          <For each={model.state.entries}>{(row, index) => <EntryRow row={row} last={index() === model.state.entries.length - 1} />}</For>
        </div>
      </div>
    </section>
  );
}

/** The view's rule as words (gui/Sources/Reader/Views.swift `ViewSentence`). */
function ViewSentence(props: { rule: Parameters<typeof RuleSentence.parts>[0] }) {
  const model = app();
  const parts = () =>
    RuleSentence.parts(
      props.rule,
      (id) => {
        const feed = model.state.feeds.find((f) => f.id === id);
        return feed ? feedName(feed) : null;
      },
      (id) => model.state.folders.find((f) => f.id === id)?.name,
    );
  return (
    <div class="sentence" aria-label={`Rule: ${RuleSentence.text(parts())}`}>
      <For each={parts()}>{(part) => (part.kind === "joiner" ? <span class="joiner">{part.text}</span> : <Chip text={part.text} aria-label={`${part.clause}: ${part.text}`} />)}</For>
      <Chip text="+" muted aria-label="Add to the rule" />
    </div>
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
