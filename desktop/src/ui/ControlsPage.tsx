// S38: a test page with every control the app draws, in each state it can be put in
// without a pointer (rest, selected, disabled). `tests/e2e/controls.spec.ts` hovers,
// presses and focuses them, and checks cursors, motion, reduced motion and forced colors.
// Test mode opens it with FYKE_SCREEN=controls; the Mac has no such page.
import { For, type JSX } from "solid-js";
import { Action, type ActionKind, Chip, Count, Dot, IconButton, KeyHint, Spinner, SymbolButton } from "./kit/Controls";
import { Select, Toggle } from "./settings/Controls";

const kinds: ActionKind[] = ["primary", "secondary", "quiet", "link", "inverse"];
const none = () => undefined;

function Group(props: { title: string; children: JSX.Element }) {
  return (
    <section class="controls-group" aria-label={props.title}>
      <h2>{props.title}</h2>
      <div class="controls-row">{props.children}</div>
    </section>
  );
}

export function ControlsPage() {
  return (
    <main class="controls-page scroll" aria-label="Controls">
      <h1>Controls</h1>
      <For each={kinds}>{(kind) => (
        <Group title={`Action · ${kind}`}>
          <Action kind={kind} data-control={`action-${kind}`} onClick={none}>Action</Action>
          <Action kind={kind} compact data-control={`action-${kind}-compact`} onClick={none}>Compact</Action>
          <Action kind={kind} selected data-control={`action-${kind}-selected`} data-state="selected" onClick={none}>Selected</Action>
          <Action kind={kind} disabled data-control={`action-${kind}-disabled`} data-state="disabled">Disabled</Action>
        </Group>
      )}</For>
      <Group title="Symbol buttons">
        <span data-control="symbol"><SymbolButton icon="plus" label="Add" onClick={none} /></span>
        <span data-control="symbol-selected" data-state="selected"><SymbolButton icon="plus" label="Add, selected" selected onClick={none} /></span>
        <span data-control="symbol-disabled" data-state="disabled"><SymbolButton icon="plus" label="Add, disabled" disabled /></span>
      </Group>
      <Group title="Icon buttons">
        <span data-control="icon"><IconButton icon="star" label="Star" onClick={none} /></span>
        <span data-control="icon-disabled" data-state="disabled"><IconButton icon="star" label="Star, disabled" enabled={false} onClick={none} /></span>
      </Group>
      <Group title="Chips">
        <span data-control="chip"><Chip text="unread" onClick={none} /></span>
        <span data-control="chip-selected" data-state="selected"><Chip text="starred" selected onClick={none} /></span>
        <span data-control="chip-muted"><Chip text="any time" muted onClick={none} /></span>
      </Group>
      <Group title="Switches">
        <span data-control="switch-off"><Toggle label="Off" on={false} change={none} /></span>
        <span data-control="switch-on" data-state="selected"><Toggle label="On" on change={none} /></span>
        <span data-control="switch-disabled" data-state="disabled"><Toggle label="Disabled" on={false} disabled change={none} /></span>
      </Group>
      <Group title="Selects">
        <span data-control="select"><Select label="Open links" value="app" options={[{ value: "app", label: "In Fyke" }, { value: "browser", label: "In the browser" }]} change={none} /></span>
        <span data-control="select-disabled" data-state="disabled"><Select label="Disabled select" value="app" disabled options={[{ value: "app", label: "In Fyke" }]} change={none} /></span>
      </Group>
      <Group title="Fields">
        <input class="feed-address" data-control="field" aria-label="Address" placeholder="Paste a site or feed address" />
        <input class="feed-address" data-control="field-disabled" data-state="disabled" aria-label="Disabled address" disabled placeholder="Disabled" />
      </Group>
      <Group title="Marks">
        <Spinner size={14} />
        <Dot color="var(--unread)" label="Unread" />
        <KeyHint text="Ctrl+K" />
        <Count value={12} />
      </Group>
    </main>
  );
}
