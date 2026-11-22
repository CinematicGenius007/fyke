// The development and test transport: a WebSocket to tools/bridge.ts, which speaks to the
// daemon's socket for a page in a plain browser. The page is opened with
// `?bridge=<port>&token=<token>`; the bridge refuses anyone without the token.
import { type DaemonEvent, type FailureFields, RPCFailure, type Transport } from "./index";

interface Reply {
  id: number;
  result?: unknown;
  error?: FailureFields;
  event?: DaemonEvent;
}

export function bridgeTransport(page: URL): Transport {
  const port = page.searchParams.get("bridge") ?? "1421";
  const token = page.searchParams.get("token") ?? "";
  const address = `ws://127.0.0.1:${port}/?token=${encodeURIComponent(token)}`;
  let socket: WebSocket | undefined;
  let opening: Promise<WebSocket> | undefined;
  let nextId = 1;
  const waiting = new Map<number, { resolve: (value: unknown) => void; reject: (error: RPCFailure) => void }>();
  const streams = new Map<number, (event: DaemonEvent) => void>();

  function open(): Promise<WebSocket> {
    if (socket?.readyState === WebSocket.OPEN) return Promise.resolve(socket);
    opening ??= new Promise((resolve, reject) => {
      const next = new WebSocket(address);
      next.onopen = () => {
        socket = next;
        opening = undefined;
        resolve(next);
      };
      next.onerror = () => {
        opening = undefined;
        reject(new RPCFailure({ message: "Cannot reach the development bridge" }));
      };
      next.onclose = () => {
        socket = undefined;
        for (const [, call] of waiting) call.reject(new RPCFailure({ message: "The development bridge closed", unknown: true }));
        waiting.clear();
      };
      next.onmessage = (message) => {
        const reply = JSON.parse(String(message.data)) as Reply;
        if (reply.event) {
          streams.get(reply.id)?.(reply.event);
          return;
        }
        const call = waiting.get(reply.id);
        if (!call) return;
        waiting.delete(reply.id);
        if (reply.error) call.reject(new RPCFailure(reply.error));
        else call.resolve(reply.result);
      };
    });
    return opening;
  }

  async function send<T>(request: Record<string, unknown>): Promise<T> {
    const ws = await open();
    const id = nextId++;
    return new Promise<T>((resolve, reject) => {
      waiting.set(id, { resolve: resolve as (value: unknown) => void, reject });
      ws.send(JSON.stringify({ ...request, id }));
    });
  }

  return {
    call: (method, params = {}, options = {}) => send({ op: "call", method, params, slow: options.slow ?? false }),
    subscribe(since, onEvent) {
      const id = nextId++;
      streams.set(id, onEvent);
      void open().then((ws) => ws.send(JSON.stringify({ op: "subscribe", id, since })));
      return () => {
        streams.delete(id);
        if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ op: "unsubscribe", id }));
      };
    },
    pause: (paused) => send({ op: "pause", paused }),
    testMode: () => send({ op: "test_mode" }),
    ready: () => send({ op: "ready" }),
    quit: (code) => send({ op: "quit", code }),
    dataHome: () => send({ op: "data_home" }),
    observeSettings: async (change) => {
      window.addEventListener("focus", change);
      return () => window.removeEventListener("focus", change);
    },
    desktopPaths: () => send({ op: "desktop_paths" }),
    openData: async () => { throw new Error("Open the desktop app to view local files."); },
    chooseFolder: async () => null,
    chooseDataFolder: async () => null,
    moveData: async () => { throw new Error("Open the desktop app to move the data folder."); },
    fontFamilies: async () => [],
    backgroundService: async (action) => {
      if (action === "status") return false;
      throw new Error("Open the desktop app to change background updating.");
    },
    openViewer: async () => { throw new Error("Open the Windows or Linux app to read pages here."); },
    closeViewer: async () => undefined,
    positionViewer: async () => undefined,
    navigateViewer: async () => undefined,
    observeViewer: async () => () => undefined,
    importOpml: () => send({ op: "import_opml" }),
    async exportOpml() {
      const { opml } = await send<{ opml: string }>({ op: "call", method: "opml.export" });
      const url = URL.createObjectURL(new Blob([opml], { type: "application/xml" }));
      const link = document.createElement("a");
      link.href = url;
      link.download = "feeds.opml";
      link.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    },
    // A page in a browser opens a tab; nothing here reaches the system.
    openExternal: async (url) => void window.open(url, "_blank", "noopener,noreferrer"),
    // A browser tab has no window to move. The actions are kept for the checks to read.
    windowAction: async (action) => {
      const page = window as unknown as { fykeWindowActions?: string[] };
      (page.fykeWindowActions ??= []).push(action);
    },
    observeMaximized: async (change) => {
      change(false);
      return () => undefined;
    },
  };
}
