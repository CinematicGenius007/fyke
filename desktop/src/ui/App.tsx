// The main window (gui/Sources/Reader/RootView.swift): sidebar, then the place's
// content, with the problem banner and the undo toast above it.
import { Match, onCleanup, onMount, Show, Switch } from "solid-js";
import { app } from "../model/app";
import { prefs } from "../model/prefs";
import { EntryList } from "./EntryList";
import { FloatLayer } from "./Float";
import { handleKey } from "./keys";
import { Icon } from "./kit/Icon";
import { Rule } from "./kit/Controls";
import { Panes } from "./Panes";
import { CommandPalette } from "./CommandPalette";
import { ConfirmDialog } from "./ConfirmDialog";
import { ReaderPane } from "./Reader";
import { SearchPanel } from "./SearchPanel";
import { ShortcutsSheet } from "./ShortcutsSheet";
import { Sidebar } from "./Sidebar";
import { Timeline } from "./Timeline";

export function App() {
  const model = app();
  onMount(() => {
    const listener = (event: KeyboardEvent) => handleKey(event);
    window.addEventListener("keydown", listener);
    // The webview's own menu (Reload, Inspect) is not the app's. Text keeps it, for
    // copy and paste, as AppKit's text views do.
    const menu = (event: MouseEvent) => {
      const target = event.target as HTMLElement | null;
      const text = target?.closest("input, textarea, [contenteditable]") || (window.getSelection()?.toString() ?? "") !== "";
      if (!text) event.preventDefault();
    };
    window.addEventListener("contextmenu", menu);
    onCleanup(() => {
      window.removeEventListener("keydown", listener);
      window.removeEventListener("contextmenu", menu);
    });
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
      <Show when={model.commands.state.isShowing}>
        <CommandPalette />
      </Show>
      <Show when={model.state.showingShortcuts}>
        <ShortcutsSheet />
      </Show>
      <Show when={model.state.confirmation}>
        <ConfirmDialog />
      </Show>
      <FloatLayer />
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
