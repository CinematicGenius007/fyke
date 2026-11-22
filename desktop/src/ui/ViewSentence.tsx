// The saved view's rule reads as a sentence. Each chip edits one clause.
import { createSignal, For, onMount, Show } from "solid-js";
import { type Clause, Rule, type RuleState } from "../logic/Rule";
import { RuleSentence } from "../logic/RuleSentence";
import { app } from "../model/app";
import { feedName, type SavedView } from "../model/types";
import { float } from "./Float";
import { Action, Chip, Rule as Divider } from "./kit/Controls";
import { Icon } from "./kit/Icon";

const states: RuleState[] = ["any", "unread", "starred", "later"];
const periods = [1, 7, 30, 90];
const addTitles: Record<Clause, string> = {
  words: "About words…",
  host: "On a site…",
  path: "Under a path…",
  exclude: "Skipping a path…",
  within: "From recent days…",
  state: "Reading state…",
  scope: "From feeds…",
};

export function ViewSentence(props: { view: SavedView }) {
  const model = app();
  const parts = () => RuleSentence.parts(
    props.view.rule,
    (id) => {
      const feed = model.state.feeds.find((feed) => feed.id === id);
      return feed ? feedName(feed) : null;
    },
    (id) => model.state.folders.find((folder) => folder.id === id)?.name,
  );
  let addButton!: HTMLButtonElement;

  function edit(anchor: HTMLElement, clause: Clause, value?: string) {
    const { id, revision, rule } = props.view;
    const apply = (newRule: Rule) => {
      float.close(true);
      void model.setViewRule(id, revision, newRule);
    };
    switch (clause) {
      case "state":
        float.below(anchor, 180, states.map((state) => ({
          title: RuleSentence.stateWord(state),
          checked: (rule.state ?? "any") === state,
          run: () => apply(Rule.setState(rule, state)),
        })));
        break;
      case "within":
        float.below(anchor, 180, [
          ...periods.map((days) => ({
            title: RuleSentence.withinWords(days).replace(/^./, (letter) => letter.toUpperCase()),
            checked: rule.within_days === days,
            run: () => apply(Rule.setWithin(rule, days)),
          })),
          { title: "Any time", checked: !rule.within_days, run: () => apply(Rule.clear(rule, "within")) },
        ]);
        break;
      case "scope":
        float.custom(anchor, 260, () => <ScopeEditor rule={rule} apply={(feeds, folders) => apply(Rule.setScope(rule, feeds, folders))} />);
        break;
      case "words":
        float.custom(anchor, 280, () => <TextEditor title="About these words" value={rule.words ?? ""}
          option={{ label: "Any one of them is enough", enabled: rule.any_words === true }}
          remove={() => apply(Rule.clear(rule, clause))} apply={(text, any) => apply(Rule.setWords(rule, text, any))} />);
        break;
      case "host":
        float.custom(anchor, 280, () => <TextEditor title="On this site" value={rule.host ?? ""} placeholder="example.com"
          option={{ label: "Include its subdomains", enabled: rule.subdomains === true }}
          remove={() => apply(Rule.clear(rule, clause))} apply={(text, subdomains) => apply(Rule.setHost(rule, text, subdomains))} />);
        break;
      case "path":
        float.custom(anchor, 280, () => <TextEditor title="Under this path" value={rule.path_prefix ?? ""} placeholder="/blog/"
          remove={() => apply(Rule.clear(rule, clause))} apply={(text) => apply(Rule.setPath(rule, text))} />);
        break;
      case "exclude": {
        const withoutOld = value === undefined ? rule : Rule.removeExclude(rule, value);
        float.custom(anchor, 280, () => <TextEditor title="Skip this path" value={value ?? ""} placeholder="/jobs/"
          remove={() => apply(withoutOld)} apply={(text) => apply(Rule.addExclude(withoutOld, text))} />);
        break;
      }
    }
  }

  return (
    <div class="sentence" role="group" aria-label={`Rule: ${RuleSentence.text(parts())}`}>
      <For each={parts()}>{(part) => {
        if (part.kind === "joiner") return <span class="joiner">{part.text}</span>;
        let anchor!: HTMLButtonElement;
        return <Chip ref={anchor} text={part.text} selected={float.isAnchoredAt(anchor)}
          aria-label={`${part.clause}: ${part.text}`} onClick={() => edit(anchor, part.clause, part.value)} />;
      }}</For>
      <Chip ref={addButton} text="+" muted aria-label="Add to the rule" onClick={() => {
        float.below(addButton, 200, Rule.missing(props.view.rule).map((clause) => ({
          title: addTitles[clause],
          run: () => edit(addButton, clause),
        })));
      }} />
    </div>
  );
}

