// S38: every control in every state (docs/design-rules.md, "Every control has every
// state"): rest, hover, pressed, a visible keyboard ring, selected and disabled; a hand
// over what acts on a click, an I-beam over text, the arrow over disabled controls;
// motion of 120 to 200 ms that stops under reduced motion; and controls that stay
// visible with forced colors. The page is src/ui/ControlsPage.tsx.
import type { Locator, Page } from "@playwright/test";
import { expect, test } from "./fixtures";

const looks = ["background-color", "color", "border-color", "box-shadow", "opacity", "text-decoration-line", "outline-style"] as const;

async function look(control: Locator) {
  return control.evaluate((el, names) => {
    const style = getComputedStyle(el);
    const inner = el.querySelector("span, svg");
    const own = names.map((name) => style.getPropertyValue(name)).join("|");
    if (!inner) return own;
    const drawn = getComputedStyle(inner);
    return `${own}|${drawn.backgroundColor}|${drawn.color}|${drawn.fill}|${drawn.stroke}|${drawn.opacity}`;
  }, [...looks]);
}

/** The element that acts: the control itself, or the button or field inside its wrapper. */
function target(page: Page, name: string) {
  return page.locator(`[data-control="${name}"]`).locator("xpath=self::*[self::button or self::input or self::select] | .//button | .//input | .//select").first();
}

async function controls(page: Page, state?: string) {
  return page.locator("[data-control]").evaluateAll((all, wanted) =>
    all.filter((el) => (el.getAttribute("data-state") ?? "") === (wanted ?? "")).map((el) => el.getAttribute("data-control")!), state);
}

async function settle(page: Page) {
  // Past the longest transition the rules allow.
  await page.waitForTimeout(260);
}

test.beforeEach(async ({ app }) => {
  await app.open({ FYKE_SCREEN: "controls" });
});

test("every enabled control changes on hover and when pressed, and shows the hand", async ({ page }) => {
  const problems: string[] = [];
  for (const name of [...(await controls(page)), ...(await controls(page, "selected"))]) {
    if (name.startsWith("field")) continue;
    const control = target(page, name);
    await page.mouse.move(0, 0);
    await settle(page);
    const rest = await look(control);
    await control.hover();
    await settle(page);
    const hover = await look(control);
    const cursor = await control.evaluate((el) => getComputedStyle(el).cursor);
    // A selected control already wears its strongest fill, so it shows the press alone.
    if (hover === rest && !name.endsWith("selected") && !name.startsWith("switch-on")) problems.push(`${name}: no hover`);
    if (cursor !== "pointer") problems.push(`${name}: cursor ${cursor}`);
    await page.mouse.down();
    await settle(page);
    const pressed = await look(control);
    await page.mouse.up();
    if (pressed === hover && pressed === rest) problems.push(`${name}: no pressed state or hover`);
  }
  expect(problems).toEqual([]);
});

test("every control shows a keyboard ring when Tab reaches it", async ({ page }, info) => {
  // WebKit on a Mac stops Tab at fields alone, as Safari does; Option-Tab reaches every
  // control. WebKitGTK and WebView2 move Tab through every control.
  const tab = info.project.name === "webkit" && process.platform === "darwin" ? "Alt+Tab" : "Tab";
  const problems: string[] = [];
  const names = [...(await controls(page)), ...(await controls(page, "selected"))];
  for (const name of names) {
    // The address field always wears a 2 px accent edge and shows the caret when
    // focused, as on the Mac (AddFeed.swift); it draws no ring besides.
    if (name === "field") continue;
    const control = target(page, name);
    // Focus from the keyboard: Tab from the element before draws :focus-visible.
    await control.evaluate((el) => {
      const before = document.createElement("span");
      before.tabIndex = 0;
      before.className = "tab-start";
      el.before(before);
      before.focus();
    });
    await page.keyboard.press(tab);
    await expect(control).toBeFocused();
    await page.locator(".tab-start").evaluate((el) => el.remove());
    const ring = await control.evaluate((el) => {
      const style = getComputedStyle(el);
      return (style.outlineStyle !== "none" && Number.parseFloat(style.outlineWidth) > 0) || style.boxShadow !== "none";
    });
    if (!ring) problems.push(name);
  }
  expect(problems).toEqual([]);
});

test("disabled controls show the arrow and look different from enabled ones", async ({ page }) => {
  const problems: string[] = [];
  for (const name of await controls(page, "disabled")) {
    const control = target(page, name);
    const { cursor, disabled } = await control.evaluate((el) => ({ cursor: getComputedStyle(el).cursor, disabled: (el as HTMLButtonElement).disabled }));
    if (!disabled) problems.push(`${name}: not disabled`);
    if (cursor !== "default" && cursor !== "auto") problems.push(`${name}: cursor ${cursor}`);
    // The Mac dims a disabled control's words or fill (Kit.swift), not its opacity.
    const enabled = name.endsWith("-disabled") ? name.replace(/-disabled$/, "") : "";
    const sibling = enabled === "switch" ? "switch-off" : enabled;
    if (sibling && (await look(control)) === (await look(target(page, sibling)))) problems.push(`${name}: looks like ${sibling}`);
  }
  expect(problems).toEqual([]);
});

test("text fields show the I-beam", async ({ page }) => {
  expect(await target(page, "field").evaluate((el) => getComputedStyle(el).cursor)).toMatch(/^(text|auto)$/);
});

test("motion is 120 to 200 ms, and none under reduced motion", async ({ page }) => {
  const durations = async () => page.locator("[data-control]").evaluateAll((all) => all.flatMap((wrapper) => {
    const el = wrapper.matches("button, input, select") ? wrapper : wrapper.querySelector("button, input, select")!;
    return getComputedStyle(el).transitionDuration.split(",").map((d) => ({ name: wrapper.getAttribute("data-control")!, ms: Number.parseFloat(d) * (d.trim().endsWith("ms") ? 1 : 1000) }));
  }));
  const moving = (await durations()).filter((d) => d.ms > 0);
  expect(moving.length).toBeGreaterThan(0);
  expect(moving.filter((d) => d.ms < 120 || d.ms > 200)).toEqual([]);
  await page.emulateMedia({ reducedMotion: "reduce" });
  expect((await durations()).filter((d) => d.ms > 1)).toEqual([]);
  const spinning = await page.locator(".spinner").first().evaluate((el) => getComputedStyle(el).animationName);
  expect(spinning).toBe("none");
});

test("with forced colors every control keeps an edge or a system color", async ({ page }, info) => {
  test.skip(info.project.name !== "chromium", "forced colors are emulated in Chromium");
  await page.emulateMedia({ forcedColors: "active" });
  const problems: string[] = [];
  for (const name of await controls(page)) {
    // Words and glyphs draw in ButtonText already; only filled shapes need an edge.
    if (name.includes("quiet") || name.includes("link") || name === "symbol" || name === "icon") continue;
    const edge = await target(page, name).evaluate((el) => {
      const style = getComputedStyle(el);
      return Number.parseFloat(style.borderTopWidth) > 0 || (style.outlineStyle !== "none" && Number.parseFloat(style.outlineWidth) > 0);
    });
    if (!edge) problems.push(name);
  }
  expect(problems).toEqual([]);
});
