import { type Rule } from "../../src/logic/Rule";
import { type Daemon, expect, reset, test } from "./fixtures";

async function put(daemon: Daemon, rule: Rule) {
  return await daemon.call<{ id: number; revision: number }>("views.put", { name: "Needles", rule });
}

async function savedRule(daemon: Daemon) {
  const { items } = await daemon.call<{ items: { rule: Rule }[] }>("views.list");
  return items[0].rule;
}

test.beforeEach(async ({ daemon }) => {
  await reset(daemon);
});

test("changing the words in a view updates the list, and Ctrl+Z restores it", async ({ app, daemon }) => {
  await put(daemon, { words: "needle" });
  const page = await app.open();
  await page.getByRole("button", { name: "Needles", exact: true }).click();
  await expect(page.locator(".entry-row")).toHaveCount(3);

  await page.getByRole("button", { name: "words: needle" }).click();
  const words = page.getByRole("textbox", { name: "About these words" });
  await expect(words).toBeFocused();
  await words.fill("strange");
  await words.press("Enter");
  await expect(page.getByText("Nothing matches yet")).toBeVisible();
  await expect(page.locator(".toast")).toContainText("Changed “Needles”");
  await expect.poll(async () => (await savedRule(daemon)).words).toBe("strange");

  await page.keyboard.press("Control+z");
  await expect(page.locator(".entry-row")).toHaveCount(3);
  expect((await savedRule(daemon)).words).toBe("needle");
});

test("the sentence can add and remove a path and can change its scope", async ({ app, daemon }) => {
  await put(daemon, { words: "needle" });
  const { items } = await daemon.call<{ items: { id: number }[] }>("feeds.list");
  const page = await app.open();
  await page.getByRole("button", { name: "Needles", exact: true }).click();
  await page.getByRole("button", { name: "Add to the rule" }).click();
  await page.getByRole("menuitem", { name: "Under a path…" }).click();
  await page.getByRole("textbox", { name: "Under this path" }).fill("blog/");
  await page.getByRole("button", { name: "Apply", exact: true }).click();
  await expect(page.getByRole("button", { name: "path: /blog" })).toBeVisible();

  await page.getByRole("button", { name: "path: /blog" }).click();
  await page.getByRole("button", { name: "Remove", exact: true }).click();
  await expect(page.getByRole("button", { name: "path: /blog" })).toHaveCount(0);

  await page.getByRole("button", { name: "scope: all feeds" }).click();
  await page.getByRole("checkbox", { name: "Local", exact: true }).click();
  await page.getByRole("button", { name: "Apply", exact: true }).click();
  await expect(page.getByRole("button", { name: "scope: Local" })).toBeVisible();
  expect((await savedRule(daemon)).feeds).toEqual([items[0].id]);
});

test("an edit opened before an external update cannot overwrite the newer view", async ({ app, daemon }) => {
  const view = await put(daemon, { words: "needle" });
  const page = await app.open();
  await page.getByRole("button", { name: "Needles", exact: true }).click();
  await page.getByRole("button", { name: "words: needle" }).click();
  const words = page.getByRole("textbox", { name: "About these words" });
  await words.fill("stale");
  await daemon.call("views.put", { id: view.id, name: "Needles", rule: { words: "text" }, expected_revision: view.revision });
  await expect(page.getByRole("button", { name: "words: text" })).toBeVisible();
  await page.getByRole("button", { name: "Apply", exact: true }).click();
  await expect(page.getByText("This view changed elsewhere. It now shows the newer rule.")).toBeVisible();
  expect((await savedRule(daemon)).words).toBe("text");
});

test("an empty unread view can include read articles", async ({ app, daemon }) => {
  await put(daemon, { state: "unread", words: "needle" });
  const { items } = await daemon.call<{ items: { id: number }[] }>("entries.list", { limit: 20 });
  await daemon.call("entries.mark_many", { ids: items.map((entry) => entry.id), read: true });
  const page = await app.open();
  await page.getByRole("button", { name: "Needles", exact: true }).click();
  await page.getByRole("button", { name: "Include read articles" }).click();
  await expect(page.locator(".entry-row")).toHaveCount(3);
  expect((await savedRule(daemon)).state).toBe("any");
});
