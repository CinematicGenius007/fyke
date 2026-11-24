import { createResource, createSignal, For, Show } from "solid-js";
import { app, words } from "../../model/app";
import { prefs } from "../../model/prefs";
import { thisComputer } from "../../platform";
import { transport } from "../../transport";
import { Action } from "../kit/Controls";
import { Icon } from "../kit/Icon";
import { PaneScroll, Row, Section, Select } from "./Controls";

interface StorageUse {
  database_bytes: number;
  articles: { entries: number; feeds: number; text_bytes: number; search_bytes: number; other_bytes: number; removable: number; removable_bytes: number };
  raw_bytes: number;
  raw_files: number;
  log_bytes: number;
  settings_bytes: number;
}

interface Space {
  label: string;
  bytes: number;
  color: string;
}

const retentionChoices = [
  { value: 0, label: "Never" }, { value: 30, label: "30 days" }, { value: 90, label: "90 days" }, { value: 365, label: "1 year" },
];

function size(bytes: number) {
  if (bytes < 1000) return `${bytes} bytes`;
  let unit = "KB";
  let amount = bytes / 1000;
  if (amount >= 1000) { unit = "MB"; amount /= 1000; }
  if (amount >= 1000) { unit = "GB"; amount /= 1000; }
  return `${amount.toLocaleString(undefined, { maximumFractionDigits: 1 })} ${unit}`;
}

function SpaceBar(props: { spaces: Space[]; small?: boolean }) {
  return (
    <div class="space-summary">
      <div class="space-bar" classList={{ small: props.small }} aria-hidden="true">
        <For each={props.spaces}>{(item) => <span style={{ "flex-grow": item.bytes, background: item.color }} />}</For>
      </div>
      <div class="space-legend">
        <For each={props.spaces}>{(item) => <span><i style={{ background: item.color }} />{item.label} <strong>{size(item.bytes)}</strong></span>}</For>
      </div>
    </div>
  );
}

