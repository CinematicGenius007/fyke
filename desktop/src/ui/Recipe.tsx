// A recipe can be edited, tried with unsaved text, or restored from its history.
import { createEffect, createResource, createSignal, For, Match, on, onCleanup, onMount, Show, Switch } from "solid-js";
import { Plural } from "../logic/Plural";
import { app, words } from "../model/app";
import { type Artifact, jobIsActive, type Recipe as RecipeRecord } from "../model/types";
import { RPCFailure } from "../transport";
import { ArtifactColumn } from "./Artifact";
import { Dates } from "./format";
import { Action, InlineLabel, Rule, Spinner } from "./kit/Controls";
import { Icon } from "./kit/Icon";

const tabs = ["Edit", "Try it", "History"] as const;
type Tab = (typeof tabs)[number];

export function Recipe(props: { id: number; brief?: Artifact }) {
  const model = app();
  const [tab, setTab] = createSignal<Tab>("Edit");
  const [recipe, setRecipe] = createSignal<RecipeRecord>();
  const [draft, setDraft] = createSignal("");
  const [conflict, setConflict] = createSignal<RecipeRecord>();
  const [saving, setSaving] = createSignal(false);
  const [problem, setProblem] = createSignal("");
  const dirty = () => recipe() !== undefined && recipe()?.text !== draft();
  const canSave = () => dirty() && !saving() && draft().trim().length > 0;

  function load(record: RecipeRecord) {
    setDraft(record.text);
    setRecipe(record);
    setConflict(undefined);
    setProblem("");
  }

  onMount(async () => {
    try {
      load(await model.library.readRecipe(props.id));
    } catch (error) {
      setProblem(words(error));
    }
  });
  createEffect(on(() => model.library.recipe(props.id)?.revision, () => {
    const fresh = model.library.recipe(props.id);
    if (fresh && recipe() && fresh.revision !== recipe()?.revision && !dirty() && !saving()) load(fresh);
  }, { defer: true }));
  createEffect(on(() => model.state.saveRequests, () => {
    if (tab() === "Edit" && model.state.openRecipe === props.id && canSave()) void save();
  }, { defer: true }));

  async function save(over?: RecipeRecord) {
    const base = over ?? recipe();
    if (!base || !canSave()) return;
    setSaving(true);
    try {
      const saved = await model.library.writeRecipe(base, draft());
      load(saved);
      if (props.brief) void model.runBrief(props.brief.viewId, saved.id);
    } catch (error) {
      if (RPCFailure.from(error).is("RevisionConflict")) {
        try {
          setConflict(await model.library.readRecipe(base.id));
        } catch (readError) {
          setProblem(words(readError));
        }
      } else setProblem(words(error));
    } finally {
      setSaving(false);
    }
  }

  async function reset(before: RecipeRecord) {
    if (saving()) return;
    setSaving(true);
    try {
      const fresh = await model.library.resetRecipe(before);
      load(fresh);
      model.undo.push(`Reset “${before.name}” to the built-in text`, async () => {
        const now = model.library.recipe(before.id);
        if (!now) return;
        if (now.revision !== fresh.revision) {
          model.set("problem", "This recipe changed elsewhere. Its newer revision is kept.");
          return;
        }
        try {
          const restored = await model.library.writeRecipe(now, before.text, "Undo reset");
          if (recipe()?.revision === fresh.revision && !dirty()) load(restored);
        } catch (error) {
          model.set("problem", words(error));
        }
      });
    } catch (error) {
      setProblem(words(error));
    } finally {
      setSaving(false);
    }
  }

  return (
    <section class="recipe-pane" aria-label="Recipe">
      <div class="recipe-bar">
        <Action kind="quiet" compact aria-label={props.brief ? "Back to Brief" : "Back"} onClick={model.back}><Icon name="left" size={12} />{props.brief ? "Brief" : "Back"}</Action>
        <Show when={recipe()}>{(record) => <span class="recipe-bar-title">/　{record().name} recipe</span>}</Show>
        <div class="recipe-tabs" role="tablist" aria-label="Recipe">
          <For each={tabs}>{(name) => <Action kind="quiet" compact role="tab" aria-selected={tab() === name}
            selected={tab() === name} onClick={() => setTab(name)}>{name}</Action>}</For>
        </div>
      </div>
      <Rule />
      <div class="reader-scroll scroll">
        <div class="recipe-column">
          <Show when={recipe()} fallback={problem() ? <div role="status">{problem()}</div> : <Spinner size={16} />}>
            {(record) => (
              <>
                <h1>{record().name}</h1>
                <div class="recipe-subtitle">
                  Tells {model.library.state.writers.find((writer) => writer.selected)?.name ?? "the writer"} how to write the brief
                  {record().usedBy ? ` · used by ${Plural.count(record().usedBy!, "routine")}` : ""}
                  {" · revision "}{record().revision}{record().updatedAt && ` · edited ${Dates.relative(record().updatedAt!)}`}
                </div>
                <Switch>
                  <Match when={tab() === "Edit"}>
                    <Show when={conflict()}>{(newer) => (
                      <div class="recipe-conflict" role="status">
                        <strong>This recipe changed elsewhere (revision {newer().revision}).</strong>
                        <p>Your edits are still here and nothing is saved yet. Keeping yours makes it the newest revision; the other stays in History.</p>
                        <Action kind="primary" compact disabled={saving()} onClick={() => void save(newer())}>Keep mine</Action>
                        <Action kind="quiet" compact disabled={saving()} onClick={() => load(newer())}>Use the newer one</Action>
                      </div>
                    )}</Show>
                    <textarea class="recipe-text selectable" aria-label="Recipe text" value={draft()}
                      readOnly={saving()} spellcheck={false} onInput={(event) => setDraft(event.currentTarget.value)} />
                    <p class="recipe-note">Fyke adds the selected articles and its citation rules after your text. They are fixed, so a recipe cannot turn citations off.</p>
                    <div class="recipe-buttons">
                      <span role="status">{problem() || (dirty() ? "Unsaved changes" : "")}</span>
                      <Show when={record().builtIn}><Action kind="quiet" disabled={saving()} onClick={() => void reset(record())}>Reset to built-in</Action></Show>
                      <Action disabled={saving() || !dirty()} onClick={() => load(record())}>Revert</Action>
                      <Action kind="primary" disabled={!canSave() || !!conflict()} onClick={() => void save()}>
                        {props.brief ? "Save and rewrite the brief" : "Save"}
                      </Action>
                    </div>
                  </Match>
                  <Match when={tab() === "Try it"}>
                    <Trial recipe={record()} text={draft()} brief={props.brief} />
                  </Match>
                  <Match when={tab() === "History"}>
                    <History recipe={record()} use={(text) => { setDraft(text); setTab("Edit"); }} />
                  </Match>
                </Switch>
              </>
            )}
          </Show>
        </div>
      </div>
    </section>
  );
}

