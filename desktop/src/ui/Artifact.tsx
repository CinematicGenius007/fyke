// Generated claims and their numbered sources are rendered as text and buttons.
import { createSignal, For, type JSX, onCleanup, Show } from "solid-js";
import { SourcesNote } from "../logic/SourcesNote";
import { prefs } from "../model/prefs";
import type { Artifact, Citation } from "../model/types";
import { Dates } from "./format";
import { Action, Rule, SectionLabel } from "./kit/Controls";
import { Icon } from "./kit/Icon";

interface Focus {
  citation: Citation;
  anchor: HTMLButtonElement;
  pinned: boolean;
}

export function ArtifactColumn(props: {
  artifact: Artifact;
  openSource: (id: number) => void;
  header: JSX.Element;
  footer?: JSX.Element;
  pinSource?: number;
}) {
  const [focus, setFocus] = createSignal<Focus | null>(null);
  let column!: HTMLElement;
  let closeTimer: ReturnType<typeof setTimeout> | undefined;
  const keepOpen = () => clearTimeout(closeTimer);
  onCleanup(keepOpen);

  function closeSoon() {
    keepOpen();
    closeTimer = setTimeout(() => {
      if (!focus()?.pinned) setFocus(null);
    }, 250);
  }

  function choose(number: number, anchor: HTMLButtonElement, pin: boolean) {
    keepOpen();
    const current = focus();
    const citation = props.artifact.citations.find((source) => source.number === number);
    if (!citation || (!pin && current?.pinned)) return;
    setFocus(current?.pinned && current.anchor === anchor ? null : { citation, anchor, pinned: pin });
  }

  function open(source: Citation) {
    setFocus(null);
    props.openSource(source.entryId);
  }

  function coordinates(anchor: HTMLElement) {
    const box = anchor.getBoundingClientRect();
    const area = column.getBoundingClientRect();
    return { top: `${box.bottom - area.top + 4}px`, left: `${Math.min(Math.max(0, box.left - area.left - 16), area.width - 340)}px` };
  }

  const note = () => SourcesNote.text(props.artifact.omittedCount, props.artifact.inputCount, props.artifact.citations.length);
  let requested = false;
  return (
    <div class="reader-scroll scroll">
      <article class="artifact-column" ref={column} style={{
        "--artifact-text": `${Math.min(prefs().ui.text_size, 21)}px`,
        "--artifact-leading": `${Math.round(Math.min(prefs().ui.text_size, 21) * prefs().ui.line_spacing)}px`,
      }} onKeyDown={(event) => {
        if (event.key === "Escape" && focus()) {
          event.preventDefault();
          const anchor = focus()?.anchor;
          setFocus(null);
          anchor?.focus();
        }
      }}>
        {props.header}
        <For each={props.artifact.sections}>{(section) => (
          <section class="artifact-section">
            <Show when={section.heading}><h2>{section.heading}</h2></Show>
            <p class="selectable"><For each={section.claims}>{(claim) => (
              <>
                {claim.text}
                <For each={claim.sources}>{(number, index) => {
                  let anchor!: HTMLButtonElement;
                  return <button ref={(element) => {
                    anchor = element;
                    if (!requested && props.pinSource === number) {
                      requested = true;
                      queueMicrotask(() => choose(number, element, true));
                    }
                  }} type="button" class="citation-mark" aria-label={`Source ${number}`}
                    aria-expanded={focus()?.anchor === anchor} onMouseEnter={() => choose(number, anchor, false)} onMouseLeave={closeSoon}
                    onClick={() => choose(number, anchor, true)}>
                    {number}{index() < claim.sources.length - 1 ? "," : ""}
                  </button>;
                }}</For>{" "}
              </>
            )}</For></p>
          </section>
        )}</For>
        <div class="artifact-sources">
          <Rule />
          <SectionLabel text="Sources" />
          <For each={props.artifact.citations}>{(source) => (
            <button type="button" class="artifact-source" aria-label={`Source ${source.number}, ${source.title}`} onClick={() => open(source)}>
              <span>{source.number}</span>
              <span classList={{ read: source.read }}>{source.title}</span>
              <span>{source.feedTitle}</span>
            </button>
          )}</For>
          <Show when={note()}><p class="artifact-source-note">{note()}</p></Show>
        </div>
        {props.footer}
        <Show when={focus()} keyed>{(current) => (
          <aside class="float-panel artifact-citation" aria-label={`Source ${current.citation.number}: ${current.citation.title}`}
            style={coordinates(current.anchor)} onMouseEnter={keepOpen} onMouseLeave={closeSoon}>
            <p class="citation-meta">{[current.citation.number, current.citation.feedTitle, current.citation.date && Dates.relative(current.citation.date)].filter(Boolean).join(" · ")}</p>
            <h2>{current.citation.title}</h2>
            <Show when={current.citation.snippet?.trim()}>{(snippet) => <blockquote class="selectable">“{snippet()}”</blockquote>}</Show>
            <div class="citation-action">
              <Action kind="quiet" compact onClick={() => open(current.citation)}>Open article ↵</Action>
              <span>Opens here, in the reader</span>
            </div>
          </aside>
        )}</Show>
      </article>
    </div>
  );
}

export function writerName(id: string | null | undefined) {
  if (!id) return "a writer";
  if (["claude", "claude-code", "claude_code"].includes(id.toLowerCase())) return "Claude Code";
  return id.toLowerCase() === "codex" ? "Codex" : id;
}

export function MadeWith(props: { artifact: Artifact; recipeName?: string; openRecipe: () => void }) {
  return (
    <div class="artifact-made-with">
      <Icon name="briefing" size={13} />
      <p>
        Written by {writerName(props.artifact.writer)} with your <strong>{props.recipeName ?? props.artifact.recipeName ?? "recipe"}</strong>
        <Show when={props.artifact.recipeRevision !== null}> · rev {props.artifact.recipeRevision}</Show>
        <Show when={props.artifact.durationSeconds !== null}> · {props.artifact.durationSeconds} s</Show>
      </p>
      <Action kind="link" compact onClick={props.openRecipe}>Edit recipe</Action>
    </div>
  );
}
