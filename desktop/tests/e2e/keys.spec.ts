// The keyboard lines of desktop-parity.md that no other suite covers: K5 (redo in a text
// field), K8 (Ctrl+1 … Ctrl+4), K18 (n and u), K20 (c f r a t) and K24 (hints spelled
// with Ctrl, never ⌘).
import type { Page } from "@playwright/test";
import { expect, readTitles, reset, test } from "./fixtures";

test.beforeEach(async ({ daemon }) => reset(daemon));

/** The methods the page sends to the daemon. Call it before the page opens, so it sees
 * the socket. */
function sent(page: Page): string[] {
  const methods: string[] = [];
  page.on("websocket", (socket) => socket.on("framesent", (frame) => {
    const match = typeof frame.payload === "string" ? /"method":"([^"]+)"/.exec(frame.payload) : null;
    if (match) methods.push(match[1]);
  }));
  return methods;
}

test("Ctrl+1 to Ctrl+4 go to Today, All, Starred and Routines", async ({ app }) => {
  const page = await app.open();
  const selected = page.locator(".sidebar-row.selected");
  for (const [key, place] of [["4", "Routines"], ["3", "Starred"], ["2", "All"], ["1", "Today"]]) {
    await page.keyboard.press(`Control+${key}`);
    await expect(selected).toHaveAccessibleName(place);
  }
});

// The text field's own undo and redo, which the webview provides; Playwright's browsers
// on a Mac take Command for them. The Mac app's Redo also goes to the text field only.
test("Shift with the undo key redoes typing in a text field", async ({ app }) => {
  const page = await app.open({ FYKE_SCREEN: "all" });
  await page.keyboard.press("Control+f");
  const field = page.getByRole("textbox").first();
  await field.focus();
  await page.keyboard.insertText("needle");
  await page.keyboard.press("ControlOrMeta+z");
  await expect(field).toHaveValue("");
  await page.keyboard.press("ControlOrMeta+Shift+z");
  await expect(field).toHaveValue("needle");
});

test("n opens the next unread article and u shows only unread ones", async ({ app, daemon }) => {
  const page = await app.open({ FYKE_SCREEN: "all" });
  await expect(page.locator(".article-title")).toHaveText("Needle one");
  await page.keyboard.press("n");
  await expect(page.locator(".article-title")).toHaveText("Needle two");
  await expect.poll(() => readTitles(daemon)).toEqual(["Needle one", "Needle two"]);
  await page.keyboard.press("Escape");
  const filter = page.locator(".timeline-filter");
  await expect(filter).toHaveText(/^All · \d+ unread$/);
  await page.keyboard.press("u");
  await expect(filter).toHaveText(/^Unread · \d+$/);
  await expect(page.locator(".timeline-row")).toHaveCount(1);
  await page.keyboard.press("u");
  await expect(filter).toHaveText(/^All · \d+ unread$/);
});

// c is covered by discussion.spec.ts, which needs a story with comments.
test("f fetches the full article, r refreshes, t opens text and theme, and a adds a feed", async ({ page, app }) => {
  const methods = sent(page);
  await app.open({ FYKE_SCREEN: "all" });
  await expect(page.locator(".article-title")).toHaveText("Needle one");
  await page.keyboard.press("f");
  await expect.poll(() => methods).toContain("entries.fetch_full");
  await page.keyboard.press("r");
  await expect.poll(() => methods).toContain("feeds.refresh_all");
  await page.keyboard.press("t");
  await expect(page.getByRole("region", { name: "Text and theme" })).toBeVisible();
  await page.keyboard.press("Escape");
  await page.keyboard.press("a");
  await expect(page.getByRole("dialog", { name: "Add a feed" })).toBeVisible();
});

test("key hints say Ctrl and Shift, never the Mac's symbols", async ({ app }) => {
  const page = await app.open({ FYKE_SCREEN: "all" });
  await expect(page.locator(".sidebar")).toContainText("Ctrl+K");
  await page.keyboard.press("?");
  await expect(page.getByText("Ctrl+Shift+A")).toBeVisible();
  for (const symbol of ["⌘", "⇧", "⌥", "⌃"]) expect(await page.locator("body").innerText()).not.toContain(symbol);
});
