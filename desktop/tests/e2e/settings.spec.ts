import { afterRoutineSave, expect, readTitles, reset, test } from "./fixtures";

test.beforeEach(async ({ daemon }) => {
  await reset(daemon);
  await daemon.call("config.set", { ui: {}, full_text: true, remove_read_after_days: 0 });
});

test.afterEach(async ({ daemon }) => {
  await daemon.call("config.set", { ui: {}, full_text: true, remove_read_after_days: 0 });
});

test("Settings keeps reader keys out and Esc returns them to the reader", async ({ app, daemon }) => {
  const page = await app.open();
  await page.keyboard.press("Control+,");
  const settings = page.getByRole("region", { name: "Settings" });
  await expect(settings.getByRole("button", { name: "General", exact: true })).toHaveAttribute("aria-pressed", "true");
  await page.keyboard.press("n");
  expect(await readTitles(daemon)).toEqual([]);
  await page.keyboard.press("Escape");
  await expect(settings).toHaveCount(0);
  await page.keyboard.press("n");
  await expect.poll(() => readTitles(daemon)).toEqual(["Needle one"]);

  await page.keyboard.press("Control+k");
  await page.getByRole("textbox", { name: "Command" }).fill("Settings Agents");
  await page.keyboard.press("Enter");
  await expect(settings.getByRole("button", { name: "Agents", exact: true })).toHaveAttribute("aria-pressed", "true");
  await expect(settings.getByRole("combobox", { name: "What agents may change" })).toHaveValue("read");
  await page.keyboard.press("Control+2");
  await expect(settings).toHaveCount(0);
});

test("General stores article fetch, image and link preferences", async ({ app, daemon }) => {
  const screen = { FYKE_SCREEN: "settings", FYKE_TAB: "General" };
  const page = await app.open(screen, null);
  await page.getByRole("switch", { name: "Fetch full articles" }).click();
  await page.getByRole("switch", { name: "Load images automatically" }).click();
  await page.getByRole("combobox", { name: "Open links" }).selectOption("browser");
  await expect.poll(() => daemon.call("config.get")).toMatchObject({
    full_text: false, ui: { load_images: true, open_links: "browser" },
  });
  await app.open(screen, null);
  await expect(page.getByRole("switch", { name: "Fetch full articles" })).not.toBeChecked();
  await expect(page.getByRole("switch", { name: "Load images automatically" })).toBeChecked();
  await expect(page.getByRole("combobox", { name: "Open links" })).toHaveValue("browser");
});

test("Reading saves independent font weights and temporary fonts clear when the theme changes", async ({ app, daemon }) => {
  const screen = { FYKE_SCREEN: "settings", FYKE_TAB: "Reading" };
  const page = await app.open(screen, null);
  await page.getByRole("combobox", { name: "Reading weight" }).selectOption("-1");
  await page.getByRole("combobox", { name: "Titles weight" }).selectOption("1");
  await page.getByRole("button", { name: /^Reading font:/ }).click();
  await page.getByRole("searchbox", { name: "Find a font" }).fill("JetBrains");
  await page.getByRole("button", { name: "JetBrains Mono", exact: true }).click();
  await expect.poll(() => daemon.call("config.get")).toMatchObject({
    ui: { weights: { reading: -1, title: 1 }, fonts: { reading: "JetBrains Mono" } },
  });
  await page.getByRole("button", { name: "Newsprint", exact: true }).click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "newsprint");
  await expect.poll(() => daemon.call("config.get")).toMatchObject({
    ui: { theme: "newsprint", follow_system: false, fonts: { reading: null } },
  });
  await app.open(screen, null);
  await expect(page.getByRole("combobox", { name: "Reading weight" })).toHaveValue("-1");
  await expect(page.getByRole("combobox", { name: "Titles weight" })).toHaveValue("1");
});

test("the article's text controls change the size and open Reading settings", async ({ app, daemon }) => {
  const page = await app.open({ FYKE_SCREEN: "all" }, null);
  await page.keyboard.press("t");
  const menu = page.getByRole("region", { name: "Text and theme" });
  await expect(menu).toBeVisible();
  await menu.getByRole("button", { name: "Increase text size" }).click();
  await expect.poll(() => daemon.call("config.get")).toMatchObject({ ui: { text_size: 20 } });
  await menu.getByRole("button", { name: "More in Settings" }).click();
  await expect(page.getByRole("button", { name: "Reading", exact: true })).toHaveAttribute("aria-pressed", "true");
});

