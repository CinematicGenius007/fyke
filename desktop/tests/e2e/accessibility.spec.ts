// Names, roles and contrast on every screen, through axe-core, in both themes; the
// keyboard path through the window; and forced colours (Windows contrast themes).
import AxeBuilder from "@axe-core/playwright";
import { expect, test } from "./fixtures";

const SCREENS: Record<string, string>[] = [
  { FYKE_SCREEN: "all" },
  { FYKE_SCREEN: "feed" },
  { FYKE_SCREEN: "today" },
  { FYKE_SCREEN: "routines" },
  { FYKE_SCREEN: "settings", FYKE_TAB: "general" },
  { FYKE_SCREEN: "settings", FYKE_TAB: "reading" },
  { FYKE_SCREEN: "settings", FYKE_TAB: "tokens" },
  { FYKE_SCREEN: "settings", FYKE_TAB: "agents" },
  { FYKE_SCREEN: "settings", FYKE_TAB: "data" },
  { FYKE_SCREEN: "add", FYKE_ADDRESS: "news" },
  { FYKE_SCREEN: "palette" },
  { FYKE_SCREEN: "search", FYKE_QUERY: "the" },
  { FYKE_SCREEN: "shortcuts" },
  { FYKE_SCREEN: "activity" },
  { FYKE_SCREEN: "health" },
  { FYKE_SCREEN: "catchup" },
  { FYKE_SCREEN: "toast" },
];

const label = (screen: Record<string, string>) => [screen.FYKE_SCREEN, screen.FYKE_TAB].filter(Boolean).join(" ");

for (const theme of ["light", "dark"] as const) {
  for (const screen of SCREENS) {
    test(`axe: ${label(screen)} ${theme}`, async ({ app, page }) => {
      await app.open({ ...screen, FYKE_CHROME: "windows" }, theme);
      await page.waitForTimeout(400);
      // A theme tile's sample shows another theme's own colours, as a picture of it does.
      const result = await new AxeBuilder({ page }).exclude(".theme-sample").withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"]).analyze();
      const found = result.violations.map((v) => `${v.id} (${v.impact}): ${v.nodes.length}× ${v.nodes.slice(0, 3).map((n) => n.target.join(" ")).join(" | ")}`);
      expect(found, found.join("\n")).toEqual([]);
    });
  }
}

test("forced colours keep the selection, unread dots and panel edges", async ({ app, page }, info) => {
  test.skip(info.project.name !== "chromium", "WebKit cannot emulate forced colours");
  await page.emulateMedia({ forcedColors: "active", colorScheme: "dark" });
  await app.open({ FYKE_SCREEN: "palette", FYKE_QUERY: "needle" }, "dark");
  const look = (selector: string, property: string) =>
    page.locator(selector).first().evaluate((element, property) => getComputedStyle(element).getPropertyValue(property), property);
  const plain = await look(".sidebar-row:not([aria-current])", "background-color");
  expect(await look(".sidebar-row[aria-current='page']", "background-color")).not.toBe(plain);
  expect(await look(".palette-row.selected", "background-color")).not.toBe(await look(".palette-row:not(.selected)", "background-color"));
  expect(await look(".float-panel, .palette, [role=dialog] > div", "border-top-width")).not.toBe("");
  const dot = await look(".palette-row .dot:not([style*='transparent'])", "background-color");
  expect(dot).not.toBe("rgba(0, 0, 0, 0)");
});

test("Tab moves from the sidebar to the list to the reader, and never to the window buttons", async ({ app, page }, info) => {
  // WebKit on macOS tabs only to text fields unless the system's keyboard setting is on.
  test.skip(info.project.name !== "chromium", "WebKit skips buttons when tabbing on macOS");
  await app.open({ FYKE_SCREEN: "feed", FYKE_CHROME: "windows" });
  const regions: string[] = [];
  for (let i = 0; i < 40; i++) {
    await page.keyboard.press("Tab");
    const region = await page.evaluate(() => {
      const element = document.activeElement;
      if (!element || element === document.body) return "none";
      if (element.closest(".window-buttons")) return "window";
      if (element.closest("nav.sidebar")) return "sidebar";
      if (element.closest(".reader-pane")) return "reader";
      if (element.closest("main")) return "list";
      return "other";
    });
    if (regions.at(-1) !== region) regions.push(region);
  }
  expect(regions, regions.join(" > ")).not.toContain("window");
  const first = (name: string) => regions.indexOf(name);
  expect(first("sidebar")).toBeGreaterThanOrEqual(0);
  expect(first("list")).toBeGreaterThan(first("sidebar"));
  expect(first("reader"), regions.join(" > ")).toBeGreaterThan(first("list"));
});
