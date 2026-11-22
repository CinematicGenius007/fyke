// X4: the daemon outlives the app, so after an update an older one can still be
// running. The app asks its api_version, stops it when it is older than its own, and
// the next call starts the current one (app.ts `replaceOutdatedDaemon`, as the Mac's
// AppModel does). Here an older daemon is a stand-in on the socket.
import { createServer, type Socket } from "node:net";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { expect, test } from "@playwright/test";
import { ownHome } from "./fixtures";

const olds = {
  "an older daemon": { api_version: 1, feeds: 0, entries: 0, unread: 0, due: 0, failing: 0, last_event_seq: 0, in_flight: 0 },
  // One that answers with a refusal is running all the same, so it is replaced too.
  "a daemon older than stats.get": null,
};

for (const [which, stats] of Object.entries(olds)) test(`${which} is stopped and the current one takes its place`, async ({ page }) => {
  const asked: string[] = [];
  const open = new Set<Socket>();
  const old = createServer((socket) => {
    open.add(socket);
    socket.on("close", () => open.delete(socket));
    createInterface({ input: socket }).on("line", (line) => {
      const request = JSON.parse(line) as { id: number; method: string };
      asked.push(request.method);
      const reply = request.method === "stats.get" && stats
        ? { result: stats }
        : request.method === "daemon.stop"
          ? { result: true }
          : { error: { code: -32601, message: "Method not found" } };
      socket.write(`${JSON.stringify({ jsonrpc: "2.0", id: request.id, ...reply })}\n`);
      if (request.method === "daemon.stop") {
        // As the daemon does: answer, then stop listening and close every connection.
        old.close();
        for (const s of open) s.end();
      }
    });
  });
  const own = await ownHome((home) => new Promise<void>((done) => old.listen(join(home, "fyked.sock"), done)));
  const { port, token } = own;
  try {
    await page.goto(own.url({ FYKE_THEME: "light" }));
    await expect(page.locator("html[data-ready]")).toBeAttached({ timeout: 15_000 });
    expect(asked.slice(0, 2)).toEqual(["stats.get", "daemon.stop"]);
    const stats = await page.evaluate(async ({ port, token }) => {
      const socket = new WebSocket(`ws://127.0.0.1:${port}/?token=${token}`);
      await new Promise((r) => (socket.onopen = r));
      const reply = await new Promise<{ result: { api_version: number } }>((done) => {
        socket.onmessage = (m) => done(JSON.parse(String(m.data)));
        socket.send(JSON.stringify({ id: 1, op: "call", method: "stats.get", params: {} }));
      });
      socket.close();
      return reply.result;
    }, { port, token });
    expect(stats.api_version).toBe(2);
    await expect(page.getByRole("button", { name: "All", exact: true })).toBeVisible();
  } finally {
    old.close();
    own.stop();
  }
});
