import { createResource, createSignal, For, onCleanup, onMount, Show } from "solid-js";
import { app, words } from "../../model/app";
import { prefs } from "../../model/prefs";
import type { Writer } from "../../model/types";
import { thisComputer } from "../../platform";
import { transport } from "../../transport";
import { Action, Spinner } from "../kit/Controls";
import { PaneScroll, Row, Section, Select } from "./Controls";

const tiers = [
  { value: "read", label: "Never" }, { value: "annotate", label: "Reading state only" }, { value: "manage", label: "Everything" },
];

export function Agents() {
  const model = app();
  const settings = prefs();
  const [info] = createResource(() => transport().desktopPaths());
  const [checking, setChecking] = createSignal<string | null>(null);
  const [problem, setProblem] = createSignal<string | null>(null);
  const [copied, setCopied] = createSignal(false);
  let copyTimer: ReturnType<typeof setTimeout> | undefined;
  onCleanup(() => clearTimeout(copyTimer));
  onMount(() => { void model.library.loadWriters().catch((error) => setProblem(words(error))); });

  const tier = () => settings.ui.agent_tier;
  const snippet = () => `{ "mcpServers": { "fyke": {\n    "command": ${JSON.stringify(info()?.program ?? "fyke")},\n    "args": ${tier() === "read" ? '["mcp"]' : `["mcp", "--tier", ${JSON.stringify(tier())}]`} } } }`;
  const display = (path: string) => {
    const home = info()?.home;
    return home && path.startsWith(home + "/") ? "~" + path.slice(home.length) : path;
  };
  const status = (writer: Writer) => writer.problem ?? (writer.found ? ["Ready", writer.version, writer.path && `found at ${display(writer.path)}`].filter(Boolean).join(" · ") : `Not found on ${thisComputer}`);

  async function change(writer: Writer, operation: () => Promise<unknown>) {
    setChecking(writer.id);
    setProblem(null);
    try {
      await operation();
      await model.library.loadWriters();
    } catch (error) {
      setProblem(words(error));
    } finally {
      setChecking(null);
    }
  }

  async function profile(writer: Writer, choose: boolean) {
    await change(writer, async () => {
      const folder = choose ? await transport().chooseFolder("Choose the folder Claude Code keeps its sign-in in") : "";
      if (folder !== null) await transport().call("config.set", { ai: { claude_profile: folder } });
    });
  }

  async function copy() {
    try {
      await navigator.clipboard.writeText(snippet());
      setCopied(true);
      clearTimeout(copyTimer);
      copyTimer = setTimeout(() => setCopied(false), 2000);
    } catch (error) {
      setProblem(words(error));
    }
  }

  return (
    <PaneScroll>
      <Section title="Who writes your briefs" detail={`Fyke hands the selected articles and your recipe to an agent already on ${thisComputer}. Fyke itself sends nothing anywhere else.`}>
        <Show when={model.library.state.writers.length} fallback={
          <p class="settings-note writer-status">{model.library.state.available ? "Looking for Codex and Claude Code…" : "Writers need a newer Fyke service. Quit and open Fyke again."}</p>
        }>
          <For each={model.library.state.writers}>{(writer) => (
            <div class="writer">
              <div class="writer-row">
                <span class="writer-badge" classList={{ found: writer.found, default: writer.selected }} aria-hidden="true">{writer.id === "codex" ? "Cx" : writer.name[0]}</span>
                <div class="writer-name"><strong>{writer.name}</strong><p class="settings-note">{status(writer)}</p></div>
                <Show when={checking() === writer.id} fallback={<Action kind="quiet" disabled={checking() !== null} aria-label={`Check ${writer.name}`} onClick={() => void change(writer, () => transport().call("writers.check", { writer: writer.id }, { slow: true }))}>Check</Action>}>
                  <Spinner size={12} />
                </Show>
                <Show when={writer.selected} fallback={<Action disabled={!writer.found || checking() !== null} aria-label={`Make default: ${writer.name}`} onClick={() => void change(writer, () => transport().call("config.set", { ai: { writer: writer.id } }))}>Make default</Action>}>
                  <span class="writer-default">Default</span>
                </Show>
              </div>
              <Show when={writer.id === "claude" && writer.installed}>
                <div class="writer-profile">
                  <div class="writer-name"><span>Profile folder</span>
                    <p class="settings-note">{writer.profile ? display(writer.profile) : "Claude Code's default (~/.claude)"}</p></div>
                  <Show when={writer.profile}><Action kind="quiet" disabled={checking() !== null} onClick={() => void profile(writer, false)}>Use default</Action></Show>
                  <Action disabled={checking() !== null} onClick={() => void profile(writer, true)}>Choose…</Action>
                </div>
              </Show>
            </div>
          )}</For>
        </Show>
        <Show when={problem()}><p role="status">{problem()}</p></Show>
      </Section>
      <Section title="Let agents use Fyke" detail="Agents connected over MCP can search and read your articles. Article text can try to mislead an agent, so changes start off.">
        <Row title="Read articles, views and briefs"><span class="settings-note">Always on</span></Row>
        <Row title="Make changes" detail="Mark read and star; or also edit views, recipes and routines" last>
          <Select label="What agents may change" width={180} value={tier()} options={tiers} change={(value) => settings.update((draft) => { draft.agent_tier = value; })} />
        </Row>
        <div class="mcp-caption"><span>Add Fyke to another agent with this configuration.</span><Action onClick={() => void copy()}>{copied() ? "Copied" : "Copy MCP config"}</Action></div>
        <pre class="mcp-config selectable">{snippet()}</pre>
      </Section>
    </PaneScroll>
  );
}
