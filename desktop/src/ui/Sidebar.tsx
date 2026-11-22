// The sidebar (gui/Sources/Reader/Sidebar.swift): places, views, the feed tree, then
// Routines and the status line. Rows are 32 high; indent comes from SidebarIndent.
import { For, type JSX, Match, onMount, Show, Switch } from "solid-js";
import { SidebarIndent } from "../logic/SidebarIndent";
import { app, type Place } from "../model/app";
import { prefs } from "../model/prefs";
import type { Feed, Folder, SavedView } from "../model/types";
import { feedName } from "../model/types";
import { Dates } from "./format";
import { Count, Dot, Rule, SectionLabel, Spinner, SymbolButton } from "./kit/Controls";
import { float, type MenuItem } from "./Float";
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
  onMenu?: (event: MouseEvent) => void;
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
      onContextMenu={(event) => props.onMenu?.(event)}
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

/** The text field that takes a row's place while it is renamed. Return keeps the
 * name; Esc or a click elsewhere leaves it as it was. */
function RenameField(props: { name: string; commit: (name: string) => void }) {
  const model = app();
  let field!: HTMLInputElement;
  let done = false;
  onMount(() => {
    field.value = props.name;
    field.focus();
    field.select();
  });
  const cancel = () => {
    if (done) return;
    done = true;
    model.set("renaming", null);
  };
  return (
    <input
      ref={field}
      class="rename-field"
      type="text"
      spellcheck={false}
      autocomplete="off"
      aria-label={`Rename ${props.name}`}
      onKeyDown={(event) => {
        if (event.isComposing) return;
        if (event.key === "Enter") {
          event.preventDefault();
          done = true;
          props.commit(field.value);
        } else if (event.key === "Escape") {
          event.preventDefault();
          cancel();
        }
      }}
      onBlur={cancel}
    />
  );
}

const isRenaming = (kind: "feed" | "folder" | "view", id: number) => {
  const renaming = app().state.renaming;
  return renaming?.kind === kind && renaming.id === id;
};

/** The menu a view row opens (Views.swift ViewMenu). Brief, catch-up and routine rows
 * join with those features. */
function viewMenu(view: SavedView): MenuItem[] {
  const model = app();
  return [
    { title: "Rename", run: () => model.set("renaming", { kind: "view", id: view.id }) },
    { title: "Mark all read", run: () => model.markAllRead({ view: view.id }) },
    "rule",
    { title: "Move up", run: () => model.moveView(view.id, -1) },
    { title: "Move down", run: () => model.moveView(view.id, 1) },
    "rule",
    { title: "Remove view", run: () => void model.removeView(view.id) },
  ];
}

/** Sidebar.swift FolderRow `menu`. Catch up joins with catch-up. */
function folderMenu(folder: Folder): MenuItem[] {
  const model = app();
  return [
    { title: "Rename", run: () => model.set("renaming", { kind: "folder", id: folder.id }) },
    { title: "New folder inside", run: () => void model.newFolder(folder.id) },
    {
      title: "Add feed here",
      run: () => {
        model.set("addFeedFolder", folder.id);
        model.set("showingAddFeed", true);
      },
    },
    { title: "Mark all read", run: () => model.markAllRead({ folder: folder.id }) },
    "rule",
    { title: "Delete folder…", run: () => model.set("confirmation", { kind: "deleteFolder", folder }) },
  ];
}

/** Sidebar.swift FeedMenu, with Move to › beside it. */
function feedMenu(feed: Feed): MenuItem[] {
  const model = app();
  const site = feed.site_url;
  return [
    { title: "Refresh", run: () => void model.refreshFeed(feed.id) },
    { title: "Rename", run: () => model.set("renaming", { kind: "feed", id: feed.id }) },
    { title: "Move to", submenu: true, run: (row) => float.side(row, 184, moveMenu(feed)) },
    { title: "Mark all read", run: () => model.markAllRead({ feed: feed.id }) },
    ...(site ? [{ title: "Open site", run: () => model.openLink(site) }] : []),
    "rule",
    { title: "Remove feed…", run: () => model.set("confirmation", { kind: "removeFeed", feed }) },
  ];
}

function moveMenu(feed: Feed): MenuItem[] {
  const model = app();
  const here = feed.folder_id ?? null;
  return [
    { title: "Top level", checked: here === null, run: () => void model.moveFeed(feed.id, null) },
    ...model.folderOutline().map(
      (row): MenuItem => ({ title: row.folder.name, checked: here === row.folder.id, indent: row.depth * 16, run: () => void model.moveFeed(feed.id, row.folder.id) }),
    ),
    "rule",
    { title: "New folder", run: () => void model.newFolder(null, feed.id) },
  ];
}

function ViewRow(props: { view: SavedView }) {
  const model = app();
  return (
    <Show
      when={!isRenaming("view", props.view.id)}
      fallback={
        <div class="sidebar-rename" style={{ "padding-left": `${SidebarIndent.leading(0)}px` }}>
          <Icon name="line.3.horizontal.decrease" size={14} class="row-icon" />
          <RenameField name={props.view.name} commit={(name) => model.renameView(props.view.id, name)} />
          <span class="rename-note">↵ to keep</span>
        </div>
      }
    >
      <SidebarRow
        title={props.view.name}
        icon="line.3.horizontal.decrease"
        selected={model.isShowing({ kind: "view", id: props.view.id })}
        onClick={() => model.go({ kind: "view", id: props.view.id })}
        onMenu={(event) => float.menu(event, 220, viewMenu(props.view))}
      >
        <Count value={props.view.unread} quiet={props.view.unread === 0} />
      </SidebarRow>
    </Show>
  );
}

function FolderRow(props: { folder: Folder; depth: number }) {
  const model = app();
  const closed = () => prefs().ui.collapsed_folders.includes(props.folder.id);
  const unread = () => model.feedsInside(props.folder.id).reduce((sum, f) => sum + f.unread, 0);
  const selected = () => model.isShowing({ kind: "folder", id: props.folder.id });
  const chevron = () => (
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
  );
  return (
    <div class="folder-row" onContextMenu={(event) => float.menu(event, 204, folderMenu(props.folder))}>
      <Show
        when={!isRenaming("folder", props.folder.id)}
        fallback={
          <div class="sidebar-rename" style={{ "padding-left": `${SidebarIndent.leading(props.depth)}px` }}>
            <span class="row-icon" />
            <RenameField name={props.folder.name} commit={(name) => model.renameFolder(props.folder.id, name)} />
          </div>
        }
      >
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
      </Show>
      {chevron()}
    </div>
  );
}

function FeedRow(props: { feed: Feed; depth: number }) {
  const model = app();
  const failing = () => model.isFailing(props.feed);
  return (
    <Show
      when={!isRenaming("feed", props.feed.id)}
      fallback={
        <div class="sidebar-rename" style={{ "padding-left": `${SidebarIndent.leading(props.depth) - 4}px` }}>
          <RenameField name={feedName(props.feed)} commit={(name) => model.renameFeed(props.feed.id, name)} />
        </div>
      }
    >
      <SidebarRow
        title={feedName(props.feed)}
        depth={props.depth}
        selected={model.isShowing({ kind: "feed", id: props.feed.id })}
        muted={props.feed.unread === 0 && !failing()}
        onClick={() => model.go({ kind: "feed", id: props.feed.id })}
        onMenu={(event) => float.menu(event, 204, feedMenu(props.feed))}
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
    </Show>
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