test("Tokens creates a custom theme, edits a color, and returns to its base when deleted", async ({ app, daemon }) => {
  const page = await app.open({ FYKE_SCREEN: "settings", FYKE_TAB: "Reading" }, null);
  await page.getByRole("button", { name: "Edit Tokens…" }).click();
  await expect(page.getByRole("button", { name: /^Ground #/ })).toBeDisabled();
  await page.getByRole("button", { name: "Duplicate to edit" }).click();
  await page.getByRole("textbox", { name: "Name", exact: true }).fill("Paper");
  await page.getByRole("button", { name: "Create theme" }).click();
  await page.getByRole("button", { name: /^Ground #/ }).click();
  await page.getByRole("textbox", { name: "Hex" }).fill("#F2EEE6");
  await page.getByRole("button", { name: "Apply", exact: true }).click();
  await expect.poll(() => daemon.call("config.get")).toMatchObject({
    ui: { themes: [{ id: "paper", base: "light", tokens: { ground: "#F2EEE6" } }] },
  });
  await page.getByRole("button", { name: "‹ Reading" }).click();
  await page.getByRole("button", { name: "Paper", exact: true }).click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "paper");
  await page.getByRole("button", { name: "Edit Tokens…" }).click();
  await page.getByRole("button", { name: "Delete…", exact: true }).click();
  await page.getByRole("button", { name: "Delete theme", exact: true }).click();
  await expect(page.locator("html")).toHaveAttribute("data-theme", "light");
  await expect.poll(() => daemon.call("config.get")).toMatchObject({ ui: { theme: "light", themes: [] } });
});

test("Data measures storage, saves retention and asks before trimming", async ({ app, daemon }) => {
  const page = await app.open({ FYKE_SCREEN: "settings", FYKE_TAB: "Data" }, null);
  await expect(page.getByText("Used in all", { exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "Change…" })).toBeDisabled();
  await expect(page.getByText("3 articles in 1 feeds.")).toBeVisible();
  await page.getByRole("combobox", { name: "Remove read articles after" }).selectOption("90");
  await expect.poll(() => daemon.call("config.get")).toMatchObject({ remove_read_after_days: 90 });
  await page.getByRole("button", { name: "Free up space…", exact: true }).click();
  await expect(page.getByText(/Titles, links and starred articles stay/)).toBeVisible();
  await page.getByRole("button", { name: "Cancel", exact: true }).click();
  await expect(page.getByText(/Titles, links and starred articles stay/)).toHaveCount(0);
});

for (const theme of ["light", "dark"] as const) {
  for (const tab of ["General", "Reading", "Tokens", "Agents", "Data"]) {
    test(`shot:settings-${tab.toLowerCase()} ${theme}`, async ({ app, daemon }, info) => {
      test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
      await afterRoutineSave(daemon);
      const page = await app.open({ FYKE_SCREEN: "settings", FYKE_TAB: tab }, theme);
      if (tab === "Data") await expect(page.getByText("Used in all", { exact: true })).toBeVisible();
      if (tab === "Agents") await expect(page.getByRole("button", { name: "Copy MCP config" })).toBeVisible();
      await app.snapshot(`settings-${tab.toLowerCase()}-${theme}`);
    });
  }
}

// The Mac's `font-weight` check draws Reading in light with these weights saved.
test("shot:settings-reading-weights", async ({ app, daemon }, info) => {
  test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
  await daemon.call("config.set", { ui: { weights: { reading: -1, title: 1, ui: 0, code: 0 } } });
  const page = await app.open({ FYKE_SCREEN: "settings", FYKE_TAB: "Reading" }, "light");
  await expect(page.getByRole("region", { name: "Settings" })).toBeVisible();
  await app.snapshot("settings-reading-weights");
  expect((await daemon.call<{ ui: { weights?: unknown } }>("config.get")).ui.weights).toEqual({ reading: -1, title: 1, ui: 0, code: 0 });
});
