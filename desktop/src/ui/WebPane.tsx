// The native webview is positioned under this toolbar. The renderer never embeds
// a page or passes feed text to the webview.
import { createEffect, createSignal, onCleanup, onMount, Show } from "solid-js";
import { app, words } from "../model/app";
import { type ViewerAction, type ViewerBounds, type ViewerUpdate, transport } from "../transport";
import { float } from "./Float";
import { Action, IconButton, Rule } from "./kit/Controls";
import { Icon } from "./kit/Icon";
import { isSafeLink } from "./links";

let nextToken = 0;

export function WebPane(props: { address: string }) {
  const model = app();
  const client = transport();
  const [page, setPage] = createSignal<ViewerUpdate>({ token: 0, url: props.address, loading: true, error: null, canGoBack: false, canGoForward: false });
  let token = 0;
  let slot!: HTMLDivElement;
  let mounted = false;
  let opened = false;
  let unlisten: (() => void) | undefined;
  let observer: ResizeObserver | undefined;
  let frame = 0;

  function bounds(): ViewerBounds {
    const { x, y, width, height } = slot.getBoundingClientRect();
    return { x: Math.max(0, x), y: Math.max(0, y), width, height };
  }

  function position() {
    if (!mounted || !opened) return;
    cancelAnimationFrame(frame);
    frame = requestAnimationFrame(() => {
      const hide = float.isOpen() || model.state.showingShortcuts || model.state.showingAddFeed ||
        model.state.confirmation || model.search.state.isShowing || model.commands.state.isShowing ||
        model.catchUp() || !!page().error || document.hidden;
      void client.positionViewer(token, bounds(), !hide).catch(() => undefined);
    });
  }

  function update(update: ViewerUpdate) {
    if (!mounted || update.token !== token) return;
    setPage(update);
    if (isSafeLink(update.url)) model.set("webBrowserAddress", update.url);
    position();
  }

  async function start(address: string) {
    const previous = token;
    const current = ++nextToken;
    token = current;
    opened = false;
    setPage({ token, url: address, loading: true, error: null, canGoBack: false, canGoForward: false });
    try {
      if (previous) await client.closeViewer(previous);
      if (!mounted || current !== token) return;
      await client.openViewer(current, address, bounds());
      if (mounted && current === token) {
        opened = true;
        position();
      }
    } catch (error) {
      if (mounted && current === token) setPage((state) => ({ ...state, loading: false, error: words(error) }));
    }
  }

  onMount(async () => {
    mounted = true;
    observer = new ResizeObserver(position);
    observer.observe(slot);
    window.addEventListener("resize", position);
    document.addEventListener("visibilitychange", position);
    try {
      const stop = await client.observeViewer(update);
      if (mounted) {
        unlisten = stop;
        await start(props.address);
      } else stop();
    } catch (error) {
      if (mounted) setPage((state) => ({ ...state, loading: false, error: words(error) }));
    }
  });

  onCleanup(() => {
    mounted = false;
    cancelAnimationFrame(frame);
    observer?.disconnect();
    window.removeEventListener("resize", position);
    document.removeEventListener("visibilitychange", position);
    unlisten?.();
    if (token) void client.closeViewer(token).catch(() => undefined);
  });

  createEffect(() => {
    // Position also follows controls drawn over the reader. A child native webview
    // otherwise sits above the HTML popup in its parent window.
    float.isOpen();
    model.state.showingShortcuts;
    model.state.showingAddFeed;
    model.state.confirmation;
    model.search.state.isShowing;
    model.commands.state.isShowing;
    model.catchUp();
    page().error;
    position();
  });

  const address = () => isSafeLink(page().url) ? new URL(page().url) : new URL(props.address);
  function navigate(action: ViewerAction) {
    if (action === "reload" && (page().error || !opened)) {
      void start(model.state.webBrowserAddress ?? props.address);
      return;
    }
    void client.navigateViewer(token, action).catch((error) => {
      setPage((state) => ({ ...state, loading: false, error: words(error) }));
    });
  }

  return (
    <section class="web-pane" aria-label="Web page">
      <div class="web-bar">
        <Action kind="quiet" compact onClick={model.closeWeb}><Icon name="left" size={14} />{model.state.article ? "Article" : "Back"}</Action>
        <IconButton icon="arrowLeft" label="Previous page" enabled={page().canGoBack} onClick={() => navigate("back")} />
        <IconButton icon="arrowRight" label="Next page" enabled={page().canGoForward} onClick={() => navigate("forward")} />
        <div class="web-address" title={address().href}>
          <Show when={address().protocol === "https:"}><Icon name="lock" size={14} /></Show>
          <strong>{address().host}</strong><span>{address().pathname + address().search + address().hash}</span>
        </div>
        <IconButton icon="reload" label="Reload" onClick={() => navigate("reload")} />
        <Action compact onClick={model.openInBrowser}><Icon name="globe" size={14} />Open in browser</Action>
      </div>
      <Rule />
      <div class="web-slot" ref={slot}>
        <Show when={page().loading && !page().error}><div class="web-progress" role="status" aria-label="Loading page" /></Show>
        <Show when={page().error}>{(error) => (
          <div class="web-failure" role="status">
            <h2>This page did not open</h2>
            <p>{error()}</p>
            <div><Action onClick={() => navigate("reload")}>Try again</Action><Action onClick={model.openInBrowser}>Open in browser</Action></div>
          </div>
        )}</Show>
      </div>
    </section>
  );
}
