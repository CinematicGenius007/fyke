// S30: when the background service does not start, and when config.json has a mistake,
// the window says so in the problem banner above the content, in the Mac's words. Each
// test has a data folder of its own.
import { chmodSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Page } from "@playwright/test";
import { expect, ownHome, snapshots, test } from "./fixtures";

/** A stand-in for fyke that exits at once, so the service never answers. */
function silent(home: string) {
  const program = join(home, "fyke-silent");
  writeFileSync(program, "#!/bin/sh\nexit 0\n");
  chmodSync(program, 0o755);
  return { FYKE_BIN: program };
}

function mistake(home: string) {
  writeFileSync(join(home, "config.json"), '{"ui": {"theme": "light",, }');
}

const cases = {
  unavailable: { before: undefined, extra: silent, words: "The background service did not start" },
  "config-mistake": { before: mistake, extra: undefined, words: /^config\.json has a mistake, so the last good settings stay in use: / },
} as const;

async function banner(page: Page, words: string | RegExp) {
  const problem = page.locator(".problem");
  await expect(problem).toBeVisible({ timeout: 15_000 });
  await expect(problem.locator("span, p").first()).toHaveText(words);
  return problem;
}

test("a service that does not start is named in the banner, which can be dismissed", async ({ page }) => {
  test.skip(process.platform === "win32", "the stand-in program is a shell script");
  const own = await ownHome(undefined, silent);
  try {
    await page.goto(own.url({ FYKE_THEME: "light" }));
    const problem = await banner(page, cases.unavailable.words);
    await problem.getByRole("button", { name: "Dismiss" }).click();
    await expect(problem).toHaveCount(0);
  } finally {
    own.stop();
  }
});

test("a mistake in config.json is named in the banner and in General, and settings still work", async ({ page }) => {
  const own = await ownHome(mistake);
  try {
    await page.goto(own.url({ FYKE_THEME: "light" }));
    await banner(page, cases["config-mistake"].words);
    await expect(page.getByRole("heading", { name: "Nothing to read yet." })).toBeVisible();
    await page.keyboard.press("Control+,");
    await expect(page.getByRole("status").filter({ hasText: "config.json has a mistake" })).toBeVisible();
  } finally {
    own.stop();
  }
});

for (const [name, scenario] of Object.entries(cases)) {
  for (const theme of ["light", "dark"] as const) {
    test(`shot:${name} ${theme}`, async ({ page }, info) => {
      test.skip(info.project.name !== "webkit", "pictures compare against the Mac in WebKit");
      const own = await ownHome(scenario.before, scenario.extra);
      try {
        await page.goto(own.url({ FYKE_THEME: theme }));
        await banner(page, scenario.words);
        await page.screenshot({ path: join(snapshots, `${name}-${theme}.png`), animations: "disabled", caret: "hide" });
      } finally {
        own.stop();
      }
    });
  }
}
