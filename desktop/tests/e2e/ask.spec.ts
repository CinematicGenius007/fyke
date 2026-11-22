import { afterRoutineSave, expect, reset, test } from "./fixtures";

test.beforeEach(async ({ daemon }) => {
  await reset(daemon);
});

test("the palette asks a question, shows citations, and turns the answer into a routine draft", async ({ app, daemon }) => {
  const { id } = await daemon.call<{ id: number }>("views.put", { name: "Needle", rule: { words: "needle" } });
  const page = await app.open();
  await page.getByRole("button", { name: "Needle", exact: true }).click();
  await page.keyboard.press("Control+k");
  const question = "What arrived this week?";
  await page.getByRole("textbox", { name: "Command" }).fill(question);
  await page.keyboard.press("Tab");
  const ask = page.getByRole("region", { name: "Ask your feeds" });
  await expect(ask.getByRole("heading", { name: question })).toBeVisible();
  await expect(ask.getByRole("button", { name: "Source 1", exact: true }).first()).toBeVisible();
  const follow = ask.getByRole("textbox", { name: "Ask a follow-up" });
  await follow.fill("Which of them was newest?");
  await follow.press("Enter");
  await expect(ask.getByRole("heading", { name: "Which of them was newest?" })).toBeVisible();
  await expect(ask.getByText(`Earlier: ${question}`)).toBeVisible();
  await ask.getByRole("button", { name: "Make it a routine" }).click();
  await expect(page.getByRole("heading", { name: "Which of them was newest?", exact: true })).toBeVisible();
  await expect(page.getByRole("button", { name: "View: Needle" })).toBeVisible();
  const { items } = await daemon.call<{ items: { id: number }[] }>("routines.list");
  expect(items).toHaveLength(0);
  expect(id).toBeGreaterThan(0);
});

for (const theme of ["light", "dark"] as const) {
  test(`shot:ask ${theme}`, async ({ app, daemon }, info) => {
    test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
    await afterRoutineSave(daemon);
    const page = await app.open({ FYKE_SCREEN: "ask", FYKE_QUERY: "needle" }, theme);
    const ask = page.getByRole("region", { name: "Ask your feeds" });
    await expect(ask.getByRole("button", { name: "Source 1", exact: true }).first()).toBeVisible();
    await app.snapshot(`ask-${theme}`);
  });
}
