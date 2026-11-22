// The UI's only way to the daemon. In the app it goes through Tauri (src-tauri/src/rpc.rs);
// in development and tests a page in a plain browser goes through tools/bridge.ts.
import { bridgeTransport } from "./bridge";
import { tauriTransport } from "./tauri";

/** A change from the daemon (`events.subscribe`, docs/api.md). */
export interface DaemonEvent {
  seq: number;
  type: string;
  subject_id?: number;
  [field: string]: unknown;
}

/** What a failed call carries, from either side. */
export interface FailureFields {
  message: string;
  kind?: string;
  code?: number;
  data?: unknown;
  /** The daemon may have done it; nobody knows. Never retried. */
  unknown?: boolean;
}

export class RPCFailure extends Error {
  readonly kind?: string;
  readonly code?: number;
  readonly data?: unknown;
  readonly unknown: boolean;

  constructor(fields: FailureFields) {
    super(fields.message);
    this.name = "RPCFailure";
    this.kind = fields.kind;
    this.code = fields.code;
    this.data = fields.data;
    this.unknown = fields.unknown ?? false;
  }

  /** Compares names whatever their spelling: `in_use`, `InUse` and `inUse` are one. */
  is(name: string): boolean {
    const flat = (text: string) => text.toLowerCase().replace(/[^\p{L}]/gu, "");
    return [this.kind, this.message].some((text) => text !== undefined && flat(text) === flat(name));
  }

  /** A daemon older than the operation answers that it does not know it. */
  get isUnknownMethod(): boolean {
    return this.is("UnknownMethod");
  }

  static from(error: unknown): RPCFailure {
    if (error instanceof RPCFailure) return error;
    if (error && typeof error === "object" && "message" in error) return new RPCFailure(error as FailureFields);
    return new RPCFailure({ message: String(error) });
  }
}

export interface CallOptions {
  /** Work that waits on the network gets its own connection and a longer timeout. */
  slow?: boolean;
}

export interface ViewerBounds {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface ViewerUpdate {
  token: number;
  url: string;
  loading: boolean;
  error: string | null;
  canGoBack: boolean;
  canGoForward: boolean;
}

export type ViewerAction = "back" | "forward" | "reload";

export interface Transport {
  call<T = unknown>(method: string, params?: object, options?: CallOptions): Promise<T>;
  /** Live events from `since`, resuming after drops. Returns a stop function. */
  subscribe(since: number, onEvent: (event: DaemonEvent) => void): () => void;
  /** While the data folder moves, a missing daemon must not be restarted. */
  pause(paused: boolean): Promise<void>;
  /** Every `FYKE_` variable the app was started with (see src-tauri/src/testmode.rs). */
  testMode(): Promise<Record<string, string>>;
  /** The UI has drawn: show the window, unless the run is headless. */
  ready(): Promise<void>;
  quit(code?: number): Promise<void>;
  /** Opens an http or https address in the system browser. */
  openExternal(url: string): Promise<void>;
  openViewer(token: number, url: string, bounds: ViewerBounds): Promise<void>;
  closeViewer(token: number): Promise<void>;
  positionViewer(token: number, bounds: ViewerBounds, visible: boolean): Promise<void>;
  navigateViewer(token: number, action: ViewerAction): Promise<void>;
  observeViewer(update: (update: ViewerUpdate) => void): Promise<() => void>;
  dataHome(): Promise<string>;
  importOpml(): Promise<boolean>;
  exportOpml(): Promise<void>;
}

let chosen: Transport | undefined;

export function transport(): Transport {
  if (!chosen) {
    const inTauri = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
    chosen = inTauri ? tauriTransport() : bridgeTransport(new URL(window.location.href));
  }
  return chosen;
}

/** For tests that give the UI a transport of their own. */
export function useTransport(next: Transport): void {
  chosen = next;
}
