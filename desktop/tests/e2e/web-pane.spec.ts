import { discussionTest as test, expect, reset } from "./fixtures";

test.beforeEach(async ({ daemon }) => {
  await reset(daemon);
});

test("Open page shows the web bar, and Escape returns to the same article", async ({ app }) => {
  const page = await app.open();
  await page.getByRole("button", { name: /Unkernel in WASM/ }).click();
  await expect(page.locator(".article-title")).toHaveText("Unkernel in WASM");
  await page.getByRole("button", { name: "Open page", exact: true }).click();

  const web = page.getByRole("region", { name: "Web page" });
  await expect(web.getByText("example.org", { exact: true })).toBeVisible();
  await expect(web.getByRole("button", { name: "Previous page" })).toBeDisabled();
  await expect(web.getByText("This page did not open")).toBeVisible();
  await expect(page.locator("iframe")).toHaveCount(0);

  await page.keyboard.press("Escape");
  await expect(web).toHaveCount(0);
  await expect(page.locator(".article-title")).toHaveText("Unkernel in WASM");
});

test("Ctrl-click asks the default browser to open the link without replacing the article", async ({ app, page: browser }) => {
  await browser.addInitScript(() => {
    window.open = (url) => {
      document.documentElement.dataset.openedExternally = String(url);
      return null;
    };
  });
  const page = await app.open();
  await page.getByRole("button", { name: /Unkernel in WASM/ }).click();
  await expect(page.locator(".article-title")).toHaveText("Unkernel in WASM");
  // Chromium on macOS translates a physical Ctrl-click to a context menu.
  await page.getByRole("link", { name: "Comments", exact: true }).dispatchEvent("click", { ctrlKey: true });
  await expect(page.locator("html")).toHaveAttribute("data-opened-externally", "https://news.ycombinator.com/item?id=41");
  await expect(page.getByRole("region", { name: "Web page" })).toHaveCount(0);
  await expect(page.locator(".article-title")).toHaveText("Unkernel in WASM");
});

test("the web bar names the default browser, as the Mac's does (C8)", async ({ app }) => {
  const page = await app.open({ FYKE_BROWSER: "Firefox" });
  await page.getByRole("button", { name: /Unkernel in WASM/ }).click();
  await page.getByRole("button", { name: "Open page", exact: true }).click();
  const web = page.getByRole("region", { name: "Web page" });
  await expect(web.locator(".web-bar").getByRole("button", { name: "Open in Firefox" })).toBeVisible();
  // The failure's own button stays general, as on the Mac.
  await expect(web.locator(".web-failure").getByRole("button", { name: "Open in browser" })).toBeVisible();
});
