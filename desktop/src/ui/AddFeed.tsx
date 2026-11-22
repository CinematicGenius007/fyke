import { createSignal, For, Match, onCleanup, onMount, Show, Switch } from "solid-js";
import { app, words } from "../model/app";
import { type FeedCandidate, previewFeeds, subscribeFeeds } from "../model/subscriptions";
import { RPCFailure, transport } from "../transport";
import { Rule } from "./kit/Controls";
import { Icon } from "./kit/Icon";

type Phase =
  | { kind: "idle" | "looking" }
  | { kind: "found"; candidates: FeedCandidate[] }
  | { kind: "failed"; message: string };

const HINT = "Paste a site or feed address. The feed is found for you.";
const EMPTY = "The page advertises no feed, and common addresses like /feed and /rss.xml came back empty. If you know the feed address, paste it above.";

export function AddFeed(props: { localFeeds: boolean }) {
  const model = app();
  const [address, setAddress] = createSignal(model.state.addFeedAddress);
  const [folder, setFolder] = createSignal(model.state.addFeedFolder);
  const [phase, setPhase] = createSignal<Phase>({ kind: "idle" });
  const [chosen, setChosen] = createSignal(new Set<string>());
  const [name, setName] = createSignal("");
  const [adding, setAdding] = createSignal(false);
  const [folderName, setFolderName] = createSignal<string | null>(null);
  const [folderError, setFolderError] = createSignal("");
  const [creatingFolder, setCreatingFolder] = createSignal(false);
  let dialog!: HTMLDialogElement;
  let addressField!: HTMLInputElement;
  let folderField!: HTMLSelectElement;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let generation = 0;

  const failure = () => { const current = phase(); return current.kind === "failed" && current; };
  const candidates = () => { const current = phase(); return current.kind === "found" && current.candidates; };
  const canSubscribe = () => phase().kind === "found" && chosen().size > 0 && !adding() && folderName() === null;

  function close() {
    dialog.close();
    model.set("showingAddFeed", false);
  }

  function cancelLookup() {
    clearTimeout(timer);
    return ++generation;
  }

  function changeAddress(value: string) {
    cancelLookup();
    setAddress(value);
    setPhase({ kind: "idle" });
    setFolderName(null);
    setFolderError("");
    if (value.includes(".")) timer = setTimeout(() => void look(), 500);
  }

  onMount(() => {
    model.set("addFeedAddress", "");
    model.set("addFeedFolder", null);
    dialog.showModal();
    addressField.focus();
    addressField.select();
    changeAddress(address());
    if (!address() && !props.localFeeds) {
      // Clipboard permission can be denied. A person can still paste into the field.
      const initial = generation;
      void navigator.clipboard?.readText().then((text) => {
        if (generation === initial && /^https?:\/\/\S+$/.test(text)) {
          changeAddress(text);
          queueMicrotask(() => addressField.select());
        }
      }).catch(() => undefined);
    }
  });
  onCleanup(cancelLookup);

  async function look() {
    const mine = cancelLookup();
    const url = address().trim();
    if (!url) return;
    setPhase({ kind: "looking" });
    try {
      const candidates = await previewFeeds(url, props.localFeeds);
      if (mine !== generation) return;
      const first = candidates[0];
      if (!first) {
        setPhase({ kind: "failed", message: EMPTY });
        return;
      }
      setChosen(new Set([first.url]));
      setName(first.title ?? "");
      setPhase({ kind: "found", candidates });
    } catch (error) {
      if (mine === generation) setPhase({ kind: "failed", message: `That address could not be reached. ${words(error)}` });
    }
  }

  async function subscribe() {
    const found = phase();
    if (found.kind !== "found" || !canSubscribe()) return;
    setAdding(true);
    try {
      await subscribeFeeds(found.candidates.filter((candidate) => chosen().has(candidate.url)), found.candidates.length === 1 ? name() : "", folder(), props.localFeeds);
      await model.reload();
      close();
    } catch (error) {
      await model.reload();
      setPhase({ kind: "failed", message: words(error) });
      addressField.focus();
    } finally {
      setAdding(false);
    }
  }

  function closeFolder() {
    setFolderName(null);
    setFolderError("");
    folderField.focus();
  }

  async function createFolder() {
    const text = folderName()?.trim();
    if (!text || creatingFolder()) return;
    setCreatingFolder(true);
    try {
      const { id } = await transport().call<{ id: number }>("folders.add", { name: text });
      await model.reload();
      setFolder(id);
      closeFolder();
    } catch (error) {
      setFolderError(RPCFailure.from(error).is("FolderExists") ? "A folder with that name is already there" : words(error));
    } finally {
      setCreatingFolder(false);
    }
  }

  function toggle(url: string) {
    const next = new Set(chosen());
    if (next.has(url)) next.delete(url);
    else next.add(url);
    setChosen(next);
  }

  return (
    <dialog ref={dialog} class="sheet add-feed scroll" aria-labelledby="add-feed-title" onCancel={(event) => {
      event.preventDefault();
      if (folderName() !== null && !creatingFolder()) closeFolder();
      else if (!adding() && !creatingFolder()) close();
    }}>
      <form onSubmit={(event) => {
        event.preventDefault();
        if (folderName() !== null) void createFolder();
        else if (canSubscribe()) void subscribe();
        else if (!adding() && phase().kind !== "looking") void look();
      }}>
        <h2 id="add-feed-title">Add a feed</h2>
        <input ref={addressField} class="feed-address" aria-label="Site or feed address" type="text"
          value={address()} onInput={(event) => changeAddress(event.currentTarget.value)} readOnly={adding() || creatingFolder()}
          onKeyDown={(event) => {
            if (event.key !== "Enter" || event.isComposing || adding() || folderName() !== null) return;
            event.preventDefault();
            if (canSubscribe()) void subscribe();
            else if (phase().kind !== "looking") void look();
          }} />
        <Switch>
          <Match when={phase().kind === "idle"}>
            <p class="add-feed-hint">{HINT}</p>
          </Match>
          <Match when={phase().kind === "looking"}>
            <p class="add-feed-hint" role="status">Looking for a feed…</p>
          </Match>
          <Match when={failure()} keyed>
            {(failure) => <div class="add-feed-error" role="status">
              <strong>No feed found on this site</strong>
              <p>{failure.message}</p>
            </div>}
          </Match>
          <Match when={candidates()} keyed>
            {(candidates) => <>
              <p class="add-feed-hint">{candidates.length === 1 ? HINT : `This site has ${candidates.length} feeds. Pick the ones you want.`}</p>
              <Show when={candidates.length === 1} fallback={<>
                <For each={candidates}>{(candidate) => <>
                  <Rule />
                  <label class="add-feed-choice">
                    <span class="add-feed-check">
                      <input class="checkbox" classList={{ on: chosen().has(candidate.url) }} type="checkbox"
                        checked={chosen().has(candidate.url)} onChange={() => toggle(candidate.url)} disabled={adding()} />
                      <Show when={chosen().has(candidate.url)}>
                        <Icon name="check" size={13} color="var(--on-accent)" />
                      </Show>
                    </span>
                    <span>
                      <span>{candidate.title ?? "Untitled feed"}</span>
                      <span class="add-feed-url">{candidate.url}</span>
                    </span>
                  </label>
                </>}</For>
                <Rule />
              </>}>
                <Rule />
                <div class="add-feed-preview">
                  <strong>{candidates[0].title ?? "Untitled feed"}</strong>
                  <p class="add-feed-url">{candidates[0].url}</p>
                  <For each={candidates[0].latest}>{(title) => <p class="add-feed-latest">{title}</p>}</For>
                </div>
              </Show>
              <div class="add-feed-details">
                <Show when={candidates.length === 1}>
                  <label class="add-feed-row">Name<input value={name()} readOnly={adding()} onInput={(event) => setName(event.currentTarget.value)} /></label>
                </Show>
                <label class="add-feed-row">
                  Folder
                  <span class="add-feed-select">
                    <select ref={folderField} value={folder()?.toString() ?? ""} disabled={adding() || creatingFolder()} onChange={(event) => {
                      const value = event.currentTarget.value;
                      if (value === "new") {
                        event.currentTarget.value = folder()?.toString() ?? "";
                        setFolderName("");
                      } else {
                        setFolder(value ? Number(value) : null);
                        setFolderName(null);
                        setFolderError("");
                      }
                    }}>
                      <option value="">None</option>
                      <For each={model.folderOutline()}>{({ folder: option, depth }) =>
                        <option value={option.id} selected={option.id === folder()}>{"\u00a0".repeat(depth * 3)}{option.name}</option>}
                      </For>
                      <option value="new">New folder</option>
                    </select>
                    <Icon name="down" size={14} />
                  </span>
                </label>
                <Show when={folderName() !== null}>
                  <label class="add-feed-row">New folder<input ref={(field) => queueMicrotask(() => field.focus())}
                    value={folderName() ?? ""} readOnly={creatingFolder()} onInput={(event) => setFolderName(event.currentTarget.value)} /></label>
                  <Show when={folderError()}><p class="add-feed-hint" role="status">{folderError()}</p></Show>
                </Show>
              </div>
            </>}
          </Match>
        </Switch>
        <div class="add-feed-actions">
          <button type="button" class="import-opml" disabled={adding() || creatingFolder()} onClick={() => {
            close();
            void model.importOpml();
          }}>Import OPML</button>
          <button type="button" class="outline-button" disabled={adding() || creatingFolder()} onClick={() => folderName() !== null ? closeFolder() : close()}>Cancel</button>
          <Switch fallback={
            <button class="add-primary" type="submit" disabled={!canSubscribe()}>
              {adding() ? "Subscribing…" : chosen().size > 1 ? `Subscribe to ${chosen().size}` : "Subscribe"}
            </button>
          }>
            <Match when={folderName() !== null}>
              <button class="add-primary" type="submit" disabled={!folderName()?.trim() || creatingFolder()}>Create</button>
            </Match>
            <Match when={phase().kind === "failed"}>
              <button class="outline-button" type="submit">Try again</button>
            </Match>
          </Switch>
        </div>
      </form>
    </dialog>
  );
}

export function FirstRun() {
  const model = app();
  const [address, setAddress] = createSignal("");
  const device = navigator.userAgent.includes("Windows") ? "PC" : "computer";
  return (
    <div class="first-run">
      <h1>Nothing to read yet.</h1>
      <p>Add a site you like. Everything stays on this {device}.</p>
      <form onSubmit={(event) => {
        event.preventDefault();
        model.set("addFeedAddress", address());
        model.set("showingAddFeed", true);
      }}>
        <input class="feed-address" aria-label="Site or feed address" placeholder="Paste a site or feed address"
          value={address()} onInput={(event) => setAddress(event.currentTarget.value)} />
        <button class="add-primary" type="submit">Add</button>
      </form>
      <div class="first-run-import">
        <span>Moving from another reader?</span>
        <button type="button" onClick={() => void model.importOpml()}>Import OPML</button>
      </div>
    </div>
  );
}
