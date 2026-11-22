// The main window (gui/Sources/Reader/RootView.swift): sidebar, then the place's
// content, with the problem banner and the undo toast above it.
import { Match, onCleanup, onMount, Show, Switch } from "solid-js";
import { app } from "../model/app";
import { prefs } from "../model/prefs";
import { EntryList } from "./EntryList";
import { handleKey } from "./keys";
import { Icon } from "./kit/Icon";
import { Rule } from "./kit/Controls";
import { Panes } from "./Panes";
import { ReaderPane } from "./Reader";
import { SearchPanel } from "./SearchPanel";
import { Sidebar } from "./Sidebar";
import { Timeline } from "./Timeline";

export function App() {
  const model = app();
  onMount(() => {
    const listener = (event: KeyboardEvent) => handleKey(event);
    window.addEventListener("keydown", listener);
    onCleanup(() => window.removeEventListener("keydown", listener));
  });

  const problem = () => {
    const file = prefs().fileProblem();
    return model.state.problem ?? (file ? `config.json has a mistake, so the last good settings stay in use: ${file}` : null);
  };

  return (
    <div class="shell">
      <Sidebar />
      <Rule vertical />
      <main class="content">
        <Switch fallback={<Timeline />}>
          <Match when={model.state.showingSettings}>
            <div class="reader-empty">Settings</div>
          </Match>
          <Match when={model.isEmpty()}>
            <div class="reader-empty">Add a feed to start reading</div>
          </Match>
          <Match when={model.usesPanes()}>
            <Panes list={<EntryList />} reader={<ReaderPane />} />
          </Match>
          <Match when={model.state.article}>
            <ReaderPane />
          </Match>
        </Switch>
      </main>
      <Show when={model.search.state.isShowing}>
        <SearchPanel />
      </Show>
      <div class="bottom-layer" aria-live="polite">
        <Show when={problem()}>
          {(text) => (
            <div class="problem">
              <span>{text()}</span>
              <button type="button" class="problem-close" aria-label="Dismiss" onClick={() => model.set("problem", null)}>
                <Icon name="close" size={10} stroke={2.4} />
              </button>
            </div>
          )}
        </Show>
        <Show when={model.undo.toast()}>
          {(toast) => (
            <div class="toast" role="status">
              <span>{toast().message}</span>
              <button type="button" class="toast-undo" onClick={() => model.undo.undoLast()}>
                Undo
              </button>
            </div>
          )}
        </Show>
      </div>
    </div>
  );
}
