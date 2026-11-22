// The sidebar (gui/Sources/Reader/Sidebar.swift): places, views, the feed tree, then
// Routines and the status line. Rows are 32 high; indent comes from SidebarIndent.
import { For, type JSX, Match, Show, Switch } from "solid-js";
import { SidebarIndent } from "../logic/SidebarIndent";
import { app, type Place } from "../model/app";
import { prefs } from "../model/prefs";
import type { Feed, Folder, SavedView } from "../model/types";
import { feedName } from "../model/types";
import { Dates } from "./format";
import { Count, Dot, Rule, SectionLabel, Spinner, SymbolButton } from "./kit/Controls";
import { Icon, type IconName } from "./kit/Icon";

type TreeRow = { kind: "folder"; folder: Folder; depth: number } | { kind: "feed"; feed: Feed; depth: number };

/** One destination row: icon, name, and whatever trails it. */
export function SidebarRow(props: {
  title: string;
  icon?: IconName;
  depth?: number;
  selected: boolean;
  muted?: boolean;
  medium?: boolean;
  label?: string;
  onClick: () => void;
  children?: JSX.Element;
  lead?: JSX.Element;
}) {
  return (
    <button
      type="button"
      class="sidebar-row"
      classList={{ selected: props.selected }}
      style={{ "padding-left": `${SidebarIndent.leading(props.depth ?? 0)}px` }}
      aria-label={props.label ?? props.title}
      aria-current={props.selected ? "page" : undefined}
      onClick={() => props.onClick()}
    >
      <Show when={props.icon}>{(icon) => <Icon name={icon()} size={14} class="row-icon" />}</Show>
      {props.lead}
      <span class="row-title" classList={{ muted: props.muted, medium: props.medium }}>
        {props.title}
      </span>
      <span class="row-trailing">{props.children}</span>
    </button>
  );
}

export function Sidebar() {
  const model = app();
  const go = (place: Place) => () => model.go(place);

  function rows(parent: number | null = null, depth = 0): TreeRow[] {
    const out: TreeRow[] = [];
    for (const folder of model.childFolders(parent)) {
      out.push({ kind: "folder", folder, depth });
      if (!prefs().ui.collapsed_folders.includes(folder.id)) out.push(...rows(folder.id, depth + 1));
    }
    const feedDepth = SidebarIndent.feedDepth(parent === null ? null : depth - 1);
    for (const feed of model.state.feeds.filter((f) => (f.folder_id ?? null) === parent)) out.push({ kind: "feed", feed, depth: feedDepth });
    return out;
  }

  return (
    <nav class="sidebar" aria-label="Sources">
      <SidebarRow title="Search" icon="magnifyingglass" selected={false} onClick={() => model.commands.show()}>
        <span class="row-note">Ctrl+K</span>
      </SidebarRow>
      <SidebarRow title="Today" icon="calendar" selected={model.isShowing({ kind: "today" })} onClick={go({ kind: "today" })}>
        <Switch>
          <Match when={model.briefJob()}>
            <Spinner size={10} />
          </Match>
          <Match when={model.hasNewBrief()}>
            <Dot color="var(--unread)" label="New brief" />
          </Match>
        </Switch>
      </SidebarRow>
      <SidebarRow title="All" icon="tray" selected={model.isShowing({ kind: "all" })} onClick={go({ kind: "all" })}>
        <Show when={model.state.feeds.length > 0}>
          <Count value={model.totalUnread()} />
        </Show>
      </SidebarRow>
      <SidebarRow title="Starred" icon="star" selected={model.isShowing({ kind: "starred" })} onClick={go({ kind: "starred" })}>
        <Show when={model.totalStarred() > 0}>
          <Count value={model.totalStarred()} quiet />
        </Show>
      </SidebarRow>
      <SidebarRow title="Catch up" icon="rectangle.stack" selected={false} onClick={() => undefined}>
        <span class="row-note">Ctrl+J</span>
      </SidebarRow>

      <div class="sidebar-scroll scroll">
        <div class="sidebar-stack">
          <SectionHeader title="Views" help="Save a search as a view (Ctrl+F, then Ctrl+S)" onAdd={() => model.search.show()} />
          <Show when={model.library.state.views.length === 0}>
            <div class="sidebar-note">{model.library.state.available ? "Search, then Ctrl+S to keep it here" : "Views need a newer Fyke service"}</div>
          </Show>
          <For each={model.library.state.views}>{(view) => <ViewRow view={view} />}</For>

          <SectionHeader title="Feeds" help="Add a feed or a folder" onAdd={() => model.set("showingAddFeed", true)} />
          <For each={rows()}>
            {(row) => (
              <Switch>
                <Match when={row.kind === "folder" && row}>{(r) => <FolderRow folder={(r() as { folder: Folder }).folder} depth={row.depth} />}</Match>
                <Match when={row.kind === "feed" && row}>{(r) => <FeedRow feed={(r() as { feed: Feed }).feed} depth={row.depth} />}</Match>
              </Switch>
            )}
          </For>
        </div>
      </div>

      <SidebarRow title="Routines" icon="clock.arrow.circlepath" selected={model.isShowing({ kind: "routines" })} onClick={go({ kind: "routines" })}>
        <Show when={model.library.nextRoutine()?.nextRunAt}>{(next) => <span class="row-note">Next {Dates.time(next())}</span>}</Show>
      </SidebarRow>
      <StatusLine />
    </nav>
  );
}

