// S29: with no feeds, the content area says so and offers an address field and OPML
// import, as the Mac's FirstRunView. It has a data folder of its own, empty.
import { join } from "node:path";
import { expect, ownHome, snapshots, test } from "./fixtures";

test("with no feeds, the first run takes an address into Add Feed", async ({ page }) => {
  const own = await ownHome();
  try {
    await page.goto(own.url({ FYKE_THEME: "light" }));
    await expect(page.getByRole("heading", { name: "Nothing to read yet." })).toBeVisible();
    await expect(page.getByText(/^Add a site you like\. Everything stays on this (Mac|PC|computer)\.$/)).toBeVisible();
    await expect(page.getByRole("button", { name: "Import OPML" })).toBeVisible();
    await page.getByRole("textbox", { name: "Site or feed address" }).fill("example.org");
    await page.keyboard.press("Enter");
    const sheet = page.getByRole("dialog", { name: "Add a feed" });
    await expect(sheet).toBeVisible();
    await expect(sheet.getByRole("textbox").first()).toHaveValue("example.org");
  } finally {
    own.stop();
  }
});

for (const theme of ["light", "dark"] as const) {
  test(`shot:first-run ${theme}`, async ({ page }, info) => {
    test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
    const own = await ownHome();
    try {
      await page.goto(own.url({ FYKE_THEME: theme }));
      await expect(page.getByRole("heading", { name: "Nothing to read yet." })).toBeVisible();
      await page.screenshot({ path: join(snapshots, `first-run-${theme}.png`), animations: "disabled", caret: "hide" });
    } finally {
      own.stop();
    }
  });
}