function ScopeEditor(props: { rule: Rule; apply: (feeds: number[], folders: number[]) => void }) {
  const model = app();
  const [feeds, setFeeds] = createSignal(props.rule.feeds ?? []);
  const [folders, setFolders] = createSignal(props.rule.folders ?? []);
  const everyFeed = () => feeds().length === 0 && folders().length === 0;
  const toggle = (values: number[], id: number) => values.includes(id) ? values.filter((found) => found !== id) : [...values, id];
  let initial!: HTMLButtonElement;
  onMount(() => initial.focus());
  return (
    <form class="rule-scope" onSubmit={(event) => {
      event.preventDefault();
      props.apply(feeds().toSorted((a, b) => a - b), folders().toSorted((a, b) => a - b));
    }}>
      <div class="rule-scope-list scroll">
        <ScopeChoice ref={(button) => initial = button} text="All feeds" checked={everyFeed()} change={() => {
          setFeeds([]);
          setFolders([]);
        }} />
        <For each={model.folderOutline()}>{({ folder, depth }) =>
          <ScopeChoice text={folder.name} indent={depth * 16} checked={folders().includes(folder.id)}
            change={() => setFolders((values) => toggle(values, folder.id))} />}
        </For>
        <For each={model.state.feeds}>{(feed) =>
          <ScopeChoice text={feedName(feed)} checked={feeds().includes(feed.id)}
            change={() => setFeeds((values) => toggle(values, feed.id))} />}
        </For>
      </div>
      <Divider />
      <div class="rule-editor-actions"><Action kind="primary" compact type="submit">Apply</Action></div>
    </form>
  );
}

function ScopeChoice(props: { ref?: (button: HTMLButtonElement) => void; text: string; checked: boolean; indent?: number; change: () => void }) {
  return (
    <button ref={props.ref} type="button" class="menu-row" role="checkbox" aria-checked={props.checked}
      style={{ "padding-left": `${8 + (props.indent ?? 0)}px` }} onClick={props.change}>
      <span class="menu-title">{props.text}</span>
      <Show when={props.checked}><Icon name="check" size={14} color="var(--unread)" /></Show>
    </button>
  );
}

function TextEditor(props: {
  title: string;
  value: string;
  placeholder?: string;
  option?: { label: string; enabled: boolean };
  remove: () => void;
  apply: (text: string, enabled: boolean) => void;
}) {
  const [text, setText] = createSignal(props.value);
  const [enabled, setEnabled] = createSignal(props.option?.enabled ?? false);
  let field!: HTMLInputElement;
  onMount(() => {
    field.focus();
    field.select();
  });
  return (
    <form class="rule-text-editor" onSubmit={(event) => {
      event.preventDefault();
      props.apply(text(), enabled());
    }}>
      <label>
        {props.title}
        <input ref={field} type="text" value={text()} placeholder={props.placeholder} onInput={(event) => setText(event.currentTarget.value)} />
      </label>
      <Show when={props.option}>{(option) => (
        <label class="rule-editor-toggle">
          <input type="checkbox" checked={enabled()} onChange={(event) => setEnabled(event.currentTarget.checked)} />
          {option().label}
        </label>
      )}</Show>
      <div class="rule-editor-actions">
        <Action kind="quiet" compact onClick={props.remove}>Remove</Action>
        <Action kind="primary" compact type="submit">Apply</Action>
      </div>
    </form>
  );
}
