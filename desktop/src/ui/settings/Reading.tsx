import { createResource, createSignal, For, Show } from "solid-js";
import { app } from "../../model/app";
import { allThemes, customTheme, fontsOf, paletteOf, prefs, themeName, type FontTokens } from "../../model/prefs";
import { css } from "../../theme/color";
import { transport } from "../../transport";
import { Action } from "../kit/Controls";
import { Icon } from "../kit/Icon";
import { PaneScroll, Row, Section, Select, Slider, Toggle } from "./Controls";
import { ThemeForm } from "./Tokens";

export const fontRows = [
  { key: "reading", label: "Reading" }, { key: "title", label: "Titles" },
  { key: "ui", label: "App" }, { key: "code", label: "Code" },
] as const;

const weights = [
  { value: -2, label: "Much lighter" }, { value: -1, label: "Lighter" }, { value: 0, label: "Normal" },
  { value: 1, label: "Bolder" }, { value: 2, label: "Much bolder" },
];
const scrollbars = [
  { value: "scrolling", label: "While scrolling" }, { value: "always", label: "Always" }, { value: "never", label: "Never" },
];

export function themeOptions() {
  const { ui } = prefs();
  return allThemes(ui).map((id) => ({ value: id, label: themeName(ui, id) }));
}

export function FontPicker(props: { label: string; value: string; change: (font: string) => void }) {
  const [open, setOpen] = createSignal(false);
  const [query, setQuery] = createSignal("");
  const [fonts] = createResource(open, () => transport().fontFamilies().catch(() => []));
  const bundled = ["Inter", "Newsreader", "Source Serif 4", "JetBrains Mono"];
  const matches = (names: string[]) => names.filter((font) => font.toLocaleLowerCase().includes(query().trim().toLocaleLowerCase()));
  function group(label: string, names: string[]) {
    return <Show when={names.length}><strong>{label}</strong><For each={names}>{(font) => (
      <button type="button" aria-pressed={font === props.value} style={{ "font-family": font }}
        onMouseDown={(event) => event.preventDefault()} onClick={() => {
          props.change(font);
          setOpen(false);
        }}>{font}</button>
    )}</For></Show>;
  }

  return (
    <div class="font-picker" onFocusOut={(event) => {
      if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setOpen(false);
    }} onKeyDown={(event) => {
      if (event.key !== "Escape" || !open()) return;
      event.preventDefault();
      event.currentTarget.querySelector("button")?.focus();
      setOpen(false);
    }}>
      <Action aria-label={`${props.label} font: ${props.value}`} aria-expanded={open()} onClick={() => { setQuery(""); setOpen(!open()); }}>
        {props.value}<Icon name="down" size={12} />
      </Action>
      <Show when={open()}>
        <div class="float-panel font-options">
          <input type="search" aria-label="Find a font" placeholder="Find a font" ref={(input) => queueMicrotask(() => input.focus())}
            value={query()} onInput={(event) => setQuery(event.currentTarget.value)} />
          <div class="font-results scroll">
            {group("Bundled", matches(bundled))}
            {group("On this computer", matches((fonts() ?? []).filter((font) => !bundled.includes(font))))}
            <Show when={fonts.loading}><span class="settings-note">Looking for fonts…</span></Show>
          </div>
        </div>
      </Show>
    </div>
  );
}

export function ThemeGallery(props: { selected: string; onSelect: (id: string) => void; onNew: () => void }) {
  const { ui } = prefs();
  return (
    <div class="theme-gallery">
      <For each={allThemes(ui)}>{(id) => {
        const palette = () => paletteOf(ui, id);
        return (
          <button type="button" class="theme-tile" aria-pressed={props.selected === id} onClick={() => props.onSelect(id)}>
            <span class="theme-sample" aria-hidden="true" style={{ background: css(palette().colors.ground), "font-family": fontsOf(ui, id).reading ?? undefined, "font-size": id === "terminal" ? "13px" : "15px" }}>
              <span style={{ color: css(palette().colors.unread) }}>Unread</span>
              <span style={{ color: css(palette().colors.read) }}>Read</span>
            </span>
            <span class="theme-name">{themeName(ui, id)}</span>
          </button>
        );
      }}</For>
      <button type="button" class="theme-tile" onClick={props.onNew}>
        <span class="theme-sample new"><Icon name="plus" /></span><span class="theme-name">New theme</span>
      </button>
    </div>
  );
}

