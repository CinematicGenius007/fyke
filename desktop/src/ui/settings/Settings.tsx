import { For, Match, Switch } from "solid-js";
import { app } from "../../model/app";
import { SymbolButton } from "../kit/Controls";
import { Icon } from "../kit/Icon";
import { General } from "./General";
import { Reading } from "./Reading";
import { Tokens } from "./Tokens";
import { Agents } from "./Agents";
import { Data } from "./Data";

export const visibleSettingsTabs = ["General", "Reading", "Agents", "Data"] as const;
const glyph = { General: "gear", Agents: "sparkle", Data: "database" } as const;

export function Settings() {
  const model = app();
  const selected = () => model.state.settingsTab === "Tokens" ? "Reading" : model.state.settingsTab;
  return (
    <section class="settings" aria-label="Settings">
      <nav class="settings-tabs" aria-label="Settings">
        <For each={visibleSettingsTabs}>{(tab) => (
          <button type="button" aria-pressed={selected() === tab} onClick={() => model.openSettings(tab)}>
            {tab === "Reading" ? <span class="settings-type-icon" aria-hidden="true">Aa</span> : <Icon name={glyph[tab]} size={18} />}
            {tab}
          </button>
        )}</For>
      </nav>
      <div class="settings-close"><SymbolButton icon="close" label="Close Settings (Esc)" onClick={() => model.set("showingSettings", false)} /></div>
      <Switch>
        <Match when={model.state.settingsTab === "General"}><General /></Match>
        <Match when={model.state.settingsTab === "Reading"}><Reading /></Match>
        <Match when={model.state.settingsTab === "Tokens"}><Tokens /></Match>
        <Match when={model.state.settingsTab === "Agents"}><Agents /></Match>
        <Match when={model.state.settingsTab === "Data"}><Data /></Match>
      </Switch>
    </section>
  );
}
