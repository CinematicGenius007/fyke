// Asks before anything that loses data (gui/Sources/Reader/Sidebar.swift
// `ConfirmationDialog`). Keeping data is the default: Esc and Cancel keep it, and only
// the filled button goes ahead. Folder delete and feed removal are the two (D13).
import { createSignal, onMount, Show } from "solid-js";
import { app } from "../model/app";
import type { Feed, Folder } from "../model/types";
import { feedName } from "../model/types";
import { Rule } from "./kit/Controls";
import { Icon } from "./kit/Icon";

const count = (number: number, noun: string) => `${number.toLocaleString()} ${noun}${number === 1 ? "" : "s"}`;

export function ConfirmDialog() {
  const model = app();
  const cancel = () => model.set("confirmation", null);
  const confirmation = () => model.state.confirmation;
  return (
    <div class="scrim centered" role="presentation">
      <div class="sheet confirm" role="alertdialog" aria-modal="true" aria-labelledby="confirm-title">
        <Show when={confirmation()} keyed>
          {(asked) => (asked.kind === "deleteFolder" ? <DeleteFolder folder={asked.folder} cancel={cancel} /> : <RemoveFeed feed={asked.feed} cancel={cancel} />)}
        </Show>
      </div>
    </div>
  );
}

function Buttons(props: { action: string; cancel: () => void; run: () => void }) {
  let keep!: HTMLButtonElement;
  // Focus starts on the button that keeps the data.
  onMount(() => keep.focus());
  return (
    <div class="confirm-buttons">
      <button ref={keep} type="button" class="outline-button" onClick={() => props.cancel()}>
        Cancel
      </button>
      <button
        type="button"
        class="solid-button"
        onClick={() => {
          props.cancel();
          props.run();
        }}
      >
        {props.action}
      </button>
    </div>
  );
}

function DeleteFolder(props: { folder: Folder; cancel: () => void }) {
  const model = app();
  const [deleteContents, setDeleteContents] = createSignal(false);
  const folders = model.foldersInside(props.folder.id).length;
  const feeds = model.feedsInside(props.folder.id);
  const articles = feeds.reduce((sum, f) => sum + f.entries, 0);
  const starred = feeds.reduce((sum, f) => sum + f.starred, 0);
  const parts = [folders > 0 ? count(folders, "folder") : null, feeds.length ? count(feeds.length, "feed") : null].filter((p): p is string => p !== null);
  const target = props.folder.parent_id == null ? "the top level" : "the folder above";
  const moves = folders + feeds.length === 1 ? "moves" : "move";
  return (
    <>
      <h2 id="confirm-title" class="confirm-title">
        Delete {props.folder.name}?
      </h2>
      <p class="confirm-text">{parts.length ? `Its ${parts.join(" and ")} ${moves} up to ${target}. Your articles stay.` : "The folder is empty."}</p>
      <Show when={parts.length}>
        <Rule />
        <div class="confirm-option">
          <button
            type="button"
            class="checkbox"
            classList={{ on: deleteContents() }}
            role="checkbox"
            aria-checked={deleteContents()}
            aria-label="Also delete everything inside"
            onClick={() => setDeleteContents((v) => !v)}
          >
            <Show when={deleteContents()}>
              <Icon name="check" size={13} color="var(--on-accent)" />
            </Show>
          </button>
          <div class="confirm-option-text">
            <span class="confirm-option-title">Also delete everything inside</span>
            <span class="confirm-option-note">
              Removes {[...parts, count(articles, "article")].join(", ")}
              {starred > 0 ? `, including ${starred} starred` : ""}. This cannot be undone.
            </span>
          </div>
        </div>
        <Rule />
      </Show>
      <Buttons action="Delete folder" cancel={props.cancel} run={() => void model.removeFolder(props.folder.id, deleteContents())} />
    </>
  );
}

function RemoveFeed(props: { feed: Feed; cancel: () => void }) {
  const model = app();
  return (
    <>
      <h2 id="confirm-title" class="confirm-title">
        Remove {feedName(props.feed)}?
      </h2>
      <p class="confirm-text">
        This deletes {count(props.feed.entries, "article")}
        {props.feed.starred > 0 ? `, including ${props.feed.starred} starred` : ""}. This cannot be undone.
      </p>
      <Buttons action="Remove feed" cancel={props.cancel} run={() => void model.removeFeed(props.feed.id)} />
    </>
  );
}
