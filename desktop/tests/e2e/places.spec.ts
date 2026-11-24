// The places beside All and the views, and the built-in themes that are neither light
// nor dark, as pictures under the Mac's names (tools/e2e_gui.py `starred_snapshot`,
// `empty_view_snapshot`, `theme_snapshot`, and `snapshot("feed")`).
import { afterRoutineSave, type Daemon, type Entry, expect, reset, test } from "./fixtures";

test.describe.configure({ mode: "serial" });

const themes = ["light", "dark"] as const;

async function entryIds(daemon: Daemon): Promise<number[]> {
  return (await daemon.call<{ items: Entry[] }>("entries.list", { limit: 500 })).items.map((e) => e.id);
}

// As the Mac's checks leave it: every article unread and unstarred, no views or
// routines, and Local at the top level with no folders.
// Leave the worker's daemon as the next suite expects it.
test.afterEach(async ({ daemon }) => reset(daemon));

test.beforeEach(async ({ daemon }) => {
  await reset(daemon);
  const folders = (await daemon.call<{ items: { id: number }[] }>("folders.list")).items;
  for (const folder of folders.reverse()) await daemon.call("folders.remove", { id: folder.id }).catch(() => undefined);
  for (const feed of (await daemon.call<{ items: { id: number; url: string }[] }>("feeds.list")).items) {
    if (feed.url.endsWith("/feed.xml")) await daemon.call("feeds.update", { id: feed.id, top_level: true });
  }
});

for (const theme of themes) {
  test(`shot:starred ${theme}`, async ({ app, daemon }, info) => {
    test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
    await afterRoutineSave(daemon);
    const [newest] = await entryIds(daemon);
    await daemon.call("entries.mark_many", { ids: [newest], starred: true });
    const page = await app.open({ FYKE_SCREEN: "starred" }, theme);
    await expect(page.locator(".article-title")).toHaveText("Needle one");
    await app.snapshot(`starred-${theme}`);
  });

  test(`shot:starred-empty ${theme}`, async ({ app, daemon }, info) => {
    test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
    await afterRoutineSave(daemon);
    const page = await app.open({ FYKE_SCREEN: "starred" }, theme);
    await expect(page.getByText("Star an article to keep it here.")).toBeVisible();
    await app.snapshot(`starred-empty-${theme}`);
  });

  test(`shot:feed ${theme}`, async ({ app, daemon }, info) => {
    test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
    await afterRoutineSave(daemon);
    const page = await app.open({ FYKE_SCREEN: "feed" }, theme);
    await expect(page.locator(".article-title")).toBeVisible();
    await app.snapshot(`feed-${theme}`);
  });

  test(`shot:view-empty ${theme}`, async ({ app, daemon }, info) => {
    test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
    await afterRoutineSave(daemon);
    await daemon.call("views.put", { name: "Nothing yet", rule: { words: "zzqxv" } });
    const page = await app.open({ FYKE_SCREEN: "view-empty" }, theme);
    await expect(page.getByText("Nothing matches yet")).toBeVisible();
    await app.snapshot(`view-empty-${theme}`);
  });
}

for (const theme of ["newsprint", "terminal"] as const) {
  test(`shot:all-${theme}`, async ({ app, daemon }, info) => {
    test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
    await afterRoutineSave(daemon);
    const page = await app.open({ FYKE_SCREEN: "all" }, theme);
    await expect(page.locator(".article-title")).toHaveText("Needle one");
    await app.snapshot(`all-${theme}`);
  });

  test(`shot:feed-${theme}`, async ({ app, daemon }, info) => {
    test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
    await afterRoutineSave(daemon);
    const page = await app.open({ FYKE_SCREEN: "feed" }, theme);
    await expect(page.locator(".article-title")).toBeVisible();
    await app.snapshot(`feed-${theme}`);
  });
}

test("Starred lists only starred articles, and says so when there are none", async ({ app, daemon }) => {
  const page = await app.open({ FYKE_SCREEN: "starred" });
  await expect(page.getByText("Star an article to keep it here.")).toBeVisible();
  const [newest] = await entryIds(daemon);
  await daemon.call("entries.mark_many", { ids: [newest], starred: true });
  await page.keyboard.press("Control+2");
  await page.keyboard.press("Control+3");
  await expect(page.locator(".timeline-row")).toHaveCount(1);
});

/** The folders the daemon keeps closed; `ui` is null until something saves it. */
async function collapsed(daemon: Daemon): Promise<number[]> {
  return (await daemon.call<{ ui: { collapsed_folders?: number[] } | null }>("config.get")).ui?.collapsed_folders ?? [];
}

// S28: a closed folder stays closed after a relaunch, as the Mac keeps it in
// `ui.collapsed_folders`.
test("a closed folder stays closed after the app opens again", async ({ app, daemon }) => {
  const folder = (await daemon.call<{ id: number }>("folders.add", { name: "Reading" })).id;
  const local = (await daemon.call<{ items: { id: number }[] }>("feeds.list")).items[0].id;
  await daemon.call("feeds.update", { id: local, folder_id: folder });
  try {
    const page = await app.open({ FYKE_SCREEN: "all" }, null);
    const sidebar = page.locator(".sidebar");
    const feedRows = () => sidebar.locator(".sidebar-row").filter({ hasNotText: /^(Today|All|Starred|Routines|Search|Reading|Needle)\b/ });
    const before = await feedRows().count();
    await page.getByRole("button", { name: "Close Reading" }).click();
    await expect(page.getByRole("button", { name: "Open Reading" })).toBeVisible();
    await expect.poll(async () => collapsed(daemon)).toContain(folder);
    await expect(feedRows()).toHaveCount(before - 1);
    await app.open({ FYKE_SCREEN: "all" }, null);
    await expect(page.getByRole("button", { name: "Open Reading" })).toBeVisible();
    await expect(feedRows()).toHaveCount(before - 1);
    await page.getByRole("button", { name: "Open Reading" }).click();
    await expect(feedRows()).toHaveCount(before);
    await expect.poll(async () => collapsed(daemon)).not.toContain(folder);
  } finally {
    await daemon.call("config.set", { ui: {} });
    await daemon.call("folders.remove", { id: folder });
  }
});
