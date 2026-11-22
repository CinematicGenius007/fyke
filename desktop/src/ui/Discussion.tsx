// Discussions stay collapsed until asked. Comment text comes from the daemon's blocks.
import { createEffect, createMemo, createSignal, For, type JSX, Match, on, Show, Switch } from "solid-js";
import { app, words } from "../model/app";
import type { Block } from "../model/types";
import { transport } from "../transport";
import { Blocks } from "./Blocks";
import { Dates } from "./format";
import { Action, Rule, Spinner } from "./kit/Controls";
import { Icon } from "./kit/Icon";

interface Comment {
  id: number;
  author: string | null;
  at: number | null;
  depth: number;
  blocks: Block[];
}

interface Thread {
  url: string;
  comments: Comment[];
  truncated: boolean;
}

type State =
  | { kind: "idle" | "loading" }
  | { kind: "failed"; message: string }
  | { kind: "loaded"; thread: Thread };

export function Discussion(props: { id: number; address: string }) {
  const model = app();
  const [state, setState] = createSignal<State>({ kind: "idle" });
  const [collapsed, setCollapsed] = createSignal(new Set<number>());
  const url = new URL(props.address);
  const onHackerNews = url.hostname === "news.ycombinator.com" && url.pathname === "/item" && /^\d+$/.test(url.searchParams.get("id") ?? "");
  let section!: HTMLElement;

  function show() {
    if (state().kind === "idle" || state().kind === "failed") void load();
    section.scrollIntoView({ block: "start", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "instant" : "smooth" });
  }

  createEffect(on(() => model.state.discussionRequest, () => {
    if (onHackerNews) show();
    else model.openLink(props.address);
  }, { defer: true }));

  async function load() {
    setState({ kind: "loading" });
    try {
      const thread = await transport().call<Thread>("entries.discussion", { id: props.id }, { slow: true });
      setState({ kind: "loaded", thread });
    } catch (error) {
      setState({ kind: "failed", message: words(error) });
    }
  }

  function toggle(id: number) {
    const next = new Set(collapsed());
    if (next.has(id)) next.delete(id);
    else next.add(id);
    setCollapsed(next);
  }

  const thread = () => { const current = state(); return current.kind === "loaded" && current.thread; };
  const problem = () => { const current = state(); return current.kind === "failed" && current.message; };
  const replies = createMemo(() => {
    const result = new Map<number, number>();
    const open: { comment: Comment; index: number }[] = [];
    const comments = thread();
    if (!comments) return result;
    // Replies are the consecutive deeper rows that follow a comment.
    comments.comments.forEach((comment, index) => {
      while (open.length && open[open.length - 1].comment.depth >= comment.depth) {
        const parent = open.pop()!;
        result.set(parent.comment.id, index - parent.index - 1);
      }
      open.push({ comment, index });
    });
    for (const parent of open) result.set(parent.comment.id, comments.comments.length - parent.index - 1);
    return result;
  });
  const visible = createMemo(() => {
    const comments = thread();
    if (!comments) return [];
    const closed = collapsed();
    let below: number | null = null;
    return comments.comments.filter((comment) => {
      if (below !== null && comment.depth > below) return false;
      below = closed.has(comment.id) ? comment.depth : null;
      return true;
    });
  });
  const openSite = () => model.openLink(props.address);

  return (
    <section class="discussion" ref={section} aria-label="Discussion">
      <Rule />
      <Switch>
        <Match when={!onHackerNews}>
          <DiscussionHeader title="Discussion" detail={url.hostname}><Action onClick={openSite}>Open discussion</Action></DiscussionHeader>
        </Match>
        <Match when={state().kind === "idle"}>
          <DiscussionHeader title="Comments on Hacker News" detail="Read the thread here, under the article.">
            <Action onClick={show}>Show comments</Action>
          </DiscussionHeader>
        </Match>
        <Match when={state().kind === "loading"}>
          <div class="discussion-loading" role="status"><Spinner size={12} />Loading comments from Hacker News…</div>
        </Match>
        <Match when={problem()} keyed>{(message) => (
          <DiscussionHeader title="The comments did not load" detail={message + " The article is unaffected."}>
            <Action onClick={() => void load()}>Try again</Action>
            <Action kind="link" onClick={openSite}>Open on Hacker News</Action>
          </DiscussionHeader>
        )}</Match>
        <Match when={thread()} keyed>{(loaded) => (
          <>
            <DiscussionHeader title={loaded.comments.length === 1 ? "1 comment" : `${loaded.comments.length.toLocaleString()} comments`}
              detail={loaded.truncated ? `The first ${loaded.comments.length.toLocaleString()} from Hacker News. The rest are on the site.` : "From Hacker News"}>
              <Action kind="link" onClick={openSite}>Open on Hacker News</Action>
            </DiscussionHeader>
            <div class="discussion-replies">
              <Show when={!loaded.comments.length}><p>No one has commented yet.</p></Show>
              <For each={visible()}>{(comment) => {
                const folded = () => collapsed().has(comment.id);
                const count = () => replies().get(comment.id) ?? 0;
                return (
                  <div class="discussion-row" classList={{ folded: folded() }}>
                    <For each={Array.from({ length: Math.min(comment.depth, 6) })}>{() => <span class="discussion-indent" aria-hidden="true" />}</For>
                    <div class="discussion-comment">
                      <button type="button" class="discussion-author" aria-expanded={!folded()} aria-label={comment.author ?? "Deleted comment"}
                        title={folded() ? "Show this comment and its replies" : "Hide this comment and its replies"} onClick={() => toggle(comment.id)}>
                        <Icon name={folded() ? "right" : "down"} size={12} color="var(--muted)" />
                        <strong classList={{ deleted: comment.author === null }}>{comment.author ?? "Deleted comment"}</strong>
                        <Show when={comment.at !== null}><span>{Dates.named(new Date(comment.at!))}</span></Show>
                        <Show when={folded() && count()}><span>{count()} {count() === 1 ? "reply" : "replies"} hidden</span></Show>
                      </button>
                      <Show when={!folded() && comment.blocks.length}>
                        <div class="blocks selectable">
                          <Blocks blocks={comment.blocks} context={{ open: (address) => model.openLink(address) }} />
                        </div>
                      </Show>
                    </div>
                  </div>
                );
              }}</For>
            </div>
          </>
        )}</Match>
      </Switch>
    </section>
  );
}

function DiscussionHeader(props: { title: string; detail: string; children: JSX.Element }) {
  return (
    <div class="discussion-head">
      <div><h2>{props.title}</h2><p>{props.detail}</p></div>
      {props.children}
    </div>
  );
}
