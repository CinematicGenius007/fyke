// Filled once starred. Until then it shows only on the row in use or under the
// pointer, so a long list stays quiet. It keeps its place while hidden, so the row
// around it never moves.
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
      <Icon name="star" size={16} filled={props.row.starred} />
    </button>
  );
}
