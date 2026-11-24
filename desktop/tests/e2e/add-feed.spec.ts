import { readFile } from "node:fs/promises";
import { afterRoutineSave, type Daemon, expect, test } from "./fixtures";

const feeds = async (daemon: Daemon) =>
  (await daemon.call<{ items: { id: number; url: string; title: string; folder_id?: number }[] }>("feeds.list")).items;

async function removeThread(daemon: Daemon) {
  const thread = (await feeds(daemon)).find((feed) => feed.url.endsWith("/thread.xml"));
  if (thread) await daemon.call("feeds.remove", { id: thread.id });
}

test.beforeEach(async ({ daemon }) => {
  await removeThread(daemon);
  const { items } = await daemon.call<{ items: { id: number }[] }>("folders.list");
  for (const folder of items) await daemon.call("folders.remove", { id: folder.id });
});

test("Ctrl+N previews a feed before subscribing and uses the chosen name and folder", async ({ app, daemon }) => {
  const { id } = await daemon.call<{ id: number }>("folders.add", { name: "Reading" });
  const page = await app.open();
  await page.keyboard.press("Control+n");
  const sheet = page.getByRole("dialog", { name: "Add a feed" });
  const address = sheet.getByRole("textbox", { name: "Site or feed address" });
  await expect(address).toBeFocused();
  await expect(sheet.getByRole("button", { name: "Subscribe" })).toBeDisabled();
  await address.fill(daemon.base + "/thread.xml");
  await expect(sheet.getByText("Unkernel in WASM")).toBeVisible();
  expect(await feeds(daemon)).toHaveLength(1);
  await sheet.getByRole("textbox", { name: "Name", exact: true }).fill("Stories");
  await sheet.getByRole("combobox", { name: "Folder" }).selectOption({ label: "Reading" });
  await sheet.getByRole("button", { name: "Subscribe" }).click();
  await expect(sheet).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Stories", exact: true })).toBeVisible();
  expect((await feeds(daemon)).find((feed) => feed.url.endsWith("/thread.xml"))?.folder_id).toBe(id);
});

test("the Feeds plus menu opens the sheet from the keyboard", async ({ app }) => {
  const page = await app.open();
  const plus = page.getByRole("button", { name: "Add a feed or a folder" });
  await plus.focus();
  await page.keyboard.press("Enter");
  await expect(page.getByRole("menuitem", { name: "Add feed", exact: true })).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(page.getByRole("dialog", { name: "Add a feed" })).toBeVisible();
});

test("a folder's menu opens Add Feed with that folder selected and Esc keeps subscriptions", async ({ app, daemon }) => {
  const { id } = await daemon.call<{ id: number }>("folders.add", { name: "Reading" });
  const page = await app.open();
  await page.getByRole("button", { name: "Reading, folder" }).click({ button: "right" });
  await page.getByRole("menuitem", { name: "Add feed here" }).click();
  const sheet = page.getByRole("dialog", { name: "Add a feed" });
  await sheet.getByRole("textbox", { name: "Site or feed address" }).fill(daemon.base + "/thread.xml");
  await expect(sheet.getByRole("combobox", { name: "Folder" })).toHaveValue(String(id));
  await page.keyboard.press("Escape");
  await expect(sheet).toHaveCount(0);
  expect(await feeds(daemon)).toHaveLength(1);
});

test("discovery offers multiple feeds and only subscribes to the checked selection", async ({ app, daemon }) => {
  const page = await app.open({ FYKE_SCREEN: "add", FYKE_ADDRESS: daemon.base + "/feed-list" });
  const sheet = page.getByRole("dialog", { name: "Add a feed" });
  await expect(sheet.getByText("This site has 2 feeds. Pick the ones you want.")).toBeVisible();
  await sheet.getByRole("checkbox", { name: /Local/ }).uncheck();
  await expect(sheet.getByRole("button", { name: "Subscribe" })).toBeDisabled();
  await sheet.getByRole("checkbox", { name: /Hacker News/ }).check();
  await sheet.getByRole("combobox", { name: "Folder" }).selectOption("new");
  await sheet.getByRole("textbox", { name: "New folder" }).fill("Links");
  await sheet.getByRole("button", { name: "Create" }).click();
  await expect(sheet.getByRole("combobox", { name: "Folder" }).locator("option:checked")).toHaveText("Links");
  await sheet.getByRole("button", { name: "Subscribe" }).click();
  await expect(sheet).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Hacker News", exact: true })).toBeVisible();
});

test("no feed offers retry and changing the address shows the next preview", async ({ app, daemon }) => {
  const page = await app.open({ FYKE_SCREEN: "add", FYKE_ADDRESS: daemon.base + "/missing" });
  const sheet = page.getByRole("dialog", { name: "Add a feed" });
  await expect(sheet.getByText("No feed found on this site")).toBeVisible();
  await sheet.getByRole("button", { name: "Try again" }).click();
  const address = sheet.getByRole("textbox", { name: "Site or feed address" });
  await address.fill(daemon.base + "/thread.xml");
  await address.press("Enter");
  await expect(sheet.getByText("Unkernel in WASM")).toBeVisible();
});

test("OPML import and export keep the feed and its folder", async ({ app, daemon }) => {
  const page = await app.open({ FYKE_SCREEN: "add" });
  const sheet = page.getByRole("dialog", { name: "Add a feed" });
  await sheet.getByRole("button", { name: "Import OPML" }).click();
  await expect(sheet).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Imported, folder" })).toBeVisible();
  const { items } = await daemon.call<{ items: { id: number; name: string }[] }>("folders.list");
  expect((await feeds(daemon)).find((feed) => feed.url.endsWith("/thread.xml"))?.folder_id).toBe(items.find((folder) => folder.name === "Imported")?.id);

  await page.getByRole("button", { name: "Settings (Ctrl+,)", exact: true }).click();
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "Export", exact: true }).click();
  const file = await download;
  expect(file.suggestedFilename()).toBe("feeds.opml");
  const exported = await readFile(await file.path(), "utf8");
  expect(exported).toContain('text="Imported"');
  expect(exported).toContain(daemon.base + "/thread.xml");
});

for (const [screen, address, ready] of [
  ["add", "news", "Paste a site or feed address. The feed is found for you."],
  ["add-found", "/thread.xml", "Unkernel in WASM"],
  ["add-none", "/missing", "No feed found on this site"],
  ["add-multiple", "/feed-list", "This site has 2 feeds. Pick the ones you want."],
]) {
  for (const theme of ["light", "dark"] as const) {
    test(`shot:${screen} ${theme}`, async ({ app, daemon }, info) => {
      test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
      await afterRoutineSave(daemon);
      const page = await app.open({ FYKE_SCREEN: "add", FYKE_ADDRESS: address.startsWith("/") ? daemon.base + address : address }, theme);
      const sheet = page.getByRole("dialog", { name: "Add a feed" });
      await expect(sheet.getByText(ready, { exact: true })).toBeVisible();
      await app.snapshot(`${screen}-${theme}`, sheet);
    });
  }
}
