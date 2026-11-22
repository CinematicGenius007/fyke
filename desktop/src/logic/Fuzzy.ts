// Matches typed letters to a title in order, with gaps allowed. Runs of letters and
// letters at the start of a word score higher, so "dbn" finds "Database Notes" and ranks
// it above a title where the letters are scattered.
// Mirrors `Fuzzy` in gui/Sources/ReaderLogic/Logic.swift. Positions count characters
// (code points), as Swift's do, not UTF-16 units.

export interface Match {
  score: number;
  /** Character offsets in the candidate that matched, for highlighting. */
  positions: number[];
}

const letterOrNumber = /[\p{L}\p{N}]/u;
const upper = /\p{Lu}/u;
const lower = /\p{Ll}/u;
const space = /\s/u;

function match(query: string, candidate: string): Match | null {
  const needle = Array.from(query.toLowerCase()).filter((c) => !space.test(c));
  if (needle.length === 0) return { score: 0, positions: [] };
  const original = Array.from(candidate);
  const hay = original.map((c) => c.toLowerCase());
  const positions: number[] = [];
  let score = 0;
  let at = 0;
  let previous = -2;
  for (const letter of needle) {
    let found = -1;
    for (let i = at; i < hay.length; i++) {
      if (hay[i] === letter) {
        found = i;
        break;
      }
    }
    if (found < 0) return null;
    let points = 1;
    if (found === previous + 1) points += 5;
    if (found === 0 || !letterOrNumber.test(original[found - 1])) points += 8;
    else if (upper.test(original[found]) && lower.test(original[found - 1])) points += 4;
    score += points;
    positions.push(found);
    previous = found;
    at = found + 1;
  }
  // A whole-word prefix is what people mean most often.
  if (needle.every((letter, i) => hay[i] === letter)) score += 10;
  // Shorter titles win ties: the match explains more of them.
  return { score: score * 100 - hay.length, positions };
}

/**
 * Candidates that match, best first. Equal scores keep their given order, so
 * destinations stay above commands.
 */
function rank<T>(query: string, items: readonly T[], text: (item: T) => string): { item: T; match: Match }[] {
  return items
    .map((item, index) => ({ item, index, match: match(query, text(item)) }))
    .filter((row): row is { item: T; index: number; match: Match } => row.match !== null)
    .sort((a, b) => (a.match.score !== b.match.score ? b.match.score - a.match.score : a.index - b.index))
    .map(({ item, match }) => ({ item, match }));
}

export const Fuzzy = { match, rank };
