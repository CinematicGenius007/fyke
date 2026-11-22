// All and Starred: one wide column grouped into this week and earlier
// (gui/Sources/Reader/RootView.swift `TimelineView`).
import { For, Show } from "solid-js";
import { app } from "../model/app";
import type { EntrySummary } from "../model/types";
import { entryDate, preview } from "../model/types";
import { Dates } from "./format";
import { Rule } from "./kit/Controls";
import { StarToggle } from "./StarToggle";

export function Timeline() {
  const model = app();
  const cutoff = () => Date.now() - 7 * 86_400_000;
  const recent = () => model.state.entries.filter((e) => entryDate(e).getTime() >= cutoff());
  const earlier = () => model.state.entries.filter((e) => entryDate(e).getTime() < cutoff());
  return (
    <div class="timeline scroll">
      <div class="timeline-column">
        <div class="timeline-heading">
          <h1 class="timeline-title">{model.placeTitle()}</h1>
          <button type="button" class="timeline-filter" onClick={() => model.toggleUnreadOnly()}>
            {model.state.unreadOnly ? `Unread · ${model.totalUnread()}` : `All · ${model.totalUnread()} unread`}
          </button>
        </div>
        <Group title="THIS WEEK" rows={recent()} />
        <Group title="EARLIER" rows={earlier()} />
        <Show when={model.state.entries.length === 0 && model.state.hasLoaded}>
          <div class="timeline-empty">{model.state.place.kind === "starred" ? "Star an article to keep it here." : "No articles to show."}</div>
        </Show>
      </div>
    </div>
  );
}

function Group(props: { title: string; rows: EntrySummary[] }) {
  return (
    <Show when={props.rows.length > 0}>
      <div class="timeline-group" classList={{ later: props.title === "EARLIER" }}>
        {props.title}
      </div>
      <Rule strong />
      <For each={props.rows}>{(row) => <TimelineRow row={row} />}</For>
    </Show>
  );
}

function TimelineRow(props: { row: EntrySummary }) {
  const model = app();
  const selected = () => model.state.selectedId === props.row.id;
  return (
    <div class="timeline-row" data-entry={props.row.id}>
      <div class="timeline-line" classList={{ selected: selected() }}>
        <button type="button" class="timeline-button" onClick={() => void model.open(props.row.id)}>
          <span class="timeline-text">
            <span class="timeline-row-title" classList={{ read: props.row.read }}>
              {props.row.title ?? "Untitled"}
            </span>
            <Show when={preview(props.row)}>{(text) => <span class="timeline-preview">{text()}</span>}</Show>
          </span>
          <span class="timeline-meta">
            <span class="one-line">{props.row.feed_title ?? ""}</span>
            <span>{Dates.relative(entryDate(props.row))}</span>
          </span>
        </button>
        <StarToggle row={props.row} showing={selected()} class="timeline-star" />
      </div>
      <Rule />
    </div>
  );
}
