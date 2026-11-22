import { createSignal, For, Show } from "solid-js";
import { app } from "../../model/app";
import { allThemes, customTheme, fontsOf, paletteOf, prefs, radiiOf, themeName, type CustomTheme, type RadiusTokens, type UISettings } from "../../model/prefs";
import { contrast, css, parseHex, toHex } from "../../theme/color";
import { tokenLabels, tokenNames, tokens, wireName, type TokenName } from "../../theme/palette";
import { Action, SymbolButton } from "../kit/Controls";
import { Icon } from "../kit/Icon";
import { PaneScroll, Row, Select, Slider } from "./Controls";
import { fontRows, FontPicker, themeOptions } from "./Reading";

/** A free id for a theme named `title`. */
export function newThemeId(ui: UISettings, title: string): string {
  const slug = title.toLowerCase().replace(/[^\p{L}\p{N}]/gu, "-") || "theme";
  const existing = new Set(allThemes(ui));
  let id = slug;
  for (let suffix = 2; existing.has(id); suffix++) id = `${slug}-${suffix}`;
  return id;
}

export function ThemeForm(props: { source: string; close: () => void; done: (id: string) => void }) {
  const settings = prefs();
  const [name, setName] = createSignal("");
  const [source, setSource] = createSignal(props.source);

  function create() {
    const title = name().trim();
    if (!title) return;
    const id = newThemeId(settings.ui, title);
    settings.update((draft) => {
      const original = customTheme(draft, source());
      const theme: CustomTheme = {
        id, name: title, base: original?.base ?? source(),
        tokens: { ...original?.tokens }, fonts: { ...original?.fonts }, radii: { ...original?.radii },
      };
      draft.themes.push(theme);
    });
    props.done(id);
  }

  return (
    <form class="settings-inline-panel" onSubmit={(event) => { event.preventDefault(); create(); }}>
      <h3>New theme</h3>
      <label>Name<input class="settings-input" value={name()} onInput={(event) => setName(event.currentTarget.value)} ref={(input) => queueMicrotask(() => input.focus())} /></label>
      <label>Start from<Select label="Start from" value={source()} options={themeOptions()} change={setSource} /></label>
      <div class="settings-actions"><Action onClick={props.close}>Cancel</Action><Action kind="primary" type="submit" disabled={!name().trim()}>Create theme</Action></div>
    </form>
  );
}

