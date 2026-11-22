// Phase 4, managing feeds: renaming in place, folders, moving and removing. The Mac's
// RenameField, newFolder and the sidebar menus (gui/Sources/Reader/Sidebar.swift).
import type { Page } from "@playwright/test";
import { afterRoutineSave, type Daemon, expect, reset, test, viewNames } from "./fixtures";

test.describe.configure({ mode: "serial" });

interface Folder {
  id: number;
  name: string;
  parent_id: number | null;
}
interface Feed {
  id: number;
  url: string;
  title: string | null;
  folder_id: number | null;
}

async function folders(daemon: Daemon): Promise<Folder[]> {
  return (await daemon.call<{ items: Folder[] }>("folders.list")).items;
}
async function feeds(daemon: Daemon): Promise<Feed[]> {
  return (await daemon.call<{ items: Feed[] }>("feeds.list")).items;
}
const folderNames = async (daemon: Daemon) => (await folders(daemon)).map((f) => f.name).sort();

/** Every folder gone with what it holds kept, only the Local feed, under its own title. */
async function resetTree(daemon: Daemon) {
  await reset(daemon);
  for (const folder of (await folders(daemon)).reverse()) await daemon.call("folders.remove", { id: folder.id }).catch(() => undefined);
  for (const feed of await feeds(daemon)) {
    if (!feed.url.endsWith("/feed.xml")) await daemon.call("feeds.remove", { id: feed.id });
    else await daemon.call("feeds.update", { id: feed.id, title: "", top_level: true });
  }
}

/** The fixture's second feed, a Hacker News story, beside Local. */
async function addThreadFeed(daemon: Daemon): Promise<number> {
  const local = (await feeds(daemon)).find((f) => f.url.endsWith("/feed.xml"))!;
  const added = await daemon.call<{ id: number }>("feeds.add", { url: local.url.replace("/feed.xml", "/thread.xml"), allow_private_network: true });
  return added.id;
}

async function menu(page: Page, row: string, item: string) {
  await page.getByRole("button", { name: row, exact: true }).click({ button: "right" });
  await page.getByRole("menuitem", { name: item, exact: true }).click();
}

test.beforeEach(async ({ daemon }) => resetTree(daemon));

async function palette(page: Page, query: string) {
  await page.keyboard.press("Control+K");
  await expect(page.getByRole("textbox", { name: "Command" })).toBeFocused();
  await page.keyboard.type(query);
  // Places rank above commands, so a folder named like the command comes first.
  await page.getByRole("dialog", { name: "Command palette" }).locator(".palette-row:not(.article)", { hasText: query }).last().click();
}

test("a saved search's name is up for editing, and Return keeps a new one", async ({ app, daemon }) => {
  const page = await app.open();
  await page.keyboard.press("Control+F");
  await page.keyboard.type("needle");
  await expect(page.locator(".search-count")).toHaveText("3 results");
  await page.keyboard.press("Control+S");
  const field = page.getByRole("textbox", { name: "Rename Needle" });
  await expect(field).toBeFocused();
  await expect(page.locator(".rename-note")).toHaveText("↵ to keep");
  await page.keyboard.type("Pins");
  await page.keyboard.press("Enter");
  await expect.poll(() => viewNames(daemon)).toEqual(["Pins"]);
  await expect(page.locator(".sidebar-row", { hasText: "Pins" })).toBeVisible();
});

test("Esc keeps the name and gives the keys back to the list", async ({ app, daemon }) => {
  const page = await app.open();
  await page.keyboard.press("Control+F");
  await page.keyboard.type("needle");
  await expect(page.locator(".search-count")).toHaveText("3 results");
  await page.keyboard.press("Control+S");
  await expect(page.getByRole("textbox", { name: "Rename Needle" })).toBeFocused();
  await page.keyboard.type("Other");
  await page.keyboard.press("Escape");
  await expect(page.locator(".rename-field")).toHaveCount(0);
  expect(await viewNames(daemon)).toEqual(["Needle"]);
  // The reader's keys work again: Down selects the first article and Return opens it.
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("Enter");
  await expect(page.locator(".article-title")).toHaveText("Needle one");
});

test("New folder makes one and puts its name up for editing", async ({ app, daemon }) => {
  const page = await app.open();
  await palette(page, "New folder");
  const field = page.getByRole("textbox", { name: "Rename New folder" });
  await expect(field).toBeFocused();
  await expect.poll(() => folderNames(daemon)).toEqual(["New folder"]);
  await page.keyboard.type("Reading");
  await page.keyboard.press("Enter");
  await expect.poll(() => folderNames(daemon)).toEqual(["Reading"]);
  await expect(page.getByRole("button", { name: "Reading, folder" })).toBeVisible();
});

