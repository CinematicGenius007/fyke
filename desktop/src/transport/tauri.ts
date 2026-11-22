// The app's transport: Tauri commands in src-tauri/src/lib.rs.
import { Channel, invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { open } from "@tauri-apps/plugin-dialog";
import { type CallOptions, type DaemonEvent, RPCFailure, type Transport, type ViewerUpdate } from "./index";

const EVENT = "fyke://event";

export function tauriTransport(): Transport {
  return {
    async call<T>(method: string, params: object = {}, options: CallOptions = {}) {
      try {
        return await invoke<T>("call", { method, params, slow: options.slow ?? false });
      } catch (error) {
        throw RPCFailure.from(error);
      }
    },
    subscribe(since, onEvent) {
      let stopped = false;
      let unlisten: (() => void) | undefined;
      void listen<DaemonEvent>(EVENT, (message) => onEvent(message.payload)).then((stop) => {
        if (stopped) stop();
        else unlisten = stop;
        if (!stopped) void invoke("subscribe", { since });
      });
      return () => {
        stopped = true;
        unlisten?.();
      };
    },
    pause: (paused) => invoke("pause", { paused }),
    testMode: () => invoke("test_mode"),
    ready: () => invoke("ready"),
    quit: (code) => invoke("quit", { code }),
    dataHome: () => invoke("data_home"),
    observeSettings: (change) => listen("fyke://config", change),
    desktopPaths: () => invoke("desktop_paths"),
    openData: (item) => invoke("open_data", { item }),
    chooseFolder: (title) => open({ title, directory: true }),
    chooseDataFolder: () => invoke("choose_data_folder"),
    moveData: (target, stage) => invoke("move_data", { target, stages: new Channel<string>(stage) }),
    fontFamilies: () => invoke("font_families"),
    backgroundService: (action) => invoke("background_service", { action }),
    openViewer: (token, url, bounds) => navigator.userAgent.includes("Macintosh")
      ? Promise.reject(new Error("Open the Windows or Linux app to read pages here."))
      : invoke("open_viewer", { token, url, bounds }),
    closeViewer: (token) => invoke("close_viewer", { token }),
    positionViewer: (token, bounds, visible) => invoke("position_viewer", { token, bounds, visible }),
    navigateViewer: (token, action) => invoke("navigate_viewer", { token, action }),
    observeViewer: (update) => listen<ViewerUpdate>("fyke://page", (event) => update(event.payload)),
    importOpml: () => invoke("import_opml"),
    exportOpml: () => invoke("export_opml"),
    openExternal: (url) => invoke("open_external", { url }),
    windowAction(action) {
      const window = getCurrentWindow();
      if (action === "minimize") return window.minimize();
      if (action === "maximize") return window.toggleMaximize();
      if (action === "close") return window.close();
      return window.startDragging();
    },
    async observeMaximized(change) {
      const window = getCurrentWindow();
      change(await window.isMaximized());
      return window.onResized(async () => change(await window.isMaximized()));
    },
  };
}
