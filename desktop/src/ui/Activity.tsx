// Background work stays in the sidebar until the reader asks to see it.
import { For, Show } from "solid-js";
import { Plural } from "../logic/Plural";
import { app } from "../model/app";
import { feedName, jobIsWriting, type Feed, type Job } from "../model/types";
import { writerName } from "./Artifact";
import { float } from "./Float";
import { Dates } from "./format";
import { Action, Dot, Rule, SectionLabel, Spinner, SymbolButton } from "./kit/Controls";
import { Icon } from "./kit/Icon";
import { isSafeLink } from "./links";

export function Activity() {
  const model = app();
  const active = model.library.activeJobs;
  const failed = model.library.needsYou;
  const earlier = () => {
    const start = new Date();
    start.setHours(0, 0, 0, 0);
    const failures = new Set(failed().map((job) => job.id));
    const running = new Set(active().map((job) => job.id));
    return model.library.state.jobs.filter((job) =>
      !running.has(job.id) && !failures.has(job.id) && (job.finishedAt ?? job.createdAt ?? new Date(0)) >= start,
    ).slice(0, 6);
  };
  const describe = (job: Job) => {
    const name = model.library.routine(job.routineId)?.name;
    return name ? `${job.title} · ${name}` : job.title;
  };

  return (
    <section class="activity-panel" aria-label="Activity">
      <header>
        <h2>Activity</h2>
        <Action kind="quiet" compact onClick={() => model.refresh()}>Refresh feeds</Action>
      </header>
      <Rule />
      <div class="activity-groups scroll">
        <SectionLabel text="Now" />
        <Show when={active().length} fallback={<p>Nothing running. Feeds refresh on their own.</p>}>
          <For each={active()}>{(job) => (
            <div class="activity-running">
              <div class="activity-job">
                <Spinner size={12} />
                <span>{describe(job)}</span>
                <Show when={job.writer}><small>{writerName(job.writer)}</small></Show>
                <SymbolButton icon="close" size={24} label={`Cancel ${job.title.toLowerCase()}`} onClick={() => void model.cancelJob(job.id)} />
              </div>
              <Show when={job.total && job.total > 0}>
                <progress value={job.progress ?? 0} max={job.total!} aria-label={job.title} />
              </Show>
            </div>
          )}</For>
        </Show>
        <Show when={failed().length || model.failingFeeds().length}>
          <SectionLabel text="Needs you" />
          <For each={failed()}>{(job) => (
            <div class="activity-failure">
              <Dot color="var(--unread)" />
              <div><strong>{describe(job)} did not finish</strong><p>{job.error ?? "It stopped."} Your articles are untouched.</p></div>
              <Action kind="inverse" compact onClick={() => {
                float.close(true);
                if (jobIsWriting(job)) void model.runBrief();
                else model.refresh();
              }}>Try again</Action>
            </div>
          )}</For>
          <Show when={model.failingFeeds().length}>
            <div class="activity-failure activity-feed">
              <Icon name="warning" size={12} />
              <div>
                <strong>{model.failingFeeds().length === 1 ? `${feedName(model.failingFeeds()[0])} is not loading` : `${model.failingFeeds().length} feeds are not loading`}</strong>
                <p>Their articles so far are kept. Fyke keeps trying on its own.</p>
              </div>
              <Action compact onClick={() => {
                float.close();
                model.showFeedHealth(model.failingFeeds()[0].id);
              }}>Show</Action>
            </div>
          </Show>
        </Show>
        <Show when={earlier().length}>
          <SectionLabel text="Earlier today" />
          <For each={earlier()}>{(job) => (
            <div class="activity-done activity-job">
              <Icon name={job.state === "done" ? "check" : job.state === "cancelled" ? "close" : "warning"} size={12} />
              <span>{describe(job)}{job.state === "cancelled" ? " · cancelled" : ""}</span>
              <small>{job.finishedAt || job.createdAt ? Dates.time((job.finishedAt ?? job.createdAt)!) : ""}</small>
            </div>
          )}</For>
        </Show>
      </div>
      <Rule />
      <footer>
        <Action kind="link" compact onClick={() => { float.close(); model.go({ kind: "routines" }); }}>Routines</Action>
        <Show when={model.library.nextRoutine()}>{(next) => <small>Next: {next().name}, {Dates.time(next().nextRunAt!)}</small>}</Show>
      </footer>
    </section>
  );
}

export function FeedHealth(props: { feed: Feed }) {
  const model = app();
  const failing = () => model.isFailing(props.feed);
  const count = () => Plural.count(props.feed.entries, "article");
  const address = () => props.feed.site_url;
  return (
    <section class="feed-health" aria-label="Feed health">
      <header>
        <h2>{feedName(props.feed)}{failing() ? " is not loading" : ""}</h2>
        <p>{props.feed.error_count === 0 ? `Its last fetch worked. Its ${count()} are here.`
          : `It failed ${Plural.count(props.feed.error_count, "time")} in a row. Its ${count()} are kept, and Fyke keeps trying on its own.`}</p>
      </header>
      <Show when={props.feed.last_error}>{(error) => <div class="feed-health-error"><span>Error</span><code class="selectable">{error()}</code></div>}</Show>
      <footer>
        <Show when={isSafeLink(address()) && address()}>{(url) => (
          <Action kind="quiet" compact onClick={() => { float.close(true); model.openLink(url()); }}>Open site</Action>
        )}</Show>
        <Action kind="primary" compact onClick={() => { float.close(true); void model.refreshFeed(props.feed.id); }}>
          {failing() ? "Try again now" : "Refresh now"}
        </Action>
      </footer>
    </section>
  );
}
