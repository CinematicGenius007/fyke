import { createEffect, createRoot } from "solid-js";
import { render } from "solid-js/web";
import "./styles/fonts.css";
import "./styles/base.css";
import "./styles/app.css";
import "./styles/settings.css";
import { app } from "./model/app";
import { prefs } from "./model/prefs";
import { applyFonts, applyPalette, applyRadii, applyWeights } from "./theme/apply";
import { measureLineHeights } from "./theme/metrics";
import { transport } from "./transport";
import { App } from "./ui/App";

/** Test mode from the app's environment, and in a browser also from the page's address. */
async function testMode() {
  const fromApp = await transport()
    .testMode()
    .catch((): Record<string, string> => ({}));
  const fromPage = Object.fromEntries([...new URLSearchParams(window.location.search)].filter(([name]) => name.startsWith("FYKE_")));
  return {
    mode: { ...fromApp, ...fromPage },
    localFeeds: fromApp.FYKE_HEADLESS === "1" && fromApp.FYKE_LOCAL_FEEDS === "1",
  };
}

/** Theme, fonts, weights and radii follow the settings as they change. */
function followTheme() {
  createRoot(() => {
    const system = window.matchMedia("(prefers-color-scheme: dark)");
    prefs().setSystemIsDark(system.matches);
    system.addEventListener("change", (event) => prefs().setSystemIsDark(event.matches));
    createEffect(() => applyPalette(prefs().palette()));
    createEffect(() => {
      const fonts = prefs().fonts();
      applyFonts(fonts);
      void document.fonts.ready.then(() => measureLineHeights());
    });
    createEffect(() => applyWeights(prefs().ui.weights));
    createEffect(() => applyRadii(prefs().radii()));
    createEffect(() => { document.documentElement.dataset.scrollbars = prefs().ui.scrollbars; });
  });
}

/** The window chrome Fyke draws (src/ui/Chrome.tsx): the system's in the app, none in a
 * browser, where the tab has its own. `FYKE_CHROME` picks one for the checks. */
function chooseChrome(mode: Record<string, string>) {
  const asked = mode.FYKE_CHROME;
  const inApp = "__TAURI_INTERNALS__" in window;
  const agent = navigator.userAgent;
  const kind = asked ?? (!inApp || agent.includes("Macintosh") ? "none" : agent.includes("Windows") ? "windows" : "linux");
  if (kind === "windows" || kind === "linux") document.documentElement.dataset.chrome = kind;
}

async function start() {
  const { mode, localFeeds } = await testMode();
  chooseChrome(mode);
  if (mode.FYKE_THEME) prefs().force(mode.FYKE_THEME);
  followTheme();
  render(() => <App localFeeds={localFeeds} />, document.getElementById("root")!);
  await app().start(() => app().openScreen(mode));
  await transport().observeSettings(() => void prefs().load()).catch(() => undefined);
  await document.fonts.ready;
  measureLineHeights();
  // Test mode's pictures wait for the screen to settle, as the Mac's do.
  const settle = Number.parseFloat(mode.FYKE_SNAPSHOT_DELAY ?? "0");
  if (settle > 0) await new Promise((r) => setTimeout(r, Math.min(settle, 3) * 1000));
  document.documentElement.dataset.ready = "1";
  await transport()
    .ready()
    .catch(() => undefined);
}

void start();
