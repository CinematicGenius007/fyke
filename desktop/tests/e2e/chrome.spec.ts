// Phase 7, window chrome (src/ui/Chrome.tsx; docs/desktop-parity.md D3, D4). In a browser
// tab the buttons record what they asked the window to do, so these check the requests;
// the Windows checklist covers what the system then does with them.
import type { Page } from "@playwright/test";
import { afterRoutineSave, expect, reset, test } from "./fixtures";

test.beforeEach(async ({ daemon }) => reset(daemon));

const actions = (page: Page) => page.evaluate(() => (window as unknown as { fykeWindowActions?: string[] }).fykeWindowActions ?? []);

test("a browser tab shows no window buttons", async ({ app }) => {
  const page = await app.open({ FYKE_SCREEN: "all" });
  await expect(page.getByRole("group", { name: "Window" })).toHaveCount(0);
  await page.mouse.click(600, 20);
  expect(await actions(page)).toEqual([]);
});

for (const kind of ["windows", "linux"] as const) {
  test(`${kind}: the buttons minimize, maximize and close`, async ({ app }) => {
    const page = await app.open({ FYKE_SCREEN: "all", FYKE_CHROME: kind });
    const buttons = page.getByRole("group", { name: "Window" });
    await buttons.getByRole("button", { name: "Minimize" }).click();
    await buttons.getByRole("button", { name: "Maximize" }).click();
    await buttons.getByRole("button", { name: "Close" }).click();
    expect(await actions(page)).toEqual(["minimize", "maximize", "close"]);
  });

  test(`${kind}: the top strip drags, a double press maximizes, and controls in it still act`, async ({ app }) => {
    const page = await app.open({ FYKE_SCREEN: "all", FYKE_CHROME: kind });
    // Empty space over the sidebar and over the reader.
    await page.mouse.click(120, 20);
    await page.mouse.click(900, 20);
    await page.mouse.dblclick(120, 20);
    expect(await actions(page)).toEqual(["drag", "drag", "drag", "maximize"]);
    // Below the strip nothing moves the window.
    await page.mouse.click(120, 600);
    expect((await actions(page)).length).toBe(4);
    // The reader's star sits in the strip and still stars.
    const star = page.locator(".reader-actions").getByRole("button", { name: /star/i }).first();
    await star.click();
    expect((await actions(page)).length).toBe(4);
  });

  test(`${kind}: the reader's actions stay clear of the buttons`, async ({ app }) => {
    const page = await app.open({ FYKE_SCREEN: "all", FYKE_CHROME: kind });
    const group = await page.getByRole("group", { name: "Window" }).boundingBox();
    const tools = await page.locator(".reader-actions").boundingBox();
    expect(group && tools).toBeTruthy();
    expect(tools!.x + tools!.width).toBeLessThanOrEqual(group!.x - 8);
  });
}

