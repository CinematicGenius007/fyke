// Every setting the app has lives under `ui` in config.json, as on the Mac
// (gui/Sources/Reader/Prefs.swift). The owner can edit that file by hand, so it is the
// only copy: the daemon writes it, and this store follows. Keys keep the file's
// snake_case spelling.
import { createRoot, createSignal } from "solid-js";
import { createStore, reconcile, unwrap } from "solid-js/store";
import { applying, builtIn, builtIns, type Palette, type ThemeTokens, tokens } from "../theme/palette";
import { transport } from "../transport";

export interface FontTokens {
  reading?: string | null;
  title?: string | null;
  ui?: string | null;
  code?: string | null;
}

/** Steps lighter (negative) or bolder, from 0, for each kind of text. */
export interface FontWeights {
  reading: number;
  title: number;
  ui: number;
  code: number;
}

export interface RadiusTokens {
  control?: number | null;
  panel?: number | null;
  sheet?: number | null;
}

export interface CustomTheme {
  id: string;
  name: string;
  base: string;
  tokens: ThemeTokens;
  fonts: FontTokens;
  radii: RadiusTokens;
}

export interface UISettings {
  theme: string;
  follow_system: boolean;
  day_theme: string;
  night_theme: string;
  text_size: number;
  line_spacing: number;
  column_width: number;
  /** Width of the article list beside the reader (D1). */
  list_width: number;
  load_images: boolean;
  /** `app` or `browser`. */
  open_links: string;
  /** `scrolling`, `always` or `never`. */
  scrollbars: string;
  agent_tier: string;
  collapsed_folders: number[];
  /** Temporary fonts on top of the active theme, until the theme changes. */
  fonts: FontTokens;
  themes: CustomTheme[];
  weights: FontWeights;
}

export const defaults = (): UISettings => ({
  theme: "light",
  follow_system: true,
  day_theme: "light",
  night_theme: "dark",
  text_size: 19,
  line_spacing: 1.6,
  column_width: 640,
  list_width: 368,
  load_images: false,
  open_links: "app",
  scrollbars: "scrolling",
  agent_tier: "read",
  collapsed_folders: [],
  fonts: {},
  themes: [],
  weights: { reading: 0, title: 0, ui: 0, code: 0 },
});

const clampStep = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? Math.min(Math.max(Math.trunc(value), -2), 2) : 0);

function pick<T>(value: unknown, fallback: T, check: (v: unknown) => boolean): T {
  return value !== undefined && value !== null && check(value) ? (value as T) : fallback;
}

const isString = (v: unknown) => typeof v === "string";
const isNumber = (v: unknown) => typeof v === "number" && Number.isFinite(v);
const isBool = (v: unknown) => typeof v === "boolean";
const isObject = (v: unknown) => typeof v === "object" && v !== null && !Array.isArray(v);

function theme(raw: unknown): CustomTheme | null {
  if (!isObject(raw)) return null;
  const r = raw as Record<string, unknown>;
  if (!isString(r.id) || !isString(r.name)) return null;
  return {
    id: r.id as string,
    name: r.name as string,
    base: pick(r.base, "light", isString),
    tokens: pick(r.tokens, {}, isObject),
    fonts: pick(r.fonts, {}, isObject),
    radii: pick(r.radii, {}, isObject),
  };
}

/** A hand-written file may hold any subset of these, and anything wrong is a default. */
export function decodeUI(raw: unknown): UISettings {
  const d = defaults();
  if (!isObject(raw)) return d;
  const r = raw as Record<string, unknown>;
  const weights = isObject(r.weights) ? (r.weights as Record<string, unknown>) : {};
  return {
    theme: pick(r.theme, d.theme, isString),
    follow_system: pick(r.follow_system, d.follow_system, isBool),
    day_theme: pick(r.day_theme, d.day_theme, isString),
    night_theme: pick(r.night_theme, d.night_theme, isString),
    text_size: pick(r.text_size, d.text_size, isNumber),
    line_spacing: pick(r.line_spacing, d.line_spacing, isNumber),
    column_width: pick(r.column_width, d.column_width, isNumber),
    list_width: pick(r.list_width, d.list_width, isNumber),
    load_images: pick(r.load_images, d.load_images, isBool),
    open_links: pick(r.open_links, d.open_links, isString),
    scrollbars: pick(r.scrollbars, d.scrollbars, isString),
    agent_tier: pick(r.agent_tier, d.agent_tier, isString),
    collapsed_folders: Array.isArray(r.collapsed_folders) ? r.collapsed_folders.filter((v): v is number => Number.isInteger(v)) : d.collapsed_folders,
    fonts: pick(r.fonts, d.fonts, isObject),
    themes: Array.isArray(r.themes) ? r.themes.map(theme).filter((t): t is CustomTheme => t !== null) : d.themes,
    weights: { reading: clampStep(weights.reading), title: clampStep(weights.title), ui: clampStep(weights.ui), code: clampStep(weights.code) },
  };
}

