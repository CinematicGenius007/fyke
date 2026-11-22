import { afterRoutineSave, expect, readTitles, reset, test } from "./fixtures";

test.beforeEach(async ({ daemon }) => {
  await reset(daemon);
  const { items } = await daemon.call<{ items: { id: number }[] }>("entries.list", { limit: 20 });
  await daemon.call("entries.mark_many", { ids: items.map((entry) => entry.id), later: false });
});

test("Ctrl+J opens catch-up, then Left skips and Down saves for Later, with Ctrl+Z", async ({ app, daemon }) => {
  const page = await app.open();
  await page.keyboard.press("Control+j");
  const catchUp = page.getByRole("dialog", { name: "Catching up on All" });
  await expect(catchUp.getByRole("heading", { name: "Needle one" })).toBeVisible();
  await page.keyboard.press("ArrowLeft");
  await expect(catchUp.getByRole("heading", { name: "Needle two" })).toBeVisible();
  await expect.poll(() => readTitles(daemon)).toEqual(["Needle one"]);
  await page.keyboard.press("ArrowDown");
  await expect(catchUp.getByRole("heading", { name: "Needle three" })).toBeVisible();
  const later = async () => {
    const { items } = await daemon.call<{ items: { title: string; later?: boolean }[] }>("entries.list");
    return items.filter((entry) => entry.later).map((entry) => entry.title);
  };
  expect(await later()).toEqual(["Needle two"]);

  await page.keyboard.press("Control+z");
  await expect(catchUp.getByRole("heading", { name: "Needle two" })).toBeVisible();
  expect(await later()).toEqual([]);
  await page.keyboard.press("Control+z");
  await expect(catchUp.getByRole("heading", { name: "Needle one" })).toBeVisible();
  expect(await readTitles(daemon)).toEqual([]);

  await page.keyboard.press("ArrowRight");
  await expect(catchUp).toHaveCount(0);
  await expect(page.locator(".article-title")).toHaveText("Needle one");
  expect(await readTitles(daemon)).toEqual(["Needle one"]);
});

test("finishing catch-up shows the summary and can bring back the last card", async ({ app }) => {
  const page = await app.open({ FYKE_SCREEN: "catchup" });
  const catchUp = page.getByRole("dialog", { name: "Catching up on All" });
  for (const title of ["Needle one", "Needle two", "Needle three"]) {
    await expect(catchUp.getByRole("heading", { name: title })).toBeVisible();
    await catchUp.getByRole("button", { name: "Skip", exact: true }).click();
  }
  await expect(catchUp.getByText("You’re caught up")).toBeVisible();
  await expect(catchUp.getByText("Skipped 3 · Later 0 · Read 0", { exact: true })).toBeVisible();
  await catchUp.getByRole("button", { name: "Undo last", exact: true }).click();
  await expect(catchUp.getByRole("heading", { name: "Needle three" })).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(catchUp).toHaveCount(0);
});

for (const theme of ["light", "dark"] as const) {
  test(`shot:catchup ${theme}`, async ({ app, daemon }, info) => {
    test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
    await afterRoutineSave(daemon);
    const page = await app.open({ FYKE_SCREEN: "catchup" }, theme);
    await expect(page.getByRole("heading", { name: "Needle one" })).toBeVisible();
    await app.snapshot(`catchup-${theme}`);
  });

  test(`shot:catchup-done ${theme}`, async ({ app, daemon }, info) => {
    test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
    await afterRoutineSave(daemon);
    const { items } = await daemon.call<{ items: { id: number }[] }>("entries.list", { limit: 500 });
    await daemon.call("entries.mark_many", { ids: items.map((e) => e.id), read: true });
    const page = await app.open({ FYKE_SCREEN: "catchup" }, theme);
    await expect(page.locator(".inline-title")).toBeVisible();
    await app.snapshot(`catchup-done-${theme}`);
  });
}
