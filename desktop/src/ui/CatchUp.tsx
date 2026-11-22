import { Match, onMount, Show, Switch } from "solid-js";
import type { CatchUpModel } from "../model/catchUp";
import { entryDate, preview, type EntrySummary } from "../model/types";
import { Dates } from "./format";
import { Action, KeyHint, Spinner } from "./kit/Controls";
import { Icon, type IconName } from "./kit/Icon";

export function CatchUp(props: { session: CatchUpModel; close: () => void }) {
  const session = props.session;
  const summary = () => `Skipped ${session.count("skip")} · Later ${session.count("later")} · Read ${session.count("read")}`;
  const heading = `Catching up on ${session.title}`;
  let pane!: HTMLElement;
  onMount(() => pane.focus());
  return (
    <section class="catchup" ref={pane} tabindex={-1} role="dialog" aria-modal="true" aria-label={heading}>
      <header class="catchup-header">
        <div class="catchup-progress">
          <h2>{heading}</h2>
          <progress aria-label="Catch-up progress" max={session.length() || 1} value={session.length() ? session.index() : Number(session.loaded())} />
        </div>
        <Action compact onClick={props.close}>Done <span class="catchup-esc">esc</span></Action>
      </header>
      <div class="catchup-center">
        <Switch>
          <Match when={session.problem()}>{(problem) => (
            <div class="inline-empty" role="status">
              <div class="inline-label">Could not load</div>
              <h2 class="inline-title">{session.loaded() && session.length() ? "Catch up was interrupted" : "Catch up could not start"}</h2>
              <p class="inline-detail">{problem()}</p>
              <Action kind="primary" compact onClick={props.close}>Close</Action>
            </div>
          )}</Match>
          <Match when={!session.loaded()}>
            <div role="status" aria-label="Loading unread articles"><Spinner size={18} /></div>
          </Match>
          <Match when={session.current()} keyed>{(row) => (
            <>
              <Card row={row} stacked={session.length() - session.index() > 1} />
              <div class="catchup-actions">
                <DecisionButton title="Skip" icon="close" hint="←" disabled={session.busy()} run={() => void session.decide("skip")} />
                <DecisionButton title="Later" icon="clock.arrow.circlepath" hint="↓" disabled={session.busy()} run={() => void session.decide("later")} />
                <DecisionButton title="Read now" icon="check" hint="→" disabled={session.busy()} primary run={() => void session.decide("read")} />
              </div>
            </>
          )}</Match>
          <Match when={session.loaded()}>
            <div class="inline-empty" role="status">
              <div class="inline-label">{session.title}</div>
              <h2 class="inline-title">{session.length() ? "You’re caught up" : "Nothing unread here"}</h2>
              <p class="inline-detail">{session.length() ? summary() + ". Articles saved for Later wait in their feeds." : `Every article in ${session.title} is read.`}</p>
              <Action kind="primary" compact onClick={props.close}>Done</Action>
              <Show when={session.index()}>
                <Action kind="quiet" compact disabled={session.busy()} onClick={() => void session.undo()}>Undo last</Action>
              </Show>
            </div>
          </Match>
        </Switch>
        <footer class="catchup-footer" aria-live="polite">
          <Show when={session.length()}>
            <span>{Math.min(session.index() + 1, session.length())} of {session.length()}</span>
            <span>·</span>
            <span>{summary()}</span>
            <Show when={session.index()}>
              <span>·</span>
              <button type="button" class="catchup-undo" disabled={session.busy()} onClick={() => void session.undo()}>Undo last Ctrl+Z</button>
            </Show>
          </Show>
        </footer>
      </div>
    </section>
  );
}

function Card(props: { row: EntrySummary; stacked: boolean }) {
  return (
    <div class="catchup-stack" classList={{ stacked: props.stacked }}>
      <article class="catchup-card">
        <div class="catchup-meta">{[props.row.feed_title, Dates.relative(entryDate(props.row))].filter(Boolean).join(" · ")}</div>
        <h2>{props.row.title ?? "Untitled"}</h2>
        <Show when={preview(props.row)}>{(text) => <p>{text()}</p>}</Show>
      </article>
    </div>
  );
}

function DecisionButton(props: { title: string; icon: IconName; hint: string; primary?: boolean; disabled: boolean; run: () => void }) {
  return (
    <Action kind={props.primary ? "primary" : "secondary"} aria-label={props.title} disabled={props.disabled} onClick={props.run}>
      <Icon name={props.icon} size={13} />
      {props.title}
      <KeyHint text={props.hint} onDark={props.primary} />
    </Action>
  );
}
