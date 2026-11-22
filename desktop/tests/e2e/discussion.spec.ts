import { type Page } from "@playwright/test";
import { expect, reset, test } from "./fixtures";

test.beforeEach(async ({ daemon }) => {
  await reset(daemon);
  await daemon.call("feeds.add", { url: daemon.base + "/thread.xml", allow_private_network: true });
});

async function openStory(page: Page) {
  await page.getByRole("button", { name: /Unkernel in WASM/ }).click();
  await expect(page.locator(".article-title")).toHaveText("Unkernel in WASM");
}

test("comments load on c, keep their replies, and can be collapsed", async ({ page, app }) => {
  let requests = 0;
  page.on("websocket", (socket) => socket.on("framesent", (frame) => {
    if (typeof frame.payload === "string" && frame.payload.includes('"method":"entries.discussion"')) requests++;
  }));
  await app.open();
  await openStory(page);
  const comments = page.getByRole("region", { name: "Discussion" });
  await expect(comments.getByRole("button", { name: "Show comments" })).toBeVisible();
  expect(requests).toBe(0);

  await page.keyboard.press("c");
  await expect(comments.getByRole("heading", { name: "4 comments" })).toBeVisible();
  await expect(comments.getByRole("link", { name: "WebSocket proxy" })).toBeVisible();
  await expect(comments.getByRole("button", { name: "Deleted comment" })).toBeVisible();
  expect(requests).toBe(1);

  const author = comments.getByRole("button", { name: "ann", exact: true });
  await author.click();
  await expect(author).toHaveAttribute("aria-expanded", "false");
  await expect(comments.getByText("1 reply hidden")).toBeVisible();
  await expect(comments.getByRole("link", { name: "WebSocket proxy" })).toHaveCount(0);
  await author.click();
  await expect(comments.getByRole("link", { name: "WebSocket proxy" })).toBeVisible();

  await page.keyboard.press("c");
  expect(requests).toBe(1);
});

for (const theme of ["light", "dark"] as const) {
  test(`shot:comments ${theme}`, async ({ app }, info) => {
    test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
    const page = await app.open({}, theme);
    await openStory(page);
    await page.keyboard.press("c");
    await expect(page.getByRole("heading", { name: "4 comments" })).toBeVisible();
    await app.snapshot(`comments-${theme}`);
  });
}
