import { For, type JSX, Show } from "solid-js";
import { Icon } from "../kit/Icon";
import { Rule, SectionLabel } from "../kit/Controls";

export function PaneScroll(props: { children: JSX.Element }) {
  return <div class="settings-scroll scroll"><div class="settings-column">{props.children}</div></div>;
}

export function Section(props: { title: string; detail?: string; trailing?: JSX.Element; children: JSX.Element }) {
  return (
    <section class="settings-section">
      <div class="settings-section-heading"><SectionLabel text={props.title} />{props.trailing}</div>
      <Show when={props.detail}><p class="settings-note">{props.detail}</p></Show>
      <Rule />
      {props.children}
    </section>
  );
}

export function Row(props: { title: string; detail?: string; last?: boolean; children: JSX.Element }) {
  return (
    <div class="setting-row" classList={{ last: props.last }}>
      <div class="setting-description">
        <div>{props.title}</div>
        <Show when={props.detail}><p>{props.detail}</p></Show>
      </div>
      <div class="setting-value">{props.children}</div>
    </div>
  );
}

export function Toggle(props: { label: string; on: boolean; disabled?: boolean; change: (on: boolean) => void }) {
  return <button type="button" role="switch" class="setting-switch" aria-label={props.label} aria-checked={props.on} disabled={props.disabled} onClick={() => props.change(!props.on)}><span /></button>;
}

export type Option<T> = { value: T; label: string };

export function Select<T extends string | number>(props: { label: string; value: T; options: readonly Option<T>[]; width?: number; disabled?: boolean; change: (value: T) => void }) {
  return (
    <div class="setting-select" style={{ width: `${props.width ?? 160}px` }}>
      <select aria-label={props.label} value={String(props.value)} disabled={props.disabled}
        onChange={(event) => {
          const option = props.options.find((item) => String(item.value) === event.currentTarget.value);
          if (option) props.change(option.value);
        }}>
        <For each={props.options}>{(option) => <option value={String(option.value)}>{option.label}</option>}</For>
      </select>
      <Icon name="down" size={12} />
    </div>
  );
}

export function Slider(props: { label: string; value: number; min: number; max: number; step: number; last?: boolean; change: (value: number) => void }) {
  return (
    <Row title={props.label} last={props.last}>
      <input class="setting-range" type="range" aria-label={props.label} min={props.min} max={props.max} step={props.step} value={props.value}
        onInput={(event) => props.change(event.currentTarget.valueAsNumber)} />
      <span class="setting-number">{props.value.toFixed(props.step < 1 ? 1 : 0)}</span>
    </Row>
  );
}
