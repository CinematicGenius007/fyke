import { createResource, createSignal, Show } from "solid-js";
import { app, words } from "../../model/app";
import { prefs } from "../../model/prefs";
import { isWindows } from "../../platform";
import { transport } from "../../transport";
import { Action } from "../kit/Controls";
import { PaneScroll, Row, Section, Select, Toggle } from "./Controls";

export function General() {
  const model = app();
  const settings = prefs();
  const [busy, setBusy] = createSignal(false);
  const [problem, setProblem] = createSignal<string | null>(null);
  const [background, { mutate }] = createResource(() => transport().backgroundService("status").catch((error) => {
    setProblem(words(error));
    return undefined;
  }));

  async function changeBackground(on: boolean) {
    setBusy(true);
    setProblem(null);
    try {
      mutate(await transport().backgroundService(on ? "install" : "uninstall"));
    } catch (error) {
      setProblem(words(error));
    } finally {
      setBusy(false);
    }
  }

  return (
    <PaneScroll>
      <Section title="Updates">
        <Row title="Check for new articles" detail="Automatic follows how often each feed posts"><span class="settings-note">Automatic</span></Row>
        <Row title="Fetch full articles" detail="Replaces short summaries, and respects each site's robots.txt">
          <Toggle label="Fetch full articles" on={settings.fullText()} change={(on) => void settings.setFullText(on)} />
        </Row>
        <Row title="Keep updating in the background" detail={`Starts when you ${isWindows ? "sign in" : "log in"}, even with this window closed`} last>
          <Toggle label="Keep updating in the background" on={background() ?? false} disabled={busy() || background.loading || background() === undefined} change={(on) => void changeBackground(on)} />
        </Row>
        <Show when={problem()}><p role="status" class="settings-note">{problem()}</p></Show>
      </Section>
      <Section title="Privacy" detail="What publishers can learn from your reading.">
        <Row title="Load images automatically" detail="Off means publishers cannot see when you read">
          <Toggle label="Load images automatically" on={settings.ui.load_images} change={(on) => settings.update((draft) => { draft.load_images = on; })} />
        </Row>
        <Row title="Open links" detail="Ctrl-click always uses your browser" last>
          <Select label="Open links" value={settings.ui.open_links} options={[{ value: "app", label: "In the app" }, { value: "browser", label: "In your browser" }]}
            change={(value) => settings.update((draft) => { draft.open_links = value; })} />
        </Row>
      </Section>
      <Section title="Subscriptions and keys">
        <Row title="Your subscriptions" detail="Import or export as OPML">
          <Action onClick={() => void model.importOpml()}>Import OPML</Action>
          <Action onClick={() => void model.exportOpml()}>Export</Action>
        </Row>
        <Row title="Keyboard shortcuts" detail="Press ? anywhere in the reader to see them" last>
          <Action onClick={() => model.set("showingShortcuts", true)}>Show</Action>
        </Row>
      </Section>
      <Show when={settings.fileProblem()}>{(message) => <p class="settings-note" role="status">config.json has a mistake, so the last good settings stay in use: {message()}</p>}</Show>
    </PaneScroll>
  );
}
