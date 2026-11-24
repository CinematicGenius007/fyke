// The Mac's `themes` scenario (tools/e2e_gui.py): a font changed on top of a theme, from
// the text menu (t), saved to that theme, dropped, cleared by another theme, or saved as
// a new theme when the theme is built in.
import { type App, type Daemon, expect, reset, test } from "./fixtures";

test.describe.configure({ mode: "serial" });

const DUSK = { id: "dusk", name: "Dusk", base: "dark", tokens: { ground: "#1C1B29" }, fonts: { reading: "Georgia" } };
interface UI {
  theme: string;
  fonts: Record<string, string | null>;
  themes: { id: string; base: string; fonts: Record<string, string> }[];
}
const ui = async (daemon: Daemon) => (await daemon.call<{ ui: UI }>("config.get")).ui;

test.beforeEach(async ({ daemon }) => reset(daemon));
test.afterEach(async ({ daemon }) => daemon.call("config.set", { ui: {} }));

async function menu(app: App, daemon: Daemon, start: object) {
  await daemon.call("config.set", { ui: start });
  const page = await app.open({ FYKE_SCREEN: "feed" }, null);
  await page.keyboard.press("t");
  const strip = page.getByRole("region", { name: "Text and theme" }).getByRole("group", { name: "Changed fonts" });
  await expect(strip).toContainText(/Changed on top of (Dusk|Light)/);
  return { page, strip };
}

const onDusk = { theme: "dusk", follow_system: false, fonts: { reading: "Inter" }, themes: [DUSK] };

test("a temporary font saves to its theme", async ({ app, daemon }) => {
  const { strip } = await menu(app, daemon, onDusk);
  await strip.getByRole("button", { name: "Save to Dusk" }).click();
  await expect.poll(async () => (await ui(daemon)).themes[0].fonts.reading).toBe("Inter");
  expect((await ui(daemon)).fonts.reading ?? null).toBeNull();
  await expect(strip).toHaveCount(0);
});

test("a temporary font can be dropped", async ({ app, daemon }) => {
  const { strip } = await menu(app, daemon, onDusk);
  await strip.getByRole("button", { name: "Back to Georgia" }).click();
  await expect.poll(async () => (await ui(daemon)).fonts.reading ?? null).toBeNull();
  expect((await ui(daemon)).themes[0].fonts.reading).toBe("Georgia");
});

test("switching theme clears a temporary font", async ({ app, daemon }) => {
  const { page } = await menu(app, daemon, onDusk);
  await page.getByRole("region", { name: "Text and theme" }).getByRole("button", { name: "Light", exact: true }).click();
  await expect.poll(async () => (await ui(daemon)).theme).toBe("light");
  const after = await ui(daemon);
  expect(after.fonts.reading ?? null).toBeNull();
  expect(after.themes[0].fonts.reading).toBe("Georgia");
});

test("a built-in saves as a new theme instead", async ({ app, daemon }) => {
  const { page, strip } = await menu(app, daemon, { theme: "light", follow_system: false, fonts: { reading: "Inter" } });
  await strip.getByRole("button", { name: "Save as new theme" }).click();
  const panel = page.getByRole("form", { name: "Save as new theme" });
  await expect(panel.getByRole("textbox", { name: "Name" })).toBeFocused();
  await page.keyboard.type("Mine");
  await page.keyboard.press("Enter");
  await expect.poll(async () => (await ui(daemon)).theme).toBe("mine");
  const after = await ui(daemon);
  expect(after.fonts.reading ?? null).toBeNull();
  expect(after.themes[0]).toMatchObject({ base: "light", fonts: { reading: "Inter" } });
});

test("Reading settings say which font changed, and save the same way", async ({ app, daemon }) => {
  await daemon.call("config.set", { ui: onDusk });
  const page = await app.open({ FYKE_SCREEN: "settings", FYKE_TAB: "Reading" }, null);
  const strip = page.getByRole("group", { name: "Changed fonts" });
  await expect(strip).toContainText("Reading font changed on top of Dusk");
  await strip.getByRole("button", { name: "Save to Dusk" }).click();
  await expect.poll(async () => (await ui(daemon)).themes[0].fonts.reading).toBe("Inter");
});
