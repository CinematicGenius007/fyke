// A routine describes when to run, where to look, and what to do.
import { createEffect, createResource, createSignal, For, Index, on, onCleanup, Show } from "solid-js";
import { unwrap } from "solid-js/store";
import { DryRunWords } from "../logic/DryRunWords";
import { Plural } from "../logic/Plural";
import { Schedule } from "../logic/Schedule";
import { app, words } from "../model/app";
import { type Routine, type RoutineAction, routineActionKinds, type RoutineActionKind } from "../model/types";
import { float, type MenuItem } from "./Float";
import { Dates } from "./format";
import { Action, InlineLabel, Chip, Rule, SectionLabel, Spinner, SymbolButton } from "./kit/Controls";
import { Icon, type IconName } from "./kit/Icon";

const titles: Record<RoutineActionKind, string> = {
  brief: "Write a brief",
  notify: "Notify me",
  mark_read: "Mark them read",
  star: "Star them",
  tag: "Tag them",
};
const short: Record<RoutineActionKind, string> = { brief: "brief", notify: "notify", mark_read: "mark read", star: "star", tag: "tag" };
const icons: Record<RoutineActionKind, IconName> = { brief: "briefing", notify: "circle", mark_read: "checkmark.circle", star: "star", tag: "plus" };
const cadence: Schedule[] = [{ kind: "weekdays" }, { kind: "daily" }, { kind: "weekly", days: [1] }, { kind: "weekly", days: [5] }, { kind: "manual" }];

export function RoutineList() {
  const model = app();
  return (
    <section class="entry-list" aria-label="Routines">
      <header class="list-header ruled">
        <div class="list-heading">
          <h2 class="list-title">Routines</h2>
          <SymbolButton icon="plus" label="New routine" disabled={!model.library.state.views.length} onClick={() => model.draftRoutine()} />
        </div>
        <Rule class="meets-divider" />
      </header>
      <div class="list-scroll scroll"><div class="list-rows">
        <Show when={model.state.routineDraft?.id === null && model.state.routineDraft}>{(draft) => <RoutineRow routine={draft()} />}</Show>
        <For each={model.library.state.routines}>{(routine) => <RoutineRow routine={routine} />}</For>
        <Show when={!model.library.state.routines.length && !model.state.routineDraft}>
          <p class="brief-empty-list">{model.library.state.views.length ? "A routine runs on a schedule over one of your views."
            : "A routine looks in a view. Save a search as a view first (Ctrl+F, then Ctrl+S)."}</p>
        </Show>
      </div></div>
    </section>
  );
}

function RoutineRow(props: { routine: Routine }) {
  const model = app();
  const selected = () => model.state.routineDraft?.id === props.routine.id;
  const last = () => {
    const failure = model.library.needsYou().find((job) => job.routineId !== null && job.routineId === props.routine.id);
    if (failure) return failure.error ?? "Last run failed";
    if (!props.routine.enabled) return "Paused";
    if (!props.routine.lastRunAt) return "Not run yet";
    return "Last run " + Dates.relative(props.routine.lastRunAt) + (props.routine.lastMatches == null ? "" : " · " + Plural.count(props.routine.lastMatches, "match", "matches"));
  };
  return (
    <div class="routine-row">
      <button type="button" class="brief-row" classList={{ selected: selected() }} aria-current={selected() ? "true" : undefined}
        onClick={() => { if (!selected()) model.set("routineDraft", structuredClone(unwrap(props.routine))); }}>
        <strong>{props.routine.name}{props.routine.id === null && " (not saved)"}</strong>
        <span class="brief-row-detail">{[Schedule.summary(props.routine.schedule), ...props.routine.actions.map((action) => short[action.kind])].join(" · ")}</span>
        <span class="brief-row-meta">{last()}</span>
      </button>
      <Show when={props.routine.id !== null}>
        <input type="checkbox" role="switch" class="routine-switch" checked={props.routine.enabled} disabled={props.routine.viewId === null}
          aria-label={`${props.routine.enabled ? "Pause" : "Resume"} ${props.routine.name}`}
          onChange={(event) => void model.toggleRoutine(props.routine, event.currentTarget.checked)} />
      </Show>
    </div>
  );
}

