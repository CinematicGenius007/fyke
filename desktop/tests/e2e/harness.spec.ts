// The harness itself: the UI loads through the bridge, reaches the daemon, and saves a
// picture under the Mac's name.
import type { Transport } from "../../src/transport";
import { expect, test } from "./fixtures";

/** The page's own transport. Runs in the page, so it imports by the dev server's path. */
type Module = { transport(): Transport };

test("the UI reaches the daemon through the bridge", async ({ app, daemon }) => {
  const page = await app.open();
  const feeds = await page.evaluate(async () => {
    const path = "/src/transport/index.ts";
    const { transport }: Module = await import(/* @vite-ignore */ path);
    return transport().call<{ items: { title: string }[] }>("feeds.list");
  });
  expect(feeds.items.map((feed) => feed.title)).toContain("Local");
  const entries = await daemon.call<{ items: unknown[] }>("entries.list", {});
  expect(entries.items.length).toBe(3);
});

test("a refusal arrives with the daemon's kind", async ({ app }) => {
  const page = await app.open();
  const failure = await page.evaluate(async () => {
    const path = "/src/transport/index.ts";
    const { transport }: Module = await import(/* @vite-ignore */ path);
    try {
      await transport().call("no.such_method");
      return null;
    } catch (error) {
      const failure = error as { kind?: string; unknown: boolean; isUnknownMethod: boolean };
      return { kind: failure.kind, unknown: failure.unknown, isUnknownMethod: failure.isUnknownMethod };
    }
  });
  expect(failure).not.toBeNull();
  expect(failure!.unknown).toBe(false);
  expect(failure!.isUnknownMethod).toBe(true);
});