// Nothing a screen draws may sit under the caption buttons: every screen in test mode,
// in both chromes, checked for controls and words that meet the buttons' corner. One
// test per screen, so each has its own time limit and they run in parallel.
const screens = ["all", "view", "feed", "starred", "folder", "view-empty", "today", "briefing", "recipe", "settings", "web", "ask", "routines", "toast", "activity", "health", "catchup", "add", "shortcuts", "delete-folder", "rename-folder", "rename-feed", "palette", "search"];
for (const kind of ["windows", "linux"] as const) {
  for (const screen of screens) {
    test(`${kind}: ${screen} puts nothing under the window buttons`, async ({ app, daemon }) => {
      await afterRoutineSave(daemon);
      const page = await app.open({ FYKE_SCREEN: screen, FYKE_CHROME: kind });
      await page.waitForTimeout(400);
      const hits = await page.evaluate(() => {
        const group = document.querySelector(".window-buttons");
        if (!group) return ["no window buttons"];
        const box = group.getBoundingClientRect();
        // A margin of 8 around the buttons, as the reader's actions keep.
        const zone = { left: box.left - 8, right: box.right, top: box.top, bottom: box.bottom + 4 };
        const found: string[] = [];
        for (const el of document.querySelectorAll<HTMLElement>("body *")) {
          if (group.contains(el)) continue;
          const own = [...el.childNodes].some((n) => n.nodeType === Node.TEXT_NODE && n.textContent!.trim());
          const control = el.matches("button, a[href], input, textarea, select, [role=tab], [role=button], svg");
          if (!own && !control) continue;
          const style = getComputedStyle(el);
          if (style.visibility === "hidden" || Number(style.opacity) === 0) continue;
          // Words count where they are drawn, not across the whole box that holds them.
          const range = document.createRange();
          range.selectNodeContents(el);
          const r = control ? el.getBoundingClientRect() : range.getBoundingClientRect();
          if (!r.width || !r.height) continue;
          if (r.left < zone.right && r.right > zone.left && r.top < zone.bottom && r.bottom > zone.top) {
            // Only what is on top at that point counts; something under a sheet's scrim does not.
            const x = Math.max(r.left, zone.left) + 1, y = Math.max(r.top, zone.top) + 1;
            const top = document.elementFromPoint(Math.min(x, r.right - 1), Math.min(y, r.bottom - 1));
            if (top && (el.contains(top) || top.contains(el))) found.push(`${el.tagName.toLowerCase()}.${el.className || ""} "${(el.textContent ?? "").trim().slice(0, 20)}"`);
          }
        }
        return found;
      });
      expect(hits).toEqual([]);
    });
  }
}

test("a press in the strip while a menu is open only closes the menu", async ({ app }) => {
  const page = await app.open({ FYKE_SCREEN: "all", FYKE_CHROME: "windows" });
  await page.getByRole("button", { name: "Local", exact: true }).click({ button: "right" });
  await expect(page.getByRole("menu")).toBeVisible();
  // A press in the strip while a menu is open closes the menu and does not drag.
  await page.mouse.click(600, 20);
  await expect(page.getByRole("menu")).toHaveCount(0);
  expect(await actions(page)).toEqual([]);
});

for (const kind of ["windows", "linux"] as const) {
  for (const theme of ["light", "dark"] as const) {
    test(`shot:chrome-${kind} ${theme}`, async ({ app, daemon }, info) => {
      test.skip(info.project.name !== "webkit", "pictures in WebKit");
      await afterRoutineSave(daemon);
      const page = await app.open({ FYKE_SCREEN: "all", FYKE_CHROME: kind }, theme);
      await page.getByRole("button", { name: "Close" }).hover();
      await app.snapshot(`chrome-${kind}-${theme}`);
    });
  }
}

test("the webview's own keys do nothing, and Ctrl+Q quits only on Linux", async ({ app }) => {
  const page = await app.open({ FYKE_SCREEN: "all", FYKE_CHROME: "windows" });
  const prevented = (init: KeyboardEventInit) =>
    page.evaluate((init) => {
      const event = new KeyboardEvent("keydown", { ...(init as KeyboardEventInit), bubbles: true, cancelable: true });
      window.dispatchEvent(event);
      return event.defaultPrevented;
    }, init);
  for (const init of [{ key: "p", ctrlKey: true }, { key: "u", ctrlKey: true }, { key: "F5" }, { key: "F7" }, { key: "R", ctrlKey: true, shiftKey: true }])
    expect(await prevented(init), JSON.stringify(init)).toBe(true);
  // Text keys are left alone.
  expect(await prevented({ key: "c", ctrlKey: true })).toBe(false);
  expect(await prevented({ key: "q", ctrlKey: true })).toBe(false);
  const wheel = await page.evaluate(() => {
    const event = new WheelEvent("wheel", { deltaY: -10, ctrlKey: true, bubbles: true, cancelable: true });
    document.body.dispatchEvent(event);
    return event.defaultPrevented;
  });
  expect(wheel).toBe(true);
});
