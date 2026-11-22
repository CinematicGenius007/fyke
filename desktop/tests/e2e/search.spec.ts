// Phase 4, search: the panel, its keys and saving a search as a view. The scenarios are
// the Mac's (tools/e2e_gui.py `keys` and `view-save`), with Ctrl for Command.
import type { Page } from "@playwright/test";
import { afterRoutineSave, expect, readTitles, reset, test, viewNames } from "./fixtures";

/** Plays the Mac's key words: `ctrl+f`, `esc`, `return`, `up`, `down`, or text to type. */
async function play(page: Page, keys: string) {
  const named: Record<string, string> = { esc: "Escape", return: "Enter", up: "ArrowUp", down: "ArrowDown" };
  for (const word of keys.split(" ")) {
    if (word.startsWith("ctrl+")) await page.keyboard.press(`Control+${word.slice(5).toUpperCase()}`);
    else if (named[word]) await page.keyboard.press(named[word]);
    else if (word === "/") await page.keyboard.press("Slash");
    else if (word === "?") await page.keyboard.type("?");
    else if (word === "j") await page.keyboard.press("j");
    else {
      await page.keyboard.type(word);
      // The panel waits for a pause in typing; the Mac's player waits a beat as well.
      await expect(page.locator(".search-count, .search-none")).toBeVisible();
    }
  }
}

test.describe.configure({ mode: "serial" });

test.beforeEach(async ({ daemon }) => reset(daemon));

const scenarios: [string, string, string[]][] = [
  ["Ctrl+F, type and Return opens the first result", "ctrl+f needle return", ["Needle one"]],
  ["/ opens search too", "/ needle return", ["Needle one"]],
  ["the down arrow moves the selection", "ctrl+f needle down return", ["Needle two"]],
  ["the up arrow moves it back", "ctrl+f needle down down up return", ["Needle two"]],
  ["selection stops at both ends", "ctrl+f needle up up down down down down return", ["Needle three"]],
  ["Esc closes without opening", "ctrl+f needle esc return", []],
  ["keys reach the list again after Esc", "ctrl+f needle esc down return", ["Needle one"]],
  ["? shows shortcuts and swallows keys until closed", "? j return ? ctrl+f needle return", ["Needle one"]],
  ["Esc closes shortcuts", "? esc ctrl+f needle return", ["Needle one"]],
  ["nothing found opens nothing", "ctrl+f qqzzxx return", []],
];

for (const [name, keys, expected] of scenarios) {
  test(name, async ({ app, daemon }) => {
    const page = await app.open();
    await play(page, keys);
    if (expected.length) await expect(page.locator(".article-title")).toHaveText(expected[0]);
    else await page.waitForTimeout(300);
    expect(await readTitles(daemon)).toEqual(expected);
  });
}

test("the panel shows the count, marks the words, and Esc gives the keys back", async ({ app }) => {
  const page = await app.open();
  await play(page, "ctrl+f needle");
  const panel = page.getByRole("dialog", { name: "Search" });
  await expect(panel.locator(".search-count")).toHaveText("3 results");
  await expect(panel.getByRole("option")).toHaveCount(3);
  await expect(panel.getByRole("option").first()).toHaveAttribute("aria-selected", "true");
  await expect(panel.locator(".search-mark").first()).toHaveText(/needle/i);
  await page.keyboard.press("Escape");
  await expect(panel).toHaveCount(0);
  await page.keyboard.press("Control+F");
  await expect(page.getByRole("textbox", { name: "Search your feeds" })).toBeFocused();
  await expect(page.getByRole("textbox", { name: "Search your feeds" })).toHaveValue("");
});

test("a click on the scrim closes the panel", async ({ app }) => {
  const page = await app.open();
  await play(page, "ctrl+f needle");
  await page.mouse.click(10, 10);
  await expect(page.getByRole("dialog", { name: "Search" })).toHaveCount(0);
});

test("Ctrl+S keeps a search as a view, named for its words", async ({ app, daemon }) => {
  const page = await app.open();
  await play(page, "ctrl+f needle ctrl+s");
  await expect(page.locator(".list-title, .timeline-title")).toHaveText("Needle");
  await expect.poll(() => viewNames(daemon)).toEqual(["Needle"]);
  await expect(page.locator(".toast")).toContainText("Saved “Needle” as a view");
});

test("Ctrl+Z takes the new view back", async ({ app, daemon }) => {
  await daemon.call("views.put", { name: "Needle", rule: { words: "needle" } });
  const page = await app.open();
  await play(page, "ctrl+f text ctrl+s");
  await expect.poll(() => viewNames(daemon)).toEqual(["Needle", "Text"]);
  // The toast shows once the undo is kept.
  await expect(page.locator(".toast")).toContainText("Saved “Text” as a view");
  await page.keyboard.press("Enter");
  await page.keyboard.press("Control+Z");
  await expect.poll(() => viewNames(daemon)).toEqual(["Needle"]);
});

for (const theme of ["light", "dark"] as const) {
  test(`shot:search ${theme}`, async ({ app, daemon }, info) => {
    test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
    await reset(daemon);
    await afterRoutineSave(daemon);
    const page = await app.open({ FYKE_SCREEN: "search", FYKE_QUERY: "needle" }, theme);
    await expect(page.locator(".search-count")).toHaveText("3 results");
    await app.snapshot(`search-${theme}`);
  });
}

test("the shortcuts sheet lists both columns with Ctrl for Command", async ({ app }) => {
  const page = await app.open();
  await page.keyboard.type("?");
  const sheet = page.getByRole("dialog", { name: "Shortcuts" });
  await expect(sheet.locator(".shortcuts-row")).toHaveCount(22);
  await expect(sheet.locator(".shortcuts-row", { hasText: "Everything" }).locator("kbd")).toHaveText("Ctrl+K");
  await page.mouse.click(10, 10);
  await expect(sheet).toHaveCount(0);
});

for (const theme of ["light", "dark"] as const) {
  test(`shot:shortcuts ${theme}`, async ({ app, daemon }, info) => {
    test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
    await afterRoutineSave(daemon);
    const page = await app.open({ FYKE_SCREEN: "shortcuts", FYKE_QUERY: "needle" }, theme);
    await expect(page.getByRole("dialog", { name: "Shortcuts" })).toBeVisible();
    await app.snapshot(`shortcuts-${theme}`);
  });
}
