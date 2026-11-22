// Renders the content model (src/blocks.zig) as the Mac's BlocksView does
// (gui/Sources/Reader/ReaderPane.swift). Feed content is untrusted: every word goes in
// as a text node, links only after the same check the Mac makes, and nothing here can
// run or load anything unless the reader asks for an image.
import { createSignal, For, type JSX, Match, Show, Switch } from "solid-js";
import { prefs } from "../model/prefs";
import type { Block } from "../model/types";
import { isSafeLink } from "./links";

const isInline = (node: Block) => ["text", "em", "strong", "link", "br"].includes(node.t) || (node.t === "code" && node.lang == null);

/** List items and quotes may hold bare inlines. Give those a paragraph. */
function wrap(nodes: Block[]): Block[] {
  const out: Block[] = [];
  let run: Block[] = [];
  const flush = () => {
    if (run.length) out.push({ t: "p", c: run } as Block);
    run = [];
  };
  for (const node of nodes) {
    if (isInline(node)) run.push(node);
    else {
      flush();
      out.push(node);
    }
  }
  flush();
  return out;
}

const unwrap = (nodes: Block[]) => nodes.flatMap((n) => (n.t === "p" ? (n.c ?? []) : [n]));

export interface BlockContext {
  open(url: string, event: MouseEvent): void;
}

function Inline(props: { nodes: Block[]; context: BlockContext; link?: string | null }): JSX.Element {
  return (
    <For each={props.nodes}>
      {(node) => (
        <Switch>
          <Match when={node.t === "text"}>
            <Show when={props.link} fallback={node.v ?? ""}>
              {(href) => (
                <a
                  href={href()}
                  rel="noreferrer noopener"
                  onClick={(event) => {
                    event.preventDefault();
                    props.context.open(href(), event);
                  }}
                >
                  {node.v ?? ""}
                </a>
              )}
            </Show>
          </Match>
          <Match when={node.t === "code"}>
            <code class="inline-code">{node.v ?? ""}</code>
          </Match>
          <Match when={node.t === "strong"}>
            <strong>
              <Inline nodes={node.c ?? []} context={props.context} link={props.link} />
            </strong>
          </Match>
          <Match when={node.t === "em"}>
            <em>
              <Inline nodes={node.c ?? []} context={props.context} link={props.link} />
            </em>
          </Match>
          <Match when={node.t === "link"}>
            <Inline nodes={node.c ?? []} context={props.context} link={isSafeLink(node.href) ? node.href : props.link} />
          </Match>
          <Match when={node.t === "br"}>
            <br />
          </Match>
        </Switch>
      )}
    </For>
  );
}

export function Blocks(props: { blocks: Block[]; context: BlockContext }): JSX.Element {
  return (
    <For each={props.blocks}>
      {(block) => (
        <Switch>
          <Match when={block.t === "p"}>
            <p class="b-p">
              <Inline nodes={block.c ?? []} context={props.context} />
            </p>
          </Match>
          <Match when={block.t === "h"}>
            <div class={`b-h level-${Math.min(Math.max(block.level ?? 2, 2), 4)}`} role="heading" aria-level={block.level ?? 2}>
              <Inline nodes={block.c ?? []} context={props.context} />
            </div>
          </Match>
          <Match when={block.t === "code"}>
            <pre class="b-code scroll">
              <code>{block.v ?? ""}</code>
            </pre>
          </Match>
          <Match when={block.t === "quote"}>
            <blockquote class="b-quote">
              <div class="b-quote-bar" />
              <div class="b-quote-body">
                <Blocks blocks={wrap(block.c ?? [])} context={props.context} />
              </div>
            </blockquote>
          </Match>
          <Match when={block.t === "list"}>
            <div class="b-list" role="list">
              <For each={block.items ?? []}>
                {(item, index) => (
                  <div class="b-item" role="listitem">
                    <span class="b-marker">{block.ordered ? `${index() + 1}.` : "•"}</span>
                    <div class="b-item-body">
                      <Blocks blocks={wrap(item)} context={props.context} />
                    </div>
                  </div>
                )}
              </For>
            </div>
          </Match>
          <Match when={block.t === "table"}>
            <div class="b-table" style={{ "grid-template-columns": `repeat(${Math.max(1, ...(block.rows ?? []).map((r) => r.length))}, auto)` }}>
              <For each={block.rows ?? []}>
                {(row) => <For each={row}>{(cell) => <div class="b-cell"><Inline nodes={unwrap(cell)} context={props.context} /></div>}</For>}
              </For>
            </div>
          </Match>
          <Match when={block.t === "hr"}>
            <div class="b-hr">
              <div class="rule" />
            </div>
          </Match>
          <Match when={block.t === "img"}>
            <ArticleImage block={block} />
          </Match>
          <Match when={block.t === "embed" && block.href}>
            <a
              class="b-embed"
              href={block.href!}
              rel="noreferrer noopener"
              onClick={(event) => {
                event.preventDefault();
                if (isSafeLink(block.href)) props.context.open(block.href!, event);
              }}
            >
              {block.href}
            </a>
          </Match>
        </Switch>
      )}
    </For>
  );
}

/** An image request tells the publisher you are reading, so loading is a choice. */
function ArticleImage(props: { block: Block }) {
  const [loadThisOne, setLoadThisOne] = createSignal(false);
  const url = () => (isSafeLink(props.block.src) ? props.block.src! : null);
  return (
    <Show when={url()}>
      {(src) => (
        <div class="b-img">
          <Show
            when={prefs().ui.load_images || loadThisOne()}
            fallback={
              <button type="button" class="b-img-load" onClick={() => setLoadThisOne(true)}>
                <span class="b-img-alt">{props.block.alt || "Image"}</span>
                <span class="b-img-action">Load</span>
              </button>
            }
          >
            <img src={src()} alt={props.block.alt ?? ""} referrerpolicy="no-referrer" loading="lazy" decoding="async" />
          </Show>
        </div>
      )}
    </Show>
  );
}
