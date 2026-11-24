// Filled once starred. Until then it appears only on the row in use or under the
// pointer, so a long list stays quiet.
import { app } from "../model/app";
import type { EntrySummary } from "../model/types";
import { Icon } from "./kit/Icon";

export function StarToggle(props: { row: EntrySummary; showing: boolean; class?: string }) {
  const model = app();
  return (
    <button
      type="button"
      class={`star-toggle ${props.class ?? ""}`}
      classList={{ on: props.row.starred, showing: props.showing }}
      title={props.row.starred ? "Remove star" : "Star"}
      aria-label={props.row.starred ? "Remove star" : "Star"}
      onClick={() => model.toggleStar(props.row.id)}
    >
      <Icon name="star" size={14} filled={props.row.starred} />
    </button>
  );
}
