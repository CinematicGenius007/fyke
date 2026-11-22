// For development and tests only: lets the UI run in a plain browser (Playwright's WebKit,
// Chromium) by carrying its calls to the daemon's socket, as src-tauri/src/rpc.rs does in
// the app. It listens on 127.0.0.1 only and refuses any connection without its token.
//
//     FYKE_HOME=/tmp/scratch bun tools/bridge.ts [--port 1421] [--token T]
//
// It prints one JSON line when listening: {"port":…,"token":"…"}. Every `FYKE_` variable
// it was started with reaches the page as test mode, as the app's environment does.
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { accessSync, constants, mkdirSync } from "node:fs";
import { createConnection, type Socket } from "node:net";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

const MAX_REQUEST = 1 << 20;
const QUICK_TIMEOUT = 35_000;
const SLOW_TIMEOUT = 120_000;

function option(name: string): string | undefined {
  const at = process.argv.indexOf(`--${name}`);
  return at >= 0 ? process.argv[at + 1] : undefined;
}

const home = process.env.FYKE_HOME || join(homedir(), ".fyke");
const socketPath = join(home, "fyked.sock");
const program = process.env.FYKE_BIN || resolve(dirname(import.meta.dir), "..", "zig-out", "bin", "fyke");
const token = option("token") ?? randomBytes(16).toString("hex");
let paused = false;

interface Failure {
  message: string;
  kind?: string;
  code?: number;
  data?: unknown;
  unknown?: boolean;
}

/** One connection that reads newline-delimited replies. */
class Line {
  private buffer = "";
  private readers: ((line: string) => void)[] = [];
  private failures: ((error: Error) => void)[] = [];
  onLine?: (line: string) => void;

  constructor(readonly socket: Socket) {
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      this.buffer += chunk;
      let at: number;
      while ((at = this.buffer.indexOf("\n")) >= 0) {
        const line = this.buffer.slice(0, at);
        this.buffer = this.buffer.slice(at + 1);
        const reader = this.readers.shift();
        this.failures.shift();
        if (reader) reader(line);
        else this.onLine?.(line);
      }
    });
    const fail = (error: Error) => {
      for (const failure of this.failures.splice(0)) failure(error);
      this.readers = [];
    };
    socket.on("error", fail);
    socket.on("close", () => fail(new Error("the daemon closed the connection")));
  }

  next(timeout?: number): Promise<string> {
    return new Promise((resolve, reject) => {
      const timer = timeout ? setTimeout(() => reject(new Error("timed out")), timeout) : undefined;
      this.readers.push((line) => {
        clearTimeout(timer);
        resolve(line);
      });
      this.failures.push((error) => {
        clearTimeout(timer);
        reject(error);
      });
    });
  }
}

function connect(): Promise<Line> {
  return new Promise((resolve, reject) => {
    const socket = createConnection({ path: socketPath });
    socket.once("connect", () => resolve(new Line(socket)));
    socket.once("error", reject);
  });
}

async function open(): Promise<Line> {
  try {
    return await connect();
  } catch {
    if (paused) throw { message: "The data folder is moving" } satisfies Failure;
    try {
      accessSync(program, constants.X_OK);
    } catch {
      throw { message: `Cannot find the fyke program at ${program}` } satisfies Failure;
    }
    mkdirSync(home, { recursive: true });
    spawn(program, ["daemon", "--log"], { stdio: "ignore", detached: true, env: process.env }).unref();
    for (let i = 0; i < 300; i++) {
      try {
        return await connect();
      } catch {
        await Bun.sleep(10);
      }
    }
    throw { message: "The background service did not start" } satisfies Failure;
  }
}

let nextId = 1;

/** One call on its own connection. Development traffic is light, so nothing is shared. */
async function call(method: string, params: unknown, slow: boolean): Promise<unknown> {
  const line = JSON.stringify({ jsonrpc: "2.0", id: nextId++, method, params: params ?? {} }) + "\n";
  if (Buffer.byteLength(line) > MAX_REQUEST) throw { message: "The request is larger than 1 MiB", kind: "too_large" } satisfies Failure;
  const connection = await open();
  try {
    connection.socket.write(line);
    let text: string;
    try {
      text = await connection.next(slow ? SLOW_TIMEOUT : QUICK_TIMEOUT);
    } catch {
      throw { message: `The connection to the background service dropped, so Fyke cannot tell whether ${method} was done`, kind: "outcome_unknown", unknown: true } satisfies Failure;
    }
    const reply = JSON.parse(text);
    if (reply.error) {
      const data = reply.error.data ?? undefined;
      throw { message: reply.error.message, kind: data?.kind, code: reply.error.code, data } satisfies Failure;
    }
    if (!("result" in reply)) throw { message: "The daemon sent an empty reply" } satisfies Failure;
    return reply.result;
  } finally {
    connection.socket.end();
  }
}

