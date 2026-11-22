// A throwaway data folder with the shared GUI fixtures (tools/gui_fixtures.py), a
// daemon, and a bridge, for each worker. `app.open` loads the UI on one screen.
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { test as base, expect, type Locator, type Page } from "@playwright/test";

const desktop = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
export const repo = resolve(desktop, "..");
export const snapshots = join(repo, "zig-out/desktop-snapshots");
const fyke = process.env.FYKE_BIN || join(repo, "zig-out/bin/fyke");

function firstLine(child: ChildProcess, what: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const lines = createInterface({ input: child.stdout! });
    let errors = "";
    child.stderr?.on("data", (chunk) => (errors += chunk));
    lines.once("line", resolve);
    child.once("exit", (code) => reject(new Error(`${what} exited with ${code}: ${errors.trim()}`)));
  });
}

export interface Daemon {
  home: string;
  base: string;
  env: Record<string, string>;
  bridge: { port: number; token: string };
  /** One request to the daemon, for setup and checks. */
  call<T = unknown>(method: string, params?: object): Promise<T>;
}

export interface Screen {
  /** FYKE_SCREEN and friends, as the Mac's test mode takes them. */
  [variable: string]: string;
}

export interface App {
  open(screen?: Screen, theme?: "light" | "dark"): Promise<Page>;
  /** Saves the window as `name`.png in zig-out/desktop-snapshots. */
  snapshot(name: string, locator?: Locator): Promise<string>;
}

export const test = base.extend<{ app: App }, { daemon: Daemon }>({
  daemon: [
    async ({}, use) => {
      // Short, because socket paths are limited to about 100 bytes.
      const home = mkdtempSync(process.platform === "win32" ? join(process.env.TEMP ?? ".", "fyke-p-") : "/tmp/fyke-p-");
      const fixtures = spawn("python3", [join(repo, "tools/gui_fixtures.py"), "--home", home, "--fyke", fyke], { stdio: ["pipe", "pipe", "pipe"] });
      const prepared = JSON.parse(await firstLine(fixtures, "gui_fixtures.py")) as { base: string; env: Record<string, string> };
      const opml = join(home, "subscriptions.opml");
      writeFileSync(opml, `<opml version="2.0"><body><outline text="Imported"><outline type="rss" text="From OPML" xmlUrl="${prepared.base}/thread.xml"/></outline></body></opml>`);
      const env = { ...process.env, ...prepared.env, FYKE_HEADLESS: "1", FYKE_OPML_IMPORT: opml } as Record<string, string>;
      const bridge = spawn("bun", [join(desktop, "tools/bridge.ts"), "--port", "0"], { env, stdio: ["ignore", "pipe", "pipe"] });
      const address = JSON.parse(await firstLine(bridge, "bridge.ts")) as { port: number; token: string };
      const call = async <T,>(method: string, params: object = {}): Promise<T> => {
        const socket = new WebSocket(`ws://127.0.0.1:${address.port}/?token=${address.token}`);
        await new Promise((ready, fail) => ((socket.onopen = ready), (socket.onerror = fail)));
        const reply = await new Promise<{ result?: T; error?: { message: string } }>((done) => {
          socket.onmessage = (message) => done(JSON.parse(String(message.data)));
          socket.send(JSON.stringify({ id: 1, op: "call", method, params }));
        });
        socket.close();
        if (reply.error) throw new Error(`${method}: ${reply.error.message}`);
        return reply.result as T;
      };
      await use({ home, base: prepared.base, env: prepared.env, bridge: address, call });
      bridge.kill();
      fixtures.stdin?.end();
      spawnSync(fyke, ["daemon", "stop"], { env, timeout: 30_000 });
      rmSync(home, { recursive: true, force: true });
    },
    { scope: "worker" },
  ],
  app: async ({ page, daemon }, use) => {
    await use({
      async open(screen = {}, theme = "light") {
        const query = new URLSearchParams({ bridge: String(daemon.bridge.port), token: daemon.bridge.token, FYKE_THEME: theme, ...screen });
        await page.goto(`/?${query}`);
        await expect(page.locator("html[data-ready]")).toBeAttached();
        return page;
      },
      async snapshot(name, locator) {
        mkdirSync(snapshots, { recursive: true });
        const path = join(snapshots, `${name}.png`);
        await (locator ?? page).screenshot({ path, animations: "disabled", caret: "hide" });
        return path;
      },
    });
  },
});

// MARK: State the Mac's checks reset and read (tools/e2e_gui.py `scenario`)

export interface Entry {
  id: number;
  title: string;
  read: boolean;
}

/** As the Mac's checks do before each scenario: every article unread, no views. */
export async function reset(daemon: Daemon) {
  const entries = await daemon.call<{ items: Entry[] }>("entries.list", { limit: 100 });
  const read = entries.items.filter((e) => e.read).map((e) => e.id);
  if (read.length) await daemon.call("entries.mark_many", { ids: read, read: false });
  const views = await daemon.call<{ items: { id: number }[] }>("views.list");
  for (const view of views.items) await daemon.call("views.remove", { id: view.id, detach: true });
}

/** The titles the daemon has as read, which is what opening an article leaves behind. */
export async function readTitles(daemon: Daemon): Promise<string[]> {
  const entries = await daemon.call<{ items: Entry[] }>("entries.list", { limit: 100 });
  return entries.items
    .filter((e) => e.read)
    .map((e) => e.title)
    .sort();
}

export async function viewNames(daemon: Daemon): Promise<string[]> {
  const views = await daemon.call<{ items: { name: string }[] }>("views.list");
  return views.items.map((v) => v.name);
}

export { expect };


/** A discussion story for one test. The worker's other suites still see only Local. */
export const discussionTest = test.extend<{ threadFeed: number }>({
  threadFeed: [
    async ({ daemon }, use) => {
      const { id } = await daemon.call<{ id: number }>("feeds.add", { url: daemon.base + "/thread.xml", allow_private_network: true });
      try {
        await use(id);
      } finally {
        await daemon.call("feeds.remove", { id });
      }
    },
    { auto: true },
  ],
});
