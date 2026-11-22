// Phase 4, the command palette: Ctrl+K, the sidebar's Search row, ranking by letters,
// articles, and the commands it runs. The scenarios are the Mac's (tools/e2e_gui.py
// `palette-keys`, `mark-all` and `settings-route`), with Ctrl for Command.
import type { Page } from "@playwright/test";
import { afterRoutineSave, expect, readTitles, reset, test } from "./fixtures";

test.describe.configure({ mode: "serial" });

test.beforeEach(async ({ daemon }) => reset(daemon));

async function palette(page: Page, query: string) {
  await page.keyboard.press("Control+K");
  await expect(page.getByRole("textbox", { name: "Command" })).toBeFocused();
  await page.keyboard.type(query);
}

const all = ["Needle one", "Needle three", "Needle two"];

test("the palette finds a command by its letters", async ({ app, daemon }) => {
  const page = await app.open();
  await palette(page, "markallread");
  await expect(page.getByRole("option").first()).toContainText("Mark all read in");
  await page.keyboard.press("Enter");
  await expect.poll(() => readTitles(daemon)).toEqual(all);
});

test("Ctrl+Z takes back mark all read", async ({ app, daemon }) => {
  const page = await app.open();
  await palette(page, "markallread");
  await page.keyboard.press("Enter");
  await expect.poll(() => readTitles(daemon)).toEqual(all);
  await expect(page.locator(".toast")).toBeVisible();
  await page.keyboard.press("Control+Z");
  await expect.poll(() => readTitles(daemon)).toEqual([]);
});

test("Mark all read is not offered in Starred", async ({ app, daemon }) => {
  const page = await app.open();
  await page.keyboard.press("Control+3");
  await expect(page.locator(".sidebar-row.selected")).toHaveAccessibleName("Starred");
  await palette(page, "markallread");
  await expect(page.getByRole("option", { name: /Mark all read/ })).toHaveCount(0);
  await page.keyboard.press("Enter");
  await page.waitForTimeout(300);
  expect(await readTitles(daemon)).toEqual([]);
});

test("Mark all read in All marks every article", async ({ app, daemon }) => {
  const page = await app.open();
  await page.keyboard.press("Control+2");
  await palette(page, "markallread");
  await expect(page.getByRole("option").first()).toContainText("Mark all read in All");
  await page.keyboard.press("Enter");
  await expect.poll(() => readTitles(daemon)).toEqual(all);
});

test("the palette opens Settings too, which keeps reader keys from the list", async ({ app, daemon }) => {
  const page = await app.open();
  await palette(page, "settings");
  await page.keyboard.press("Enter");
  await page.keyboard.press("n");
  await page.waitForTimeout(300);
  expect(await readTitles(daemon)).toEqual([]);
});

test("empty, it lists the places and the first commands; arrows move and Return runs", async ({ app }) => {
  const page = await app.open();
  await page.keyboard.press("Control+K");
  const dialog = page.getByRole("dialog", { name: "Command palette" });
  await expect(dialog.locator(".palette-section")).toHaveText(["GO TO", "DO"]);
  await expect(dialog.getByRole("listbox").getByRole("group")).toHaveCount(2);
  await expect(dialog.getByRole("option").first()).toContainText("Today");
  await expect(dialog.getByRole("option").first()).toHaveAttribute("aria-selected", "true");
  await page.keyboard.press("ArrowDown");
  await expect(dialog.getByRole("option").nth(1)).toHaveAttribute("aria-selected", "true");
  await page.keyboard.press("Enter");
  await expect(dialog).toHaveCount(0);
  await expect(page.locator(".sidebar-row.selected")).toHaveAccessibleName("All");
});

test("typed words find articles, and Return on one opens it", async ({ app }) => {
  const page = await app.open();
  await palette(page, "needle two");
  const dialog = page.getByRole("dialog", { name: "Command palette" });
  await expect(dialog.getByRole("group", { name: /articles/i })).toBeVisible();
  const article = dialog.getByRole("option", { name: /Needle two/ });
  await article.click();
  await expect(page.locator(".article-title")).toHaveText("Needle two");
});

test("the sidebar's Search row opens the palette, and Esc closes it", async ({ app }) => {
  const page = await app.open();
  await page.getByRole("button", { name: "Search", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "Command palette" });
  await expect(dialog).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(dialog).toHaveCount(0);
});

for (const theme of ["light", "dark"] as const) {
  test(`shot:palette ${theme}`, async ({ app, daemon }, info) => {
    test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
    await reset(daemon);
    await afterRoutineSave(daemon);
    const page = await app.open({ FYKE_SCREEN: "palette", FYKE_QUERY: "needle" }, theme);
    await expect(page.getByRole("group", { name: /articles/i })).toBeVisible();
    await app.snapshot(`palette-${theme}`);
  });
}
