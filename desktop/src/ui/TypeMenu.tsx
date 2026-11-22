import { For, Show } from "solid-js";
import { app } from "../model/app";
import { allThemes, fontsOf, paletteOf, prefs, themeName } from "../model/prefs";
import { css } from "../theme/color";
import { float } from "./Float";
import { Action, Rule } from "./kit/Controls";
import { FontPicker } from "./settings/Reading";

export function TypeMenu() {
  const settings = prefs();
  const { ui } = settings;
  const size = (step: number) => settings.update((draft) => { draft.text_size = Math.min(28, Math.max(14, draft.text_size + step)); });
  const reading = () => fontsOf(ui, settings.active()).reading!;
  return (
    <section class="type-menu" aria-label="Text and theme">
      <div class="type-themes">
        <For each={allThemes(ui)}>{(id) => (
          <button type="button" title={themeName(ui, id)} aria-label={themeName(ui, id)} aria-pressed={settings.active() === id}
            style={{ color: css(paletteOf(ui, id).colors.ink), background: css(paletteOf(ui, id).colors.ground), "font-family": fontsOf(ui, id).reading ?? undefined }}
            onClick={() => settings.update((draft) => { draft.theme = id; draft.follow_system = false; })}>Aa</button>
        )}</For>
      </div>
      <div><span>Font</span><FontPicker label="Reading" value={settings.fonts().reading!} change={(family) => settings.update((draft) => {
        draft.fonts.reading = family === reading() ? null : family;
      })} /></div>
      <Show when={ui.fonts.reading}>
        <Action kind="quiet" onClick={() => settings.update((draft) => { draft.fonts.reading = null; })}>Back to {themeName(ui, settings.active())}</Action>
      </Show>
      <Rule />
      <div>
        <span>Size</span>
        <Action compact aria-label="Decrease text size" disabled={ui.text_size <= 14} onClick={() => size(-1)}>A</Action>
        <output>{ui.text_size}</output>
        <Action compact aria-label="Increase text size" disabled={ui.text_size >= 28} onClick={() => size(1)}>A</Action>
      </div>
      <Action kind="quiet" onClick={() => {
        float.close();
        app().openSettings("Reading");
      }}>More in Settings</Action>
    </section>
  );
}
