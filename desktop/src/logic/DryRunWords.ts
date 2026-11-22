// What a routine would have done last week. Mirrors `DryRunWords` in
// gui/Sources/ReaderLogic/Logic.swift.

export const DryRunWords = {
  /** "Would have caught 38 articles over 5 days, about 8 each." */
  summary(counts: readonly number[]): string {
    const total = counts.reduce((a, b) => a + b, 0);
    const days = counts.filter((c) => c > 0).length;
    if (total <= 0) return "Nothing would have matched last week.";
    const noun = total === 1 ? "article" : "articles";
    if (days <= 1) return `Would have caught ${total} ${noun} on one day.`;
    // Swift's `rounded()` rounds halves away from zero; counts are positive, so Math.round agrees.
    const each = Math.round(total / days);
    return `Would have caught ${total} ${noun} over ${days} days, about ${each} each.`;
  },

  /**
   * Bar heights from 0 to 1, against the busiest day. A day with any match is at least
   * a sliver, so it never looks the same as an empty day.
   */
  bars(counts: readonly number[]): number[] {
    const top = counts.length ? Math.max(...counts) : 0;
    if (top <= 0) return counts.map(() => 0);
    return counts.map((c) => (c === 0 ? 0 : Math.max(0.12, c / top)));
  },
};