// MARK: Themes, fonts and weights (Prefs.swift and Theme.swift)

export const allThemes = (ui: UISettings) => [...builtIns, ...ui.themes.map((t) => t.id)];
export const customTheme = (ui: UISettings, id: string) => ui.themes.find((t) => t.id === id);
export const themeName = (ui: UISettings, id: string) => customTheme(ui, id)?.name ?? id.slice(0, 1).toUpperCase() + id.slice(1);

/** A saved choice may name a theme since deleted. */
const known = (ui: UISettings, id: string) => (allThemes(ui).includes(id) ? id : "light");

export function activeTheme(ui: UISettings, systemIsDark: boolean): string {
  return known(ui, ui.follow_system ? (systemIsDark ? ui.night_theme : ui.day_theme) : ui.theme);
}

function builtInFonts(id: string): Required<FontTokens> {
  // Terminal's look is its typeface as much as its colors.
  const text = id === "terminal" ? tokens.fonts.code : tokens.fonts.reading;
  return { reading: text, title: text, ui: tokens.fonts.ui, code: tokens.fonts.code };
}

/** A theme's fonts with nothing left unset. */
export function fontsOf(ui: UISettings, id: string): Required<FontTokens> {
  const custom = customTheme(ui, id);
  const base = builtInFonts(custom?.base ?? id);
  const own = custom?.fonts ?? {};
  return { reading: own.reading ?? base.reading, title: own.title ?? base.title, ui: own.ui ?? base.ui, code: own.code ?? base.code };
}

/** What is on screen: the active theme's fonts, under any temporary change. */
export function currentFonts(ui: UISettings, systemIsDark: boolean): Required<FontTokens> {
  const theme = fontsOf(ui, activeTheme(ui, systemIsDark));
  return {
    reading: ui.fonts.reading ?? theme.reading,
    title: ui.fonts.title ?? theme.title,
    ui: ui.fonts.ui ?? theme.ui,
    code: ui.fonts.code ?? theme.code,
  };
}

export function paletteOf(ui: UISettings, id: string): Palette {
  const custom = customTheme(ui, id);
  return custom ? applying(builtIn(custom.base), custom.tokens, custom.id) : builtIn(id);
}

export function radiiOf(ui: UISettings, id: string): Required<RadiusTokens> {
  const own = customTheme(ui, id)?.radii ?? {};
  return { control: own.control ?? tokens.radii.control, panel: own.panel ?? tokens.radii.panel, sheet: own.sheet ?? tokens.radii.sheet };
}

/** The weights from light to black, as `Font.Weight.shifted` steps through them. */
export const weightLadder = [100, 200, 300, 400, 500, 600, 700, 800, 900] as const;

export function shifted(weight: number, steps: number): number {
  const at = weightLadder.indexOf(weight as (typeof weightLadder)[number]);
  if (steps === 0 || at < 0) return weight;
  return weightLadder[Math.min(Math.max(at + steps, 0), weightLadder.length - 1)];
}

// MARK: The store