test("a second new folder takes the next free name, and a taken name is refused in words", async ({ app, daemon }) => {
  await daemon.call("folders.add", { name: "New folder" });
  await daemon.call("folders.add", { name: "Reading" });
  const page = await app.open();
  await palette(page, "New folder");
  await expect(page.getByRole("textbox", { name: "Rename New folder 2" })).toBeFocused();
  await page.keyboard.type("Reading");
  await page.keyboard.press("Enter");
  await expect(page.getByText("A folder with that name is already there")).toBeVisible();
  expect(await folderNames(daemon)).toEqual(["New folder", "New folder 2", "Reading"]);
});

test("a folder's menu renames it in place", async ({ app, daemon }) => {
  await daemon.call("folders.add", { name: "Reading" });
  const page = await app.open();
  await menu(page, "Reading, folder", "Rename");
  await expect(page.getByRole("textbox", { name: "Rename Reading" })).toBeFocused();
  await page.keyboard.type("Later");
  await page.keyboard.press("Enter");
  await expect.poll(() => folderNames(daemon)).toEqual(["Later"]);
});

test("a feed's menu renames it, and an empty name gives back its own title", async ({ app, daemon }) => {
  const page = await app.open();
  await menu(page, "Local", "Rename");
  await page.keyboard.type("Pins");
  await page.keyboard.press("Enter");
  await expect(page.getByRole("button", { name: "Pins", exact: true })).toBeVisible();
  await expect.poll(async () => (await feeds(daemon))[0].title).toBe("Pins");
  await menu(page, "Pins", "Rename");
  await page.keyboard.press("Backspace");
  await page.keyboard.press("Enter");
  await expect(page.getByRole("button", { name: "Local", exact: true })).toBeVisible();
});

test("Move to puts a feed in a folder and back at the top level", async ({ app, daemon }) => {
  const reading = (await daemon.call<{ id: number }>("folders.add", { name: "Reading" })).id;
  const page = await app.open();
  await page.getByRole("button", { name: "Local", exact: true }).click({ button: "right" });
  await page.getByRole("menuitem", { name: "Move to" }).click();
  await expect(page.getByRole("menuitem", { name: "Top level" })).toBeVisible();
  await page.getByRole("menuitem", { name: "Reading" }).click();
  await expect.poll(async () => (await feeds(daemon))[0].folder_id).toBe(reading);
  await expect(page.getByRole("menu")).toHaveCount(0);
  await page.getByRole("button", { name: "Local", exact: true }).click({ button: "right" });
  await page.getByRole("menuitem", { name: "Move to" }).click();
  await page.getByRole("menuitem", { name: "Top level" }).click();
  await expect.poll(async () => (await feeds(daemon))[0].folder_id ?? null).toBe(null);
});

test("Move to › New folder makes a folder holding the feed and names it", async ({ app, daemon }) => {
  const page = await app.open();
  await page.getByRole("button", { name: "Local", exact: true }).click({ button: "right" });
  await page.getByRole("menuitem", { name: "Move to" }).click();
  await page.getByRole("menuitem", { name: "New folder" }).click();
  await expect(page.getByRole("textbox", { name: "Rename New folder" })).toBeFocused();
  await page.keyboard.type("News");
  await page.keyboard.press("Enter");
  await expect.poll(() => folderNames(daemon)).toEqual(["News"]);
  const news = (await folders(daemon))[0].id;
  expect((await feeds(daemon))[0].folder_id).toBe(news);
});

test("Esc and a click elsewhere close a menu without acting", async ({ app, daemon }) => {
  const page = await app.open();
  await page.getByRole("button", { name: "Local", exact: true }).click({ button: "right" });
  await expect(page.getByRole("menu")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByRole("menu")).toHaveCount(0);
  await page.getByRole("button", { name: "Local", exact: true }).click({ button: "right" });
  await page.mouse.click(900, 600);
  await expect(page.getByRole("menu")).toHaveCount(0);
  expect((await feeds(daemon)).length).toBe(1);
});

test("deleting a folder asks first; Esc keeps it, and Delete moves what it holds up", async ({ app, daemon }) => {
  const reading = (await daemon.call<{ id: number }>("folders.add", { name: "Reading" })).id;
  const local = (await feeds(daemon))[0];
  await daemon.call("feeds.update", { id: local.id, folder_id: reading });
  const page = await app.open();
  await menu(page, "Reading, folder", "Delete folder…");
  const dialog = page.getByRole("alertdialog", { name: "Delete Reading?" });
  await expect(dialog).toContainText("Its 1 feed moves up to the top level. Your articles stay.");
  await expect(dialog.getByRole("button", { name: "Cancel" })).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(dialog).toHaveCount(0);
  expect(await folderNames(daemon)).toEqual(["Reading"]);
  await menu(page, "Reading, folder", "Delete folder…");
  await dialog.getByRole("button", { name: "Delete folder" }).click();
  await expect.poll(() => folderNames(daemon)).toEqual([]);
  expect((await feeds(daemon))[0].folder_id ?? null).toBe(null);
});

