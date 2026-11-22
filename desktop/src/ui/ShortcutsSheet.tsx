// The key list (gui/Sources/Reader/Sidebar.swift `ShortcutsPopup`), over the app, so
// that looking one up loses no place. Ctrl stands where the Mac has Command (K24).
import { For } from "solid-js";
import { app } from "../model/app";
import { Rule } from "./kit/Controls";

export const shortcutList = {
  move: [
    ["Next, previous", "j k"],
    ["Open", "Return"],
    ["Back", "Esc"],
    ["Next unread", "n"],
    ["Search", "/"],
    ["Today, All, Starred, Routines", "Ctrl+1–4"],
    ["Everything", "Ctrl+K"],
  ],
  act: [
    ["Star", "s"],
    ["Read or unread", "m"],
    ["Unread only", "u"],
    ["Open page here", "o"],
    ["Open in browser", "Shift+O"],
    ["Comments", "c"],
    ["Fetch full article", "f"],
    ["Refresh", "r"],
    ["Add feed", "a"],
    ["Text and theme", "t"],
    ["Save search as view", "Ctrl+S"],
    ["Settings", "Ctrl+,"],
    ["Catch up", "Ctrl+J"],
    ["Ask your feeds", "Ctrl+Shift+A"],
    ["Undo", "Ctrl+Z"],
  ],
} as const;

export function ShortcutsSheet() {
  const model = app();
  const close = () => model.set("showingShortcuts", false);
  return (
    <div class="scrim centered" onClick={(event) => event.target === event.currentTarget && close()}>
      <div class="shortcuts" role="dialog" aria-label="Shortcuts">
        <div class="shortcuts-head">
          <h2 class="shortcuts-title">Shortcuts</h2>
          <span class="shortcuts-note">Esc to close</span>
        </div>
        <div class="shortcuts-columns">
          <Column title="MOVE" rows={shortcutList.move} />
          <Column title="ACT" rows={shortcutList.act} />
        </div>
        <Rule class="shortcuts-rule" />
        <p class="shortcuts-note shortcuts-foot">Press ? anywhere to see this list.</p>
      </div>
    </div>
  );
}

function Column(props: { title: string; rows: readonly (readonly [string, string])[] }) {
  return (
    <div class="shortcuts-column">
      <span class="section-label shortcuts-label">{props.title}</span>
      <For each={props.rows}>
        {([name, keys]) => (
          <>
            <Rule />
            <div class="shortcuts-row">
              <span>{name}</span>
              <kbd>{keys}</kbd>
            </div>
          </>
        )}
      </For>
    </div>
  );
}