function Trial(props: { recipe: RecipeRecord; text: string; brief?: Artifact }) {
  const model = app();
  const [id, setId] = createSignal<number>();
  const [starting, setStarting] = createSignal(false);
  const [problem, setProblem] = createSignal("");
  const [result, setResult] = createSignal<Artifact>();
  const job = () => model.library.state.jobs.find((candidate) => candidate.id === id());
  let disposed = false;
  onCleanup(() => { disposed = true; });
  createEffect(on(() => job()?.state, async (state) => {
    const current = job();
    if (state === "failed") setProblem(current?.error ?? "The writer stopped.");
    if (state !== "done") return;
    if (current?.artifactId == null) {
      setProblem("The writer finished but returned nothing to show.");
      return;
    }
    try {
      const brief = await model.library.readArtifact("briefs.get", current.artifactId);
      if (!disposed && id() === current.id) setResult(brief);
    } catch (error) {
      if (!disposed) setProblem(words(error));
    }
  }));
  async function tryRecipe() {
    if (starting() || (job() && jobIsActive(job()!))) return;
    setStarting(true);
    setId(undefined);
    setProblem("");
    setResult(undefined);
    try {
      const queued = await model.library.queueWriting("briefs.try", {
        view_id: props.brief?.viewId, rule: props.brief?.rule ?? { state: "unread" },
        recipe_id: props.recipe.id, text: props.text,
      });
      setId(queued.id);
    } catch (error) {
      setProblem(words(error));
    } finally {
      setStarting(false);
    }
  }

  return (
    <>
      <div class="recipe-trial-header">
        <p>{props.brief ? `Writes over the ${Plural.count(props.brief.inputCount, "article")} of this brief with the text in Edit, saved or not.`
          : "Writes over your newest unread articles with the text in Edit, saved or not."}</p>
        <Action kind="primary" disabled={starting() || (!!job() && jobIsActive(job()!)) || !props.text.trim()}
          onClick={() => void tryRecipe()}>{result() || problem() ? "Try again" : "Try it"}</Action>
      </div>
      <Show when={job() && jobIsActive(job()!)}>
        <div class="inline-empty" role="status">
          <InlineLabel tone="working">Trying the recipe</InlineLabel>
          <h2 class="inline-title">Writing a trial brief</h2>
          <p class="inline-detail">Nothing is saved: the trial is not listed in Today, and the recipe keeps its text until you save it.</p>
          <Action kind="secondary" onClick={() => void model.cancelJob(id()!)}>Cancel</Action>
        </div>
      </Show>
      <Show when={problem()}>
        <div class="inline-empty" role="status">
          <InlineLabel tone="failed">Trial failed</InlineLabel>
          <h2 class="inline-title">The trial did not finish</h2>
          <p class="inline-detail">{problem()} The recipe and your briefs are unchanged.</p>
          <Action kind="primary" onClick={() => void tryRecipe()}>Try again</Action>
        </div>
      </Show>
      <Show when={result()} keyed>{(artifact) => (
        <ArtifactColumn artifact={artifact} openSource={(entry) => { model.back(); void model.open(entry); }}
          header={<><span class="generated-label">Trial · not saved</span><h2>{artifact.title}</h2></>} />
      )}</Show>
    </>
  );
}