function SectionHeader(props: { title: string; help: string; onAdd: () => void }) {
  return (
    <div class="section-header">
      <SectionLabel text={props.title} />
      <SymbolButton icon="plus" label={props.help} size={20} iconSize={13} onClick={props.onAdd} />
    </div>
  );
}

function ViewRow(props: { view: SavedView }) {
  const model = app();
  return (
    <SidebarRow
      title={props.view.name}
      icon="line.3.horizontal.decrease"
      selected={model.isShowing({ kind: "view", id: props.view.id })}
      onClick={() => model.go({ kind: "view", id: props.view.id })}
    >
      <Count value={props.view.unread} quiet={props.view.unread === 0} />
    </SidebarRow>
  );
}

function FolderRow(props: { folder: Folder; depth: number }) {
  const model = app();
  const closed = () => prefs().ui.collapsed_folders.includes(props.folder.id);
  const unread = () => model.feedsInside(props.folder.id).reduce((sum, f) => sum + f.unread, 0);
  const selected = () => model.isShowing({ kind: "folder", id: props.folder.id });
  return (
    <div class="folder-row">
      <SidebarRow
        title={props.folder.name}
        depth={props.depth}
        selected={selected()}
        medium={!selected()}
        label={`${props.folder.name}, folder`}
        lead={<span class="row-icon" />}
        onClick={() => model.go({ kind: "folder", id: props.folder.id })}
      >
        <Show when={unread() > 0}>
          <Count value={unread()} />
        </Show>
      </SidebarRow>
      <button
        type="button"
        class="chevron"
        style={{ left: `${SidebarIndent.leading(props.depth)}px` }}
        title={closed() ? "Open folder" : "Close folder"}
        aria-label={closed() ? `Open ${props.folder.name}` : `Close ${props.folder.name}`}
        onClick={() => model.toggleFolder(props.folder.id)}
      >
        <Icon name={closed() ? "right" : "down"} size={10} stroke={2} />
      </button>
    </div>
  );
}

function FeedRow(props: { feed: Feed; depth: number }) {
  const model = app();
  const failing = () => model.isFailing(props.feed);
  return (
    <SidebarRow
      title={feedName(props.feed)}
      depth={props.depth}
      selected={model.isShowing({ kind: "feed", id: props.feed.id })}
      muted={props.feed.unread === 0 && !failing()}
      onClick={() => model.go({ kind: "feed", id: props.feed.id })}
    >
      <Switch>
        <Match when={failing()}>
          <span class="row-warning" title={`${feedName(props.feed)} is not loading`}>
            <Icon name="warning" size={13} />
          </span>
        </Match>
        <Match when={props.feed.unread > 0}>
          <Count value={props.feed.unread} />
        </Match>
      </Switch>
    </SidebarRow>
  );
}

/** The one line of background work. It opens Activity. */
function StatusLine() {
  const model = app();
  return (
    <div class="status-line">
      <Rule class="status-rule" />
      <button
        type="button"
        class="sidebar-row status"
        classList={{ selected: model.state.showingActivity }}
        aria-label={`Activity: ${model.statusWords()}`}
        onClick={() => model.set("showingActivity", (v) => !v)}
      >
        <span class="row-icon centered">
          <Show when={!model.statusIsBusy()} fallback={<Spinner size={10} />}>
            <Dot color={model.statusNeedsYou() ? "var(--unread)" : "var(--control)"} />
          </Show>
        </span>
        <span class="status-words" classList={{ attention: model.statusNeedsYou() }}>
          {model.statusWords()}
        </span>
      </button>
      <SymbolButton
        icon="gearshape"
        label="Settings (Ctrl+,)"
        selected={model.state.showingSettings}
        onClick={() => (model.state.showingSettings ? model.set("showingSettings", false) : model.openSettings())}
      />
    </div>
  );
}
