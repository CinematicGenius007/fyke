import { type Daemon, expect, reset, test } from "./fixtures";

type SavedRoutine = { id: number; name: string; view_id: number | null; enabled: boolean | number; schedule: { kind: string } };

async function routines(daemon: Daemon) {
  return (await daemon.call<{ items: SavedRoutine[] }>("routines.list")).items;
}

async function view(daemon: Daemon) {
  return await daemon.call<{ id: number }>("views.put", { name: "Needle", rule: { words: "needle" } });
}

test.beforeEach(async ({ daemon }) => {
  for (const routine of await routines(daemon)) await daemon.call("routines.remove", { id: routine.id });
  await reset(daemon);
});

test("a routine starts from a view, saves on Ctrl+S, previews and runs", async ({ app, daemon }) => {
  const { id } = await view(daemon);
  const page = await app.open();
  const current = page.getByRole("button", { name: "Needle", exact: true });
  await current.click({ button: "right" });
  await page.getByRole("menuitem", { name: "Make a routine…" }).click();
  await expect(page.getByRole("heading", { name: "Morning needle", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Repeat: Every weekday" }).click();
  await page.getByRole("menuitem", { name: "Only when I run it" }).click();
  await page.keyboard.press("Control+s");
  await expect.poll(async () => (await routines(daemon))[0]?.view_id).toBe(id);
  await expect(page.getByText(/Nothing would have matched|Would have caught/)).toBeVisible();
  await page.getByRole("button", { name: "Run now", exact: true }).click();
  await expect(page.getByRole("region", { name: "Activity", exact: true })).toBeVisible();
  const routine = (await routines(daemon))[0];
  expect(routine.schedule.kind).toBe("manual");
  await expect.poll(async () => (await daemon.call<{ items: unknown[] }>("routines.runs", { id: routine.id })).items.length).toBeGreaterThan(0);
});

test("undo restores a removed view and reconnects its routine", async ({ app, daemon }) => {
  const { id } = await view(daemon);
  await daemon.call("routines.put", { name: "Morning needle", view_id: id, schedule: { kind: "manual" }, actions: [{ kind: "notify" }] });
  const page = await app.open();
  await page.getByRole("button", { name: "Needle", exact: true }).click({ button: "right" });
  await page.getByRole("menuitem", { name: "Remove view" }).click();
  await expect.poll(async () => (await routines(daemon))[0].view_id).toBeNull();
  await expect(page.locator(".toast")).toContainText("Removed");
  await page.keyboard.press("Control+z");
  await expect.poll(async () => (await routines(daemon))[0].view_id).not.toBeNull();
  const { items } = await daemon.call<{ items: { id: number; name: string }[] }>("views.list");
  expect((await routines(daemon))[0].view_id).toBe(items.find((view) => view.name === "Needle")?.id);
  expect((await routines(daemon))[0].enabled).toBeTruthy();
});

test("pause and resume are persisted and removal can be undone", async ({ app, daemon }) => {
  const { id } = await view(daemon);
  await daemon.call("routines.put", { name: "Morning needle", view_id: id, schedule: { kind: "manual" }, actions: [{ kind: "notify" }] });
  const page = await app.open({ FYKE_SCREEN: "routines" });
  await page.getByRole("switch", { name: "Pause Morning needle" }).click();
  await expect.poll(async () => Boolean((await routines(daemon))[0].enabled)).toBe(false);
  await page.getByRole("switch", { name: "Resume Morning needle" }).click();
  await expect.poll(async () => Boolean((await routines(daemon))[0].enabled)).toBe(true);
  await page.getByRole("button", { name: "Remove", exact: true }).click();
  await expect.poll(async () => (await routines(daemon)).length).toBe(0);
  await expect(page.locator(".toast")).toContainText("Removed");
  await page.keyboard.press("Control+z");
  await expect.poll(async () => (await routines(daemon))[0]?.name).toBe("Morning needle");
});

for (const theme of ["light", "dark"] as const) {
  test(`shot:routines ${theme}`, async ({ app, daemon }, info) => {
    test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
    const { id } = await view(daemon);
    await daemon.call("routines.put", { name: "Morning needle", view_id: id, schedule: { kind: "weekdays", time: "07:30" }, actions: [{ kind: "brief", recipe_id: 1 }, { kind: "notify" }] });
    const page = await app.open({ FYKE_SCREEN: "routines" }, theme);
    await expect(page.getByRole("heading", { name: "Morning needle", exact: true })).toBeVisible();
    await expect(page.getByText(/Nothing would have matched|Would have caught/)).toBeVisible();
    await app.snapshot(`routines-${theme}`);
  });
}
