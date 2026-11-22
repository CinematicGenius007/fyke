// The reader pane (gui/Sources/Reader/ReaderPane.swift): the article in a centered
// column, with its actions in the top-right corner.
import { Show } from "solid-js";
import { app, type Article } from "../model/app";
import { prefs } from "../model/prefs";
import { Blocks } from "./Blocks";
import { Discussion } from "./Discussion";
import { isSafeLink } from "./links";
import { Dates } from "./format";
import { IconButton } from "./kit/Controls";
import { Icon } from "./kit/Icon";

export function ReaderPane() {
  const model = app();
  return (
    <div class="reader-pane">
      <Show when={model.state.article} keyed fallback={<div class="reader-empty">Select an article</div>}>
        {(article) => (
          <>
            <div class="reader-scroll scroll">
              <Column article={article} />
            </div>
            <Actions />
          </>
        )}
      </Show>
    </div>
  );
}

function Column(props: { article: Article }) {
  const model = app();
  const entry = () => props.article.entry;
  const meta = () => [entry().feed_title, Dates.long(new Date(entry().published_at ?? entry().first_seen_at))].filter(Boolean).join(" · ");
  return (
    <article class="reading-column" style={{ "--column": `${prefs().ui.column_width}px`, "--text-size": `${prefs().ui.text_size}px`, "--line-spacing": String(prefs().ui.line_spacing) }}>
      <div class="article-meta">{meta()}</div>
      <h1 class="article-title selectable">{entry().title ?? "Untitled"}</h1>
      <Show when={model.state.fullTextStatus}>{(status) => <div class="article-status">{status()}</div>}</Show>
      <Show when={props.article.blocks.length === 0}>
        <p class="b-p soft">This feed sent no text for this article.</p>
        <div class="article-empty-actions">
          <button type="button" class="plain-button" onClick={() => model.fetchFull()}>
            Fetch full article
          </button>
          <button type="button" class="plain-button" onClick={() => model.openPage()}>
            Open page
          </button>
        </div>
      </Show>
      <div class="blocks selectable">
        <Blocks blocks={props.article.blocks} context={{ open: (url, event) => model.openLink(url, event.ctrlKey || event.metaKey) }} />
      </div>
      <Show when={isSafeLink(entry().discussion_url) && entry().discussion_url} keyed>
        {(address) => <Discussion id={entry().id} address={address} />}
      </Show>
    </article>
  );
}

function Actions() {
  const model = app();
  const entry = () => model.state.article!.entry;
  return (
    <div class="reader-actions">
      <button type="button" class="type-button" title="Text and theme" onClick={() => model.set("showingType", (v) => !v)}>
        Aa
      </button>
      <IconButton icon="star" label={entry().starred ? "Remove star" : "Star"} color={entry().starred ? "var(--unread)" : undefined} filled={entry().starred} onClick={() => model.toggleStar()} />
      <IconButton icon="circle" label={entry().read ? "Mark unread" : "Mark read"} color={entry().read ? undefined : "var(--unread)"} filled={!entry().read} onClick={() => model.toggleRead()} />
      <button type="button" class="open-page" title="Open the page here. Ctrl-click a link for your browser." onClick={() => model.openPage()}>
        <Icon name="globe" />
        <span>Open page</span>
      </button>
    </div>
  );
}
