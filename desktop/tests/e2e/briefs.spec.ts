import { type Daemon, expect, reset, test } from "./fixtures";

async function published(daemon: Daemon) {
  return (await daemon.call<{ items: { id: number; title: string }[] }>("briefs.list")).items;
}

async function recipe(daemon: Daemon) {
  return await daemon.call<{ id: number; text: string; revision: number }>("recipes.get", { id: 1 });
}

async function publish(daemon: Daemon) {
  const count = (await published(daemon)).length;
  await daemon.call("briefs.run", { rule: { state: "unread" } });
  await expect.poll(async () => (await published(daemon)).length).toBe(count + 1);
}

test.beforeEach(async ({ daemon }) => {
  await reset(daemon);
});

test("Today only writes on request, and citations open their article in the reader", async ({ app, daemon }) => {
  const original = (await published(daemon)).length;
  const page = await app.open({ FYKE_SCREEN: "today" });
  await expect(page.getByText("No brief yet", { exact: true })).toBeVisible();
  expect(await published(daemon)).toHaveLength(original);
  await page.keyboard.press("Control+r");
  await expect(page.getByRole("heading", { name: "Needles, briefly", exact: true })).toBeVisible();
  await expect(page.getByText("AI brief", { exact: true })).toBeVisible();
  await expect(page.getByText(/Written by.*with your/)).toBeVisible();
  expect(await published(daemon)).toHaveLength(original + 1);

  const source = page.getByRole("button", { name: "Source 1", exact: true }).first();
  await source.hover();
  const citation = page.getByRole("complementary", { name: /Source 1:/ });
  await expect(citation).toBeVisible();
  await source.click();
  await citation.getByRole("button", { name: "Open article ↵" }).click();
  await expect(page.locator(".article-title")).toHaveText(/^Needle /);
  await page.getByRole("button", { name: "Back to Brief" }).click();
  await expect(page.getByRole("heading", { name: "Needles, briefly", exact: true })).toBeVisible();
});

for (const theme of ["light", "dark"] as const) {
  for (const shot of ["today", "citation", "recipe"] as const) {
    test(`shot:${shot} ${theme}`, async ({ app, daemon }, info) => {
      test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
      if (!(await published(daemon)).length) await publish(daemon);
      const page = await app.open({
        FYKE_SCREEN: shot === "recipe" ? "recipe" : "today",
        ...(shot === "citation" ? { FYKE_PIN_CITATION: "1" } : {}),
      }, theme);
      if (shot === "recipe") await expect(page.getByRole("textbox", { name: "Recipe text" })).toBeVisible();
      else await expect(page.getByRole("heading", { name: "Needles, briefly", exact: true })).toBeVisible();
      if (shot === "citation") await expect(page.getByRole("complementary", { name: /Source 1:/ })).toBeVisible();
      await app.snapshot(`${shot}-${theme}`);
    });
  }
}

test("recipes save revisions, show history and can undo a reset", async ({ app, daemon }) => {
  const before = await recipe(daemon);
  const briefsBefore = (await published(daemon)).length;
  const page = await app.open({ FYKE_SCREEN: "recipe" });
  const field = page.getByRole("textbox", { name: "Recipe text" });
  await expect(field).toHaveValue(before.text);
  const edited = "Write about the needles and cite each claim.";
  await field.fill(edited);
  await field.press("Control+s");
  await expect.poll(async () => (await recipe(daemon)).text).toBe(edited);
  if (briefsBefore > 0) {
    await expect.poll(async () => (await published(daemon)).length).toBe(briefsBefore + 1);
  }

  await page.getByRole("tab", { name: "History" }).click();
  await expect(page.getByRole("button", { name: new RegExp(`Revision ${before.revision + 1}\\b`) })).toBeVisible();
  await page.getByRole("tab", { name: "Edit" }).click();
  await page.getByRole("button", { name: "Reset to built-in" }).click();
  await expect(page.locator(".toast")).toContainText("to the built-in text");
  await page.keyboard.press("Control+z");
  await expect.poll(async () => (await recipe(daemon)).text).toBe(edited);
  await expect(field).toHaveValue(edited);
});

test("trying unsaved recipe text leaves the recipe and published list unchanged", async ({ app, daemon }) => {
  const before = await recipe(daemon);
  const count = (await published(daemon)).length;
  const page = await app.open({ FYKE_SCREEN: "recipe" });
  await page.getByRole("textbox", { name: "Recipe text" }).fill("Use the newest needle.");
  await page.getByRole("tab", { name: "Try it" }).click();
  await page.getByRole("button", { name: "Try it", exact: true }).click();
  await expect(page.getByText("Trial · not saved", { exact: true })).toBeVisible();
  expect(await recipe(daemon)).toMatchObject({ text: before.text, revision: before.revision });
  expect(await published(daemon)).toHaveLength(count);
});
