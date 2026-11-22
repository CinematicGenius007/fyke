// Phase 3, reading: the places, the list, the reader and their keys, against the shared
// fixtures (tools/gui_fixtures.py). Pictures use the Mac's names, for tools/parity.ts.
import { expect, test } from "./fixtures";

const themes = ["light", "dark"] as const;

// The Mac's checks save this view from a search (e2e_gui.py `view-save`) before taking
// these pictures. Search comes in phase 4, so here the daemon saves the same view.
test.beforeEach(async ({ daemon }) => {
  const views = await daemon.call<{ items: { name: string }[] }>("views.list");
  if (!views.items.some((v) => v.name === "Needle")) await daemon.call("views.put", { name: "Needle", rule: { words: "needle" } });
});

for (const screen of ["all", "view"] as const) {
  for (const theme of themes) {
    test(`shot:${screen} ${theme}`, async ({ app }, info) => {
      test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
      const page = await app.open({ FYKE_SCREEN: screen, FYKE_QUERY: "needle" }, theme);
      await expect(page.locator(".article-title")).toHaveText("Needle one");
      await app.snapshot(`${screen}-${theme}`);
    });
  }
}

test("All opens the first article, marks it read and shows its text", async ({ app }) => {
  const page = await app.open({ FYKE_SCREEN: "all" });
  await expect(page.locator(".article-title")).toHaveText("Needle one");
  await expect(page.locator(".article-meta")).toHaveText("Local · 5 November");
  await expect(page.locator(".blocks")).toContainText("needle text");
  await expect(page.getByRole("button", { name: "Mark unread" })).toBeVisible();
  await expect(page.locator(".sidebar-row.selected")).toHaveAccessibleName("All");
});

test("Escape goes back to the timeline, and Return opens the selected row again", async ({ app }) => {
  const page = await app.open({ FYKE_SCREEN: "all" });
  await expect(page.locator(".article-title")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.locator(".timeline-title")).toHaveText("All");
  await expect(page.locator(".timeline-row-title")).toHaveCount(3);
  await page.keyboard.press("Enter");
  await expect(page.locator(".article-title")).toHaveText("Needle one");
});

test("j and k move through a view's list and open each article", async ({ app }) => {
  const page = await app.open({ FYKE_SCREEN: "view" });
  await expect(page.locator(".list-title")).toHaveText("Needle");
  await expect(page.locator(".sentence")).toHaveAccessibleName(/Rule: Articles from all feeds about needle/);
  await page.keyboard.press("j");
  await expect(page.locator(".article-title")).toHaveText("Needle two");
  await expect(page.locator(".entry-row.selected .entry-title")).toHaveText("Needle two");
  await page.keyboard.press("k");
  await expect(page.locator(".article-title")).toHaveText("Needle one");
});

test("s stars the open article and the daemon keeps it; m marks it unread", async ({ app, daemon }) => {
  const page = await app.open({ FYKE_SCREEN: "view" });
  await expect(page.locator(".article-title")).toHaveText("Needle one");
  await page.keyboard.press("s");
  await expect(page.getByRole("button", { name: "Remove star" }).first()).toBeVisible();
  await expect(page.locator(".sidebar-row", { hasText: "Starred" }).locator(".count")).toHaveText("1");
  const starred = await daemon.call<{ items: { title: string }[] }>("entries.list", { starred_only: true });
  expect(starred.items.map((e) => e.title)).toEqual(["Needle one"]);
  await page.keyboard.press("m");
  await expect(page.getByRole("button", { name: "Mark read" })).toBeVisible();
  // Put the fixtures back for the next test in this worker.
  await page.keyboard.press("s");
  await expect(page.getByRole("button", { name: "Star", exact: true }).first()).toBeVisible();
});

test("a feed shows its list beside the reader, and the divider resizes it", async ({ app }) => {
  const page = await app.open({ FYKE_SCREEN: "feed" });
  await expect(page.locator(".list-title")).toHaveText("Local");
  await expect(page.locator(".article-title")).toHaveText("Needle two");
  const list = page.locator(".pane-list");
  expect((await list.boundingBox())!.width).toBe(368);
  const divider = page.getByRole("separator", { name: "Resize the article list" });
  const box = (await divider.boundingBox())!;
  await page.mouse.move(box.x + 4, box.y + 300);
  await page.mouse.down();
  await page.mouse.move(box.x + 64, box.y + 300, { steps: 4 });
  await page.mouse.up();
  await expect.poll(async () => (await list.boundingBox())!.width).toBe(428);
  await divider.dblclick();
  await expect.poll(async () => (await list.boundingBox())!.width).toBe(368);
});

test("feed content is text, never markup", async ({ app }) => {
  const page = await app.open({ FYKE_SCREEN: "all" });
  await expect(page.locator(".blocks")).toBeVisible();
  // Nothing from the feed may add elements beyond the block renderer's own.
  expect(await page.locator(".blocks script, .blocks iframe, .blocks object, .blocks [onerror]").count()).toBe(0);
  expect(await page.evaluate(() => document.querySelectorAll("[style*='url(']").length)).toBe(0);
});