export function RoutineReader() {
  const model = app();
  return (
    <Show when={model.state.routineDraft} keyed fallback={
      <div class="reader-scroll scroll">
        <div class="brief-state inline-empty">
          <InlineLabel>Routines</InlineLabel>
          <h2 class="inline-title">{model.library.state.views.length ? "No routine chosen" : "Routines start from a view"}</h2>
          <p class="inline-detail">{model.library.state.views.length ? "Pick one on the left, or make one from a view."
            : "Search for what you follow, keep it with Ctrl+S, and a routine can brief it every morning."}</p>
          <Show when={model.library.state.views.length}
            fallback={<Action kind="primary" onClick={() => model.search.show()}>Search</Action>}>
            <Action kind="primary" onClick={() => model.draftRoutine()}>New routine</Action>
          </Show>
        </div>
      </div>
    }>
      {(routine) => <Editor initial={routine} />}
    </Show>
  );
}

function Editor(props: { initial: Routine }) {
  const model = app();
  const [baseline, setBaseline] = createSignal(structuredClone(unwrap(props.initial)));
  const [draft, setDraft] = createSignal(baseline());
  const [saving, setSaving] = createSignal(false);
  const [running, setRunning] = createSignal(false);
  const [renaming, setRenaming] = createSignal(false);
  const [problem, setProblem] = createSignal("");
  const [preview, refresh] = createResource(() => draft().id ?? undefined, async (id) => {
    try {
      return { value: await model.library.previewRoutine(id), error: "" };
    } catch (error) {
      return { value: null, error: words(error) };
    }
  });
  const update = (change: Partial<Routine>) => setDraft((routine) => ({ ...routine, ...change }));
  const selected = () => model.library.view(draft().viewId);
  const saved = () => model.library.routine(draft().id);
  const dirty = () => draft().id === null || JSON.stringify(draft()) !== JSON.stringify(baseline());
  let closed = false;
  onCleanup(() => { closed = true; });
  const canSave = () => dirty() && !!draft().name.trim() && !!selected() && draft().actions.length > 0 &&
    draft().actions.every((action) => action.kind !== "tag" || !!action.tag?.trim()) && !saving();

  async function save() {
    if (!canSave()) return;
    setSaving(true);
    try {
      const made = await model.library.saveRoutine(draft());
      if (!closed) {
        setDraft(made);
        setBaseline(made);
        setProblem("");
        model.set("routineDraft", made);
        if (props.initial.id === made.id) void refresh.refetch();
      }
    } catch (error) {
      setProblem(words(error));
    } finally {
      setSaving(false);
    }
  }
  createEffect(on(() => model.state.saveRequests, () => {
    if (model.state.place.kind === "routines" && !model.state.showingSettings) void save();
  }, { defer: true }));

  async function runNow() {
    const id = draft().id;
    if (id === null || running() || saving()) return;
    setRunning(true);
    try {
      await model.library.runRoutine(id);
      setProblem("");
      model.set("showingActivity", true);
      void refresh.refetch();
    } catch (error) {
      setProblem(words(error));
    } finally {
      setRunning(false);
    }
  }

  function changeAction(index: number, change: Partial<RoutineAction>) {
    update({ actions: draft().actions.map((action, at) => at === index ? { ...action, ...change } : action) });
  }
  const doneRenaming = (event: KeyboardEvent) => {
    if (event.key === "Enter" || event.key === "Escape") {
      event.preventDefault();
      setRenaming(false);
    }
  };

  return (
    <div class="routine-reader">
      <Show when={draft().id !== null}>
        <div class="routine-remove">
          <Action kind="quiet" compact disabled={saving() || running()} onClick={() => void model.removeRoutine(draft())}>Remove</Action>
        </div>
      </Show>
      <div class="reader-scroll scroll">
        <div class="recipe-column routine-editor">
          <Show when={renaming()} fallback={
            <h1 aria-label={draft().name}><button class="routine-name" type="button" aria-label={`Rename ${draft().name}`} onClick={() => setRenaming(true)}>{draft().name}</button></h1>
          }>
            <input class="routine-name-field" ref={(field) => queueMicrotask(() => { field.focus(); field.select(); })}
              aria-label="Routine name" value={draft().name} onInput={(event) => update({ name: event.currentTarget.value })}
              onKeyDown={doneRenaming} onBlur={() => setRenaming(false)} />
          </Show>
          <p class="recipe-subtitle">Runs in the background while Fyke’s service runs, even with this window closed.</p>
          <div class="routine-sentence">
            <div class="routine-line" role="group" aria-label="When">
              <span>When</span>
              <div>
                <MenuChip text={Schedule.repeatWords(draft().schedule)} label="Repeat" choices={() => cadence.map((schedule) => ({
                  title: Schedule.repeatWords(schedule),
                  checked: draft().schedule.kind === schedule.kind && (schedule.days === undefined || String(schedule.days) === String(draft().schedule.days)),
                  run: () => update({ schedule: { ...schedule, time: schedule.kind === "manual" ? undefined : draft().schedule.time ?? "07:30" } }),
                }))} />
                <Show when={draft().schedule.kind !== "manual"}>
                  <span>at</span>
                  <MenuChip text={draft().schedule.time ?? "07:30"} label="Time" choices={() => Schedule.halfHours.map((time) => ({
                    title: time, checked: draft().schedule.time === time, run: () => update({ schedule: { ...draft().schedule, time } }),
                  }))} />
                </Show>
              </div>
            </div>
            <Rule />
            <div class="routine-line" role="group" aria-label="Look in">
              <span>Look in</span>
              <div>
                <MenuChip text={selected()?.name ?? "Choose a view"} label="View" choices={() => model.library.state.views.map((view) => ({
                  title: view.name, detail: view.sentence ?? undefined, checked: view.id === draft().viewId, run: () => update({ viewId: view.id }),
                }))} />
                <span>for articles new since the last run</span>
              </div>
            </div>
            <Rule />
            <div class="routine-line" role="group" aria-label="Then">
              <span>Then</span>
              <div class="routine-actions">
                <Index each={draft().actions}>{(action, index) => (
                  <div class="routine-action">
                    <Icon name={icons[action().kind]} size={13} />
                    <span>{action().kind === "brief" ? "Write a brief with" : titles[action().kind]}</span>
                    <Show when={action().kind === "brief"}>
                      <MenuChip text={model.library.recipe(action().recipe_id)?.name ?? "a recipe"} label="Recipe" choices={() => model.library.state.recipes.map((recipe) => ({
                        title: recipe.name, checked: recipe.id === action().recipe_id, run: () => changeAction(index, { recipe_id: recipe.id }),
                      }))} />
                    </Show>
                    <Show when={action().kind === "tag"}>
                      <input aria-label="Tag" placeholder="tag" value={action().tag ?? ""} onInput={(event) => changeAction(index, { tag: event.currentTarget.value })} />
                    </Show>
                    <SymbolButton icon="close" label="Remove this action" size={24} onClick={() => update({ actions: draft().actions.filter((_, at) => at !== index) })} />
                  </div>
                )}</Index>
                <MenuChip text="Add action" label="Add action" choices={() => routineActionKinds.map((kind) => ({
                  title: titles[kind], run: () => update({ actions: [...draft().actions, { kind, recipe_id: kind === "brief" ? model.library.state.recipes[0]?.id : undefined }] }),
                }))} />
              </div>
            </div>
          </div>
          <div class="routine-preview">
            <div>
              <SectionLabel text="Dry run · last week" />
              <Show when={draft().id !== null} fallback={<p>Save to see what this routine would have caught last week.</p>}>
                <Show when={preview.loading} fallback={
                  <Show when={preview()?.value} fallback={<small>{preview()?.error}</small>}>{(value) => (
                    <>
                      <p>{DryRunWords.summary(value().days.map((day) => day.count))}</p>
                      <For each={value().actions}>{(line) => <small>{line}</small>}</For>
                    </>
                  )}</Show>
                }><Spinner size={12} /></Show>
              </Show>
            </div>
            <Show when={preview()?.value}>{(value) => {
              const heights = () => DryRunWords.bars(value().days.map((day) => day.count));
              return <div class="routine-bars">
                <For each={value().days}>{(day, index) =>
                  <div aria-label={`${day.label}: ${Plural.count(day.count, "article")}`}>
                    <i classList={{ positive: day.count > 0 }} style={{ height: `${Math.max(3, 40 * heights()[index()])}px` }} />
                    {day.label}
                  </div>}
                </For>
              </div>;
            }}</Show>
          </div>
          <Rule />
          <div class="recipe-buttons routine-footer">
            <span role="status">{problem() || (draft().schedule.kind === "manual" ? "Runs only when you press Run now."
              : saved()?.nextRunAt && !dirty() ? `Next run ${Dates.relative(saved()!.nextRunAt!)} ${Dates.time(saved()!.nextRunAt!)}. Missed while asleep? It runs once on wake.`
              : "Missed while asleep? It runs once on wake, never twice.")}</span>
            <Action disabled={draft().id === null || running() || saving()} onClick={() => void runNow()}>Run now</Action>
            <Action kind="primary" disabled={!canSave()} onClick={() => void save()}>Save</Action>
          </div>
        </div>
      </div>
    </div>
  );
}

function MenuChip(props: { text: string; label: string; choices: () => MenuItem[] }) {
  let anchor!: HTMLButtonElement;
  return <Chip ref={anchor} aria-label={props.label === props.text ? props.label : `${props.label}: ${props.text}`} text={props.text}
    selected={float.isAnchoredAt(anchor)} onClick={() => float.below(anchor, 200, props.choices())} />;
}