export function activateTheme(id: string) {
  const settings = prefs();
  settings.update((draft) => {
    if (!draft.follow_system) draft.theme = id;
    else if (settings.systemIsDark()) draft.night_theme = id;
    else draft.day_theme = id;
  });
}

export function Reading() {
  const model = app();
  const settings = prefs();
  const { ui } = settings;
  const [createTheme, setCreateTheme] = createSignal<"new" | "save-fonts" | null>(null);
  const changedFonts = () => fontRows.filter(({ key }) => ui.fonts[key] != null);
  const activeCustom = () => customTheme(ui, settings.active());

  function font(key: keyof FontTokens, family: string) {
    settings.update((draft) => {
      const themeFont = fontsOf(ui, settings.active())[key];
      draft.fonts[key] = family === themeFont ? null : family;
    });
  }

  return (
    <PaneScroll>
      <Section title="Theme" detail="Colors for the whole app. Blue marks unread, purple marks read.">
        <ThemeGallery selected={settings.active()} onSelect={(id) => settings.update((draft) => {
          draft.theme = id;
          draft.follow_system = false;
        })} onNew={() => setCreateTheme("new")} />
        <Show when={createTheme()}>
          <ThemeForm source={settings.active()} copyFonts={createTheme() === "save-fonts"} close={() => setCreateTheme(null)} done={(id) => {
            const editTokens = createTheme() === "new";
            setCreateTheme(null);
            if (!editTokens) return;
            model.set("editingTheme", id);
            model.openSettings("Tokens");
          }} />
        </Show>
      </Section>
      <Section title="Day and night">
        <Row title="Follow system appearance" detail="Uses your day theme by day, your night theme at night" last={!ui.follow_system}>
          <Toggle label="Follow system appearance" on={ui.follow_system} change={(on) => settings.update((draft) => { draft.follow_system = on; })} />
        </Row>
        <Show when={ui.follow_system}>
          <Row title="Day"><Select label="Day" width={180} value={ui.day_theme} options={themeOptions()} change={(id) => settings.update((draft) => { draft.day_theme = id; })} /></Row>
          <Row title="Night" last><Select label="Night" width={180} value={ui.night_theme} options={themeOptions()} change={(id) => settings.update((draft) => { draft.night_theme = id; })} /></Row>
        </Show>
      </Section>
      <Section title="Fonts" detail="Each theme keeps its own. A change here applies to the theme in use.">
        <For each={fontRows}>{({ key, label }) => (
          <Row title={label}>
            <FontPicker label={label} value={settings.fonts()[key]!} change={(family) => font(key, family)} />
            <Select label={`${label} weight`} width={132} value={ui.weights[key]} options={weights}
              change={(value) => settings.update((draft) => { draft.weights[key] = value; })} />
          </Row>
        )}</For>
        <Row title="Colors, fonts and corners" detail="Every token of every theme" last>
          <Action onClick={() => model.openSettings("Tokens")}>Edit Tokens…</Action>
        </Row>
        <Show when={changedFonts().length > 0}>
          <div class="font-change">
            <p>{changedFonts().map(({ label }) => label).join(", ")} changed for {themeName(ui, settings.active())}</p>
            <Action kind="quiet" onClick={() => settings.update((draft) => { draft.fonts = {}; })}>Back to {themeName(ui, settings.active())}</Action>
            <Show when={activeCustom()} fallback={<Action onClick={() => setCreateTheme("save-fonts")}>Save as new theme…</Action>}>
              <Action onClick={() => settings.update((draft) => {
                const theme = customTheme(draft, settings.active());
                if (!theme) return;
                for (const { key } of changedFonts()) theme.fonts[key] = draft.fonts[key];
                draft.fonts = {};
              })}>Save to {themeName(ui, settings.active())}</Action>
            </Show>
          </div>
        </Show>
      </Section>
      <Section title="Text">
        <Slider label="Size" value={ui.text_size} min={14} max={28} step={1} change={(value) => settings.update((draft) => { draft.text_size = value; })} />
        <Slider label="Line spacing" value={ui.line_spacing} min={1.2} max={2} step={0.1} change={(value) => settings.update((draft) => { draft.line_spacing = value; })} />
        <Slider label="Column width" value={ui.column_width} min={480} max={800} step={20} change={(value) => settings.update((draft) => { draft.column_width = value; })} />
        <Row title="Show scrollbars" detail="Web pages keep their own" last>
          <Select label="Show scrollbars" value={ui.scrollbars} options={scrollbars} change={(value) => settings.update((draft) => { draft.scrollbars = value; })} />
        </Row>
      </Section>
    </PaneScroll>
  );
}