function createPrefs() {
  const [ui, setUI] = createStore<UISettings>(defaults());
  const [systemIsDark, setSystemIsDark] = createSignal(false);
  const [fileProblem, setFileProblem] = createSignal<string | null>(null);
  const [fullText, setFullText] = createSignal(true);
  const [retention, setRetention] = createSignal(0);
  /** Test mode's theme, for this run only (D18). It is never saved. */
  let forcedTheme: string | null = null;
  /** False until `ui` holds what config.json says, and while the file is broken. */
  let readFile = false;
  let pendingSave: ReturnType<typeof setTimeout> | null = null;
  let saving = false;
  let patch: Partial<UISettings> = {};
  let lastTheme = "light";

  const active = () => activeTheme(ui, systemIsDark());

  function withTestMode(settings: UISettings): UISettings {
    return forcedTheme ? { ...settings, theme: forcedTheme, follow_system: false } : settings;
  }

  /** Every theme has its own fonts, so a temporary font goes when its theme does. */
  function clearFontsIfThemeChanged() {
    const theme = active();
    if (theme === lastTheme) return;
    lastTheme = theme;
    if (Object.values(ui.fonts).some((v) => v != null)) setUI("fonts", reconcile({}));
  }

  async function load(): Promise<void> {
    try {
      const reply = (await transport().call("config.get")) as Record<string, unknown>;
      setFullText(reply.full_text !== false);
      setRetention(typeof reply.remove_read_after_days === "number" ? reply.remove_read_after_days : 0);
      const problem = typeof reply.config_error === "string" ? reply.config_error : null;
      setFileProblem(problem);
      if (problem) {
        readFile = false;
        return;
      }
      // A change waiting to be saved is newer than what the file held.
      if (pendingSave || saving) return;
      setUI(reconcile(withTestMode(decodeUI(reply.ui))));
      lastTheme = active();
      readFile = true;
    } catch (error) {
      setFileProblem(error instanceof Error ? error.message : String((error as { message?: string }).message ?? error));
      readFile = false;
    }
  }

  function save() {
    if (!readFile || forcedTheme) return;
    if (pendingSave) clearTimeout(pendingSave);
    pendingSave = setTimeout(() => {
      pendingSave = null;
      if (!saving) void flush();
    }, 300);
  }

  async function setConfig(params: object) {
    try {
      await transport().call("config.set", params);
      return true;
    } catch (error) {
      setFileProblem(error instanceof Error ? error.message : String(error));
      return false;
    }
  }

  async function flush() {
    if (!Object.keys(patch).length) return;
    saving = true;
    const changes = patch;
    patch = {};
    await setConfig({ ui_patch: changes });
    saving = false;
    if (!pendingSave) void flush();
  }

  /** Changes settings, then saves them after 300 ms of quiet. */
  function update(change: (draft: UISettings) => void) {
    const before = structuredClone(unwrap(ui));
    const draft = structuredClone(before);
    change(draft);
    setUI(reconcile(draft));
    clearFontsIfThemeChanged();
    if (!readFile || forcedTheme) return;
    const settings = structuredClone(unwrap(ui));
    for (const key of Object.keys(settings) as (keyof UISettings)[]) {
      if (JSON.stringify(before[key]) === JSON.stringify(settings[key])) continue;
      if (key === "fonts" || key === "weights") {
        const changes = { ...patch[key] };
        for (const slot of ["reading", "title", "ui", "code"] as const) {
          if (before[key][slot] !== settings[key][slot]) Object.assign(changes, { [slot]: settings[key][slot] ?? null });
        }
        Object.assign(patch, { [key]: changes });
      } else {
        Object.assign(patch, { [key]: settings[key] });
      }
    }
    save();
  }

  return {
    ui,
    update,
    load,
    active,
    fileProblem,
    fullText,
    retention,
    async setFullText(on: boolean) {
      if (await setConfig({ full_text: on })) setFullText(on);
    },
    async setRetention(days: number) {
      if (await setConfig({ remove_read_after_days: days })) setRetention(days);
    },
    systemIsDark,
    setSystemIsDark(dark: boolean) {
      setSystemIsDark(dark);
      clearFontsIfThemeChanged();
    },
    /** Test mode only: shows `id` for this run, and saves nothing. */
    force(id: string) {
      forcedTheme = id;
      setUI(reconcile(withTestMode(structuredClone(unwrap(ui)))));
      lastTheme = active();
    },
    palette: () => paletteOf(ui, active()),
    fonts: () => currentFonts(ui, systemIsDark()),
    radii: () => radiiOf(ui, active()),
  };
}

export type Prefs = ReturnType<typeof createPrefs>;

let shared: Prefs | undefined;

/** The one settings store, made on first use. */
export function prefs(): Prefs {
  shared ??= createRoot(createPrefs);
  return shared;
}
