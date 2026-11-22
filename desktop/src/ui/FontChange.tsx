// Offers to keep or drop fonts changed on top of the active theme, in the text menu and
// in Reading settings, as the Mac's `FontChangeStrip` (TokensPane.swift).
import { createSignal, Show } from "solid-js";
import { customTheme, fontsOf, type FontTokens, prefs, themeName } from "../model/prefs";
import { float } from "./Float";
import { Action } from "./kit/Controls";
import { activateTheme } from "./settings/Reading";
import { newThemeId } from "./settings/Tokens";

const slots: { key: keyof FontTokens; label: string }[] = [
  { key: "reading", label: "Reading font" }, { key: "title", label: "Title font" },
  { key: "ui", label: "App font" }, { key: "code", label: "Code font" },
];

/** As the Mac's `Fonts.label`. */
const fontLabel = (family: string) => (family === "Source Serif 4" ? "Source Serif" : family);

/** Writes the temporary fonts into a custom theme (`Prefs.saveFonts(to:)`). */
function saveFontsTo(id: string) {
  prefs().update((draft) => {
    const theme = customTheme(draft, id);
    if (!theme) return;
    for (const { key } of slots) if (draft.fonts[key] != null) theme.fonts[key] = draft.fonts[key];
    draft.fonts = {};
  });
}

/** Turns what is on screen, built-in or not, into a new theme and uses it (`Prefs.saveAsNewTheme`). */
function saveAsNewTheme(name: string) {
  const settings = prefs();
  const source = settings.active();
  const id = newThemeId(settings.ui, name);
  settings.update((draft) => {
    const original = customTheme(draft, source);
    draft.themes.push({
      id, name, base: original?.base ?? source,
      tokens: { ...original?.tokens }, fonts: { ...original?.fonts }, radii: { ...original?.radii },
    });
  });
  saveFontsTo(id);
  activateTheme(id);
}

function NamePanel(props: { done: (name: string) => void }) {
  const [name, setName] = createSignal("");
  const finish = () => {
    const trimmed = name().trim();
    if (!trimmed) return;
    float.close(true);
    props.done(trimmed);
  };
  return (
    <form class="name-panel" aria-label="Save as new theme" onSubmit={(event) => { event.preventDefault(); finish(); }}>
      <h3>Save as new theme</h3>
      <label><span>Name</span><input class="settings-input" value={name()} onInput={(event) => setName(event.currentTarget.value)}
        ref={(input) => queueMicrotask(() => input.focus())} /></label>
      <div class="settings-actions">
        <Action kind="quiet" onClick={() => float.close(true)}>Cancel</Action>
        <Action kind="primary" type="submit" disabled={!name().trim()}>Save</Action>
      </div>
    </form>
  );
}

export function FontChangeStrip(props: { short: boolean }) {
  const settings = prefs();
  const { ui } = settings;
  let anchor!: HTMLButtonElement;
  const changed = () => slots.filter(({ key }) => ui.fonts[key] != null);
  const name = () => themeName(ui, settings.active());
  const what = () => (changed().length === 1 ? `${changed()[0].label} changed` : "Fonts changed");
  const back = () => {
    const only = changed();
    if (only.length !== 1) return "Back to theme fonts";
    return `Back to ${fontLabel(fontsOf(ui, settings.active())[only[0].key] ?? "")}`;
  };
  return (
    <Show when={changed().length > 0}>
      <div class="font-strip" role="group" aria-label="Changed fonts">
        <p>{props.short ? `Changed on top of ${name()}` : `${what()} on top of ${name()}`}</p>
        <div>
          <Show when={customTheme(ui, settings.active())} fallback={
            <button ref={anchor} type="button" onClick={() => float.custom(anchor, 280, () => <NamePanel done={saveAsNewTheme} />)}>Save as new theme</button>
          }>
            <button type="button" onClick={() => saveFontsTo(settings.active())}>Save to {name()}</button>
          </Show>
          <button type="button" onClick={() => settings.update((draft) => { draft.fonts = {}; })}>{back()}</button>
        </div>
      </div>
    </Show>
  );
}