export function Tokens() {
  const model = app();
  const settings = prefs();
  const { ui } = settings;
  const id = () => model.state.editingTheme && allThemes(ui).includes(model.state.editingTheme) ? model.state.editingTheme : settings.active();
  const custom = () => customTheme(ui, id());
  const palette = () => paletteOf(ui, id());
  const radius = () => radiiOf(ui, id());
  const [panel, setPanel] = createSignal<"new" | "rename" | "delete" | null>(null);
  const [name, setName] = createSignal("");
  const [editingColor, setEditingColor] = createSignal<TokenName | null>(null);
  const count = () => {
    const theme = custom();
    if (!theme) return 0;
    return [theme.tokens, theme.fonts, theme.radii].flatMap((group) => Object.values(group)).filter((value) => value != null).length;
  };

  function edit(change: (theme: CustomTheme) => void) {
    settings.update((draft) => {
      const theme = customTheme(draft, id());
      if (theme) change(theme);
    });
  }

  function remove() {
    const theme = custom();
    if (!theme) return;
    settings.update((draft) => {
      draft.themes = draft.themes.filter((item) => item.id !== theme.id);
      for (const slot of ["theme", "day_theme", "night_theme"] as const) {
        if (draft[slot] === theme.id) draft[slot] = theme.base;
      }
    });
    model.set("editingTheme", theme.base);
    setPanel(null);
  }

  function select(theme: string) {
    model.set("editingTheme", theme);
    setPanel(null);
    setEditingColor(null);
  }

  return (
    <PaneScroll>
      <div class="tokens-editor">
        <Action kind="quiet" compact onClick={() => model.openSettings("Reading")}>‹ Reading</Action>
        <div class="tokens-themes">
          <For each={allThemes(ui)}>{(theme) => <button type="button" aria-pressed={id() === theme} onClick={() => select(theme)}>{themeName(ui, theme)}</button>}</For>
          <button type="button" onClick={() => setPanel("new")}><Icon name="plus" size={13} />New theme</button>
        </div>
        <div class="tokens-header">
          <div><strong>{themeName(ui, id())}</strong>
            <p class="settings-note">{custom() ? `Based on ${themeName(ui, custom()!.base)}, ${count()} ${count() === 1 ? "change" : "changes"}` : "Built in, so it stays as designed"}</p></div>
          <div class="settings-actions">
            <Show when={custom()} fallback={<Action kind="primary" onClick={() => setPanel("new")}>Duplicate to edit</Action>}>
              <Show when={count()}><Action kind="quiet" onClick={() => edit((theme) => {
                theme.tokens = {};
                theme.fonts = {};
                theme.radii = {};
              })}>Reset all</Action></Show>
              <Action onClick={() => { setName(custom()!.name); setPanel("rename"); }}>Rename</Action>
              <Action onClick={() => setPanel("delete")}>Delete…</Action>
            </Show>
          </div>
        </div>
        <Show when={panel() === "new"}><ThemeForm source={id()} close={() => setPanel(null)} done={select} /></Show>
        <Show when={panel() === "rename"}>
          <form class="settings-inline-panel" onSubmit={(event) => {
            event.preventDefault();
            if (!name().trim()) return;
            edit((theme) => { theme.name = name().trim(); });
            setPanel(null);
          }}>
            <label>Rename theme<input class="settings-input" ref={(input) => queueMicrotask(() => input.select())} value={name()} onInput={(event) => setName(event.currentTarget.value)} /></label>
            <div class="settings-actions"><Action onClick={() => setPanel(null)}>Cancel</Action><Action type="submit" kind="primary" disabled={!name().trim()}>Rename</Action></div>
          </form>
        </Show>
        <Show when={panel() === "delete"}>
          <div class="settings-inline-panel">
            <p>Delete {themeName(ui, id())}? Anywhere that uses it will return to {custom() && themeName(ui, custom()!.base)}.</p>
            <div class="settings-actions"><Action onClick={() => setPanel(null)}>Cancel</Action><Action kind="primary" onClick={remove}>Delete theme</Action></div>
          </div>
        </Show>
        <details open>
          <summary>Color</summary>
          <For each={tokenNames}>{(token) => {
            const value = () => toHex(palette().colors[token]);
            const label = tokenLabels[token];
            return (
              <div>
                <div class="color-token-row" classList={{ changed: custom()?.tokens[wireName[token]] != null }}>
                  <button type="button" class="token-colour" disabled={!custom()} aria-expanded={editingColor() === token} onClick={() => setEditingColor(editingColor() === token ? null : token)}>
                    <span style={{ background: css(palette().colors[token]) }} />{label}<code>{value()}</code>
                  </button>
                  <SymbolButton icon="reload" label={`Reset ${label}`} disabled={custom()?.tokens[wireName[token]] == null} size={18} iconSize={14}
                    onClick={() => edit((theme) => { delete theme.tokens[wireName[token]]; })} />
                </div>
                <Show when={editingColor() === token && custom()}>
                  <ColorEditor value={value()} ground={palette().colors.ground} close={() => setEditingColor(null)} change={(hex) => edit((theme) => {
                    const inherited = toHex(paletteOf(ui, theme.base).colors[token]);
                    if (hex === inherited) delete theme.tokens[wireName[token]];
                    else theme.tokens[wireName[token]] = hex;
                  })} />
                </Show>
              </div>
            );
          }}</For>
        </details>
        <details>
          <summary>Fonts <span>{Object.values(fontsOf(ui, id())).join(", ")}</span></summary>
          <For each={fontRows}>{({ key, label }) => (
            <Row title={label}>
              <Show when={custom()} fallback={<span class="settings-note">{fontsOf(ui, id())[key]}</span>}>
                <Show when={custom()?.fonts[key]}><Action compact kind="quiet" aria-label={`Reset ${label} font`} onClick={() => edit((theme) => { delete theme.fonts[key]; })}>Reset</Action></Show>
                <FontPicker label={label} value={fontsOf(ui, id())[key]!} change={(family) => edit((theme) => {
                  if (family === fontsOf(ui, theme.base)[key]) delete theme.fonts[key];
                  else theme.fonts[key] = family;
                })} />
              </Show>
            </Row>
          )}</For>
        </details>
        <details>
          <summary>Radius <span>{radius().control}, {radius().panel}, {radius().sheet}</span></summary>
          <For each={[["control", "Controls"], ["panel", "Panels"], ["sheet", "Sheets"]] as [keyof RadiusTokens, string][]}>{([key, label]) => (
            <Show when={custom()} fallback={<Row title={label}><span class="setting-number">{radius()[key]}</span></Row>}>
              <Slider label={label} value={radius()[key]!} min={0} max={24} step={1} change={(value) => edit((theme) => {
                if (value === tokens.radii[key]) delete theme.radii[key];
                else theme.radii[key] = value;
              })} />
            </Show>
          )}</For>
        </details>
        <p class="settings-note">Saved in config.json. Edit it there and the app follows.</p>
      </div>
    </PaneScroll>
  );
}

function ColorEditor(props: { value: string; ground: ReturnType<typeof paletteOf>["colors"]["ground"]; close: () => void; change: (hex: string) => void }) {
  const [hex, setHex] = createSignal(props.value);
  const parsed = () => parseHex(hex().trim());
  return (
    <form class="settings-inline-panel color-editor" onSubmit={(event) => {
      event.preventDefault();
      const color = parsed();
      if (!color) return;
      props.change(toHex(color));
      props.close();
    }}>
      <label>Color<input class="settings-input" type="color" value={(parsed() ? toHex(parsed()!) : props.value).slice(0, 7)} onInput={(event) => setHex(event.currentTarget.value)} /></label>
      <label>Hex<input class="settings-input" value={hex()} aria-invalid={!parsed()} onInput={(event) => setHex(event.currentTarget.value)} /></label>
      <Show when={parsed()}>{(color) => <span class="settings-note">Contrast on ground {contrast(color(), props.ground).toFixed(2)}:1</span>}</Show>
      <div class="settings-actions"><Action onClick={props.close}>Cancel</Action><Action kind="primary" type="submit" disabled={!parsed()}>Apply</Action></div>
    </form>
  );
}
