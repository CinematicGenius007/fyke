import { render } from "solid-js/web";
import "./styles/fonts.css";
import "./styles/base.css";
import { applyFonts, applyPalette } from "./theme/apply";
import { builtIn } from "./theme/palette";
import { transport } from "./transport";
import { App } from "./ui/App";

/** Test mode from the app's environment, and in a browser also from the page's address. */
async function testMode(): Promise<Record<string, string>> {
  const fromApp = await transport().testMode().catch(() => ({}));
  const fromPage = Object.fromEntries([...new URLSearchParams(window.location.search)].filter(([name]) => name.startsWith("FYKE_")));
  return { ...fromApp, ...fromPage };
}

async function start() {
  const mode = await testMode();
  const dark = mode.FYKE_THEME ? mode.FYKE_THEME === "dark" : window.matchMedia("(prefers-color-scheme: dark)").matches;
  applyPalette(builtIn(mode.FYKE_THEME ?? (dark ? "dark" : "light")));
  applyFonts({});
  render(() => <App />, document.getElementById("root")!);
  await document.fonts.ready;
  document.documentElement.dataset.ready = "1";
  await transport().ready().catch(() => undefined);
}

void start();