export function Data() {
  const model = app();
  const settings = prefs();
  const [problem, setProblem] = createSignal<string | null>(null);
  const [busy, setBusy] = createSignal(false);
  const [confirm, setConfirm] = createSignal<"articles" | "copies" | null>(null);
  const [target, setTarget] = createSignal<string | null>(null);
  const [stage, setStage] = createSignal<string | null>(null);
  const [moveError, setMoveError] = createSignal<string | null>(null);
  const [updated, setUpdated] = createSignal<Date | null>(null);
  const [paths, { refetch: refreshPaths }] = createResource(() => transport().desktopPaths());
  const [space, { refetch: measure }] = createResource(async () => {
    setProblem(null);
    try {
      const result = await transport().call<StorageUse>("storage.get", {}, { slow: true });
      setUpdated(new Date());
      return result;
    } catch (error) {
      setProblem(words(error));
      return undefined;
    }
  });
  const total = () => {
    const use = space.latest;
    return use ? use.database_bytes + use.raw_bytes + use.log_bytes + use.settings_bytes : 0;
  };

  async function chooseMove() {
    setProblem(null);
    try {
      setTarget(await transport().chooseDataFolder());
    } catch (error) {
      setProblem(words(error));
    }
  }

  async function move(folder: string) {
    setStage("Stopping…");
    try {
      await transport().moveData(folder, setStage);
      setTarget(null);
    } catch (error) {
      setMoveError(words(error));
    } finally {
      setStage(null);
      await model.start();
      await refreshPaths();
      await measure();
    }
  }

  async function trim(kind: "articles" | "copies") {
    setConfirm(null);
    setBusy(true);
    setProblem(null);
    try {
      await transport().call("storage.free", kind === "articles" ? { trim_older_than_days: 90 } : { feed_copies: true }, { slow: true });
      await measure();
    } catch (error) {
      setProblem(words(error));
    } finally {
      setBusy(false);
    }
  }

  function pathText(path: string | undefined) {
    const home = paths()?.home;
    return path && home && path.startsWith(home + "/") ? "~" + path.slice(home.length) : path;
  }

  return (
    <PaneScroll>
      <Section title="Where your data lives" detail={`Feeds, articles and settings stay in one folder on ${thisComputer}.`}>
        <Row title="Data folder" detail={pathText(paths()?.data)}>
          <Action kind="quiet" onClick={() => void transport().openData("folder").catch((error) => setProblem(words(error)))}>Open</Action>
          <Action disabled={!paths()?.canMove} onClick={() => void chooseMove()}>Change…</Action>
        </Row>
        <Row title="Settings file" detail={pathText(paths()?.config)} last>
          <Action onClick={() => void transport().openData("config").catch((error) => setProblem(words(error)))}>Open</Action>
        </Row>
      </Section>
      <Section title="Disk space" detail={updated() ? "Checked just now" : " "} trailing={
        <Action disabled={space.loading || busy()} onClick={() => void measure()}><Icon name="reload" size={14} />Refresh</Action>
      }>
        <Show when={problem()}><p class="settings-note" role="status">{problem()}</p></Show>
        <Show when={space.loading && !space.latest}><p class="settings-note writer-status" role="status">Measuring…</p></Show>
        <Show when={space.latest}>{(measured) => {
          const use = () => measured();
          const articles = () => use().articles;
          return (
            <div class="storage">
              <p class="space-total"><span>Used in all</span><strong>{size(total())}</strong></p>
              <SpaceBar spaces={[
                { label: "Articles and search", bytes: use().database_bytes, color: "var(--ink)" },
                { label: "Feed copies", bytes: use().raw_bytes, color: "var(--unread)" },
                { label: "Logs and settings", bytes: use().log_bytes + use().settings_bytes, color: "var(--control)" },
              ]} />
              <details open>
                <summary>Articles and search <strong>{size(use().database_bytes)}</strong></summary>
                <p class="settings-note">{articles().entries.toLocaleString()} articles in {articles().feeds.toLocaleString()} feeds.
                  <Show when={articles().removable}> {articles().removable.toLocaleString()} were read over 90 days ago ({size(articles().removable_bytes)}).</Show></p>
                <SpaceBar small spaces={[
                  { label: "Article text", bytes: articles().text_bytes, color: "var(--ink)" },
                  { label: "Search index", bytes: articles().search_bytes, color: "var(--ink-soft)" },
                  { label: "Other", bytes: articles().other_bytes, color: "var(--control)" },
                ]} />
                <div class="storage-actions">
                  <Action disabled={busy()} onClick={() => setConfirm("articles")}>Free up space…</Action>
                  <span class="settings-note">Remove read articles after</span>
                  <Select label="Remove read articles after" value={settings.retention()} options={retentionChoices} width={128} change={(days) => void settings.setRetention(days)} />
                </div>
                <Show when={confirm() === "articles"}>
                  <TrimConfirmation cancel={() => setConfirm(null)} accept={() => void trim("articles")}>
                    Removes the text of {articles().removable.toLocaleString()} articles read over 90 days ago. Titles, links and starred articles stay.
                  </TrimConfirmation>
                </Show>
              </details>
              <details>
                <summary>Feed copies <strong>{size(use().raw_bytes)}</strong></summary>
                <p class="settings-note">Up to 20 per feed, kept so a parser fix can replay them.</p>
                <p class="settings-note">{use().raw_files.toLocaleString()} copies</p>
                <Action disabled={busy()} onClick={() => setConfirm("copies")}>Free up space…</Action>
                <Show when={confirm() === "copies"}>
                  <TrimConfirmation cancel={() => setConfirm(null)} accept={() => void trim("copies")}>Keeps the newest copy of each feed and removes the rest.</TrimConfirmation>
                </Show>
              </details>
              <Row title="Logs and settings" detail="The log is replaced each time the service starts." last><strong>{size(use().log_bytes + use().settings_bytes)}</strong></Row>
            </div>
          );
        }}</Show>
      </Section>
      <Show when={target()} keyed>{(folder) => (
        <dialog class="settings-move" aria-labelledby="move-heading" ref={(dialog) => queueMicrotask(() => dialog.showModal())}
          onCancel={(event) => { event.preventDefault(); if (!stage()) { setMoveError(null); setTarget(null); } }}>
          <h2 id="move-heading">{stage() ? "Moving your data" : moveError() ? "The data folder could not move" : "Move your data?"}</h2>
          <Show when={stage()} fallback={
            <>
              <p><Show when={moveError()} fallback={<>{size(total())} moves to <code>{pathText(folder)}</code>. Fyke restarts when it is done.</>}>{moveError()}</Show></p>
              <div class="settings-actions">
                <Action onClick={() => { setMoveError(null); setTarget(null); }}>{moveError() ? "Close" : "Cancel"}</Action>
                <Show when={!moveError()}><Action kind="primary" onClick={() => void move(folder)}>Move data</Action></Show>
              </div>
            </>
          }><p role="status">{stage()}</p></Show>
        </dialog>
      )}</Show>
    </PaneScroll>
  );
}

function TrimConfirmation(props: { children: import("solid-js").JSX.Element; cancel: () => void; accept: () => void }) {
  return <div class="settings-inline-panel storage-confirm"><p>{props.children}</p><Action onClick={props.cancel}>Cancel</Action><Action kind="primary" onClick={props.accept}>Free up space</Action></div>;
}
