// Questions use the selected view, or all feeds, and answers cite their articles.
import { createEffect, createSignal, For, on, onCleanup, onMount, Show } from "solid-js";
import { Plural } from "../logic/Plural";
import { app, words } from "../model/app";
import { type Artifact, jobIsActive } from "../model/types";
import { ArtifactColumn } from "./Artifact";
import { Action, SymbolButton } from "./kit/Controls";
import { Icon } from "./kit/Icon";

interface Turn {
  question: string;
  jobId?: number;
  answer?: Artifact;
  problem?: string;
}

export function Ask(props: { question: string; viewId: number | null }) {
  const model = app();
  const [turns, setTurns] = createSignal<Turn[]>([]);
  const latest = () => turns().at(-1);
  const pending = () => !!latest() && !latest()?.answer && !latest()?.problem;
  const job = () => model.library.state.jobs.find((item) => item.id === latest()?.jobId);
  const scope = () => {
    const view = model.library.view(props.viewId);
    return view ? `in ${view.name}` : "in all your feeds";
  };
  let closed = false;
  onCleanup(() => { closed = true; });

  function update(change: Partial<Turn>) {
    if (!closed) setTurns((all) => [...all.slice(0, -1), { ...all[all.length - 1], ...change }]);
  }

  async function submit(value: string) {
    const text = value.trim();
    if (!text || pending()) return;
    const earlier = latest();
    const question = earlier ? `Earlier question: ${earlier.question}\nFollow-up: ${text}` : text;
    setTurns((all) => [...all, { question: text }]);
    try {
      const queued = await model.library.queueWriting("ask.run", { view_id: props.viewId, question });
      update({ jobId: queued.id });
    } catch (error) {
      update({ problem: words(error) });
    }
  }

  onMount(() => {
    if (props.question.trim()) void submit(props.question);
  });
  createEffect(on(() => job()?.state, async (state) => {
    const current = job();
    if (!current || latest()?.answer) return;
    if (state === "cancelled") update({ problem: "You cancelled it." });
    if (state === "failed") update({ problem: current.error ?? "The writer stopped." });
    if (state !== "done") return;
    if (current.artifactId === null) {
      update({ problem: "The writer finished without an answer." });
      return;
    }
    try {
      const answer = await model.library.readArtifact("answers.get", current.artifactId);
      if (latest()?.jobId === current.id && !latest()?.answer) update({ answer });
    } catch (error) {
      if (latest()?.jobId === current.id) update({ problem: words(error) });
    }
  }));

  async function copy(answer: Artifact) {
    const claims = answer.sections.map((section) => [
      section.heading,
      section.claims.map((claim) => claim.text + claim.sources.map((number) => ` [${number}]`).join("")).join(" "),
    ].filter(Boolean).join("\n")).join("\n\n");
    const sources = answer.citations.map((source) => `[${source.number}] ${source.title}${source.url ? ` <${source.url}>` : ""}`).join("\n");
    try {
      await navigator.clipboard.writeText(`${claims}\n\n${sources}`);
    } catch (error) {
      model.set("problem", words(error));
    }
  }

  const heading = (turn: Turn) => (
    <>
      <For each={turns().slice(0, -1)}>{(earlier) => <p class="ask-earlier">Earlier: {earlier.question}</p>}</For>
      <div class="brief-meta">
        <span class="generated-label">Asked</span>
        {scope()}{turn.answer && ` · ${Plural.count(Math.max(turn.answer.inputCount, turn.answer.citations.length), "article")} read`}
      </div>
      <h1 class="ask-question selectable">{turn.question}</h1>
    </>
  );

  return (
    <section class="ask-pane" aria-label="Ask your feeds">
      <header class="recipe-bar">
        <Action kind="quiet" compact onClick={model.back}><Icon name="left" size={12} />{model.state.article ? "Back to article" : "Back"}</Action>
        <Show when={latest()?.answer}>{(answer) => (
          <div class="recipe-tabs">
            <Action kind="quiet" compact onClick={() => void copy(answer())}>Copy</Action>
            <Action kind="quiet" compact disabled={!model.library.state.views.length}
              onClick={() => model.draftRoutine(props.viewId, Array.from(latest()!.question).slice(0, 60).join(""), [{ kind: "brief" }, { kind: "notify" }])}>
              Make it a routine
            </Action>
          </div>
        )}</Show>
      </header>
      <Show when={latest()?.answer} keyed fallback={
        <div class="reader-scroll scroll">
          <div class="recipe-column ask-column">
            <Show when={latest()} fallback={
              <>
                <h1>Ask your feeds</h1>
                <p class="ask-hint">Answers come only from your articles {scope()}, with every claim cited.</p>
                <QuestionField placeholder="Which posts disagree about…" autofocus pending={pending()} submit={(text) => void submit(text)} />
                <Show when={!model.library.state.available}><p>This needs a newer Fyke service.</p></Show>
              </>
            }>{(turn) => (
              <>
                {heading(turn())}
                <Show when={turn().problem} fallback={
                  <div class="inline-empty" role="status">
                    <div class="inline-label">Answering</div>
                    <h2 class="inline-title">Reading your articles {scope()}</h2>
                    <p class="inline-detail">The writer answers only from your articles and cites each one it uses. Nothing is changed while it reads.</p>
                    <Show when={job() && jobIsActive(job()!)}><Action kind="primary" onClick={() => void model.cancelJob(job()!.id)}>Cancel</Action></Show>
                  </div>
                }>{(problem) => (
                  <div class="inline-empty" role="status">
                    <div class="inline-label">No answer</div>
                    <h2 class="inline-title">This question was not answered</h2>
                    <p class="inline-detail">{problem()} Nothing changed in your feeds.</p>
                    <Action kind="primary" onClick={() => {
                      const question = turn().question;
                      setTurns((all) => all.slice(0, -1));
                      void submit(question);
                    }}>Ask again</Action>
                  </div>
                )}</Show>
              </>
            )}</Show>
          </div>
        </div>
      }>
        {(answer) => {
          const followUp = <div class="ask-follow-up"><QuestionField placeholder="Ask a follow-up" pending={pending()} submit={(text) => void submit(text)} /></div>;
          return <ArtifactColumn artifact={answer} header={heading({ ...latest()!, answer })} footer={followUp}
            openSource={(entry) => { model.back(); void model.open(entry); }} />;
        }}
      </Show>
    </section>
  );
}


function QuestionField(props: {
  placeholder: string;
  autofocus?: boolean;
  pending: boolean;
  submit: (text: string) => void;
}) {
  const [text, setText] = createSignal("");
  let input!: HTMLInputElement;
  onMount(() => {
    if (props.autofocus) input.focus();
  });
  return (
    <form class="ask-field" onSubmit={(event) => { event.preventDefault(); props.submit(input.value); }}>
      <Icon name="sparkle" size={12} color="var(--muted)" />
      <input ref={input} type="text" aria-label={props.placeholder} placeholder={props.placeholder}
        onInput={(event) => setText(event.currentTarget.value)}
        onKeyDown={(event) => {
          if (event.key !== "Enter" || event.isComposing) return;
          event.preventDefault();
          props.submit(event.currentTarget.value);
        }} />
      <span>Answers only from your feeds</span>
      <SymbolButton type="submit" icon="up" size={28} label="Ask" selected={!!text().trim()} disabled={!text().trim() || props.pending} />
    </form>
  );
}
