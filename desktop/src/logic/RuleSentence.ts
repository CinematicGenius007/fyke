// The rule as words, some of which can be tapped. "Unread from Engineering about storage
// or query skipping /jobs/" is two joiners and four chips.
// Mirrors `RuleSentence` and `SentencePart` in gui/Sources/ReaderLogic/Rule.swift.
import { type Clause, Rule, type RuleState } from "./Rule";

export type SentencePart =
  | { kind: "chip"; clause: Clause; text: string; value?: string }
  | { kind: "joiner"; text: string };

const chip = (clause: Clause, text: string, value?: string): SentencePart =>
  value === undefined ? { kind: "chip", clause, text } : { kind: "chip", clause, text, value };
const joiner = (text: string): SentencePart => ({ kind: "joiner", text });

/**
 * The sentence's first word. With no state the subject is the plain noun, so the
 * sentence still reads as one: "Articles from all feeds about needle".
 */
function stateWord(state: RuleState | null | undefined): string {
  switch (state ?? "any") {
    case "any":
      return "Articles";
    case "unread":
      return "Unread";
    case "starred":
      return "Starred";
    case "later":
      return "Later";
  }
}

function withinWords(days: number): string {
  switch (days) {
    case 1:
      return "last day";
    case 7:
      return "last week";
    case 30:
    case 31:
      return "last month";
    default:
      return `last ${days} days`;
  }
}

function scopeWords(names: string[]): string {
  switch (names.length) {
    case 0:
      return "all feeds";
    case 1:
      return names[0];
    case 2:
      return `${names[0]} and ${names[1]}`;
    default:
      return `${names[0]} and ${names.length - 1} more`;
  }
}

/** Names that a deleted feed or folder no longer has read "Deleted source", as the daemon's sentence does. */
function parts(
  input: Rule,
  feedName: (id: number) => string | null | undefined,
  folderName: (id: number) => string | null | undefined,
): SentencePart[] {
  const rule = Rule.normalized(input);
  const out: SentencePart[] = [chip("state", stateWord(rule.state)), joiner("from")];
  const names = [
    ...(rule.folders ?? []).map((id) => folderName(id) ?? "Deleted source"),
    ...(rule.feeds ?? []).map((id) => feedName(id) ?? "Deleted source"),
  ];
  out.push(chip("scope", scopeWords(names)));
  if (rule.words != null) {
    out.push(joiner("about"));
    const tokens = rule.words.split(" ");
    out.push(chip("words", tokens.join(rule.any_words === true ? " or " : " "), rule.words));
  }
  if (rule.host != null) {
    out.push(joiner("on"));
    out.push(chip("host", rule.subdomains === true ? `any ${rule.host}` : rule.host, rule.host));
  }
  if (rule.path_prefix != null) {
    out.push(joiner("under"));
    out.push(chip("path", rule.path_prefix));
  }
  (rule.exclude_path_prefix ?? []).forEach((path, index) => {
    out.push(joiner(index === 0 ? "skipping" : "and"));
    out.push(chip("exclude", path, path));
  });
  if (rule.within_days != null) {
    out.push(joiner("from the"));
    out.push(chip("within", withinWords(rule.within_days)));
  }
  return out;
}

/** The sentence as one line, for accessibility labels and the palette. */
function text(list: readonly SentencePart[]): string {
  return list.map((part) => part.text).join(" ");
}

export const RuleSentence = { stateWord, withinWords, scopeWords, parts, text };
