import { createResource, For, Match, Show, Switch } from "solid-js";
import { Plural } from "../logic/Plural";
import { app, words } from "../model/app";
import type { Artifact } from "../model/types";
import { ArtifactColumn, MadeWith, writerName } from "./Artifact";
import { Dates } from "./format";
import { Action, Rule, SectionLabel, Spinner, SymbolButton } from "./kit/Controls";
import { Icon } from "./kit/Icon";
import { ReaderPane } from "./Reader";
import { Recipe } from "./Recipe";

const date = new Intl.DateTimeFormat("en-IN", { weekday: "long", day: "numeric", month: "short" });

function viewTitle(brief: Artifact) {
  return brief.viewName ?? app().library.view(brief.viewId)?.name ?? "All feeds";
}

export function BriefList() {
  const model = app();
  return (
    <section class="entry-list" aria-label="Today">
      <header class="list-header ruled">
        <div class="list-heading"><h2 class="list-title">Today</h2><span class="list-unread">{date.format(new Date())}</span></div>
        <Rule class="meets-divider" />
      </header>
      <div class="list-scroll scroll">
        <div class="list-rows brief-list">
          <SectionLabel text="Briefs" />
          <Show when={model.briefJob()}>{(job) => (
            <div class="brief-writing">
              <Spinner size={12} />
              <div><strong>Writing a brief…</strong><p>{job().writer ? `${writerName(job().writer)} · started ${job().createdAt ? Dates.relative(job().createdAt!) : "now"}` : "Started just now"}</p></div>
            </div>
          )}</Show>
          <For each={model.library.state.briefs}>{(brief) => {
            const selected = () => !model.state.article && !model.state.openRecipe && model.selectedBrief()?.id === brief.id;
            return <button type="button" class="brief-row" classList={{ selected: selected() }} aria-current={selected() ? "true" : undefined}
              onClick={() => model.selectBrief(brief.id)}>
              <span class="brief-row-meta">{[viewTitle(brief), brief.createdAt && Dates.time(brief.createdAt)].filter(Boolean).join(" · ")}</span>
              <span class="entry-title" classList={{ read: model.library.state.briefs[0]?.id !== brief.id }}>{brief.title}</span>
              <span class="brief-row-detail">From {Plural.count(Math.max(brief.inputCount, brief.citations.length), "article")}</span>
            </button>;
          }}</For>
          <Show when={!model.library.state.briefs.length && !model.briefJob()}>
            <p class="brief-empty-list">Briefs you write appear here, newest first.</p>
          </Show>
        </div>
      </div>
    </section>
  );
}

export function TodayReader() {
  const model = app();
  const [detail] = createResource(() => model.selectedBrief()?.id, async (id) => {
    try {
      return { brief: await model.library.readArtifact("briefs.get", id), error: null };
    } catch (error) {
      return { brief: null, error: words(error) };
    }
  });

  const working = () => {
    const job = model.briefJob();
    const selected = model.selectedBrief();
    return job && (!selected || (job.createdAt?.getTime() ?? 0) > (selected.createdAt?.getTime() ?? 0)) ? job : null;
  };
  const failed = () => {
    const job = model.library.needsYou().find((job) => ["brief", "digest", "synthesize"].includes(job.kind));
    return job && (job.finishedAt?.getTime() ?? 0) > (model.selectedBrief()?.createdAt?.getTime() ?? 0) ? job : null;
  };
  const edit = () => model.openRecipe(model.selectedBrief()?.recipeId);

  return (
    <div class="reader-pane today-reader">
      <Switch>
        <Match when={model.state.openRecipe} keyed>
          {(id) => <Recipe id={id} brief={model.selectedBrief()} />}
        </Match>
        <Match when={model.state.article}>
          <ReaderPane />
          <div class="brief-back"><Action kind="quiet" compact aria-label="Back to Brief" onClick={model.back}><Icon name="left" size={12} />Brief</Action></div>
        </Match>
        <Match when={true}>
          <Switch>
            <Match when={!model.library.state.available}>
              <BriefState title="Briefs need a newer Fyke service" label="Today"
                detail="The background service running now does not write briefs. Your feeds and articles work as before." action="Restart the service" run={() => void model.restartService()} />
            </Match>
            <Match when={working()}>{(job) => (
              <BriefState title={`Reading your articles with the ${model.library.state.recipes[0]?.name ?? "recipe"} recipe`} label="Writing your brief"
                detail={`${writerName(job().writer)} is working. Nothing changes in your articles while it writes; keep reading.`}
                action="Cancel" run={() => void model.cancelJob(job().id)} />
            )}</Match>
            <Match when={failed()}>{(job) => (
              <BriefState title={`${writerName(job().writer)} could not write the brief`} label="Brief not written"
                detail={`${job().error ?? "It stopped before it finished."} Nothing was lost: your articles and earlier briefs are as they were.`}
                action="Try again" run={() => void model.runBrief()} />
            )}</Match>
            <Match when={!model.selectedBrief()}>
              <BriefState title="No brief yet" label="Today"
                detail="A brief reads your newest unread articles and cites each one it uses. Opening Today never runs a writer; it writes when you ask."
                action="Write a brief" run={() => void model.runBrief()} />
            </Match>
            <Match when={detail.loading}><div class="reader-empty" role="status" aria-label="Loading brief"><Spinner size={16} /></div></Match>
            <Match when={detail()?.error}>{(error) => (
              <BriefState title="This brief could not be opened" label="Today" detail={error()}
                action="Read the articles instead" run={() => model.go({ kind: "all" })} />
            )}</Match>
            <Match when={detail()?.brief} keyed>{(brief) => (
              <ArtifactColumn artifact={brief} openSource={(id) => void model.open(id)} pinSource={model.state.pinCitation}
                header={<>
                  <div class="brief-meta"><span class="generated-label">AI brief</span> {viewTitle(brief)}{brief.createdAt && ` · ${Dates.long(brief.createdAt)}`}</div>
                  <h1 class="brief-title selectable">{brief.title}</h1>
                </>}
                footer={<MadeWith artifact={brief} recipeName={model.library.recipe(brief.recipeId)?.name} openRecipe={edit} />} />
            )}</Match>
          </Switch>
          <div class="reader-actions">
            <SymbolButton icon="arrow.clockwise" label="Write a new brief (Ctrl+R)" disabled={model.briefPending() || !!model.briefJob() || !model.library.state.available} onClick={() => void model.runBrief()} />
            <Action compact disabled={!model.library.state.recipes.length} onClick={edit}><Icon name="briefing" size={12} />Recipe</Action>
          </div>
        </Match>
      </Switch>
    </div>
  );
}

function BriefState(props: { title: string; label: string; detail: string; action: string; run: () => void }) {
  return (
    <div class="reader-scroll scroll">
      <div class="brief-state inline-empty">
        <div class="inline-label">{props.label}</div>
        <h2 class="inline-title">{props.title}</h2>
        <p class="inline-detail">{props.detail}</p>
        <Action kind="primary" onClick={props.run}>{props.action}</Action>
      </div>
    </div>
  );
}
