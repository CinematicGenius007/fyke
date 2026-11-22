import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { expect, test } from "./fixtures";

test("Ctrl+0 opens Activity and Esc closes it", async ({ app }) => {
  const page = await app.open();
  await page.keyboard.press("Control+0");
  const activity = page.getByRole("region", { name: "Activity", exact: true });
  await expect(activity.getByText("Nothing running. Feeds refresh on their own.")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(activity).toHaveCount(0);
  await expect(page.getByRole("button", { name: /^Activity:/ })).toBeFocused();
});

test("Activity reveals a failing feed, its error, and the retry action", async ({ app, daemon }) => {
  const path = join(daemon.home, "failing.opml");
  const address = daemon.base + "/missing";
  await writeFile(path, `<opml version="2.0"><body><outline text="Missing feed" type="rss" xmlUrl="${address}"/></body></opml>`);
  await daemon.call("opml.import", { path, allow_private_network: true });
  const missing = async () => {
    const { items } = await daemon.call<{ items: { id: number; url: string; error_count: number }[] }>("feeds.list");
    return items.find((feed) => feed.url === address);
  };
  await expect.poll(async () => (await missing())?.error_count ?? 0).toBeGreaterThan(0);
  const page = await app.open();
  await page.getByRole("button", { name: "Activity: 1 thing needs you" }).click();
  const activity = page.getByRole("region", { name: "Activity", exact: true });
  await expect(activity.getByText("Missing feed is not loading")).toBeVisible();
  await activity.getByRole("button", { name: "Show", exact: true }).click();

  const health = page.getByRole("region", { name: "Feed health" });
  await expect(health.getByRole("heading", { name: "Missing feed is not loading" })).toBeVisible();
  await expect(health.getByText(/are kept, and Fyke keeps trying/)).toBeVisible();
  await expect(health.getByText("Error", { exact: true })).toBeVisible();
  const before = (await missing())!.error_count;
  await health.getByRole("button", { name: "Try again now" }).click();
  await expect.poll(async () => (await missing())?.error_count ?? 0).toBeGreaterThan(before);
  await daemon.call("feeds.remove", { id: (await missing())!.id });
});

for (const theme of ["light", "dark"] as const) {
  for (const shot of ["activity", "health", "toast"] as const) {
    test(`shot:${shot} ${theme}`, async ({ app }, info) => {
      test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
      const page = await app.open({ FYKE_SCREEN: shot }, theme);
      const title = shot === "activity" ? "Activity" : shot === "health" ? "Local" : "Marked 12 articles in Databases as read";
      await expect(page.getByText(title, { exact: true }).last()).toBeVisible();
      await app.snapshot(`${shot}-${theme}`);
    });
  }
}