function History(props: { recipe: RecipeRecord; use: (text: string) => void }) {
  const model = app();
  const [open, setOpen] = createSignal<number>();
  const [revisions] = createResource(() => props.recipe.revision, async () => {
    try {
      return { items: await model.library.recipeHistory(props.recipe.id), error: "" };
    } catch (error) {
      return { items: [], error: words(error) };
    }
  });
  const [text] = createResource(open, async (revision) => {
    try {
      const known = revisions()?.items.find((known) => known.revision === revision)?.text;
      return { text: known ?? (await model.library.readRecipe(props.recipe.id, revision)).text, error: "" };
    } catch (error) {
      return { text: "", error: words(error) };
    }
  });
  return (
    <div class="recipe-history">
      <Show when={revisions.loading}><Spinner size={16} /></Show>
      <Show when={revisions()?.error}>{(error) => <p role="status">{error()}</p>}</Show>
      <For each={revisions()?.items}>{(record) => (
        <>
          <Rule />
          <button type="button" class="recipe-history-row" aria-expanded={open() === record.revision}
            onClick={() => setOpen(open() === record.revision ? undefined : record.revision)}>
            <strong>Revision {record.revision}</strong>
            <Show when={record.revision === props.recipe.revision}><span>current</span></Show>
            <span>{record.note}</span>
            <time>{record.createdAt && Dates.relative(record.createdAt)}</time>
            <Icon name={open() === record.revision ? "down" : "right"} size={12} />
          </button>
          <Show when={open() === record.revision}>
            <pre class="selectable">{text.loading ? "…" : (text()?.error || text()?.text)}</pre>
            <Show when={record.revision !== props.recipe.revision && !text.loading && text()?.text}>
              {(value) => <Action compact onClick={() => props.use(value())}>Put this text in Edit</Action>}
            </Show>
          </Show>
        </>
      )}</For>
      <Rule />
    </div>
  );
}