test("deleting a folder with everything inside removes its feeds", async ({ app, daemon }) => {
  const reading = (await daemon.call<{ id: number }>("folders.add", { name: "Reading" })).id;
  const thread = await addThreadFeed(daemon);
  await daemon.call("feeds.update", { id: thread, folder_id: reading });
  const page = await app.open();
  await menu(page, "Reading, folder", "Delete folder…");
  const dialog = page.getByRole("alertdialog", { name: "Delete Reading?" });
  await dialog.getByRole("checkbox", { name: "Also delete everything inside" }).click();
  await expect(dialog).toContainText("Removes 1 feed, 1 article. This cannot be undone.");
  await dialog.getByRole("button", { name: "Delete folder" }).click();
  await expect.poll(async () => (await feeds(daemon)).map((f) => f.id).includes(thread)).toBe(false);
  expect(await folderNames(daemon)).toEqual([]);
});

test("removing a feed asks first, and Remove unsubscribes", async ({ app, daemon }) => {
  const thread = await addThreadFeed(daemon);
  const page = await app.open();
  await menu(page, "Hacker News", "Remove feed…");
  const dialog = page.getByRole("alertdialog", { name: "Remove Hacker News?" });
  await expect(dialog).toContainText("This deletes 1 article. This cannot be undone.");
  await dialog.getByRole("button", { name: "Cancel" }).click();
  expect((await feeds(daemon)).length).toBe(2);
  await menu(page, "Hacker News", "Remove feed…");
  await dialog.getByRole("button", { name: "Remove feed" }).click();
  await expect.poll(async () => (await feeds(daemon)).map((f) => f.id).includes(thread)).toBe(false);
});

test("a view's menu removes it, and Ctrl+Z puts it back", async ({ app, daemon }) => {
  await daemon.call("views.put", { name: "Needle", rule: { words: "needle" } });
  const page = await app.open();
  await menu(page, "Needle", "Remove view");
  await expect.poll(() => viewNames(daemon)).toEqual([]);
  await expect(page.locator(".toast")).toContainText("Removed “Needle”");
  await page.keyboard.press("Control+Z");
  await expect.poll(() => viewNames(daemon)).toEqual(["Needle"]);
});

test("a view's menu moves it down and up", async ({ app, daemon }) => {
  await daemon.call("views.put", { name: "First", rule: { words: "needle" } });
  await daemon.call("views.put", { name: "Second", rule: { words: "text" } });
  const page = await app.open();
  await menu(page, "First", "Move down");
  await expect.poll(() => viewNames(daemon)).toEqual(["Second", "First"]);
  await menu(page, "First", "Move up");
  await expect.poll(() => viewNames(daemon)).toEqual(["First", "Second"]);
});

// The Mac takes these with a folder "Reading" holding Local (tools/e2e_gui.py `tree_snapshot`).
for (const screen of ["rename-folder", "rename-feed", "delete-folder", "folder"] as const) {
  for (const theme of ["light", "dark"] as const) {
    test(`shot:${screen} ${theme}`, async ({ app, daemon }, info) => {
      test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
      await afterRoutineSave(daemon);
      const folder = await daemon.call<{ id: number }>("folders.add", { name: "Reading", parent_id: null });
      const local = (await feeds(daemon))[0];
      await daemon.call("feeds.update", { id: local.id, folder_id: folder.id, top_level: false });
      const page = await app.open({ FYKE_SCREEN: screen, FYKE_QUERY: "needle" }, theme);
      if (screen === "delete-folder") await expect(page.getByRole("alertdialog")).toBeVisible();
      else if (screen === "folder") await expect(page.locator(".article-title")).toBeVisible();
      else await expect(page.locator(".rename-field")).toBeFocused();
      await app.snapshot(`${screen}-${theme}`);
    });
  }
}

test("dragging a feed or folder moves it, and dragging to Feeds puts it back at the top level", async ({ app, daemon }) => {
  const reading = (await daemon.call<{ id: number }>("folders.add", { name: "Reading" })).id;
  const later = (await daemon.call<{ id: number }>("folders.add", { name: "Later" })).id;
  const page = await app.open();
  const local = page.getByRole("button", { name: "Local", exact: true });
  const destination = page.getByRole("button", { name: "Reading, folder" });
  const header = page.getByRole("heading", { name: "Feeds" });
  await local.dragTo(destination);
  await expect.poll(async () => (await feeds(daemon))[0].folder_id).toBe(reading);
  await local.dragTo(header);
  await expect.poll(async () => (await feeds(daemon))[0].folder_id ?? null).toBe(null);

  const laterRow = page.getByRole("button", { name: "Later, folder" });
  await laterRow.dragTo(destination);
  await expect.poll(async () => (await folders(daemon)).find((folder) => folder.id === later)?.parent_id).toBe(reading);
  await laterRow.dragTo(header);
  await expect.poll(async () => (await folders(daemon)).find((folder) => folder.id === later)?.parent_id ?? null).toBe(null);
});