/** Events from `since`, reconnecting a second after any drop, until `stopped()`. */
async function follow(since: number, emit: (event: Record<string, unknown>) => void, stopped: () => boolean) {
  let seq = since;
  while (!stopped()) {
    let connection: Line | undefined;
    try {
      connection = await open();
      const current = connection;
      const done = new Promise<void>((resolve) => current.socket.once("close", () => resolve()));
      current.onLine = (text) => {
        const params = JSON.parse(text).params;
        if (!params || typeof params !== "object") return;
        if (typeof params.seq === "number") seq = params.seq;
        if (!stopped()) emit(params);
      };
      current.socket.write(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "events.subscribe", params: { since_seq: seq, notifies: true } }) + "\n");
      const first = JSON.parse(await current.next());
      if (first.error) throw new Error(first.error.message);
      const watch = setInterval(() => stopped() && current.socket.destroy(), 200);
      await done;
      clearInterval(watch);
    } catch {
      connection?.socket.destroy();
    }
    if (!stopped()) await Bun.sleep(1000);
  }
}

function testMode(): Record<string, string> {
  return Object.fromEntries(Object.entries(process.env).filter(([name, value]) => name.startsWith("FYKE_") && value !== undefined)) as Record<string, string>;
}

interface Client {
  streams: Set<number>;
}

const server = Bun.serve<Client>({
  hostname: "127.0.0.1",
  port: Number(option("port") ?? 1421),
  fetch(request, server) {
    const url = new URL(request.url);
    if (url.searchParams.get("token") !== token) return new Response("Forbidden", { status: 403 });
    if (server.upgrade(request, { data: { streams: new Set() } })) return undefined;
    return new Response("WebSocket only", { status: 400 });
  },
  websocket: {
    maxPayloadLength: 4 * MAX_REQUEST,
    async message(ws, raw) {
      const request = JSON.parse(String(raw));
      const { id, op } = request;
      const reply = (body: object): void => {
        if (ws.readyState === 1) ws.send(JSON.stringify({ id, ...body }));
      };
      try {
        switch (op) {
          case "call":
            return reply({ result: (await call(request.method, request.params, request.slow)) ?? null });
          case "subscribe":
            ws.data.streams.add(id);
            void follow(request.since ?? 0, (event) => reply({ event }), () => !ws.data.streams.has(id) || ws.readyState !== 1);
            return;
          case "unsubscribe":
            ws.data.streams.delete(id);
            return;
          case "pause":
            paused = Boolean(request.paused);
            return reply({ result: null });
          case "test_mode":
            return reply({ result: testMode() });
          case "import_opml": {
            const path = process.env.FYKE_OPML_IMPORT;
            if (!path || process.env.FYKE_HEADLESS !== "1") {
              return reply({ error: { message: "Open the desktop app to import a file." } });
            }
            await call("opml.import", { path, allow_private_network: process.env.FYKE_LOCAL_FEEDS === "1" }, true);
            return reply({ result: true });
          }
          case "desktop_paths":
            return reply({ result: { data: home, config: join(home, "config.json"), home: process.env.HOME ?? null, program, canMove: false } });
          case "data_home":
            return reply({ result: home });
          case "ready":
            return reply({ result: null });
          case "quit":
            reply({ result: null });
            if (process.env.FYKE_BRIDGE_EXIT_ON_QUIT) setTimeout(() => process.exit(request.code ?? 0), 50);
            return;
          default:
            return reply({ error: { message: `Unknown operation ${op}` } });
        }
      } catch (error) {
        const failure = error instanceof Error ? { message: error.message } : (error as Failure);
        reply({ error: failure });
      }
    },
    close(ws) {
      ws.data.streams.clear();
    },
  },
});

console.log(JSON.stringify({ port: server.port, token }));
